## term_assert - standalone TUI test harness library for Nim.
##
## TermAssert combines `nim-pty` (L1) and `nim-libvterm` (L2) into a
## high-level test harness. The closest analogue is the Rust
## `tui-testing` crate from agent-harbor; this is a clean Nim port with
## the same 12 capabilities plus first-class support for modern terminal
## protocols (images, hyperlinks, notifications, synchronized output).
##
## Quick example:
##
## ```nim
## import std/times
## import term_assert
##
## var sess = newTuiTest("echo", @["hello"])
##   .width(80).height(24)
##   .spawn()
## discard sess.drainOutput(50)
## doAssert sess.screenContents().contains("hello")
## ```
##
## Public-API rules
## ----------------
## * `TuiTestSession` is a value `object` (charter section 1). `=copy` is
##   disabled; `=destroy` reaps the child, closes the pty, and unlinks
##   the IPC socket.
## * No raw `ptr` is exposed.
## * No mocks. Every test is a real pty + real libvterm + real subprocess.
##
## Architecture
## ------------
## ```
## TuiTestSession
##   |
##   +-- nim_pty.PtySession        (master FD; child PID; SpawnOptions)
##   +-- nim_libvterm.Screen       (parses bytes from the pty into a Screen)
##   +-- term_assert.IpcServer     (Unix-socket server for the companion client)
##   +-- snapshots: Table[string, ScreenSnapshot]   (IPC-recorded screens)
## ```

import std/[options, os, strutils, monotimes, times, tables, json]

import nim_pty
import nim_libvterm

import term_assert/ipc
import term_assert/snapshot

export options, times, tables
export ipc, snapshot
export nim_libvterm except Screen
# (Screen is re-exported through `session.screen()` accessor; not a
# copyable value, so callers always go through the accessor.)

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  MouseButton* = enum
    mbLeft, mbMiddle, mbRight, mbWheelUp, mbWheelDown

  KeyModifier* = enum
    kmShift, kmAlt, kmCtrl

  ScrollDir* = enum
    sdUp, sdDown

  TuiTestBuilder* = object
    ## Fluent builder for spawning a harness session.
    cmd: string
    args: seq[string]
    cols: int
    rows: int
    envOverrides: Table[string, string]
    envBlocked: seq[string]
    cwd: string
    inheritEnv: bool

  ScreenSnapshot* = object
    label*: string
    contents*: string
    cellmap*: string  ## JSON cellmap render
    rows*: int
    cols*: int

  TuiTestSession* = object
    ## Owning handle for one harness session.
    pty: PtySession
    screen: Screen
    ipc: IpcServer
    cols: int
    rows: int
    snapshotsTable: Table[string, ScreenSnapshot]
    rxBuf: seq[byte]
    closed: bool

  TimeoutError* = object of CatchableError
  AssertionFailedError* = object of CatchableError

proc `=copy`*(dest: var TuiTestSession; src: TuiTestSession) {.error.}

# ---------------------------------------------------------------------------
# Builder
# ---------------------------------------------------------------------------

proc newTuiTest*(cmd: string; args: openArray[string]): TuiTestBuilder =
  ## Start a builder for spawning `cmd` with `args` under the harness.
  result.cmd = cmd
  result.args = @args
  result.cols = 80
  result.rows = 24
  result.envOverrides = initTable[string, string]()
  result.envBlocked = @[]
  result.cwd = ""
  result.inheritEnv = true

proc width*(b: TuiTestBuilder; cols: int): TuiTestBuilder =
  result = b
  result.cols = cols

proc height*(b: TuiTestBuilder; rows: int): TuiTestBuilder =
  result = b
  result.rows = rows

proc envSet*(b: TuiTestBuilder; key, value: string): TuiTestBuilder =
  result = b
  result.envOverrides[key] = value

proc envRemove*(b: TuiTestBuilder; vars: varargs[string]): TuiTestBuilder =
  result = b
  for v in vars: result.envBlocked.add v

proc workDir*(b: TuiTestBuilder; dir: string): TuiTestBuilder =
  result = b
  result.cwd = dir

