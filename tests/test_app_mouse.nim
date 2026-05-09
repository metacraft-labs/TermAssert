## test_app_mouse - reads SGR mouse sequences from stdin and prints
## "click@col,row" for every press it sees. Used by
## `test_harness_mouse_events`.

import std/[strutils, posix, termios]

when isMainModule:
  # Switch the slave pty into raw mode so we get bytes immediately
  # without the canonical line-buffering kicking in.
  var t: Termios
  if tcGetAttr(0.cint, addr t) == 0:
    t.c_lflag = t.c_lflag and not (ICANON or ECHO)
    t.c_iflag = t.c_iflag and not (ICRNL)
    discard tcSetAttr(0.cint, TCSANOW, addr t)
  let ready = "ready\r\n"
  discard write(1.cint, unsafeAddr ready[0], ready.len)
  var buf = ""
  while true:
    var ch: array[64, char]
    let n = read(0.cint, addr ch[0], ch.len)
    if n <= 0: break
    let s = newString(n)
    copyMem(unsafeAddr s[0], addr ch[0], n)
    buf.add s
    # Look for SGR press sequences: ESC [ < B ; X ; Y M
    while true:
      let i = buf.find("\x1b[<")
      if i < 0: break
      let mEnd = buf.find('M', i)
      let mEnd2 = buf.find('m', i)
      var endIdx = -1
      if mEnd >= 0 and (mEnd2 < 0 or mEnd < mEnd2): endIdx = mEnd
      else: endIdx = mEnd2
      if endIdx < 0: break  # incomplete; wait for more
      # Only respond to press events ("M"); ignore release ("m").
      let payload = buf[i + 3 ..< endIdx]
      let isPress = buf[endIdx] == 'M'
      buf = buf[endIdx + 1 .. ^1]
      if not isPress: continue
      let parts = payload.split(';')
      if parts.len == 3:
        let col = parts[1]
        let row = parts[2]
        let line = "click@" & col & "," & row & "\r\n"
        discard write(1.cint, unsafeAddr line[0], line.len)
    if buf.contains("\x04"):
      break
