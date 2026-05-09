## test_harness_drain_output - child emits ~50 KiB of styled output;
## drainOutput reads everything; final screen has the right cells.

import std/[unittest, times, options, strutils]
import term_assert
import test_helpers

suite "M28 harness: drainOutput":
  test "drain 50 KiB of output":
    compileChildApp("test_app_drain")
    let bin = childAppPath("test_app_drain")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    let bytes = sess.drainOutput(60)
    check bytes >= 40_000   # leave headroom for CRLF expansion + control bytes
    let txt = sess.screenContents()
    check txt.contains("ABCD")
    let _ = sess.waitExit(initDuration(seconds = 5))
    sess.close()
