## test_styled_snapshot - the styled snapshot (`styledSnapshotDiffs`,
## `renderStyles`, `parseStyles`) and the colour SVG (`renderColourSvg`),
## over Screens whose contents this file chose.
##
## `snap` compares `plaintext.txt` only (its own comment says the other five
## formats are refreshed, not diffed), so a screen whose words were right and
## whose colours were wrong passed it. A consumer that asserts on colours --
## CodeTracer's terminal views, whose areas are told apart by background --
## needs the styles compared too, from a file small enough to commit. These
## cases pin what that file says and that a one-cell colour change, a changed
## attribute and a changed word are each reported.
##
## No mocks: a real libvterm Screen (`newScreen` + `feed`, the parser every
## harness session uses) and the real filesystem.

import std/[unittest, os, strutils, times]
import nim_libvterm
import term_assert/snapshot

proc screenOf(rows, cols: int; bytes: string): Screen =
  result = newScreen(rows, cols)
  result.feed("\x1b[2J\x1b[H" & bytes)

let tmpRoot = getTempDir() / ("term_assert_styled_" & $epochTime())
createDir(tmpRoot)

suite "styled snapshot":
  test "renderStyles numbers styles by first use and runs them per row":
    let s = screenOf(2, 6, "\x1b[38;2;1;2;3;48;2;10;20;30mab\x1b[0m\x1b[1mcd\x1b[0m\r\n\x1b[4mxy\x1b[0m")
    let text = renderStyles(s)
    let lines = text.splitLines
    check lines[0] == "# TermAssert styles v1 2x6"
    check lines[1] == "0 #010203/#0a141e"
    check lines[2] == "1 default/default+bold"
    check lines[3] == "2 default/default"
    check lines[4] == "3 default/default+underline:usSingle"
    check lines[5] == "r0: 0*2 1*2 2*2"
    check lines[6] == "r1: 3*2 2*4"
    let parsed = parseStyles(text)
    check parsed.len == 2
    check parsed[0].len == 6
    check parsed[0][0] == "#010203/#0a141e"
    check parsed[1][1] == "default/default+underline:usSingle"

  test "indexed colours and a wide glyph's trailing half":
    let s = screenOf(1, 6, "\x1b[38;5;196m\xE4\xB8\x96\x1b[0mz")
    let rows = parseStyles(renderStyles(s))
    # The wide glyph is one cell here, as in renderPlain.
    check rows[0].len == 5
    check rows[0][0] == "i196/default"

  test "a screen that matches its snapshot reports nothing":
    let s = screenOf(2, 8, "\x1b[48;2;40;40;40mpanel\x1b[0m")
    let dir = tmpRoot / "match"
    check styledSnapshotDiffs(s, dir).len == 0      # first run records
    check fileExists(dir / snapPlainText)
    check fileExists(dir / snapStyles)
    check styledSnapshotDiffs(s, dir).len == 0      # second run compares

  test "one cell's background is reported by its cell":
    let golden = screenOf(1, 8, "\x1b[48;2;40;40;40mpanel\x1b[0m")
    let dir = tmpRoot / "background"
    discard styledSnapshotDiffs(golden, dir)
    let changed = screenOf(1, 8, "\x1b[48;2;40;40;40mpan\x1b[48;2;41;40;40me\x1b[48;2;40;40;40ml\x1b[0m")
    let diffs = styledSnapshotDiffs(changed, dir)
    check diffs.len == 1
    check diffs[0] == "cell (0,3): golden default/#282828, now default/#292828"

  test "an attribute and a word are both reported":
    let golden = screenOf(1, 8, "abc")
    let dir = tmpRoot / "attr"
    discard styledSnapshotDiffs(golden, dir)
    let bolder = screenOf(1, 8, "a\x1b[1mb\x1b[0mc")
    let d1 = styledSnapshotDiffs(bolder, dir)
    check d1.len == 1
    check d1[0].contains("cell (0,1)") and d1[0].contains("+bold")
    let worded = screenOf(1, 8, "abd")
    let d2 = styledSnapshotDiffs(worded, dir)
    check d2.len == 1
    check d2[0].contains("golden: abc") and d2[0].contains("now:    abd")

  test "SNAP_RECORD=1 re-records instead of comparing":
    let dir = tmpRoot / "record"
    discard styledSnapshotDiffs(screenOf(1, 4, "old"), dir)
    putEnv("SNAP_RECORD", "1")
    check styledSnapshotDiffs(screenOf(1, 4, "new"), dir).len == 0
    delEnv("SNAP_RECORD")
    check readFile(dir / snapPlainText) == "new"

  test "a styles file that is not in the format is reported, not trusted":
    let dir = tmpRoot / "broken"
    discard styledSnapshotDiffs(screenOf(1, 4, "abc"), dir)
    writeFile(dir / snapStyles, "# TermAssert styles v1 1x4\nr0: 7*4\n")
    let diffs = styledSnapshotDiffs(screenOf(1, 4, "abc"), dir)
    check diffs.len == 1
    check diffs[0].contains("unreadable")

  test "renderColourSvg draws backgrounds and glyphs in their colours":
    let s = screenOf(1, 4, "\x1b[38;2;255;0;0;48;2;0;0;255mA\x1b[0m\x1b[7mB\x1b[0m")
    let svg = renderColourSvg(s, defaultFg = "#eeeeee", defaultBg = "#000000")
    check svg.contains("<rect x=\"0\" y=\"0\" width=\"8\" height=\"16\" fill=\"#0000ff\"/>")
    check svg.contains("fill=\"#ff0000\">A</text>")
    # Reverse swaps the defaults: a light cell, a dark glyph.
    check svg.contains("<rect x=\"8\" y=\"0\" width=\"8\" height=\"16\" fill=\"#eeeeee\"/>")
    check svg.contains("fill=\"#000000\">B</text>")

removeDir(tmpRoot)
