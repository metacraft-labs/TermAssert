## test_harness_key_modes - sendKey follows the key reporting the child asked
## for: xterm's `modifyOtherKeys` level 2 (`CSI > 4 ; 2 m`) and the Kitty
## keyboard protocol's disambiguate flag (`CSI > 1 u`), and falls back to the
## legacy bytes when it asked for nothing or took the request back.
##
## The expected bytes are what the terminals send: xterm 410 driven through
## X key events with each child below, and kitty 0.45's own key encoder (the
## tables are in `keyBytes(name, mode)`'s documentation).
##
## Byte-level checks of `keyBytes(name, mode)` and of `KeyModeTracker` (fed
## at every split point, which is how a pty read cuts a request), then
## delivery to real children in a real pty: `sh` writes the request, puts
## the tty in raw mode and echoes its input with `cat -v`. No stand-ins.

import std/[unittest, times, strutils]
import term_assert
import term_assert/key_modes

const
  Legacy = KeyMode()
  Mok2 = KeyMode(modifyOtherKeys: 2)
  Kitty1 = KeyMode(kittyFlags: 1)

proc modeAfter(stream: string; cut = -1): KeyMode =
  ## The mode `stream` leaves a tracker in, fed whole or cut in two at `cut`.
  var t = initKeyModeTracker()
  let bytes = cast[seq[byte]](stream)
  if cut < 0:
    t.feed(bytes)
  else:
    t.feed(bytes.toOpenArray(0, cut - 1))
    t.feed(bytes.toOpenArray(cut, bytes.high))
  t.keyMode()

proc echoChild(request: string): TuiTestSession =
  ## A child that writes `request`, then echoes every byte it reads as
  ## `cat -v` shows it.
  result = newTuiTest("/bin/sh", @["-c",
    "stty raw -echo; printf '" & request & "'; printf READY; exec cat -v"])
    .width(160).height(4).spawn()
  result.waitForText("READY", initDuration(seconds = 5))

proc expectEcho(s: var TuiTestSession; want: string) =
  try: s.waitForText(want, initDuration(seconds = 2))
  except CatchableError: discard
  check s.screenContents().contains(want)

