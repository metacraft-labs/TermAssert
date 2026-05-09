## test_app_hyperlink - emits an OSC 8 hyperlink wrapping the word
## "Click". Used by `test_harness_hyperlink_assertion`.

import std/os

when isMainModule:
  stdout.write "\x1b]8;;https://example.com\x1b\\Click\x1b]8;;\x1b\\"
  flushFile(stdout)
  sleep(120)
