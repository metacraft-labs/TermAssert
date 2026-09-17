## test_snapshot_encoder_fidelity - the six-format encoders against a Screen
## whose contents this file chose.
##
## `test_harness_six_format_snapshot.nim` asserts that `snap` WRITES six files.
## This one asserts what is IN two of them, because the module header of
## `term_assert/snapshot.nim` makes a stronger claim than "six files exist":
##
##     "Writes the harness-captured Screen state as the same six-file layout
##      that isonim-tui's M2 TerminalTestHarness produces. The two harness
##      tiers can therefore share tests/snapshots/ directories."
##
## Two defects were found against that claim by a cross-tier comparison, and
## both are pinned here:
##
##   * `renderPlain` emitted a SPACE for the trailing half of a width-2 glyph,
##     which isonim-tui's `encodePlaintext` skips by its own documented rule.
##     Measured: one extra character per wide glyph -- a 71-wide-glyph screen's
##     plaintext.txt grew from 1 904 bytes to 1 975 -- so two tiers rendering
##     an IDENTICAL screen produced different files.
##   * `renderCellmap` did not encode `underline` AT ALL. libvterm models
##     underline as a 2-bit style field rather than a boolean SGR flag, so
##     `attrsJson` cannot carry it, and a stream that emits `CSI 4 m` and one
##     that does not produced BYTE-IDENTICAL cellmap.json.
##
## No pty and no child process: the subject is the encoders, and a `Screen` fed
## the bytes directly is the smallest thing that has one.

import std/[json, strutils, unittest, unicode]
import nim_libvterm
import term_assert

suite "snapshot encoders: fidelity of the written files":

  test "renderPlain skips the trailing half of a wide glyph":
    var s = newScreen(3, 20)
    s.feed("\x1b[2J\x1b[H┌世界─┐")
    let rows = renderPlain(s).split('\n')
    # The wide glyphs occupy two columns each on the screen but are ONE
    # character each in the text, exactly as isonim-tui's `encodePlaintext`
    # writes them.
    check rows[0] == "┌世界─┐"
    check rows[0].runeLen == 5
    check rows.len == 3
    # The positive twin, through the same encoder: a narrow row is unchanged,
    # so "skip width 0" has not become "skip something else".
    var t = newScreen(1, 20)
    t.feed("\x1b[2J\x1b[Habc def")
    check renderPlain(t).split('\n')[0] == "abc def"

  test "renderAnsi does not re-emit the continuation column":
    # The same rule on the replayable stream: a character emitted for the
    # trailing half shifts every cell to its right by one column when the
    # stream is replayed.
    var s = newScreen(1, 12)
    s.feed("\x1b[2J\x1b[H世界|")
    var replayed = newScreen(1, 12)
    replayed.feed(renderAnsi(s))
    check renderPlain(replayed).split('\n')[0] == "世界|"
    check $replayed.cellAt(0, 0).rune == "世"
    check replayed.cellAt(0, 1).width == 0
    check $replayed.cellAt(0, 2).rune == "界"
    check replayed.cellAt(0, 3).width == 0
    check $replayed.cellAt(0, 4).rune == "|"

  test "renderCellmap carries the underline style":
    var underlined = newScreen(1, 8)
    underlined.feed("\x1b[2J\x1b[H\x1b[4mabc\x1b[0m")
    var plain = newScreen(1, 8)
    plain.feed("\x1b[2J\x1b[Habc")

    let u = parseJson(renderCellmap(underlined))["cells"][0][0]
    let p = parseJson(renderCellmap(plain))["cells"][0][0]
    check u.hasKey("underline")
    check u["underline"].getStr() == "usSingle"
    check p["underline"].getStr() == "usNone"
    # THE POINT, stated as the thing that was false: the two files differ.
    # `attrs` cannot carry it -- libvterm's underline is a style field, not one
    # of the boolean SGR attributes -- so without the key the two screens were
    # byte-identical here.
    check u["attrs"] == p["attrs"]
    check renderCellmap(underlined) != renderCellmap(plain)

  test "renderCellmap distinguishes the modern underline styles":
    # `usSingle` alone would let a curly/dotted/dashed distinction collapse to
    # a boolean the moment somebody re-spelled the field.
    for (param, expected) in [("4", "usSingle"), ("4:2", "usDouble"),
                              ("4:3", "usCurly"), ("4:4", "usDotted"),
                              ("4:5", "usDashed")]:
      var s = newScreen(1, 4)
      s.feed("\x1b[2J\x1b[H\x1b[" & param & "mx")
      let cell = parseJson(renderCellmap(s))["cells"][0][0]
      check cell["underline"].getStr() == expected

  test "renderCellmap reports the wide pair as 2 and 0":
    var s = newScreen(1, 8)
    s.feed("\x1b[2J\x1b[H世x")
    let cells = parseJson(renderCellmap(s))["cells"][0]
    check cells[0]["rune"].getStr() == "世"
    check cells[0]["width"].getInt() == 2
    check cells[1]["width"].getInt() == 0
    check cells[2]["rune"].getStr() == "x"
    check cells[2]["width"].getInt() == 1
