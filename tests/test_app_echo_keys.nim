## test_app_echo_keys - child app that echoes any keystrokes back to
## stdout. Used by `test_harness_pilot_typing`.

import std/posix

when isMainModule:
  # `stdout.write` would buffer; use raw write(2) for instant flushing.
  let ready = "ready\r\n"
  discard write(1.cint, unsafeAddr ready[0], ready.len)
  while true:
    var buf: array[64, byte]
    let n = read(0.cint, addr buf[0], buf.len)
    if n <= 0: break
    discard write(1.cint, addr buf[0], n)
    var sawEot = false
    for i in 0 ..< n:
      if buf[i] == 0x04: sawEot = true
    if sawEot: break
