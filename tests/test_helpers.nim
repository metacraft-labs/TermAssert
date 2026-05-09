## test_helpers.nim - shared utilities for TermAssert integration tests.
##
## Every test compiles a tiny child app on demand (via `compileChildApp`),
## then spawns it under the harness. The child apps live in this same
## `tests/` directory with the prefix `test_app_`.

import std/[os, osproc, monotimes, times]

const tagDir = "test-logs"

proc childAppPath*(stem: string): string =
  ## Return the compiled-binary path for a child-app stem like
  ## "echo_keys". The binary is built into `test-logs/` so it doesn't
  ## clutter `tests/`.
  let here = currentSourcePath().parentDir()
  let outDir = here.parentDir() / tagDir
  outDir / stem

proc compileChildApp*(stem: string) =
  ## Compile `tests/<stem>.nim` into `test-logs/<stem>` if not already
  ## up-to-date. The harness tests can then exec the binary directly.
  let here = currentSourcePath().parentDir()
  let src = here / (stem & ".nim")
  let outDir = here.parentDir() / tagDir
  createDir(outDir)
  let outBin = outDir / stem
  if fileExists(outBin):
    let outTime = getFileInfo(outBin).lastWriteTime
    let srcTime = getFileInfo(src).lastWriteTime
    if outTime > srcTime: return
  let extraPaths =
    "--path:" & here.parentDir() / "src" &
    " --path:" & here.parentDir().parentDir() / "TermAssertClient" / "src"
  let cmd = "nim c --styleCheck:usages --styleCheck:error --mm:orc -d:release --threads:on " &
            extraPaths & " -o:" & outBin & " " & src
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    raise newException(IOError,
      "failed to compile child app " & stem & ":\n" & output)

proc waitWithDeadline*(deadlineMs: int; check: proc(): bool {.closure.}): bool =
  ## Wait until `check()` returns true or the deadline elapses. Polls
  ## every 10 ms.
  let dl = getMonoTime() + initDuration(milliseconds = deadlineMs)
  while getMonoTime() < dl:
    if check(): return true
    sleep(10)
  return false
