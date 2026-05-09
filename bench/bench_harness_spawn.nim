## bench_harness_spawn - measure the wall-clock to spawn a pty + drive
## 1000 keystrokes through the harness + close. Target: < 200 ms on the
## reference machine.
##
## Output is written to `bench-results/harness_spawn.json` in
## github-action-benchmark format so CI can track regressions.

import std/[json, monotimes, os, strutils, times]
import term_assert

proc requireBin(name: string): string =
  for dir in getEnv("PATH").split(':'):
    if dir.len == 0: continue
    let candidate = dir / name
    if fileExists(candidate): return candidate
  for fb in ["/bin/" & name, "/usr/bin/" & name]:
    if fileExists(fb): return fb
  raise newException(IOError, "binary not found: " & name)

proc oneRun(bin: string): Duration =
  let t0 = getMonoTime()
  var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
  # Drive 1000 ASCII keystrokes through the pty.
  var s = ""
  for i in 0 ..< 1000:
    s.add char(ord('a') + (i mod 26))
  sess.send(s)
  let _ = sess.drainOutput(20)
  sess.terminate()
  let _ = sess.waitExit(initDuration(seconds = 1))
  sess.close()
  result = getMonoTime() - t0

when isMainModule:
  # `cat` is the simplest "echo back stdin" shim. It's universally
  # available and behaves predictably.
  let bin = requireBin("cat")
  var samples: seq[Duration] = @[]
  for i in 0 ..< 5:
    samples.add oneRun(bin)
  var totalMs: int64 = 0
  for d in samples: totalMs += d.inMilliseconds
  let avgMs = totalMs div samples.len
  echo "harness_spawn average: ", avgMs, " ms (over ", samples.len, " runs)"
  echo "  individual: ",
    samples[0].inMilliseconds, "ms ",
    samples[1].inMilliseconds, "ms ",
    samples[2].inMilliseconds, "ms ",
    samples[3].inMilliseconds, "ms ",
    samples[4].inMilliseconds, "ms"
  let resultsDir = currentSourcePath().parentDir().parentDir() / "bench-results"
  createDir(resultsDir)
  let report = %*[
    {
      "name": "harness_spawn",
      "unit": "ms",
      "value": avgMs,
      "extra": "spawn pty + 1000 keys + close, average over 5 runs"
    }
  ]
  writeFile(resultsDir / "harness_spawn.json", $report & "\n")