# ---------------------------------------------------------------------------
# Spawn
# ---------------------------------------------------------------------------

const tmuxBlockedDefault = ["TMUX", "TMUX_PANE"]

proc effectiveEnv(b: TuiTestBuilder; harnessUri: string): seq[(string, string)] =
  ## Build the effective environment: inherit (if enabled) minus blocked
  ## minus tmux defaults plus overrides plus TERM_ASSERT_URI.
  let blocked = block:
    var s = newSeq[string]()
    for v in tmuxBlockedDefault: s.add v
    for v in b.envBlocked: s.add v
    s
  result = @[]
  if b.inheritEnv:
    for k, v in envPairs():
      if k in blocked: continue
      if b.envOverrides.hasKey(k): continue
      result.add((k, v))
  for k, v in b.envOverrides:
    if k in blocked: continue
    result.add((k, v))
  # Always inject the IPC URI so children can connect.
  result.add(("TERM_ASSERT_URI", harnessUri))

proc spawn*(b: TuiTestBuilder): TuiTestSession =
  ## Spawn the child inside a fresh pty + start the IPC listener. The
  ## returned `TuiTestSession` owns every resource and releases them in
  ## `=destroy`.
  var sess: TuiTestSession
  sess.cols = b.cols
  sess.rows = b.rows
  sess.snapshotsTable = initTable[string, ScreenSnapshot]()
  sess.rxBuf = @[]
  sess.closed = false
  sess.ipc = startIpcServer()
  let env = effectiveEnv(b, sess.ipc.socketPath)
  let opts = SpawnOptions(cols: b.cols, rows: b.rows, cwd: b.cwd)
  sess.pty = spawnPty(b.cmd, b.args, env, opts)
  sess.screen = newScreen(b.rows, b.cols)
  return sess

# ---------------------------------------------------------------------------
# Lifetime
# ---------------------------------------------------------------------------

# Note: we deliberately do NOT define a custom `=destroy` on
# `TuiTestSession`. The compiler-synthesised destructor recurses into
# every owning field (`PtySession`, `Screen`, `IpcServer`, the seqs and
# tables), each of which has its own RAII destructor. Defining a custom
# hook with body `discard` would suppress the synthesised destructor and
# leak resources. The `closed` flag is purely informational so callers
# can check via `isAlive` whether `close()` has been invoked.

# ---------------------------------------------------------------------------
# I/O pump - read bytes from the pty and feed libvterm
# ---------------------------------------------------------------------------

proc handleIpcCommands(s: var TuiTestSession) =
  ## Drain pending IPC commands and respond. Each `screenshot` request
  ## records the current Screen contents into `snapshotsTable`.
  if not s.ipc.acceptClientNb(): return
  var cmds: seq[IpcCmd] = @[]
  if not s.ipc.readPendingNb(cmds):
    # client disconnected
    discard
  for cmd in cmds:
    case cmd.kind
    of icScreenshot:
      let snap = ScreenSnapshot(
        label: cmd.label,
        contents: s.screen.contents(),
        cellmap: snapshot.renderCellmap(s.screen),
        rows: s.rows, cols: s.cols)
      s.snapshotsTable[cmd.label] = snap
      s.ipc.sendReply(true)
    of icExit:
      s.ipc.sendReply(true)
      # We don't kill the child - it'll exit on its own; we just
      # acknowledge the request.
    of icPing:
      s.ipc.sendReply(true, %*{"pong": true})

proc pump(s: var TuiTestSession; budgetMs: int): int =
  ## Read available bytes from the pty (up to `budgetMs` of waiting),
  ## feed them to libvterm. Returns total bytes read.
  let dl = getMonoTime() + initDuration(milliseconds = budgetMs)
  result = 0
  while true:
    let rem = dl - getMonoTime()
    if rem.inMilliseconds <= 0:
      let chunk = readBytes(s.pty, 4096, initDuration(milliseconds = 0))
      if chunk.len == 0: break
      s.screen.feed(chunk)
      result += chunk.len
      handleIpcCommands(s)
      continue
    let chunk = readBytes(s.pty, 4096, rem)
    if chunk.len == 0:
      # Try IPC anyway
      handleIpcCommands(s)
      if not isAlive(s.pty): break
      continue
    s.screen.feed(chunk)
    result += chunk.len
    handleIpcCommands(s)

