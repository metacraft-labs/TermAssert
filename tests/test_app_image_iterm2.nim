## test_app_image_iterm2 - emits an iTerm2 OSC 1337 inline-image sequence
## carrying a 3x2 24-bit BMP fixture. Used by `test_harness_image_iterm2`.
##
## Wire format:
##
##   `\x1b]1337;File=name=test.bmp;inline=1:<base64-of-BMP>\x1b\\`
##
## The BMP construction (file header + DIB header + bottom-up pixel data)
## matches the fixture in `nim-libvterm/tests/test_decode_iterm2.nim`. The
## visual layout is:
##   row 0: red, green, blue
##   row 1: white, gray(128), black

import std/[base64, os]

proc le16(buf: var seq[byte]; v: uint16) =
  buf.add byte(v and 0xFF)
  buf.add byte((v shr 8) and 0xFF)

proc le32(buf: var seq[byte]; v: uint32) =
  buf.add byte(v and 0xFF)
  buf.add byte((v shr 8) and 0xFF)
  buf.add byte((v shr 16) and 0xFF)
  buf.add byte((v shr 24) and 0xFF)

proc buildBmp(w, h: int; rows: seq[seq[(byte, byte, byte)]]): seq[byte] =
  let stride = ((w * 3) + 3) and (not 3)
  let pixelOffset = 14 + 40
  let pixelBytes = stride * h
  result = @[]
  # BITMAPFILEHEADER (14 bytes)
  result.add byte('B')
  result.add byte('M')
  le32(result, uint32(pixelOffset + pixelBytes))
  le16(result, 0)
  le16(result, 0)
  le32(result, uint32(pixelOffset))
  # BITMAPINFOHEADER (40 bytes)
  le32(result, 40)
  le32(result, uint32(w))
  le32(result, uint32(h))
  le16(result, 1)
  le16(result, 24)
  le32(result, 0)
  le32(result, uint32(pixelBytes))
  le32(result, 2835)
  le32(result, 2835)
  le32(result, 0)
  le32(result, 0)
  # Pixel data, bottom-up.
  for y in countdown(h - 1, 0):
    var written = 0
    for x in 0 ..< w:
      let (r, g, b) = rows[y][x]
      result.add b
      result.add g
      result.add r
      written += 3
    while written < stride:
      result.add 0
      inc written

when isMainModule:
  let rows: seq[seq[(byte, byte, byte)]] = @[
    @[(255'u8, 0'u8, 0'u8), (0'u8, 255'u8, 0'u8), (0'u8, 0'u8, 255'u8)],
    @[(255'u8, 255'u8, 255'u8), (128'u8, 128'u8, 128'u8), (0'u8, 0'u8, 0'u8)],
  ]
  let bmp = buildBmp(3, 2, rows)
  var bmpStr = newString(bmp.len)
  for i in 0 ..< bmp.len:
    bmpStr[i] = char(bmp[i])
  let b64 = base64.encode(bmpStr)
  stdout.write "\x1b]1337;File=name=test.bmp;inline=1:" & b64 & "\x1b\\"
  flushFile(stdout)
  sleep(120)
