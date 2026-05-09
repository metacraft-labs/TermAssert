## test_app_layout - prints a fixed three-line layout that
## `test_harness_region_text` slices.

when isMainModule:
  stdout.write "abcdefghij\r\n"
  stdout.write "ABCDEFGHIJ\r\n"
  stdout.write "0123456789\r\n"
  flushFile(stdout)
  # Sleep briefly so the harness can finish reading before we exit.
  import std/os
  sleep(150)
