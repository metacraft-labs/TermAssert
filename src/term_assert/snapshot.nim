## term_assert/snapshot.nim - six-format snapshot writer.
##
## Writes the harness-captured Screen state as the same six-file layout
## that `isonim-tui`'s M2 `TerminalTestHarness` produces. The two harness
## tiers can therefore share `tests/snapshots/` directories - a snapshot
## taken in either tier is comparable to a snapshot taken in the other.
##
## Files written under `tests/snapshots/<name>/`:
##   * plaintext.txt    - the screen as plain UTF-8, one row per line
##   * ansi.ansi        - reconstructed ANSI byte stream (best-effort)
##   * cellmap.json     - per-cell rune+attrs metadata
##   * svg.svg          - rendered SVG of the screen
##   * annotated.svg    - SVG with cell-coordinate guides
##   * treedump.txt     - text dump of the cell-by-cell state
##
## When the env var `SNAP_RECORD=1` is set, `compareSnap` becomes
## `recordSnap`: existing files are overwritten with the current state.
## Otherwise mismatches surface as test failures with a diff.

import std/[os, strutils, json, unicode]
import nim_libvterm

const
  snapPlainText* = "plaintext.txt"
  snapAnsi* = "ansi.ansi"
  snapCellmap* = "cellmap.json"
  snapSvg* = "svg.svg"
  snapAnnotatedSvg* = "annotated.svg"
  snapTreedump* = "treedump.txt"

  snapAllFiles* = [
    snapPlainText, snapAnsi, snapCellmap,
    snapSvg, snapAnnotatedSvg, snapTreedump]

proc renderPlain*(s: Screen): string =
  ## Plain UTF-8: one row per line, trailing whitespace stripped.
  let (rows, cols) = s.size()
  result = ""
  for r in 0 ..< rows:
    var line = ""
    for c in 0 ..< cols:
      let cell = s.cellAt(r, c)
      if cell.rune.int32 == 0:
        line.add ' '
      else:
        line.add $cell.rune
    line = line.strip(leading = false, trailing = true)
    result.add line
    if r + 1 < rows: result.add '\n'

proc renderAnsi*(s: Screen): string =
  ## Best-effort: emit a sequence that reproduces the screen content via
  ## SGR + cursor-positioning. Not a perfect inversion (libvterm won't
  ## tell us about every state nuance) but enough to faithfully replay
  ## the printable cells with their colors.
  let (rows, cols) = s.size()
  result = "\x1b[2J\x1b[H"
  for r in 0 ..< rows:
    result.add "\x1b[" & $(r+1) & ";1H"
    for c in 0 ..< cols:
      let cell = s.cellAt(r, c)
      var sgr = "\x1b[0m"
      if caBold in cell.attrs: sgr.add "\x1b[1m"
      if caItalic in cell.attrs: sgr.add "\x1b[3m"
      if caBlink in cell.attrs: sgr.add "\x1b[5m"
      if caReverse in cell.attrs: sgr.add "\x1b[7m"
      if caStrike in cell.attrs: sgr.add "\x1b[9m"
      case cell.fg.kind
      of ckRgb: sgr.add "\x1b[38;2;" & $cell.fg.r & ";" & $cell.fg.g & ";" & $cell.fg.b & "m"
      of ckIndexed: sgr.add "\x1b[38;5;" & $cell.fg.idx & "m"
      of ckDefault: discard
      case cell.bg.kind
      of ckRgb: sgr.add "\x1b[48;2;" & $cell.bg.r & ";" & $cell.bg.g & ";" & $cell.bg.b & "m"
      of ckIndexed: sgr.add "\x1b[48;5;" & $cell.bg.idx & "m"
      of ckDefault: discard
      result.add sgr
      if cell.rune.int32 == 0:
        result.add ' '
      else:
        result.add $cell.rune

proc colorJson(c: Color): JsonNode =
  case c.kind
  of ckDefault: %*{"kind": "default"}
  of ckIndexed: %*{"kind": "indexed", "idx": int(c.idx)}
  of ckRgb: %*{"kind": "rgb", "r": int(c.r), "g": int(c.g), "b": int(c.b)}

proc attrsJson(attrs: set[CellAttr]): JsonNode =
  result = newJArray()
  if caBold in attrs: result.add %"bold"
  if caItalic in attrs: result.add %"italic"
  if caBlink in attrs: result.add %"blink"
  if caReverse in attrs: result.add %"reverse"
  if caConceal in attrs: result.add %"conceal"
  if caStrike in attrs: result.add %"strike"

