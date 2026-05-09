## test_harness_notification_received - child emits OSC 9 notification;
## the harness sees it via `waitForNotification`.

import std/[unittest, times, options, strutils]
import term_assert
import test_helpers

suite "M28 harness: notification (OSC 9)":
  test "Build complete notification":
    compileChildApp("test_app_notification")
    let bin = childAppPath("test_app_notification")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    sess.waitForNotification(byTitle("Build complete"),
                            initDuration(seconds = 2))
    let notes = sess.notifications()
    check notes.len >= 1
    var seen = false
    for n in notes:
      if n.body.contains("Build complete"): seen = true
    check seen
    let _ = sess.waitExit(initDuration(seconds = 3))
    sess.close()
