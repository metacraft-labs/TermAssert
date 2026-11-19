## test_harness_pending_input - pendingInput counts the bytes the child has
## not read yet: what was sent while it was not reading, and zero once it
## has read them. The child is `sh` that sleeps before it starts reading
## (`cat`), in a real pty. No stand-ins.

import std/[unittest, times, monotimes, os]
import term_assert

suite "harness: input the child has not read":
  test "sent while the child sleeps, then read":
    var s = newTuiTest("/bin/sh", @["-c",
      "stty raw -echo; printf READY; sleep 2; exec cat > /dev/null"]).width(80).height(5).spawn()
    s.waitForText("READY", initDuration(seconds = 5))
    check s.pendingInput() == 0
    s.send("abc")
    # the kernel moves written bytes to the child's terminal a moment later
    # (the pty's flip buffer), well inside the child's two-second sleep
    let arrival = getMonoTime() + initDuration(milliseconds = 1000)
    while s.pendingInput() != 3 and getMonoTime() < arrival:
      sleep(10)
    check s.pendingInput() == 3
    let deadline = getMonoTime() + initDuration(seconds = 10)
    while s.pendingInput() != 0 and getMonoTime() < deadline:
      sleep(50)
    check s.pendingInput() == 0
    s.close()
