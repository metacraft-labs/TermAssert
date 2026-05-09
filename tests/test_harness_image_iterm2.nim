## test_harness_image_iterm2 - child emits an iTerm2 OSC 1337 inline-image
## carrying a 3x2 BMP fixture; harness decodes via the OSC dispatch path
## and exposes the resulting `Image` through `session.images()`.

import std/[unittest, times, options]
import term_assert
import test_helpers

suite "M28 harness: image (iTerm2 OSC 1337)":
  test "iTerm2 BMP 3x2 decoded end-to-end":
    compileChildApp("test_app_image_iterm2")
    let bin = childAppPath("test_app_image_iterm2")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    let _ = sess.drainOutput(150)

    let imgs = sess.images()
    check imgs.len == 1
    if imgs.len >= 1:
      let img = sess.imageData(imgs[0])
      check img.format == ifITerm2
      check img.width == 3
      check img.height == 2
      check img.pixels.len == 24

      # First pixel: (0, 0) red.
      check img.pixels[0] == 255
      check img.pixels[1] == 0
      check img.pixels[2] == 0
      check img.pixels[3] == 255

      # Middle pixel: (1, 1) gray (128, 128, 128).
      let mid = (1 * 3 + 1) * 4
      check img.pixels[mid + 0] == 128
      check img.pixels[mid + 1] == 128
      check img.pixels[mid + 2] == 128
      check img.pixels[mid + 3] == 255

      # Last pixel: (1, 2) black.
      let last = (1 * 3 + 2) * 4
      check img.pixels[last + 0] == 0
      check img.pixels[last + 1] == 0
      check img.pixels[last + 2] == 0
      check img.pixels[last + 3] == 255

    let _ = sess.waitExit(initDuration(seconds = 3))
    sess.close()
