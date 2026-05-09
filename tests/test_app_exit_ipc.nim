## test_app_exit_ipc - asks the harness for a clean exit and then quits
## with the agreed code.

import std/os
import term_assert_client

when isMainModule:
  stdout.write "starting\r\n"
  flushFile(stdout)
  var c = connectHarness()
  c.requestExit(0)
  sleep(50)
  quit(0)
