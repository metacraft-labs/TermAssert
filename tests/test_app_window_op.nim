## test_app_window_op - sends a CSI 8 t resize request that the harness
## should record in its `windowOps()` log. Used by
## `test_harness_window_op_capture`.

import std/os

when isMainModule:
  stdout.write "\x1b[8;30;100t"
  flushFile(stdout)
  sleep(120)