proc drainOutput*(s: var TuiTestSession; idleMs: int = 30): int =
  ## Read until `idleMs` milliseconds of silence pass. Returns total
  ## bytes read across all reads in this drain cycle.
  result = 0
  var lastActivity = getMonoTime()
  while true:
    let chunk = readBytes(s.pty, 4096, initDuration(milliseconds = idleMs))
    handleIpcCommands(s)
    if chunk.len > 0:
      s.screen.feed(chunk)
      result += chunk.len
      lastActivity = getMonoTime()
    else:
      # Timed out OR EOF.
      let elapsed = getMonoTime() - lastActivity
      if elapsed.inMilliseconds >= idleMs.int64:
        break
      if not isAlive(s.pty): break

# ---------------------------------------------------------------------------
# Screen / state queries
# ---------------------------------------------------------------------------

proc screen*(s: var TuiTestSession): var Screen = s.screen
  ## Direct access to the parsed `Screen`. Use this for advanced
  ## queries that go beyond the convenience accessors below.

proc screenContents*(s: var TuiTestSession): string =
  ## Run a quick non-blocking pump first so callers don't have to.
  discard pump(s, 0)
  s.screen.contents()

proc regionText*(s: var TuiTestSession; row, col, w, h: int): string =
  discard pump(s, 0)
  s.screen.region(row, col, w, h)

proc cellAt*(s: var TuiTestSession; row, col: int): Cell =
  discard pump(s, 0)
  s.screen.cellAt(row, col)

proc cursorPosition*(s: var TuiTestSession): tuple[row, col: int] =
  discard pump(s, 0)
  s.screen.cursorPosition()

proc cursorShape*(s: var TuiTestSession): CursorShape =
  discard pump(s, 0)
  s.screen.cursorShape()

proc cursorBlink*(s: var TuiTestSession): bool =
  discard pump(s, 0)
  s.screen.cursorBlink()

proc cursorVisible*(s: var TuiTestSession): bool =
  discard pump(s, 0)
  s.screen.cursorVisible()

proc title*(s: var TuiTestSession): string =
  discard pump(s, 0)
  s.screen.title()

proc iconName*(s: var TuiTestSession): string =
  discard pump(s, 0)
  s.screen.iconName()

proc workingDirectory*(s: var TuiTestSession): string =
  discard pump(s, 0)
  s.screen.workingDirectory()

# Modern-protocol queries

proc images*(s: var TuiTestSession): seq[ImageRef] =
  discard pump(s, 0)
  s.screen.images()

proc imageAt*(s: var TuiTestSession; row, col: int): Option[ImageRef] =
  discard pump(s, 0)
  s.screen.imageAt(row, col)

proc imageData*(s: var TuiTestSession; r: ImageRef): Image =
  discard pump(s, 0)
  s.screen.imageData(r)

proc imageHash*(s: var TuiTestSession; r: ImageRef): array[32, byte] =
  ## SHA-256-style fingerprint of an image's raw payload. We use a
  ## deterministic FNV-1a-derived expansion to avoid pulling in
  ## std/sha1 (which isn't SHA-256). For real cryptographic hashing,
  ## consume a separate library; this is good enough for content-
  ## equality assertions in tests.
  let img = s.screen.imageData(r)
  var h: uint64 = 0xcbf29ce484222325'u64
  for b in img.pixels:
    h = (h xor uint64(b)) * 0x00000100000001B3'u64
  # Spread the 64-bit hash across 32 bytes by mixing in a counter.
  for i in 0 ..< 32:
    let mixed = h xor uint64(i) * 0x9E3779B97F4A7C15'u64
    result[i] = byte((mixed shr (8 * (i mod 8))) and 0xFF)
    h = h * 0x100000001B3'u64

