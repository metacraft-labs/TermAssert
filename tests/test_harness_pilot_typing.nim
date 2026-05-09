## test_harness_pilot_typing - spawn echo_keys, type "hi", verify
## both that the harness can drive stdin and that the screen reflects
## the echo.

import std/[unittest, times, options, strutils]
import term_assert
import test_helpers

suite "M28 harness: pilot typing":
  test "send hi waits for hi":
    compileChildApp("test_app_echo_keys")
    let bin = childAppPath("test_app_echo_keys")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    # Wait for the child to be ready first.
    sess.waitForText("ready", initDuration(seconds = 2))
    sess.send("hi")
    sess.waitForText("hi", initDuration(seconds = 2))
    let txt = sess.screenContents()
    check txt.contains("hi")
    # Terminate the long-running child rather than waiting for it.
    sess.terminate()
    sess.close()
