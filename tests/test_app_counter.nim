## test_app_counter - prints an incrementing counter on the bottom line
## with a CSI cursor-position move every 200 ms. Used by
## `test_harness_wait_for_region_change`.

import std/os

when isMainModule:
  for i in 0 .. 20:
    # CSI 24;1H moves to row 24 col 1; then write the counter.
    stdout.write "\x1b[24;1H"
    stdout.write "counter: " & $i
    stdout.write "        "  # erase trailing
    flushFile(stdout)
    sleep(120)
