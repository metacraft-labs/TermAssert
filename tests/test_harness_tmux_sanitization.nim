## test_harness_tmux_sanitization - TMUX and TMUX_PANE are stripped from
## the spawned env by default; spawning `env` proves it.

import std/[unittest, times, options, os, strutils]
import term_assert

proc requireBin(name: string): string =
  for dir in getEnv("PATH").split(':'):
    if dir.len == 0: continue
    let candidate = dir / name
    if fileExists(candidate): return candidate
  for fb in ["/bin/" & name, "/usr/bin/" & name]:
    if fileExists(fb): return fb
  raise newException(IOError, "binary not found: " & name)

suite "M28 harness: tmux sanitization":
  test "TMUX and TMUX_PANE are stripped":
    putEnv("TMUX", "/tmp/tmux-something")
    putEnv("TMUX_PANE", "%99")
    let bin = requireBin("env")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    let _ = sess.drainOutput(120)
    let txt = sess.screenContents()
    check not txt.contains("TMUX=/tmp")
    check not txt.contains("TMUX_PANE=%99")
    let _ = sess.waitExit(initDuration(seconds = 3))
    sess.close()
    delEnv("TMUX")
    delEnv("TMUX_PANE")
