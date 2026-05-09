## test_app_screenshot - draws some content, then asks the harness to
## take a screenshot via the IPC. Used by `test_harness_screenshot_ipc`.

import std/os
import term_assert_client

when isMainModule:
  stdout.write "hello from the child\r\n"
  stdout.write "second line\r\n"
  flushFile(stdout)
  sleep(80)
  var c = connectHarness()
  c.requestScreenshot("checkpoint_1")
  sleep(80)
  c.requestExit(0)
  sleep(50)
  quit(0)
