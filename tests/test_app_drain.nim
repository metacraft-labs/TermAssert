## test_app_drain - emits 50 KiB of styled output split across many
## small writes. Used by `test_harness_drain_output`.

import std/[os, strutils]

when isMainModule:
  let chunk = "\x1b[31mABCDEFGH\x1b[0m"  # 8 visible bytes per write
  let chunks = (50 * 1024) div chunk.len
  for i in 0 ..< chunks:
    stdout.write chunk
    if i mod 200 == 0:
      flushFile(stdout)
  flushFile(stdout)
  sleep(50)
