# `assertSynchronizedRender` has no failure path, so it passes for a child that never brackets a frame

| | |
|---|---|
| Status | open |
| Recorded | 2026-10-08 |
| Observed in | TermAssert @ 243f4c2 (`origin/dev`); the procedure body is identical on `origin/agents` @ d0c89e7 |
| Area | `src/term_assert.nim` — `assertSynchronizedRender` (DEC 2026 synchronized output) |

## Observed

`assertSynchronizedRender` runs the action, pumps once, reads the screen's
`synchronizedOutput()` flag and the window-op log, and then does nothing with either:

```nim
  action()
  discard pump(s, 100)
  let observed = s.screen.synchronizedOutput()
  let log = s.screen.windowOps()
  discard log
  if not observed:
    # The flag goes false again on `?2026 l`, so just observing it
    # NEVER true means the child didn't bracket. We accept either flag
    # latching OR a record in the window-op log; the latter is what
    # libvterm's pre-scanner stores.
    discard
```

Both branches fall through. There is no `raise` in the procedure, so it returns normally
for every child — including one that has never emitted `CSI ? 2026 h` or `CSI ? 2026 l`.
It is the only `assert*` procedure in `src/term_assert.nim` without a raise on its failure
path; its siblings (`assertWindowResize`, `assertNotificationReceived`,
`assertHyperlinkAt`, …) raise `AssertionFailedError`.

Measured on 2026-10-08 (probe below, Nim 2.2.4) with a child whose whole output is
`no-sync-here`:

```text
opens in transcript: 0 closes: 0
synchronizedOutput(): false
assertSynchronizedRender: RETURNED NORMALLY (passed)
```

The comment names the underlying difficulty correctly: `nim-libvterm`'s
`synchronizedOutput()` is a **live flag**, true only between the open and the close, so a
check made after the action has, by construction, missed a correctly bracketed frame as
well. Neither of the two remedies the comment names (latching the flag, or reading the
window-op log) is implemented.

The defect was found by CodeTracer's terminal campaign, which could not use the assertion
and verified DEC 2026 pairing another way — CodeTracer-TUI CTUI-11:

> "=TermAssert.assertSynchronizedRender= CANNOT FAIL — its "not observed" arm is =discard=
> ... =assertSynchronizedRender= is additionally the ONLY =assert*= in =term_assert.nim=
> with no =raise= on its failure path, and the window-op-log fallback its own comment
> promises is computed, =discard=-ed and never consulted."

and recommended fixing it here rather than in each consumer: *"=assertSynchronizedRender=
should either observe the flag DURING the action (incremental pumping, since libvterm's
flag is live and not latched) or scan the byte log for the pair — and raise when it sees
neither."* (`codetracer-specs/milestones/CodeTracer-TUI.milestones.org`, CTUI-11, *WHAT
libvterm CAN AND CANNOT SEE ABOUT DEC 2026*.) The same measurement, with an `echo` child,
is recorded as `codetracer-specs/spec/Testing/Verification-Harness-Traps.md` §26 (*"An
assertion whose negative arm is `discard` is documentation with a call site"*).

## Expected

Not specified in TermAssert's own documentation beyond its README listing *"first-class
assertions for modern terminal protocols (… synchronized output …)"*. The consumer
specification states what the assertion is for:
`codetracer-specs/spec/Front-Ends/CodeTracer-TUI.md`, the TermAssert capability table, row
*DEC 2026* — `assertSynchronizedRender` — *"Tear-free atomic frames actually requested and
paired"*.

Proposed: the assertion raises when the action produced no bracketed frame, and when the
brackets it produced are unpaired; and it passes for a child that brackets correctly. A
function named `assertX` must have an input that makes it fail.

## Evidence

Probe, compiled from a TermAssert checkout at 243f4c2 with the sibling `nim-pty`,
`nim-libvterm` and `TermAssertClient` on the path (the Justfile's `src-paths`):

```nim
import std/strutils
import term_assert
var s = newTuiTest("/bin/sh", @["-c", "printf no-sync-here; sleep 1"]).width(40).height(5).transcript().spawn()
discard s.drainOutput(300)
let t = s.transcriptBytes()
echo "opens in transcript: ", t.count("\e[?2026h"), " closes: ", t.count("\e[?2026l")
echo "synchronizedOutput(): ", s.synchronizedOutput()
try:
  s.assertSynchronizedRender(proc () = s.send("x"))
  echo "assertSynchronizedRender: RETURNED NORMALLY (passed)"
except AssertionDefect, CatchableError:
  echo "assertSynchronizedRender: raised ", getCurrentExceptionMsg()
s.close()
```

```sh
nim c --path:src --path:../nim-pty/src --path:../nim-libvterm/src \
  --path:../TermAssertClient/src --mm:orc probe_sync.nim && ./probe_sync
```

## Suggested direction

Two ways to observe a live flag, with different costs:

- **Scan the bytes.** With the transcript enabled, count `CSI ? 2026 h` and `CSI ? 2026 l`
  in the bytes the action produced: at least one open, strictly alternating, balanced.
  Exact and cheap, but it requires the transcript (currently opt-in and capped) and
  asserts on the stream rather than on what the terminal did with it.
- **Latch during the action.** Pump in small increments while the action's output
  arrives and record whether the flag was ever observed true, then require it false at the
  end. Asserts on the terminal model, but can miss a frame whose open and close arrive in
  one read — so it needs the parser (or `nim-libvterm`) to latch "was set since last read"
  rather than relying on sampling.

Whichever is chosen, the test suite should carry a negative control: a child that never
brackets, a child that opens without closing, each making the assertion raise — a
positive-only test is how this one shipped.

## Related

- `issues/2026-10-08-send-mouse-click-cannot-express-a-drag.md` — the other TermAssert
  defect CodeTracer worked around locally.
- `codetracer-specs/spec/Testing/Silent-Self-Pass-Audit-2026-08-23.md` — the defect class:
  a harness that reports success where it cannot observe.
- `codetracer-specs/spec/Front-Ends/CodeTracer-TUI-Graphics.md` — records the same finding
  where the TUI's DEC 2026 support is specified.
- This repository had no `issues/` history to search; `git log --all -i
  -S'assertSynchronizedRender'` finds only the commit that introduced the procedure.
