# `sendMouseClick` writes press and release at one cell, and nothing else can express a drag

| | |
|---|---|
| Status | open |
| Recorded | 2026-10-08 |
| Observed in | TermAssert @ 243f4c2 (`origin/dev`); the procedure bodies are identical on `origin/agents` @ d0c89e7 |
| Area | `src/term_assert.nim` — `sendMouseClick`, `sendMouseScroll` (mouse input synthesis) |

## Observed

The only pointer-input procedures TermAssert exports are `sendMouseClick` and
`sendMouseScroll`. `sendMouseClick` builds one SGR 1006 press and one release from the
**same** `(row, col)` and sends both:

```nim
  let press = "\x1b[<" & $bcode & ";" & $xCol & ";" & $yRow & "M"
  let release = "\x1b[<" & $bcode & ";" & $xCol & ";" & $yRow & "m"
  s.send(press)
  s.send(release)
```

`sendMouseScroll` is `sendMouseClick` with a wheel button. There is no procedure that
sends a press alone, a release alone, or a motion report, so a consumer cannot spell a
drag — press at one cell, motion, release at another — through the library at all.

Measured on 2026-10-08 (probe below, Nim 2.2.4) against a raw child that echoes its input
visibly:

```text
screen after sendMouseClick(3, 5): READY^[[<0;6;4M^[[<0;6;4m
compiles(sendMouseDrag): false
compiles(sendMouseMove): false
compiles(sendMousePress): false
compiles(sendMouseRelease): false
```

A CodeTracer campaign found this independently while testing pane drags and had to write
its own SGR reports instead of using TermAssert — CodeTracer-Platform PLAT-6:

> "=TermAssert.sendMouseClick= writes a press AND a release AT ONE CELL, so it cannot
> express a drag at all and this suite spells its own reports. The third case pins that
> encoder against the harness's own on a REAL child's stdin: =sh -c 'stty raw -echo;
> printf READY; exec cat -v'= in a pty, and =sendMouseClick(3, 5)= reads back
> =^[[<0;6;4M^[[<0;6;4m= — byte for byte what =sgrReport= produces."

(`codetracer-specs/milestones/CodeTracer-Platform.milestones.org`, PLAT-6, *THE INPUT
HELPER WAS MEASURED RATHER THAN TRUSTED*.) That workaround lives in one consumer's suite
and is not discoverable from TermAssert's API.

## Expected

Not specified in TermAssert's own documentation. Its README promises to *"Synthesize input
(text, named keys, mouse SGR sequences)"* and lists *"mouse 1006/1016"* among the protocols
it asserts first-class, without saying that only click and wheel are expressible.

The consumer specification that relies on it does require drags through TermAssert:
`codetracer-specs/spec/Front-Ends/CodeTracer-TUI.md`, the TermAssert capability table, row
*Mouse model* — `sendMouseClick(row, col, button)`, `sendMouseScroll` — *"§4.4 end to end:
click a frame, click the gutter, drag a list pane's scrollbar scrubber"*. The last of those
cannot be done with the listed procedures.

Proposed: TermAssert can express a drag — a press at one cell, motion reports, and a
release at another — with the same encoding discipline as `sendMouseClick`.

The project-neutral scenario format planned for TermAssert
(`metacraft-specs/spec/Scenarios/Scenario-Format.md`, §4.3.1 `drag` and §4.9) makes this
visible as a capability: until it is fixed, a TermAssert backend must declare that it
cannot perform `input.pointer.drag`, and every scenario containing a drag is reported
`unsupported` on the terminal.

## Evidence

Probe, compiled from a TermAssert checkout at 243f4c2 with the sibling `nim-pty`,
`nim-libvterm` and `TermAssertClient` on the path (the Justfile's `src-paths`):

```nim
import std/[os, strutils, times]
import term_assert
var s = newTuiTest("/bin/sh", @["-c", "stty raw -echo; printf READY; exec cat -v"]).width(40).height(5).spawn()
s.waitForText("READY", initDuration(seconds = 5))
s.sendMouseClick(3, 5)
discard s.drainOutput(300)
echo "screen after sendMouseClick(3, 5): ", s.screenContents().strip()
echo "compiles(sendMouseDrag): ", compiles(s.sendMouseDrag(3, 5, 3, 20))
echo "compiles(sendMouseMove): ", compiles(s.sendMouseMove(3, 20))
echo "compiles(sendMousePress): ", compiles(s.sendMousePress(3, 5))
echo "compiles(sendMouseRelease): ", compiles(s.sendMouseRelease(3, 20))
s.close()
```

```sh
nim c --path:src --path:../nim-pty/src --path:../nim-libvterm/src \
  --path:../TermAssertClient/src --mm:orc probe_drag.nim && ./probe_drag
```

The `compiles(...)` lines show the four plausible spellings are absent; the exported
procedure list of `src/term_assert.nim` contains no other pointer procedure.

## Suggested direction

Two shapes, not exclusive:

- **Primitives** — `sendMousePress(row, col, button, modifiers)`,
  `sendMouseMove(row, col, buttonsHeld, modifiers)` (SGR motion: button code + 32, `M`
  terminator) and `sendMouseRelease(row, col, button, modifiers)`. Most flexible; the caller
  must know the protocol's rules.
- **A gesture** — `sendMouseDrag(fromRow, fromCol, toRow, toCol, button, steps)` built on
  the primitives, emitting intermediate motion reports.

Either way, decide what happens when the child has not enabled motion tracking (DEC 1002 /
1003): a real terminal sends no motion reports then, so the harness should either refuse
(raise) or send only press and release — sending motion the child did not ask for would
test a terminal that does not exist. `mouseProtocol()` already exposes what the child
negotiated.

## Related

- `issues/2026-10-08-assert-synchronized-render-cannot-fail.md` — the other TermAssert
  defect CodeTracer worked around locally.
- `codetracer-specs/spec/Testing/Verification-Harness-Traps.md` §25 — an input synthesiser
  that cannot spell an input turns a test into a test of something else.
- Not measured, noted for whoever fixes this: `sendMouseScroll` also sends a *release*
  for the wheel buttons (64/65), because it reuses `sendMouseClick`. Whether real
  terminals send a release for a wheel event, and whether any consumer depends on it, has
  not been checked.
- This is the first issue filed in this repository; there was no `issues/` history to
  search. `git log --all -i -S'drag'` finds no earlier record.
