## test_harness_mouse_drag - press, motion and release as separate reports,
## and a drag built on them, delivered to a real child in a real pty.
##
## The child is `sh` in raw mode echoing its input with `cat -v`, after
## enabling a mouse tracking mode, so every byte TermAssert sends is visible on
## the screen exactly. No stand-ins.

import std/[unittest, times, strutils]
import term_assert

proc child(modes: string): TuiTestSession =
  let script = "printf '" & modes & "'; stty raw -echo; printf READY; exec cat -v"
  result = newTuiTest("/bin/sh", @["-c", script]).width(200).height(5).spawn()
  result.waitForText("READY", initDuration(seconds = 5))

proc echoed(s: var TuiTestSession; expected: string): string =
  ## Waits until `expected` appears (or a second passes) and returns what the
  ## child echoed after READY.
  try: s.waitForText(expected, initDuration(seconds = 2))
  except CatchableError: discard
  discard s.drainOutput(100)
  let text = s.screenContents().replace("\n", "").strip()
  text[text.find("READY") + 5 .. ^1].strip()

const drag = "\\033[?1002h\\033[?1006h"

suite "TermAssert: pointer press, motion, release and drag":
  test "a drag is a press, one motion per crossed cell, and a release elsewhere":
    var s = child(drag)
    check s.mouseTracking() == mtDrag
    s.sendMouseDrag(3, 5, 3, 9)
    let want = "^[[<0;6;4M^[[<32;7;4M^[[<32;8;4M^[[<32;9;4M^[[<32;10;4M^[[<0;10;4m"
    check s.echoed(want) == want
    s.close()

  test "modifiers set the SGR bits on press, motion and release":
    var s = child(drag)
    s.sendMouseDrag(1, 1, 1, 2, mbLeft, {kmShift, kmCtrl})
    let want = "^[[<20;2;2M^[[<52;3;2M^[[<20;3;2m"
    check s.echoed(want) == want
    s.close()

  test "steps spaces the motion reports evenly":
    var s = child(drag)
    s.sendMouseDrag(0, 0, 0, 4, steps = 2)
    let want = "^[[<0;1;1M^[[<32;3;1M^[[<32;5;1M^[[<0;5;1m"
    check s.echoed(want) == want
    s.close()

  test "press, motion with a button held, and release, one at a time":
    var s = child(drag)
    s.sendMousePress(0, 0, mbRight)
    s.sendMouseMove(0, 3, {mbRight})
    s.sendMouseRelease(0, 3, mbRight, {kmAlt})
    let want = "^[[<2;1;1M^[[<34;4;1M^[[<10;4;1m"
    check s.echoed(want) == want
    s.close()

  test "click tracking only: motion and drags are refused and nothing is sent":
    var s = child("\\033[?1000h\\033[?1006h")
    check s.mouseTracking() == mtClick
    expect MouseTrackingError: s.sendMouseMove(1, 1, {mbLeft})
    expect MouseTrackingError: s.sendMouseDrag(1, 1, 1, 5)
    expect MouseTrackingError: s.sendMouseMove(1, 1)
    s.send("x")
    check s.echoed("x") == "x"
    s.close()

  test "any-motion tracking: a motion with no button held":
    var s = child("\\033[?1003h\\033[?1006h")
    s.sendMouseMove(2, 3)
    let want = "^[[<35;4;3M"
    check s.echoed(want) == want
    s.close()

  test "a click is unchanged: press and release at one cell":
    var s = child(drag)
    s.sendMouseClick(3, 5)
    let want = "^[[<0;6;4M^[[<0;6;4m"
    check s.echoed(want) == want
    s.close()
