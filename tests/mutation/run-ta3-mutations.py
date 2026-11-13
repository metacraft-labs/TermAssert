#!/usr/bin/env python3
"""TA-3 verification gate: answering the child's queries.

Each arm is a defect in how the session writes the emulator's answers back
to the child; the kill command compiles and runs
tests/test_harness_answer_queries.nim against a real pty.
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
        "for t in test_harness_answer_queries; do "
        "nim c -r --hints:off --passC:-w --path:src --path:tests " + paths +
        " --mm:orc -d:release --threads:on --nimcache:${BUILD_DIR}/nc-$t "
        "-o:${BUILD_DIR}/$t tests/$t.nim; done"]

ARMS = [
    Arm("Q1", S, "  if s.answering and replies.len > 0:", "  if false:",
        "the emulator's answers never written back"),
    Arm("Q2", S, "  sess.answering = b.answerQueries", "  sess.answering = true",
        "a session answers although it was not asked to"),
    Arm("Q3", S, "    s.pty.write(toOpenArrayByte(replies, 0, replies.high))",
        "    s.pty.write(toOpenArrayByte(replies, 0, min(replies.high, 8)))",
        "a long answer cut short (two answers in one read lose the second)"),
]

if __name__ == "__main__":
    main("ta3", ROOT, ARMS, KILL)
