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
##
## ## Styled snapshots
##
## `snap` compares `plaintext.txt` only, so a screen whose words are right and
## whose colours are wrong passes it. A STYLED snapshot (`styledSnapshotDiffs`)
## compares the words AND every cell's style, from two small files meant to be
## committed:
##
##   * plaintext.txt - as above;
##   * styles.txt    - every cell's foreground, background and attributes, as a
##                     legend of the distinct styles and one line of runs per
##                     row (`renderStyles` documents the format).
##
## `cellmap.json` carries the same facts but at ~150 bytes a cell, which is
## too large to commit for a screen of any size and too verbose to review;
## `styles.txt` is typically a few hundred bytes a screen. `renderColourSvg`
## draws the screen in its colours (the six-format `svg.svg` draws every
## cell light-on-black), for a reviewer's eyes or a PNG conversion.

import std/[os, strutils, json, unicode]
import nim_libvterm

const
  snapPlainText* = "plaintext.txt"
  snapAnsi* = "ansi.ansi"
  snapCellmap* = "cellmap.json"
  snapSvg* = "svg.svg"
  snapAnnotatedSvg* = "annotated.svg"
  snapTreedump* = "treedump.txt"
  snapStyles* = "styles.txt"
    ## A styled snapshot's second file (`renderStyles`); not one of the six.

  snapAllFiles* = [
    snapPlainText, snapAnsi, snapCellmap,
    snapSvg, snapAnnotatedSvg, snapTreedump]

proc renderPlain*(s: Screen): string =
  ## Plain UTF-8: one row per line, trailing whitespace stripped.
  ##
  ## Width-2 cells emit the wide rune once; their trailing-half continuation
  ## cell (`width == 0`) is skipped. That is the same rule isonim-tui's
  ## `testing/snapshot/plaintext.encodePlaintext` states in its own docstring,
  ## and this encoder claims — in this module's header — to produce the same
  ## six-file layout, so the rule has to be the same one. Emitting a space for
  ## the continuation instead added one character per wide glyph and made the
  ## two tiers' `plaintext.txt` differ over screens that were identical.
  let (rows, cols) = s.size()
  result = ""
  for r in 0 ..< rows:
    var line = ""
    for c in 0 ..< cols:
      let cell = s.cellAt(r, c)
      if cell.width == 0: continue
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
      # Same rule as `renderPlain`: the trailing half of a width-2 glyph is
      # not a character, and emitting one for it would shift every cell to its
      # right by a column when this stream is replayed.
      if cell.width == 0: continue
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
      # UNDERLINE IS NOT ONE OF `Cell.attrs`, and leaving it out made this
      # file silent about a styling difference the Screen knows. libvterm
      # models underline as a 2-bit style field rather than a boolean SGR
      # flag, so `attrsJson` above cannot carry it; a compositor that emits
      # `CSI 4 m` and one that does not produced byte-identical `cellmap.json`
      # here. Emitted as the style's name so `usSingle` / `usDouble` /
      # `usCurly` / `usDotted` / `usDashed` stay distinguishable.
      ch["underline"] = %($cell.underline)
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

proc colourSpelling(c: Color): string =
  case c.kind
  of ckDefault: "default"
  of ckIndexed: "i" & $int(c.idx)
  of ckRgb: "#" & toHex(int(c.r), 2).toLowerAscii & toHex(int(c.g), 2).toLowerAscii &
            toHex(int(c.b), 2).toLowerAscii

proc styleKey*(cell: Cell): string =
  ## One cell's style: `<fg>/<bg>` and its attributes, each `+name`, in a
  ## fixed order (bold, italic, blink, reverse, conceal, strike, then the
  ## underline style when there is one).
  result = colourSpelling(cell.fg) & "/" & colourSpelling(cell.bg)
  if caBold in cell.attrs: result.add "+bold"
  if caItalic in cell.attrs: result.add "+italic"
  if caBlink in cell.attrs: result.add "+blink"
  if caReverse in cell.attrs: result.add "+reverse"
  if caConceal in cell.attrs: result.add "+conceal"
  if caStrike in cell.attrs: result.add "+strike"
  if cell.underline != usNone: result.add "+underline:" & $cell.underline

const StylesHeader = "# TermAssert styles v1"

