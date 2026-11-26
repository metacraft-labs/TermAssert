## test_app_focus - asks for focus reports (`CSI ? 1004 h`, unless run with
## `--no-report`) and prints "focus-in" / "focus-out" for every `CSI I` /
## `CSI O` it reads. Used by `test_harness_focus_reports`.

import std/[os, strutils, posix, termios]

when isMainModule:
  var t: Termios
  if tcGetAttr(0.cint, addr t) == 0:
    t.c_lflag = t.c_lflag and not (ICANON or ECHO)
    t.c_iflag = t.c_iflag and not (ICRNL)
    discard tcSetAttr(0.cint, TCSANOW, addr t)
  let ask = if "--no-report" in commandLineParams(): "" else: "\e[?1004h"
  let ready = ask & "ready\r\n"
  discard write(1.cint, unsafeAddr ready[0], ready.len)
  var buf = ""
  while true:
    var ch: array[64, char]
    let n = read(0.cint, addr ch[0], ch.len)
    if n <= 0: break
    let s = newString(n)
    copyMem(unsafeAddr s[0], addr ch[0], n)
    buf.add s
    while true:
      let i = buf.find("\e[")
      if i < 0 or i + 2 >= buf.len: break
      let line = case buf[i + 2]
        of 'I': "focus-in\r\n"
        of 'O': "focus-out\r\n"
        else: ""
      buf = buf[i + 3 .. ^1]
      if line.len > 0: discard write(1.cint, unsafeAddr line[0], line.len)
    if buf.contains("\x04"): break
