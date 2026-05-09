## test_harness_screenshot_ipc - child requests a screenshot via the
## companion client; the harness records it under the requested label.

import std/[unittest, times, options, strutils, tables]
import term_assert
import test_helpers

suite "M28 harness: screenshot IPC":
  test "child captures a screenshot":
    compileChildApp("test_app_screenshot")
    let bin = childAppPath("test_app_screenshot")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    let _ = sess.waitExit(initDuration(seconds = 5))
    let snaps = sess.snapshots()
    check snaps.hasKey("checkpoint_1")
    let snap = snaps["checkpoint_1"]
    check snap.contents.contains("hello from the child")
    sess.close()