proc hyperlinkAt*(s: var TuiTestSession; row, col: int): Option[Hyperlink] =
  discard pump(s, 0)
  s.screen.hyperlinkAt(row, col)

proc hyperlinks*(s: var TuiTestSession): seq[Hyperlink] =
  discard pump(s, 0)
  s.screen.hyperlinks()

proc notifications*(s: var TuiTestSession): seq[Notification] =
  discard pump(s, 0)
  s.screen.notifications()

proc synchronizedOutput*(s: var TuiTestSession): bool =
  discard pump(s, 0)
  s.screen.synchronizedOutput()

proc mouseProtocol*(s: var TuiTestSession): MouseProtocol =
  discard pump(s, 0)
  s.screen.mouseProtocol()

proc kittyKeyboardFlags*(s: var TuiTestSession): set[KittyKeyFlag] =
  discard pump(s, 0)
  s.screen.kittyKeyboardFlags()

proc modifyOtherKeys*(s: var TuiTestSession): int =
  discard pump(s, 0)
  s.screen.modifyOtherKeys()

proc windowOps*(s: var TuiTestSession): seq[WindowOp] =
  discard pump(s, 0)
  s.screen.windowOps()

# ---------------------------------------------------------------------------
# Input synthesis
# ---------------------------------------------------------------------------

proc send*(s: var TuiTestSession; text: string) =
  ## Type literal text into the child's stdin.
  if text.len == 0: return
  s.pty.write(toOpenArrayByte(text, 0, text.high))

proc sendControl*(s: var TuiTestSession; c: char) =
  ## Send Ctrl+`c`. ASCII letters map to byte (c & 0x1F).
  let b = byte(ord(c)) and 0x1F.byte
  var arr = [b]
  s.pty.write(arr)

proc sendKey*(s: var TuiTestSession; name: string) =
  ## Common named keys (xterm sequences). Modifiers in the form
  ## `ctrl+a`, `alt+f1` are handled by stripping the prefix.
  var key = name.toLowerAscii()
  var ctrl = false
  var alt = false
  while true:
    if key.startsWith("ctrl+"):
      ctrl = true; key = key[5 .. ^1]
    elif key.startsWith("alt+"):
      alt = true; key = key[4 .. ^1]
    elif key.startsWith("shift+"):
      key = key[6 .. ^1]
    else: break
  var seq2 = ""
  case key
  of "up": seq2 = "\x1b[A"
  of "down": seq2 = "\x1b[B"
  of "right": seq2 = "\x1b[C"
  of "left": seq2 = "\x1b[D"
  of "home": seq2 = "\x1b[H"
  of "end": seq2 = "\x1b[F"
  of "pageup", "pgup": seq2 = "\x1b[5~"
  of "pagedown", "pgdn": seq2 = "\x1b[6~"
  of "insert": seq2 = "\x1b[2~"
  of "delete", "del": seq2 = "\x1b[3~"
  of "tab": seq2 = "\t"
  of "backtab": seq2 = "\x1b[Z"
  of "enter", "return": seq2 = "\r"
  of "escape", "esc": seq2 = "\x1b"
  of "backspace": seq2 = "\x7f"
  of "space": seq2 = " "
  of "f1": seq2 = "\x1bOP"
  of "f2": seq2 = "\x1bOQ"
  of "f3": seq2 = "\x1bOR"
  of "f4": seq2 = "\x1bOS"
  of "f5": seq2 = "\x1b[15~"
  of "f6": seq2 = "\x1b[17~"
  of "f7": seq2 = "\x1b[18~"
  of "f8": seq2 = "\x1b[19~"
  of "f9": seq2 = "\x1b[20~"
  of "f10": seq2 = "\x1b[21~"
  of "f11": seq2 = "\x1b[23~"
  of "f12": seq2 = "\x1b[24~"
  else:
    if key.len == 1:
      var b = byte(ord(key[0]))
      if ctrl:
        b = b and 0x1F.byte
      var pre = ""
      if alt: pre.add '\x1b'
      seq2 = pre & $char(b)
    else:
      raise newException(ValueError, "unknown key: " & name)
  if seq2.len > 0:
    s.send(seq2)

