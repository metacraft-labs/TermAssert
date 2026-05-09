## test_harness_window_op_capture - child sends CSI 8;30;100 t; harness
## records a Resize entry in windowOps().

import std/[unittest, times, options]
import term_assert
import test_helpers

suite "M28 harness: window-op (CSI t)":
  test "child requests resize":
    compileChildApp("test_app_window_op")
    let bin = childAppPath("test_app_window_op")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    let _ = sess.drainOutput(150)
    let ops = sess.windowOps()
    var foundResize = false
    for op in ops:
      if op.kind == woResize:
        foundResize = true
    check foundResize
    sess.assertWindowResize(100, 30)
    let _ = sess.waitExit(initDuration(seconds = 3))
    sess.close()
