## test_harness_spawn_echo - the simplest possible end-to-end check:
## `newTuiTest("echo", @["hello"]).spawn()` ends with "hello" visible
## in the screen contents.

import std/[unittest, options, times, os, strutils]
import term_assert

proc requireBin(name: string): string =
  for dir in getEnv("PATH").split(':'):
    if dir.len == 0: continue
    let candidate = dir / name
    if fileExists(candidate): return candidate
  for fb in ["/bin/" & name, "/usr/bin/" & name]:
    if fileExists(fb): return fb
  raise newException(IOError, "binary not found: " & name)

suite "M28 harness: spawn echo":
  test "echo hello":
    let bin = requireBin("echo")
    var sess = newTuiTest(bin, @["hello"]).width(80).height(24).spawn()
    let _ = sess.drainOutput(80)
    let txt = sess.screenContents()
    check txt.contains("hello")
    let ec = sess.waitExit(initDuration(seconds = 2))
    check ec.isSome
    check ec.get == 0
    sess.close()