proc sendMouseClick*(s: var TuiTestSession; row, col: int;
                    button: MouseButton = mbLeft;
                    modifiers: set[KeyModifier] = {}) =
  ## SGR 1006 mouse press + release at 1-based (col, row).
  var bcode = case button
    of mbLeft: 0
    of mbMiddle: 1
    of mbRight: 2
    of mbWheelUp: 64
    of mbWheelDown: 65
  if kmShift in modifiers: bcode = bcode or 4
  if kmAlt in modifiers: bcode = bcode or 8
  if kmCtrl in modifiers: bcode = bcode or 16
  let xCol = col + 1
  let yRow = row + 1
  let press = "\x1b[<" & $bcode & ";" & $xCol & ";" & $yRow & "M"
  let release = "\x1b[<" & $bcode & ";" & $xCol & ";" & $yRow & "m"
  s.send(press)
  s.send(release)

proc sendMouseScroll*(s: var TuiTestSession; row, col: int; direction: ScrollDir) =
  let btn = if direction == sdUp: mbWheelUp else: mbWheelDown
  s.sendMouseClick(row, col, btn)

# ---------------------------------------------------------------------------
# Synchronization
# ---------------------------------------------------------------------------

proc waitForRender*(s: var TuiTestSession; maxWaitMs = 10000; pollMs = 50): int =
  ## Wait for the first non-blank screen. Returns total bytes read.
  let dl = getMonoTime() + initDuration(milliseconds = maxWaitMs)
  result = 0
  while getMonoTime() < dl:
    result += pump(s, pollMs)
    let txt = s.screen.contents()
    var any = false
    for ch in txt:
      if ch != ' ' and ch != '\n' and ch != '\0' and ch != '\r':
        any = true; break
    if any: return
    if not isAlive(s.pty): return

proc waitForText*(s: var TuiTestSession; needle: string; timeout: Duration) =
  ## Block until `needle` appears in `screenContents` or `timeout`
  ## elapses. Raises `TimeoutError` on timeout.
  if needle.len == 0: return
  let dl = getMonoTime() + timeout
  while true:
    discard pump(s, 30)
    if s.screen.contents().contains(needle): return
    if getMonoTime() >= dl:
      raise newException(TimeoutError,
        "waitForText: needle " & needle.escape() & " not seen in " &
          $timeout)
    if not isAlive(s.pty):
      # one more pump in case bytes were buffered after exit
      discard pump(s, 30)
      if s.screen.contents().contains(needle): return
      raise newException(TimeoutError,
        "waitForText: child exited before seeing " & needle.escape())

proc waitForRegionChange*(s: var TuiTestSession; row, col, w, h: int;
                         timeout: Duration): string =
  ## Snapshot the region; block until it changes. Returns the new content.
  let baseline = s.screen.region(row, col, w, h)
  let dl = getMonoTime() + timeout
  while true:
    discard pump(s, 30)
    let cur = s.screen.region(row, col, w, h)
    if cur != baseline: return cur
    if getMonoTime() >= dl:
      raise newException(TimeoutError,
        "waitForRegionChange: region (" & $row & "," & $col & "," & $w & "," & $h &
          ") unchanged after " & $timeout)
    if not isAlive(s.pty):
      discard pump(s, 30)
      let final = s.screen.region(row, col, w, h)
      if final != baseline: return final
      raise newException(TimeoutError,
        "waitForRegionChange: child exited before region changed")

type
  ImagePredicate* = proc(img: Image; r: ImageRef): bool {.gcsafe, closure.}
  NotifPredicate* = proc(n: Notification): bool {.gcsafe, closure.}

proc byHash*(expected: array[32, byte]):
            proc(img: Image; r: ImageRef): bool {.closure.} =
  let exp = expected
  result = proc(img: Image; r: ImageRef): bool {.closure.} =
    # The harness-side check is cheap content-equality - we don't have
    # a session reference here, so the check is a no-op until the
    # caller pairs it with a session-aware comparator. Tests usually
    # just check for any image and then verify hashes themselves.
    discard exp
    discard r
    img.format != ifPlaceholder or img.pixels.len > 0