suite "TermAssert: key reporting modes":
  test "modifyOtherKeys 2: modified keys are CSI 27 ; m ; code ~":
    check keyBytes("ctrl+alt+j", Mok2) == "\x1b[27;7;106~"
    check keyBytes("ctrl+shift+k", Mok2) == "\x1b[27;6;75~"
    check keyBytes("ctrl+a", Mok2) == "\x1b[27;5;97~"
    check keyBytes("alt+x", Mok2) == "\x1b[27;3;120~"
    check keyBytes("shift+a", Mok2) == "\x1b[27;2;65~"
    check keyBytes("ctrl+1", Mok2) == "\x1b[27;5;49~"
    check keyBytes("ctrl+enter", Mok2) == "\x1b[27;5;13~"
    check keyBytes("ctrl+tab", Mok2) == "\x1b[27;5;9~"
    check keyBytes("shift+tab", Mok2) == "\x1b[Z"
    check keyBytes("shift+space", Mok2) == "\x1b[27;2;32~"
    check keyBytes("alt+escape", Mok2) == "\x1b[27;3;27~"
    check keyBytes("shift+escape", Mok2) == "\x1b[27;2;27~"
    check keyBytes("alt+shift+a", Mok2) == "\x1b[27;4;65~"
    check keyBytes("Alt+T", Mok2) == "\x1b[27;3;116~"
    check keyBytes("Alt+Shift+T", Mok2) == "\x1b[27;4;84~"
    check keyBytes("A", Mok2) == "\x1b[27;2;65~"
    check keyBytes("ctrl+alt+shift+j", Mok2) == "\x1b[27;8;74~"
    check keyBytes("ctrl+shift+tab", Mok2) == "\x1b[27;6;9~"
    check keyBytes("ctrl+[", Mok2) == "\x1b[27;5;91~"
    check keyBytes("ctrl+/", Mok2) == "\x1b[27;5;47~"
    check keyBytes("escape", Mok2) == "\x1b"
    check keyBytes("ctrl+up", Mok2) == "\x1b[1;5A"
    check keyBytes("shift+f5", Mok2) == "\x1b[15;2~"

  test "Kitty flag 1: modified keys are CSI code ; m u":
    check keyBytes("ctrl+alt+j", Kitty1) == "\x1b[106;7u"
    check keyBytes("ctrl+shift+k", Kitty1) == "\x1b[107;6u"
    check keyBytes("ctrl+a", Kitty1) == "\x1b[97;5u"
    check keyBytes("alt+shift+a", Kitty1) == "\x1b[97;4u"
    check keyBytes("shift+a", Kitty1) == "A"
    check keyBytes("Alt+T", Kitty1) == "\x1b[116;3u"
    check keyBytes("Alt+Shift+T", Kitty1) == "\x1b[116;4u"
    check keyBytes("A", Kitty1) == "A"
    check keyBytes("escape", Kitty1) == "\x1b[27u"
    check keyBytes("shift+enter", Kitty1) == "\x1b[13;2u"
    check keyBytes("shift+tab", Kitty1) == "\x1b[9;2u"
    check keyBytes("ctrl+space", Kitty1) == "\x1b[32;5u"
    check keyBytes("enter", Kitty1) == "\r"
    check keyBytes("ctrl+enter", Kitty1) == "\x1b[13;5u"
    check keyBytes("alt+backspace", Kitty1) == "\x1b[127;3u"
    check keyBytes("alt+space", Kitty1) == "\x1b[32;3u"
    check keyBytes("shift+space", Kitty1) == " "
    check keyBytes("ctrl+1", Kitty1) == "\x1b[49;5u"
    check keyBytes("ctrl+alt+shift+j", Kitty1) == "\x1b[106;8u"
    check keyBytes("ctrl+up", Kitty1) == "\x1b[1;5A"
    check keyBytes("ctrl+shift+a", KeyMode(kittyFlags: 1 or 2 or 16)) == "\x1b[97;6u"

  test "plain keys are unchanged in every mode; the session-less form stays legacy":
    for mode in [Legacy, Mok2, Kitty1]:
      for k in ["a", "z", "7", "/", "enter", "tab", "space", "up", "f5"]:
        checkpoint $mode & " " & k
        check keyBytes(k, mode) == keyBytes(k)
    check keyBytes("ctrl+alt+j", Legacy) == keyBytes("ctrl+alt+j")
    check keyBytes("ctrl+alt+j") == "\x1b\n"

  test "a combination a mode cannot express is refused, never sent without a modifier":
    for (k, mode) in [("ctrl+shift+k", Legacy), ("shift+1", Mok2), ("shift+1", Kitty1),
                      ("ctrl+backspace", Mok2), ("ctrl+backtab", Kitty1),
                      ("ctrl+a", KeyMode(kittyFlags: 8)), ("ctrl+a", KeyMode(kittyFlags: 2)),
                      ("a", KeyMode(kittyFlags: 1 or 4))]:
      checkpoint k & " " & $mode
      expect KeyEncodingError: discard keyBytes(k, mode)

  test "the tracker follows requests, wherever a read cuts them":
    let stream = "x\x1b[?1049h\x1b[>4;2m\x1b[>1u\x1b[=3;2u\x1b[<u\x1b[>5u"
    for cut in 0 .. stream.len:
      checkpoint "cut at " & $cut
      check modeAfter(stream, cut) == KeyMode(modifyOtherKeys: 2, kittyFlags: 5)
    check modeAfter("\x1b[>4;2m\x1b[>4m") == Legacy
    check modeAfter("\x1b[>4;2m\x1b[>m") == Legacy
    check modeAfter("\x1b[>1u\x1b[=2;2u") == KeyMode(kittyFlags: 3)
    check modeAfter("\x1b[>1u\x1b[>3u\x1b[<2u") == Legacy
    check modeAfter("\x1b[>1u\x1b[<5u") == Legacy
    # the main and alternate screens keep separate Kitty stacks
    check modeAfter("\x1b[>1u\x1b[?1049h") == Legacy
    check modeAfter("\x1b[>1u\x1b[?1049h\x1b[>3u\x1b[?1049l") == Kitty1
    check modeAfter("\x1b[>4;2m\x1b[>1u\x1bc") == Legacy

  test "a child that requests modifyOtherKeys 2 receives xterm's form":
    var s = echoChild("\\033[>4;2m")
    check s.keyMode() == Mok2
    s.sendKey("ctrl+alt+j")
    s.sendKey("ctrl+shift+k")
    s.sendKey("a")
    s.expectEcho("^[[27;7;106~^[[27;6;75~a")
    s.close()

  test "a child that pushes Kitty flag 1 receives the Kitty form":
    var s = echoChild("\\033[>1u")
    check s.keyMode() == Kitty1
    s.sendKey("ctrl+alt+j")
    s.sendKey("ctrl+shift+k")
    s.sendKey("b")
    s.expectEcho("^[[106;7u^[[107;6ub")
    s.close()

  test "a child that pushes and then pops gets the legacy bytes again":
    var s = echoChild("\\033[>1u\\033[<u")
    check s.keyMode() == Legacy
    s.sendKey("ctrl+a")
    s.sendKey("alt+x")
    s.sendKey("c")
    s.expectEcho("^A^[xc")
    expect KeyEncodingError: s.sendKey("ctrl+shift+k")
    s.close()

  test "a child that never asks gets the legacy bytes":
    var s = echoChild("")
    check s.keyMode() == Legacy
    s.sendKey("ctrl+a")
    s.sendKey("alt+x")
    s.sendKey("d")
    s.expectEcho("^A^[xd")
    s.close()

  test "a request that arrives in two reads takes effect once complete":
    var s = newTuiTest("/bin/sh", @["-c",
      "stty raw -echo; printf 'START\\033[>4;'; sleep 1; printf '2mREADY'; exec cat -v"])
      .width(160).height(4).spawn()
    s.waitForText("START", initDuration(seconds = 5))
    discard s.drainOutput(300)
    check s.keyMode() == Legacy
    s.waitForText("READY", initDuration(seconds = 5))
    check s.keyMode() == Mok2
    s.sendKey("ctrl+alt+j")
    s.expectEcho("^[[27;7;106~")
    s.close()
