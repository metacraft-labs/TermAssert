## test_app_synchronized - brackets some output between DEC mode 2026
## set/reset to test `assertSynchronizedRender`.

import std/os

when isMainModule:
  stdout.write "\x1b[?2026h"
  for i in 0 ..< 5:
    stdout.write "row " & $i & "\r\n"
  stdout.write "\x1b[?2026l"
  flushFile(stdout)
  sleep(120)