proc renderStyles*(s: Screen): string =
  ## The screen's cell styles as text:
  ##
  ##     # TermAssert styles v1 <rows>x<cols>
  ##     <n> <style>        one per distinct style, numbered by first use
  ##     ...
  ##     r<row>: <n>*<count> <n>*<count> ...
  ##
  ## Styles are numbered in row-major order of first appearance, so the file
  ## is a function of the screen. The trailing half of a width-2 glyph is not
  ## a cell of its own here (as in `renderPlain`): it carries the glyph's
  ## style and is skipped.
  let (rows, cols) = s.size()
  var legend: seq[string]
  var runsText = ""
  for r in 0 ..< rows:
    var line = "r" & $r & ":"
    var current = -1
    var count = 0
    for c in 0 ..< cols:
      let cell = s.cellAt(r, c)
      if cell.width == 0: continue
      let key = styleKey(cell)
      var id = legend.find(key)
      if id < 0:
        legend.add key
        id = legend.high
      if id == current:
        inc count
      else:
        if current >= 0: line.add " " & $current & "*" & $count
        current = id
        count = 1
    if current >= 0: line.add " " & $current & "*" & $count
    runsText.add line & "\n"
  result = StylesHeader & " " & $rows & "x" & $cols & "\n"
  for i, key in legend: result.add $i & " " & key & "\n"
  result.add runsText

proc parseStyles*(text: string): seq[seq[string]] =
  ## `renderStyles`' text back as each row's cell styles. Raises
  ## `ValueError` on text that is not in that format.
  var legend: seq[string]
  for raw in text.splitLines:
    let line = raw.strip(leading = false)
    if line.len == 0 or line.startsWith("#"): continue
    if line.startsWith("r"):
      let colon = line.find(':')
      if colon < 0: raise newException(ValueError, "styles: no ':' in " & line)
      var row: seq[string]
      for run in strutils.splitWhitespace(line[colon + 1 .. ^1]):
        let star = run.find('*')
        if star < 0: raise newException(ValueError, "styles: bad run " & run)
        let id = parseInt(run[0 ..< star])
        if id < 0 or id >= legend.len:
          raise newException(ValueError, "styles: style " & $id & " is not in the legend")
        for _ in 0 ..< parseInt(run[star + 1 .. ^1]): row.add legend[id]
      result.add row
    else:
      let space = line.find(' ')
      if space < 0: raise newException(ValueError, "styles: bad legend line " & line)
      if parseInt(line[0 ..< space]) != legend.len:
        raise newException(ValueError, "styles: legend out of order at " & line)
      legend.add line[space + 1 .. ^1]

proc styleDiffs*(golden, actual: string; limit = 12): seq[string] =
  ## Where two `renderStyles` texts disagree, cell by cell: at most `limit`
  ## named cells, then a count of the rest.
  let g = parseStyles(golden)
  let a = parseStyles(actual)
  if g.len != a.len:
    return @["styles: " & $g.len & " rows in the golden, " & $a.len & " now"]
  var extra = 0
  for r in 0 ..< g.len:
    for c in 0 ..< max(g[r].len, a[r].len):
      let gk = if c < g[r].len: g[r][c] else: "<none>"
      let ak = if c < a[r].len: a[r][c] else: "<none>"
      if gk != ak:
        if result.len < limit:
          result.add "cell (" & $r & "," & $c & "): golden " & gk & ", now " & ak
        else:
          inc extra
  if extra > 0: result.add "... and " & $extra & " more cells"

proc shouldRecord*(): bool

proc styledSnapshotDiffs*(s: Screen; dir: string): seq[string] =
  ## Compare `s` with the styled snapshot in `dir` (`plaintext.txt`,
  ## `styles.txt`): empty when both agree. Writes the two files instead, and
  ## reports nothing, when `SNAP_RECORD=1` or when `dir` holds no snapshot
  ## yet -- the same rule as `snap`. A plaintext difference is reported by
  ## row, a style difference by cell.
  let plain = renderPlain(s)
  let styles = renderStyles(s)
  if shouldRecord() or not fileExists(dir / snapPlainText) or
      not fileExists(dir / snapStyles):
    createDir(dir)
    writeFile(dir / snapPlainText, plain)
    writeFile(dir / snapStyles, styles)
    return
  let goldenPlain = readFile(dir / snapPlainText)
  if goldenPlain != plain:
    let lg = goldenPlain.splitLines()
    let la = plain.splitLines()
    for i in 0 ..< max(lg.len, la.len):
      let g = if i < lg.len: lg[i] else: ""
      let a = if i < la.len: la[i] else: ""
      if g != a: result.add "row " & $i & ":\n  golden: " & g & "\n  now:    " & a
  let goldenStyles = readFile(dir / snapStyles)
  if goldenStyles != styles:
    try:
      result.add styleDiffs(goldenStyles, styles)
    except ValueError as e:
      result.add "styles.txt in " & dir & " is unreadable: " & e.msg

