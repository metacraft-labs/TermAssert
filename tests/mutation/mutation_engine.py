"""A small mutation-testing engine shared by the run-<name>-mutations.py harnesses.

An arm is a named source edit: replace `old` (which must occur exactly once in
its file) with `new`, run the kill command, restore the file. The arm is KILLED
when the command fails, SURVIVED when it passes, TIMEOUT when it is still
running at the arm's deadline (`MUTATION_ARM_TIMEOUT_S`). A gate is met only when every
arm is killed.

The subject files' SHA-256 are recorded beside the harness
(`<name>-mutation-control.sha256`); a grading run refuses to start when a
subject changed since they were recorded, because an arm's needle may then no
longer mean what it meant.

    run-<name>-mutations.py --needle-scan             check every needle, run nothing
    run-<name>-mutations.py --record-control-hashes   record the subjects' hashes
    run-<name>-mutations.py [--only=ID,...]           grade (writes <name>-mutation-results.txt)
"""
import hashlib
import re
import os
import subprocess
import sys
import tempfile
import time
import signal
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Arm:
    id: str
    file: str
    old: str
    new: str
    why: str
    pre: list = field(default_factory=list)       # commands run after the edit, before the kill command
    restore: list = field(default_factory=list)   # further files the pre-commands rewrite


ARM_TIMEOUT_S = int(os.environ.get("MUTATION_ARM_TIMEOUT_S", "1200"))
"""How long one arm's kill command may run (`MUTATION_ARM_TIMEOUT_S`): one
still running then is ended with its process group and graded TIMEOUT, which
does not meet the gate."""


def scrub(text: str, root: Path, build: str) -> str:
    """Evidence names paths relative to the repository: no machine's directory
    layout ends up in a committed results file."""
    text = text.replace(build, "$BUILD_DIR")
    text = re.sub(r"/tmp/[^\s'\"]*?-mut-[a-z0-9_]+", "$BUILD_DIR", text)
    text = text.replace(str(root.parent) + "/", "../").replace(str(root) + "/", "")
    text = re.sub(r"/home/[^\s'\"]*", "<path>", text)
    return text


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main(name: str, root: Path, arms: list, kill: list):
    here = Path(sys.argv[0]).resolve().parent
    control = here / f"{name}-mutation-control.sha256"
    results = here / f"{name}-mutation-results.txt"
    subjects = sorted({a.file for a in arms})
    args = sys.argv[1:]
    only = None
    for a in args:
        if a.startswith("--only="):
            only = set(a[len("--only="):].split(","))

    bad = []
    for a in arms:
        n = (root / a.file).read_text().count(a.old)
        if n != 1:
            bad.append(f"{a.id}: needle occurs {n} times in {a.file}")
    if bad:
        print("\n".join(bad))
        sys.exit(2)
    if "--needle-scan" in args:
        print(f"{len(arms)} needles, each found exactly once")
        return
    if "--record-control-hashes" in args:
        control.write_text("".join(f"{sha(root / s)}  {s}\n" for s in subjects))
        print(f"recorded {len(subjects)} subject hashes in {control.name}")
        return
    if not control.exists():
        sys.exit(f"{control.name} is missing: run with --record-control-hashes")
    recorded = dict(reversed(l.split("  ", 1)) for l in control.read_text().splitlines())
    stale = [s for s in subjects if recorded.get(s) != sha(root / s)]
    if stale:
        sys.exit("stale harness: subjects changed since the control hashes were recorded: "
                 + ", ".join(stale) + " (review the needles, then --record-control-hashes)")

    build = tempfile.mkdtemp(prefix=f"{name}-mut-")
    env = dict(os.environ, BUILD_DIR=build)
    lines = [f"# {name} mutation results — {time.strftime('%Y-%m-%d %H:%M:%S %z')}",
             f"# kill command: {scrub(' '.join(kill), root, build)}", ""]
    survived = 0
    for a in arms:
        if only and a.id not in only:
            continue
        path = root / a.file
        saved = {a.file: path.read_text()}
        for r in a.restore:
            saved[r] = (root / r).read_text()
        try:
            path.write_text(saved[a.file].replace(a.old, a.new, 1))
            for cmd in a.pre:
                subprocess.run(cmd, cwd=root, env=env, check=True, capture_output=True)
            t0 = time.time()
            # in a session of its own, so that a kill command still running
            # at the arm's deadline is ended with everything it started
            p = subprocess.Popen(kill, cwd=root, env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, errors="replace",
                                 start_new_session=True)
            timed_out = False
            try:
                out, err = p.communicate(timeout=ARM_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                out, err = p.communicate()
            dt = time.time() - t0
        finally:
            for f, text in saved.items():
                (root / f).write_text(text)
        # an arm the kill command did not finish on is not killed: a deadline
        # is no assertion
        verdict = "TIMEOUT" if timed_out else ("KILLED" if p.returncode != 0 else "SURVIVED")
        if verdict != "KILLED":
            survived += 1
        tail = [l for l in ((out or "") + (err or "")).splitlines() if l.strip()][-3:]
        lines.append(f"{verdict:8} {a.id:6} {dt:6.1f}s  {a.why}")
        for t in tail:
            lines.append(f"           | {scrub(t, root, build)[:160]}")
        print(lines[-1 - len(tail)], flush=True)
    for s in subjects:
        assert sha(root / s) == recorded[s], f"{s} was not restored"
    total = len([a for a in arms if not only or a.id in only])
    lines.append("")
    lines.append(f"{total - survived}/{total} killed, {survived} survived or timed out")
    if not only:
        results.write_text("\n".join(lines) + "\n")
    print(lines[-1])
    sys.exit(1 if survived else 0)
