## test_harness_six_format_snapshot - snap("page1") writes six files at
## tests/snapshots/page1/. SNAP_RECORD=1 re-records.

import std/[unittest, times, options, os, strutils]
import term_assert
import test_helpers

suite "M28 harness: six-format snapshot":
  test "snap writes six files":
    compileChildApp("test_app_layout")
    let bin = childAppPath("test_app_layout")
    var sess = newTuiTest(bin, @[]).width(80).height(24).spawn()
    let _ = sess.drainOutput(150)
    # Use a temporary root so we don't pollute the repo.
    let tmpRoot = getTempDir() / ("term_assert_snap_" & $epochTime())
    createDir(tmpRoot)
    defer:
      try: removeDir(tmpRoot)
      except CatchableError: discard
    sess.snap("page1", tmpRoot)
    let dir = tmpRoot / "tests" / "snapshots" / "page1"
    check fileExists(dir / "plaintext.txt")
    check fileExists(dir / "ansi.ansi")
    check fileExists(dir / "cellmap.json")
    check fileExists(dir / "svg.svg")
    check fileExists(dir / "annotated.svg")
    check fileExists(dir / "treedump.txt")
    let plaintext = readFile(dir / "plaintext.txt")
    check plaintext.contains("abcdefghij")
    # Re-record path: SNAP_RECORD=1 must overwrite.
    putEnv("SNAP_RECORD", "1")
    sess.snap("page1", tmpRoot)
    delEnv("SNAP_RECORD")
    let _ = sess.waitExit(initDuration(seconds = 3))
    sess.close()