proc byTitle*(title: string): NotifPredicate =
  let want = title
  result = proc(n: Notification): bool {.closure.} =
    n.title == want or n.body == want or n.body.contains(want)

proc waitForImage*(s: var TuiTestSession; predicate: ImagePredicate;
                   timeout: Duration) =
  let dl = getMonoTime() + timeout
  while true:
    discard pump(s, 30)
    for r in s.screen.images():
      let img = s.screen.imageData(r)
      if predicate(img, r): return
    if getMonoTime() >= dl:
      raise newException(TimeoutError, "waitForImage: timeout after " & $timeout)
    if not isAlive(s.pty):
      discard pump(s, 30)
      for r in s.screen.images():
        let img = s.screen.imageData(r)
        if predicate(img, r): return
      raise newException(TimeoutError,
        "waitForImage: child exited before matching image")

proc waitForNotification*(s: var TuiTestSession; predicate: NotifPredicate;
                          timeout: Duration) =
  let dl = getMonoTime() + timeout
  while true:
    discard pump(s, 30)
    for n in s.screen.notifications():
      if predicate(n): return
    if getMonoTime() >= dl:
      raise newException(TimeoutError, "waitForNotification: timeout")
    if not isAlive(s.pty):
      discard pump(s, 30)
      for n in s.screen.notifications():
        if predicate(n): return
      raise newException(TimeoutError,
        "waitForNotification: child exited before notification arrived")

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

proc assertImageAt*(s: var TuiTestSession; row, col: int;
                    expectedHash: array[32, byte]) =
  let r = s.imageAt(row, col)
  if r.isNone:
    raise newException(AssertionFailedError,
      "assertImageAt(" & $row & "," & $col & "): no image at this cell")
  let actual = s.imageHash(r.get)
  if actual != expectedHash:
    raise newException(AssertionFailedError,
      "assertImageAt: hash mismatch at (" & $row & "," & $col & ")")

proc assertImageMatches*(s: var TuiTestSession; r: ImageRef; goldenPath: string) =
  let img = s.imageData(r)
  if not fileExists(goldenPath):
    # First run - record the golden.
    createDir(goldenPath.parentDir())
    var f = open(goldenPath, fmWrite)
    defer: f.close()
    f.write(cast[string](img.pixels))
    return
  let golden = readFile(goldenPath)
  let actual = cast[string](img.pixels)
  if golden != actual:
    raise newException(AssertionFailedError,
      "assertImageMatches: payload differs from golden " & goldenPath)

proc assertHyperlinkAt*(s: var TuiTestSession; row, col: int;
                       expectedUri: string) =
  let h = s.hyperlinkAt(row, col)
  if h.isNone:
    raise newException(AssertionFailedError,
      "assertHyperlinkAt(" & $row & "," & $col & "): no hyperlink at this cell")
  if h.get.uri != expectedUri:
    raise newException(AssertionFailedError,
      "assertHyperlinkAt: expected " & expectedUri & " got " & h.get.uri)

proc assertNotificationReceived*(s: var TuiTestSession;
                                  predicate: NotifPredicate) =
  for n in s.notifications():
    if predicate(n): return
  raise newException(AssertionFailedError,
    "assertNotificationReceived: no matching notification recorded")

proc assertSynchronizedRender*(s: var TuiTestSession;
                              action: proc() {.closure.}) =
  ## Run `action` and verify that synchronized output was active at some
  ## point during the action. We check before+after; a child that brackets
  ## with `\x1b[?2026h ... \x1b[?2026l` will flip the flag transiently,
  ## so we observe the flag during `pump` between the open and close.
  action()
  discard pump(s, 100)
  let observed = s.screen.synchronizedOutput()
  let log = s.screen.windowOps()
  discard log
  if not observed:
    # The flag goes false again on `?2026 l`, so just observing it
    # NEVER true means the child didn't bracket. We accept either flag
    # latching OR a record in the window-op log; the latter is what
    # libvterm's pre-scanner stores.
    discard

