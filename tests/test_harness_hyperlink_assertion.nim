## test_harness_hyperlink_assertion - child emits OSC 8 hyperlink; the
## harness's `hyperlinks()` table records it.

import std/[unittest, times, options]
import term_assert
import test_helpers

suite "M28 harness: hyperlink (OSC 8)":
  test "OSC 8 link visible":
    compileChildApp("test_app_hyperlink")
    let bin = childAppPath("test_app_hyperlink")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    let _ = sess.drainOutput(150)
    let links = sess.hyperlinks()
    check links.len >= 1
    var found = false
    for h in links:
      if h.uri == "https://example.com":
        found = true
        break
    check found
    let _ = sess.waitExit(initDuration(seconds = 3))
    sess.close()
