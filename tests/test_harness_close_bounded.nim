## test_harness_close_bounded - `close` ends a child that ignores SIGHUP, in
## bounded time. A child started by a `nohup` caller inherits SIGHUP ignored;
## before `close` escalated, closing such a session waited for the child
## forever (a `cat` blocked reading its pty held a mutation grade for hours).
##
## A real child in a real pty: `sh` ignores SIGHUP and execs `cat`, which keeps
## the disposition and blocks reading. No stand-ins.

import std/[unittest, times, monotimes]
import term_assert

suite "TermAssert: closing a session":
  test "a child that ignores SIGHUP is ended, and close returns promptly":
    var s = newTuiTest("/bin/sh", @["-c", "trap '' HUP; printf READY; exec cat"])
      .width(40).height(3).spawn()
    s.waitForText("READY", initDuration(seconds = 5))
    let t0 = getMonoTime()
    s.close()
    let took = (getMonoTime() - t0).inMilliseconds
    checkpoint "close took " & $took & " ms"
    check took < 5000
