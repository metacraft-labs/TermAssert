## test_harness_mouse_events - sendMouseClick(5, 10) delivers an SGR
## mouse press; child prints "click@col,row".

import std/[unittest, times, options, strutils]
import term_assert
import test_helpers

suite "M28 harness: mouse events":
  test "click fires SGR sequence":
    compileChildApp("test_app_mouse")
    let bin = childAppPath("test_app_mouse")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    sess.waitForText("ready", initDuration(seconds = 3))
    sess.sendMouseClick(5, 10)
    sess.waitForText("click@", initDuration(seconds = 2))
    # The child writes "click@<col+1>,<row+1>" because SGR mouse coords
    # are 1-based.
    let txt = sess.screenContents()
    check txt.contains("click@11,6")
    sess.send("\x04")
    let _ = sess.waitExit(initDuration(seconds = 3))
    sess.close()
