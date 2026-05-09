## test_app_image_sixel - emits a Sixel DCS sequence drawing a 4x6 solid
## blue band. Used by `test_harness_image_sixel`.
##
## Wire format:
##
##   `\x1bP q <body> \x1b\\`
##
## Body breakdown:
##   #1;2;0;0;100   - define pen 1 = RGB(0%, 0%, 100%) -- pure blue
##   #1             - select pen 1
##   ~~~~           - four sixel chars (each = 6-pixel column of full band)
##
## Reuses the exact same byte sequence as
## `nim-libvterm/tests/test_dcs_sixel_ingest.nim` so the L2 parser path
## the harness drives is identical to the unit test.

import std/os

when isMainModule:
  stdout.write "\x1bPq#1;2;0;0;100#1~~~~\x1b\\"
  flushFile(stdout)
  sleep(120)
