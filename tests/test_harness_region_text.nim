## test_harness_region_text - layout app produces three known lines;
## regionText(0,0,10,3) returns the matching slab.

import std/[unittest, times, options, strutils]
import term_assert
import test_helpers

suite "M28 harness: regionText":
  test "top-left rectangle":
    compileChildApp("test_app_layout")
    let bin = childAppPath("test_app_layout")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    let _ = sess.drainOutput(150)
    let region = sess.regionText(0, 0, 10, 3)
    check region.contains("abcdefghij")
    check region.contains("ABCDEFGHIJ")
    check region.contains("0123456789")
    let _ = sess.waitExit(initDuration(seconds = 2))
    sess.close()