proc xmlEscape(s: string): string =
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

proc resolved(c: Color; fallback: string): string =
  case c.kind
  of ckRgb: colourSpelling(c)
  of ckIndexed:
    # The xterm palette (https://invisible-island.net/xterm/xterm.faq.html#color_by_number):
    # the 16 system colours, the 6x6x6 cube and the grey ramp.
    const System = ["#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd",
                    "#00cdcd", "#e5e5e5", "#7f7f7f", "#ff0000", "#00ff00", "#ffff00",
                    "#5c5cff", "#ff00ff", "#00ffff", "#ffffff"]
    let i = int(c.idx)
    if i < 16: System[i]
    elif i < 232:
      let k = i - 16
      proc level(v: int): int = (if v == 0: 0 else: 55 + 40 * v)
      "#" & toHex(level(k div 36), 2).toLowerAscii & toHex(level((k div 6) mod 6), 2).toLowerAscii &
        toHex(level(k mod 6), 2).toLowerAscii
    else:
      let v = 8 + 10 * (i - 232)
      "#" & toHex(v, 2).toLowerAscii & toHex(v, 2).toLowerAscii & toHex(v, 2).toLowerAscii
  of ckDefault: fallback

proc renderColourSvg*(s: Screen; defaultFg = "#eeeeee"; defaultBg = "#000000";
                      cellW = 8; cellH = 16; fontSize = 13;
                      fontFamily = "DejaVu Sans Mono, monospace"): string =
  ## The screen drawn in its own colours: each cell's background as a
  ## rectangle (runs of one colour merged), each glyph in its foreground at
  ## its cell's position, bold as `font-weight: bold`, `reverse` swapping the
  ## two, underline as a line under the cell. A cell `cellW` x `cellH`
  ## pixels; the terminal's default colours are `defaultFg` / `defaultBg`.
  let (rows, cols) = s.size()
  let w = cols * cellW
  let h = rows * cellH
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & $w & "\" height=\"" & $h &
           "\" font-family=\"" & fontFamily & "\" font-size=\"" & $fontSize & "\">\n"
  result.add "<rect x=\"0\" y=\"0\" width=\"" & $w & "\" height=\"" & $h &
             "\" fill=\"" & defaultBg & "\"/>\n"
  proc colours(cell: Cell): (string, string) =
    var fg = resolved(cell.fg, defaultFg)
    var bg = resolved(cell.bg, defaultBg)
    if caReverse in cell.attrs: swap(fg, bg)
    (fg, bg)
  for r in 0 ..< rows:
    var c = 0
    while c < cols:
      let (_, bg) = colours(s.cellAt(r, c))
      var e = c + 1
      while e < cols and colours(s.cellAt(r, e))[1] == bg: inc e
      if bg != defaultBg:
        result.add "<rect x=\"" & $(c * cellW) & "\" y=\"" & $(r * cellH) & "\" width=\"" &
                   $((e - c) * cellW) & "\" height=\"" & $cellH & "\" fill=\"" & bg & "\"/>\n"
      c = e
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let cell = s.cellAt(r, c)
      if cell.width == 0: continue
      let (fg, _) = colours(cell)
      if cell.underline != usNone:
        result.add "<rect x=\"" & $(c * cellW) & "\" y=\"" & $(r * cellH + cellH - 2) &
                   "\" width=\"" & $(max(1, cell.width) * cellW) & "\" height=\"1\" fill=\"" & fg & "\"/>\n"
      if cell.rune.int32 == 0 or cell.rune.int32 == 32: continue
      result.add "<text x=\"" & $(c * cellW) & "\" y=\"" & $(r * cellH + cellH - 4) &
                 "\" fill=\"" & fg & "\"" &
                 (if caBold in cell.attrs: " font-weight=\"bold\"" else: "") &
                 ">" & xmlEscape($cell.rune) & "</text>\n"
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