proc renderCellmap*(s: Screen): string =
  let (rows, cols) = s.size()
  var root = newJObject()
  root["rows"] = %rows
  root["cols"] = %cols
  var arr = newJArray()
  for r in 0 ..< rows:
    var row = newJArray()
    for c in 0 ..< cols:
      let cell = s.cellAt(r, c)
      var ch = newJObject()
      let runeStr = if cell.rune.int32 == 0: " " else: $cell.rune
      ch["rune"] = %runeStr
      ch["fg"] = colorJson(cell.fg)
      ch["bg"] = colorJson(cell.bg)
      ch["attrs"] = attrsJson(cell.attrs)
      ch["width"] = %cell.width
      ch["hyperlinkId"] = %int(uint32(cell.hyperlinkId))
      ch["imageRef"] = %int(uint32(cell.imageRef))
      row.add ch
    arr.add row
  root["cells"] = arr
  result = $root

proc renderSvg*(s: Screen): string =
  ## Minimal SVG: one rect per cell + one `<text>` for non-blank cells.
  let (rows, cols) = s.size()
  let cw = 8
  let ch = 16
  let w = cols * cw
  let h = rows * ch
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & $w &
           "\" height=\"" & $h & "\" font-family=\"monospace\" font-size=\"14\">\n"
  result.add "<rect x=\"0\" y=\"0\" width=\"" & $w & "\" height=\"" & $h & "\" fill=\"black\"/>\n"
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let cell = s.cellAt(r, c)
      if cell.rune.int32 == 0: continue
      let x = c * cw
      let y = r * ch + ch - 3
      var glyph = $cell.rune
      glyph = glyph.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
      result.add "<text x=\"" & $x & "\" y=\"" & $y &
                 "\" fill=\"#eee\">" & glyph & "</text>\n"
  result.add "</svg>\n"

proc renderAnnotatedSvg*(s: Screen): string =
  ## SVG plus a faint grid + 10-cell tick marks for visual diffing.
  let (rows, cols) = s.size()
  let cw = 8
  let ch = 16
  let w = cols * cw
  let h = rows * ch
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & $w &
           "\" height=\"" & $h & "\" font-family=\"monospace\" font-size=\"14\">\n"
  result.add "<rect x=\"0\" y=\"0\" width=\"" & $w & "\" height=\"" & $h & "\" fill=\"black\"/>\n"
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let cell = s.cellAt(r, c)
      if cell.rune.int32 == 0: continue
      let x = c * cw
      let y = r * ch + ch - 3
      var glyph = $cell.rune
      glyph = glyph.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
      result.add "<text x=\"" & $x & "\" y=\"" & $y &
                 "\" fill=\"#eee\">" & glyph & "</text>\n"
  # Grid every 10 cols/rows.
  for c in 0 ..< cols:
    if c mod 10 != 0: continue
    let x = c * cw
    result.add "<line x1=\"" & $x & "\" y1=\"0\" x2=\"" & $x & "\" y2=\"" & $h &
               "\" stroke=\"#444\" stroke-width=\"0.3\"/>\n"
  for r in 0 ..< rows:
    if r mod 5 != 0: continue
    let y = r * ch
    result.add "<line x1=\"0\" y1=\"" & $y & "\" x2=\"" & $w & "\" y2=\"" & $y &
               "\" stroke=\"#444\" stroke-width=\"0.3\"/>\n"
  result.add "</svg>\n"

proc renderTreedump*(s: Screen): string =
  let (rows, cols) = s.size()
  result = "Screen " & $rows & "x" & $cols & "\n"
  let (cr, cc) = s.cursorPosition()
  result.add "Cursor (" & $cr & "," & $cc & ") shape=" & $s.cursorShape() &
             " visible=" & $s.cursorVisible() & "\n"
  result.add "Title: " & s.title() & "\n"
  result.add "Cells:\n"
  for r in 0 ..< rows:
    result.add "  row " & $r & ": "
    for c in 0 ..< cols:
      let cell = s.cellAt(r, c)
      if cell.rune.int32 == 0:
        result.add '.'
      else:
        result.add $cell.rune
    result.add '\n'

proc shouldRecord*(): bool =
  let v = getEnv("SNAP_RECORD")
  v == "1" or v == "true" or v == "yes"

proc writeFiles*(s: Screen; dir: string) =
  ## Force-write all six golden files into `dir` (creating the directory
  ## if needed). Used in record mode and on first run.
  createDir(dir)
  writeFile(dir / snapPlainText, renderPlain(s))
  writeFile(dir / snapAnsi, renderAnsi(s))
  writeFile(dir / snapCellmap, renderCellmap(s))
  writeFile(dir / snapSvg, renderSvg(s))
  writeFile(dir / snapAnnotatedSvg, renderAnnotatedSvg(s))
  writeFile(dir / snapTreedump, renderTreedump(s))

proc snapshotDir*(name: string; root: string = ""): string =
  ## Resolve a snapshot directory under `<root>/tests/snapshots/<name>`.
  ## When `root` is empty, defaults to the current working directory.
  let r = if root.len == 0: getCurrentDir() else: root
  r / "tests" / "snapshots" / name
