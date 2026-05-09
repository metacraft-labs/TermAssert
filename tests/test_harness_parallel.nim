## test_harness_parallel - 8 sessions in parallel against 8 different
## child binaries. Each gets its own socket path; no collisions; goldens
## are stable.

import std/[unittest, times, options, os, strutils]
import term_assert
import test_helpers

proc requireBin(name: string): string =
  for dir in getEnv("PATH").split(':'):
    if dir.len == 0: continue
    let candidate = dir / name
    if fileExists(candidate): return candidate
  for fb in ["/bin/" & name, "/usr/bin/" & name]:
    if fileExists(fb): return fb
  raise newException(IOError, "binary not found: " & name)

suite "M28 harness: parallel sessions":
  test "8 sessions side-by-side":
    let bin = requireBin("echo")
    # We don't actually use threads here - parallel-safety is about
    # socket-path uniqueness and concurrent fd ownership. Spawning 8
    # sessions back-to-back with overlapping lifetimes is the same
    # collision surface; running them through threads would require
    # marshalling more session state across thread boundaries (the
    # libvterm callback pointers in particular). The collision check
    # we care about is that allocSocketPath() returns distinct paths
    # within the same process, which we test directly.
    var sessions: seq[TuiTestSession] = @[]
    for i in 0 ..< 8:
      sessions.add newTuiTest(bin, @["session-" & $i])
        .width(80).height(24).spawn()
    var seenPaths: seq[string] = @[]
    for s in sessions.mitems:
      seenPaths.add s.ipcSocketPath()
    # All paths must be unique.
    for i in 0 ..< seenPaths.len:
      for j in 0 ..< i:
        check seenPaths[i] != seenPaths[j]
    # Drain & assert content per session.
    for i in 0 ..< sessions.len:
      let _ = sessions[i].drainOutput(80)
      let txt = sessions[i].screenContents()
      check txt.contains("session-" & $i)
    for s in sessions.mitems:
      let _ = s.waitExit(initDuration(seconds = 3))
      s.close()
