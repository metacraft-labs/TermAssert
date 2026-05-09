## test_harness_image_sixel - child emits a Sixel DCS sequence; harness
## decodes via libvterm's DCS state-fallback path and exposes the
## resulting `Image` through `session.images()`.

import std/[unittest, times, options]
import term_assert
import test_helpers

suite "M28 harness: image (Sixel)":
  test "Sixel solid-blue 4x6 decoded end-to-end":
    compileChildApp("test_app_image_sixel")
    let bin = childAppPath("test_app_image_sixel")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    let _ = sess.drainOutput(150)

    let imgs = sess.images()
    check imgs.len == 1
    if imgs.len >= 1:
      let img = sess.imageData(imgs[0])
      check img.format == ifSixel
      check img.width == 4
      check img.height == 6
      check img.pixels.len == 4 * 6 * 4

      # First pixel: solid blue (0, 0, 255, 255).
      check img.pixels[0] == 0
      check img.pixels[1] == 0
      check img.pixels[2] == 255
      check img.pixels[3] == 255

      # Last pixel: (5, 3) -- still blue.
      let last = (5 * 4 + 3) * 4
      check img.pixels[last + 0] == 0
      check img.pixels[last + 1] == 0
      check img.pixels[last + 2] == 255
      check img.pixels[last + 3] == 255

      # Image registers a placement at the cursor. 4x6 px ÷ 8x16 cell = 1x1
      # cell footprint, so cell (0, 0) maps back to the same ref.
      let ref0 = sess.imageAt(0, 0)
      check ref0.isSome
      if ref0.isSome:
        check ref0.get == imgs[0]

    let _ = sess.waitExit(initDuration(seconds = 3))
    sess.close()
