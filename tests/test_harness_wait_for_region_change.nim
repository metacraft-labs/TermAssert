## test_harness_wait_for_region_change - counter app increments a value
## on a fixed row; harness blocks on `waitForRegionChange` and gets the
## new content.

import std/[unittest, times, options, strutils]
import term_assert
import test_helpers

suite "M28 harness: waitForRegionChange":
  test "counter row changes":
    compileChildApp("test_app_counter")
    let bin = childAppPath("test_app_counter")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    # Let the first counter value land.
    sess.waitForText("counter:", initDuration(seconds = 3))
    let changed = sess.waitForRegionChange(
      23, 0, 80, 1, initDuration(seconds = 3))
    check changed.contains("counter")
    let _ = sess.waitExit(initDuration(seconds = 5))
    sess.close()
