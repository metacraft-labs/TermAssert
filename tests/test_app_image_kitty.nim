## test_app_image_kitty - emits a Kitty graphics APC sequence carrying a
## small RGBA fixture (16x16). Used by `test_harness_image_kitty` and
## `test_harness_image_assertion_workflow`.
##
## Wire format (Kitty graphics, raw-RGBA passthrough):
##
##   `\x1b_Ga=T,f=32,s=W,v=H,i=1;<base64-of-W*H*4-RGBA-bytes>\x1b\\`
##
## We use a procedurally-generated checkerboard so the harness side can
## reproduce the exact same byte buffer (and hence the same FNV-1a hash)
## without sharing a fixture file. The pattern -- and the dimensions --
## must stay in lock-step with the harness test's `buildKittyRgba()`.

import std/[base64, os]

const W = 16
const H = 16

proc buildRgba(): string =
  ## 16x16 red/green checkerboard. Same construction as the harness
  ## test's helper; both sides must match byte-for-byte.
  result = newString(W * H * 4)
  for y in 0 ..< H:
    for x in 0 ..< W:
      let p = (y * W + x) * 4
      if ((x + y) and 1) == 0:
        result[p + 0] = char(255)  # red
        result[p + 1] = char(0)
        result[p + 2] = char(0)
        result[p + 3] = char(255)
      else:
        result[p + 0] = char(0)    # green
        result[p + 1] = char(255)
        result[p + 2] = char(0)
        result[p + 3] = char(255)

when isMainModule:
  let raw = buildRgba()
  let b64 = base64.encode(raw)
  stdout.write "\x1b_Ga=T,f=32,s=" & $W & ",v=" & $H & ",i=1;" & b64 & "\x1b\\"
  flushFile(stdout)
  sleep(120)
