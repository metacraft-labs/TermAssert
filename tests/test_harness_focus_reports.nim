## test_harness_focus_reports - sendFocus writes the terminal's FocusIn /
## FocusOut reports to a child that asked for them (DEC 1004), and refuses
## for a child that did not: a real terminal sends nothing then.

import std/[unittest, times, strutils]
import term_assert
import test_helpers

suite "harness: focus reports":
  test "a child that asked for them reads CSI I and CSI O":
    compileChildApp("test_app_focus")
    var sess = newTuiTest(childAppPath("test_app_focus"), @[]).width(80).height(24).spawn()
    sess.waitForText("ready", initDuration(seconds = 3))
    check sess.focusReporting()
    sess.sendFocus(false)
    sess.waitForText("focus-out", initDuration(seconds = 2))
    sess.sendFocus(true)
    sess.waitForText("focus-in", initDuration(seconds = 2))
    sess.send("\x04")
    discard sess.waitExit(initDuration(seconds = 3))
    sess.close()

  test "a child that did not ask is sent nothing":
    compileChildApp("test_app_focus")
    var sess = newTuiTest(childAppPath("test_app_focus"), @["--no-report"]).width(80).height(24).spawn()
    sess.waitForText("ready", initDuration(seconds = 3))
    check not sess.focusReporting()
    expect FocusReportingError:
      sess.sendFocus(true)
    sess.send("\x04")
    discard sess.waitExit(initDuration(seconds = 3))
    check not sess.screenContents().contains("focus-in")
    sess.close()
