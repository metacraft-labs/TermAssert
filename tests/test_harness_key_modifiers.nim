## test_harness_key_modifiers - sendKey encodes Shift, Ctrl and Alt the way a
## terminal (xterm) does, and refuses what no terminal encoding expresses
## instead of sending the key without its modifier.
##
## Byte-level checks of `keyBytes`, then delivery to a real child in a real
## pty (`sh` in raw mode echoing with `cat -v`). No stand-ins.

import std/[unittest, times, strutils]
import term_assert

suite "TermAssert: keys with modifiers":
  test "cursor, editing and function keys carry xterm's modifier parameter":
    check keyBytes("up") == "\x1b[A"
    check keyBytes("shift+down") == "\x1b[1;2B"
    check keyBytes("alt+left") == "\x1b[1;3D"
    check keyBytes("ctrl+right") == "\x1b[1;5C"
    check keyBytes("ctrl+shift+home") == "\x1b[1;6H"
    check keyBytes("shift+delete") == "\x1b[3;2~"
    check keyBytes("ctrl+pagedown") == "\x1b[6;5~"
    check keyBytes("f2") == "\x1bOQ"
    check keyBytes("shift+f2") == "\x1b[1;2Q"
    check keyBytes("ctrl+f5") == "\x1b[15;5~"
    check keyBytes("shift+tab") == "\x1b[Z"

  test "letters: Shift is the capital, Ctrl the control character, Alt the ESC prefix":
    check keyBytes("shift+a") == "A"
    check keyBytes("ctrl+a") == "\x01"
    check keyBytes("alt+x") == "\x1bx"
    check keyBytes("ctrl+alt+c") == "\x1b\x03"
    check keyBytes("A") == "A"
    check keyBytes("alt+enter") == "\x1b\r"

  test "a combination no terminal encoding expresses is refused":
    for k in ["ctrl+enter", "shift+enter", "ctrl+tab", "shift+esc", "ctrl+shift+a",
              "ctrl+1", "shift+1", "ctrl+shift+backtab"]:
      checkpoint k
      expect KeyEncodingError: discard keyBytes(k)
    expect ValueError: discard keyBytes("hyper")

  test "the bytes reach the child as encoded":
    var s = newTuiTest("/bin/sh", @["-c", "stty raw -echo; printf READY; exec cat -v"])
      .width(120).height(4).spawn()
    s.waitForText("READY", initDuration(seconds = 5))
    s.sendKey("shift+down")
    s.sendKey("ctrl+right")
    s.sendKey("shift+a")
    let want = "^[[1;2B^[[1;5CA"
    try: s.waitForText(want, initDuration(seconds = 2))
    except CatchableError: discard
    check s.screenContents().contains(want)
    s.close()
