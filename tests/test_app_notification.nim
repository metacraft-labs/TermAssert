## test_app_notification - emits an OSC 9 notification that the harness
## records. Used by `test_harness_notification_received`.

import std/os

when isMainModule:
  stdout.write "\x1b]9;Build complete\x07"
  flushFile(stdout)
  sleep(120)
