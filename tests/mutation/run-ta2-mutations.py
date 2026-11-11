#!/usr/bin/env python3
"""TA-2 verification gate: keys with modifiers.

Each arm is a defect in how sendKey encodes a modifier; the kill command
compiles and runs tests/test_harness_key_modifiers.nim against a real pty.
Sibling sources from NIM_PTY_SRC, NIM_LIBVTERM_SRC, TERM_ASSERT_CLIENT_SRC.
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
        "nim c -r --hints:off --passC:-w --path:src --path:tests " + paths +
        " --mm:orc -d:release --threads:on --nimcache:${BUILD_DIR}/nc-keys "
        "-o:${BUILD_DIR}/keys tests/test_harness_key_modifiers.nim"]

ARMS = [
    Arm("K1", S, "  let m = 1 + (if shift: 1 else: 0) + (if alt: 2 else: 0) + (if ctrl: 4 else: 0)",
        "  let m = 1 + (if alt: 2 else: 0) + (if ctrl: 4 else: 0)",
        "Shift dropped from the modifier parameter"),
    Arm("K2", S, "      if c in {'a'..'z'}: c = c.toUpperAscii", "      if c in {'a'..'z'}: discard",
        "Shift dropped from a letter"),
    Arm("K3", S, """    if ctrl or shift:
      raise newException(KeyEncodingError, "no terminal encoding for " & name)""",
        """    if false:
      raise newException(KeyEncodingError, "no terminal encoding for " & name)""",
        "a modifier dropped instead of refused"),
    Arm("K4", S, "    (if modified: \"\\x1b[\" & $n & \";\" & $m & \"~\" else: \"\\x1b[\" & $n & \"~\")",
        "    (\"\\x1b[\" & $n & \"~\")", "the modifier parameter dropped on tilde keys"),
]

if __name__ == "__main__":
    main("ta2", ROOT, ARMS, KILL)
