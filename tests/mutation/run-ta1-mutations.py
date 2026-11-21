#!/usr/bin/env python3
"""TA-1 verification gate: pointer press, motion, release and drag.

Each arm is a defect in the SGR encoding or in the tracking rule; the kill
command compiles and runs the pointer suites against a real pty
(tests/test_harness_mouse_drag.nim, tests/test_harness_mouse_events.nim).
Sibling sources are taken from NIM_PTY_SRC, NIM_LIBVTERM_SRC and
TERM_ASSERT_CLIENT_SRC (default: ../<sibling>/src).
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mutation_engine import Arm, main  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
S = "src/term_assert.nim"
paths = " ".join(f"--path:{os.environ.get(var, default)}" for var, default in [
    ("NIM_PTY_SRC", "../nim-pty/src"), ("NIM_LIBVTERM_SRC", "../nim-libvterm/src"),
    ("TERM_ASSERT_CLIENT_SRC", "../TermAssertClient/src")])
KILL = ["bash", "-euo", "pipefail", "-c",
        "for t in test_harness_mouse_drag test_harness_mouse_events; do "
        "nim c -r --hints:off --passC:-w --path:src --path:tests " + paths +
        " --mm:orc -d:release --threads:on --nimcache:${BUILD_DIR}/nc-$t "
        "-o:${BUILD_DIR}/$t tests/$t.nim; done"]

ARMS = [
    Arm("M1", S, "  s.send(sgrReport((base + 32) or modifierBits(modifiers), row, col, 'M'))",
        "  s.send(sgrReport(base or modifierBits(modifiers), row, col, 'M'))",
        "motion reported without the +32 motion bit"),
    Arm("M2", S, "  s.send(sgrReport(buttonCode(button) or modifierBits(modifiers), row, col, 'm'))",
        "  s.send(sgrReport(buttonCode(button) or modifierBits(modifiers), row, col, 'M'))",
        "the release terminated with M"),
    Arm("M3", S, '"\\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) & $final',
        '"\\x1b[<" & $code & ";" & $(row + 1) & ";" & $(col + 1) & $final',
        "column and row swapped"),
    Arm("M4", S, "(if kmShift in modifiers: 4 else: 0) or (if kmAlt in modifiers: 8 else: 0) or",
        "(if kmShift in modifiers: 0 else: 0) or (if kmAlt in modifiers: 8 else: 0) or",
        "the Shift bit dropped"),
    Arm("M5", S, "  if ord(have) < ord(needed):", "  if false:", "the tracking check removed"),
    Arm("M6", S, "    if (r, c) == last and steps == 0: continue",
        "    if k mod 2 == 0 and k != n: continue", "an intermediate cell skipped"),
]

if __name__ == "__main__":
    main("ta1", ROOT, ARMS, KILL)
