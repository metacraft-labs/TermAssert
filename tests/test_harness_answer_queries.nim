## test_harness_answer_queries - with `answerQueries`, the child's queries are
## answered as a terminal answers them: Device Attributes and the cursor
## position report come back on its input, in the order asked. Without it the
## terminal answers nothing, as before.
##
## Real children in a real pty: `sh` puts the tty in raw mode with a one-second
## read timeout, writes the query, reads what comes back and shows its bytes
## (`od -c`). No stand-ins.

import std/[unittest, times, strutils]
import term_assert

proc asker(query: string; answer: bool): TuiTestSession =
  ## A child that writes `query`, then shows the bytes it reads within a second.
  result = newTuiTest("/bin/sh", @["-c",
    "stty raw -echo min 0 time 10; printf '" & query & "'; " &
    "r=$(dd bs=64 count=1 2>/dev/null | od -An -c | tr -s ' '); " &
    "printf '\\033[H\\033[2JGOT[%s]' \"$r\"; sleep 5"])
    .width(80).height(4).answerQueries(answer).spawn()

proc got(s: var TuiTestSession): string =
  s.waitForText("GOT[", initDuration(seconds = 5))
  discard s.drainOutput(100)
  let c = s.screenContents()
  let i = c.find("GOT[")
  c[i + 4 ..< c.find(']', i)].strip

suite "TermAssert: answering the child's queries":
  test "Primary Device Attributes are answered":
    var s = asker("\\033[c", true)
    check s.got() == "033 [ ? 1 ; 2 c"
    s.close()

  test "the cursor position report names where the cursor is":
    var s = asker("\\033[2;5H\\033[6n", true)
    check s.got() == "033 [ 2 ; 5 R"
    s.close()

  test "two queries are answered in the order asked":
    var s = asker("\\033[6n\\033[c", true)
    check s.got() == "033 [ 1 ; 1 R 033 [ ? 1 ; 2 c"
    s.close()

  test "without answerQueries the terminal answers nothing":
    var s = asker("\\033[c", false)
    check s.got() == ""
    s.close()
