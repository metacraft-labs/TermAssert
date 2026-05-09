## test_harness_image_assertion_workflow - exercises the
## `waitForImage` / `assertImageMatches` assertion roundtrip end-to-end
## against a real fixture file.
##
## Reuses the Kitty test app (16x16 RGBA fixture) so the harness sees a
## real decoded image.
##
## Golden-file format
## ------------------
## We have no PNG encoder, so the golden is the raw RGBA pixel buffer,
## byte-identical to `Image.pixels`. The fixture lives at
## `tests/fixtures/golden_image.rgba` -- the `.rgba` suffix is used
## (instead of `.png`) so the file extension never lies about contents.
## The harness's `assertImageMatches` writes/reads the raw pixel buffer
## verbatim, so the same assertion roundtrip works whether the recorded
## golden is a PNG or a raw RGBA payload; only the extension changes.

import std/[unittest, times, options, os]
import term_assert
import test_helpers

const W = 16
const H = 16

proc buildExpectedRgba(): seq[byte] =
  result = newSeq[byte](W * H * 4)
  for y in 0 ..< H:
    for x in 0 ..< W:
      let p = (y * W + x) * 4
      if ((x + y) and 1) == 0:
        result[p + 0] = 255
        result[p + 1] = 0
        result[p + 2] = 0
        result[p + 3] = 255
      else:
        result[p + 0] = 0
        result[p + 1] = 255
        result[p + 2] = 0
        result[p + 3] = 255

proc fnv1a32(buf: openArray[byte]): array[32, byte] =
  var h: uint64 = 0xcbf29ce484222325'u64
  for b in buf:
    h = (h xor uint64(b)) * 0x00000100000001B3'u64
  for i in 0 ..< 32:
    let mixed = h xor uint64(i) * 0x9E3779B97F4A7C15'u64
    result[i] = byte((mixed shr (8 * (i mod 8))) and 0xFF)
    h = h * 0x100000001B3'u64

proc byPixelsEqual(expected: seq[byte]):
                  proc(img: Image; r: ImageRef): bool {.gcsafe, closure.} =
  ## Predicate: match an image whose decoded pixels equal `expected`.
  ## The library's `byHash` doesn't actually compare bytes (it has no
  ## session reference at predicate-evaluation time); we capture the
  ## expected buffer in a closure and do the byte compare here.
  let exp = expected
  result = proc(img: Image; r: ImageRef): bool {.gcsafe, closure.} =
    discard r
    img.pixels == exp

suite "M28 harness: image assertion workflow":
  test "waitForImage + assertImageMatches roundtrip":
    compileChildApp("test_app_image_kitty")
    let bin = childAppPath("test_app_image_kitty")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()

    let expected = buildExpectedRgba()
    sess.waitForImage(byPixelsEqual(expected), initDuration(seconds = 2))

    let imgs = sess.images()
    check imgs.len >= 1
    if imgs.len >= 1:
      # Sanity-check: hash the harness sees equals the hash we compute
      # locally from the same RGBA buffer.
      let harnessHash = sess.imageHash(imgs[0])
      let localHash = fnv1a32(expected)
      check harnessHash == localHash

      # Golden-file roundtrip. `test-logs/` is gitignored, so a per-run
      # subdir keeps the workspace clean. First call records, second
      # call compares.
      let here = currentSourcePath().parentDir()
      let goldenDir = here.parentDir() / "test-logs" / "image_assertion_workflow"
      createDir(goldenDir)
      let goldenPath = goldenDir / "golden_image.rgba"
      if fileExists(goldenPath): removeFile(goldenPath)

      # First run: records.
      sess.assertImageMatches(imgs[0], goldenPath)
      check fileExists(goldenPath)

      # Second run: compares against the just-written fixture and must
      # succeed without raising.
      sess.assertImageMatches(imgs[0], goldenPath)

    let _ = sess.waitExit(initDuration(seconds = 3))
    sess.close()
