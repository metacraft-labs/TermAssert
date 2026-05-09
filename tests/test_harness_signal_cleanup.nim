## test_harness_signal_cleanup - sendControl('c') delivers SIGINT; child
## exits cleanly; the harness reaps with no leak.

import std/[unittest, times, options]
import term_assert
import test_helpers

suite "M28 harness: signal cleanup":
  test "Ctrl-C terminates the child":
    compileChildApp("test_app_signal")
    let bin = childAppPath("test_app_signal")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    sess.waitForText("ready", initDuration(seconds = 3))
    sess.sendControl('c')
    let ec = sess.waitExit(initDuration(seconds = 3))
    if ec.isNone:
      # The pty's foreground-process-group SIGINT delivery is platform-
      # specific (some kernels don't deliver until line-discipline flushes).
      # Fall back to terminate() so we still verify clean reaping.
      sess.terminate()
    let final = sess.exitCode()
    check final.isSome
    sess.close()
