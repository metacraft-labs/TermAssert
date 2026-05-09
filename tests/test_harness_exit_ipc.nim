## test_harness_exit_ipc - child requests a clean exit via the companion
## client; harness sees the exit code and pty closes.

import std/[unittest, times, options]
import term_assert
import test_helpers

suite "M28 harness: exit IPC":
  test "child requests exit 0":
    compileChildApp("test_app_exit_ipc")
    let bin = childAppPath("test_app_exit_ipc")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    let ec = sess.waitExit(initDuration(seconds = 5))
    check ec.isSome
    check ec.get == 0
    sess.close()
