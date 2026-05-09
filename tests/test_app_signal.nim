## test_app_signal - prints "ready" and waits indefinitely; the test
## harness sends SIGINT (Ctrl-C) and verifies the child exits.

import std/[os, posix]

proc onSig(sig: cint) {.noconv.} =
  stdout.write "got SIGINT\r\n"
  flushFile(stdout)
  quit(130)

when isMainModule:
  signal(SIGINT, onSig)
  stdout.write "ready\r\n"
  flushFile(stdout)
  while true:
    sleep(100)
