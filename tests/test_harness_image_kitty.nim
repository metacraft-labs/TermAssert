## test_harness_image_kitty - child emits a Kitty graphics APC with a
## 16x16 RGBA fixture; the harness's libvterm decodes it via the L2
## ingestion path; `session.images()` reports one ImageRef whose decoded
## pixels and FNV-1a hash match the buffer the child wrote.

import std/[unittest, times, options]
import term_assert
import test_helpers

const W = 16
const H = 16

proc buildExpectedRgba(): seq[byte] =
  ## Must produce byte-identical output to `test_app_image_kitty.nim`'s
  ## `buildRgba()`.
  result = newSeq[byte](W * H * 4)
  for y in 0 ..< H:
    for x in 0 ..< W:
      let p = (y * W + x) * 4
      if ((x + y) and 1) == 0:
        result[p + 0] = 255  # red
        result[p + 1] = 0
        result[p + 2] = 0
        result[p + 3] = 255
      else:
        result[p + 0] = 0    # green
        result[p + 1] = 255
        result[p + 2] = 0
        result[p + 3] = 255

proc fnv1a32(buf: openArray[byte]): array[32, byte] =
  ## Mirror `term_assert.imageHash`: FNV-1a 64 spread across 32 bytes via
  ## a Weyl-style mix counter. Matches the harness-side hash exactly so
  ## test-side and library-side hashes are equal when pixels are equal.
  var h: uint64 = 0xcbf29ce484222325'u64
  for b in buf:
    h = (h xor uint64(b)) * 0x00000100000001B3'u64
  for i in 0 ..< 32:
    let mixed = h xor uint64(i) * 0x9E3779B97F4A7C15'u64
    result[i] = byte((mixed shr (8 * (i mod 8))) and 0xFF)
    h = h * 0x100000001B3'u64

suite "M28 harness: image (Kitty graphics)":
  test "Kitty f=32 16x16 RGBA decoded end-to-end":
    compileChildApp("test_app_image_kitty")
    let bin = childAppPath("test_app_image_kitty")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    let _ = sess.drainOutput(150)

    let imgs = sess.images()
    check imgs.len == 1
    if imgs.len >= 1:
      let img = sess.imageData(imgs[0])
      check img.format == ifKitty
      check img.width == W
      check img.height == H
      check img.pixels.len == W * H * 4

      let expected = buildExpectedRgba()
      check img.pixels == expected

      let expectedHash = fnv1a32(expected)
      let actualHash = sess.imageHash(imgs[0])
      check actualHash == expectedHash

    let _ = sess.waitExit(initDuration(seconds = 3))
    sess.close()