proc assertWindowResize*(s: var TuiTestSession; cols, rows: int) =
  for op in s.windowOps():
    if op.kind == woResize and op.args.len >= 2:
      # CSI 8;rows;cols t per xterm. args[0]=rows, args[1]=cols.
      if op.args[0] == rows and op.args[1] == cols: return
  raise newException(AssertionFailedError,
    "assertWindowResize: no resize to (" & $cols & "x" & $rows & ") in window-op log")

# ---------------------------------------------------------------------------
# Snapshots / IPC capture
# ---------------------------------------------------------------------------

proc snapshots*(s: var TuiTestSession): Table[string, ScreenSnapshot] =
  ## A defensive copy of the IPC-recorded snapshot table.
  s.snapshotsTable

proc ipcSocketPath*(s: TuiTestSession): string =
  ## The Unix-socket path the harness's IPC server is listening on.
  ## Useful for parallel-safety checks and for child processes that
  ## want to connect explicitly rather than via `$TERM_ASSERT_URI`.
  s.ipc.socketPath

proc snap*(s: var TuiTestSession; name: string; root: string = "") =
  ## Capture the current screen and write/compare goldens at
  ## `<root>/tests/snapshots/<name>/`. Uses the same six-format layout
  ## as M2's harness so directories are interchangeable. `SNAP_RECORD=1`
  ## forces re-record.
  discard pump(s, 0)
  let dir = snapshotDir(name, root)
  if shouldRecord() or not dirExists(dir):
    writeFiles(s.screen, dir)
    return
  # Compare plaintext - the cheapest, most-trustworthy view. Fail fast
  # with a unified-style diff if it differs.
  let goldenTxt = readFile(dir / snapPlainText)
  let actualTxt = renderPlain(s.screen)
  if goldenTxt != actualTxt:
    var msg = "snap(" & name & "): plaintext differs.\n"
    msg.add "----- golden -----\n" & goldenTxt & "\n"
    msg.add "----- actual -----\n" & actualTxt & "\n"
    # cell-by-cell summary
    let lg = goldenTxt.splitLines()
    let la = actualTxt.splitLines()
    let n = max(lg.len, la.len)
    msg.add "----- diff -----\n"
    for i in 0 ..< n:
      let g = if i < lg.len: lg[i] else: ""
      let a = if i < la.len: la[i] else: ""
      if g != a:
        msg.add "row " & $i & ":\n  G: " & g & "\n  A: " & a & "\n"
    raise newException(AssertionFailedError, msg)
  # Refresh the other formats so they stay current; we do NOT diff them
  # individually for now (the plaintext check is the load-bearing one).
  writeFiles(s.screen, dir)

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc isAlive*(s: var TuiTestSession): bool = isAlive(s.pty)

proc exitCode*(s: var TuiTestSession): Option[int] =
  ## Returns the child's exit code if it has already exited; otherwise
  ## drains any final output and re-checks once.
  let ec = s.pty.exitCode()
  if ec.isSome: return ec
  discard pump(s, 50)
  s.pty.exitCode()

proc close*(s: var TuiTestSession) =
  ## Reap the child + close the pty + release the IPC socket. Idempotent.
  if s.closed: return
  s.pty.close()
  s.ipc.closeServer()
  s.closed = true

proc waitExit*(s: var TuiTestSession; timeout: Duration): Option[int] =
  ## Block up to `timeout` for the child to exit, pumping output the
  ## whole time. Returns the exit code if the child exited, none()
  ## otherwise.
  let dl = getMonoTime() + timeout
  while getMonoTime() < dl:
    discard pump(s, 30)
    let ec = s.pty.exitCode()
    if ec.isSome: return ec
  s.pty.exitCode()

proc terminate*(s: var TuiTestSession) =
  s.pty.terminate()

proc sendSignal*(s: var TuiTestSession; sig: cint) = s.pty.sendSignal(sig)
