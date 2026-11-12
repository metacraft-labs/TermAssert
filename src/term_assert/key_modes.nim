## term_assert/key_modes - which key encoding the child asked the terminal for.
##
## A real terminal changes the bytes it sends for a modified key when the
## APPLICATION asks it to. Two requests are in common use:
##
## * xterm's `modifyOtherKeys` resource, set by `CSI > 4 ; Pv m` (`Pv` = 0, 1
##   or 2) and reset by `CSI > 4 m`, `CSI > m` or `CSI > 4 n`.
## * the Kitty keyboard protocol's progressive enhancement flags
##   (https://sw.kovidgoyal.net/kitty/keyboard-protocol/): `CSI > flags u`
##   pushes, `CSI < n u` pops `n` entries (default 1) and `CSI = flags ; mode u`
##   changes the current entry (mode 1 sets, 2 adds bits, 3 removes bits). The
##   main and alternate screens keep independent stacks.
##
## `KeyModeTracker` watches the child's output for these requests. It is a
## byte-at-a-time state machine, so a request split across two pty reads is
## seen exactly as one that arrived whole. Full RIS (`ESC c`) resets both.
##
## The Kitty stack follows kitty's own implementation (`screen.c`): eight
## slots, an entry counts only once it has been pushed or set, the current
## flags are the highest such entry (none means 0), a push onto a full stack
## evicts the oldest entry, and a pop clears from the top.

type
  KittyStack = array[8, int]
    ## Bit 0x80 marks a slot in use; the low bits are the flags.

  TrackState = enum
    tsGround, tsEsc, tsCsi

  KeyMode* = object
    ## The key reporting the child has requested, as last seen in its output.
    modifyOtherKeys*: int
      ## xterm `modifyOtherKeys` level: 0 (off, the default), 1 or 2.
    kittyFlags*: int
      ## The Kitty progressive-enhancement flags currently in force on the
      ## active screen: 1 disambiguate, 2 report event types, 4 report
      ## alternate keys, 8 report all keys as escape codes, 16 report text.

  KeyModeTracker* = object
    state: TrackState
    csi: string
    modifyOtherKeys: int
    kitty: array[bool, KittyStack]
    onAlt: bool

const MaxCsiLen = 64
  ## Longer parameter strings are not key-mode requests; the sequence is
  ## abandoned rather than buffered without bound.

proc current(st: KittyStack): int =
  for i in countdown(st.high, 0):
    if (st[i] and 0x80) != 0: return st[i] and 0x7f
  0

proc push(st: var KittyStack; flags: int) =
  var top = -1
  for i in countdown(st.high, 0):
    if (st[i] and 0x80) != 0:
      top = i
      break
  if top == st.high:
    for i in 0 ..< st.high: st[i] = st[i + 1]
  else:
    inc top
  st[top] = 0x80 or (flags and 0x7f)

proc pop(st: var KittyStack; n: int) =
  var left = n
  for i in countdown(st.high, 0):
    if left == 0: break
    if (st[i] and 0x80) != 0:
      st[i] = 0
      dec left

proc setFlags(st: var KittyStack; flags, how: int) =
  var top = 0
  for i in countdown(st.high, 0):
    if (st[i] and 0x80) != 0:
      top = i
      break
  let old = st[top] and 0x7f
  let v = case how
    of 2: old or flags
    of 3: old and not flags
    else: flags
  st[top] = 0x80 or (v and 0x7f)

proc initKeyModeTracker*(): KeyModeTracker =
  KeyModeTracker()

proc keyMode*(t: KeyModeTracker): KeyMode =
  KeyMode(modifyOtherKeys: t.modifyOtherKeys, kittyFlags: current(t.kitty[t.onAlt]))

proc params(body: string): seq[int] =
  ## Numeric parameters; an empty one is -1 (the default). Sub-parameters
  ## after ':' are ignored.
  var cur = -1
  var inSub = false
  for ch in body:
    case ch
    of '0'..'9':
      if not inSub:
        cur = (if cur < 0: 0 else: cur) * 10 + (ord(ch) - ord('0'))
        if cur > 1_000_000: cur = 1_000_000
    of ';':
      result.add cur
      cur = -1
      inSub = false
    of ':': inSub = true
    else: discard
  if body.len > 0: result.add cur

proc dispatch(t: var KeyModeTracker; final: char) =
  var body = t.csi
  var leader = '\0'
  if body.len > 0 and body[0] in {'<', '=', '>', '?'}:
    leader = body[0]
    body = body[1 .. ^1]
  for ch in body:
    if ch in {'\x20'..'\x2F'}: return  # intermediates: not one of ours
  let p = params(body)
  proc arg(i, default: int): int =
    (if i < p.len and p[i] >= 0: p[i] else: default)
  case final
  of 'h', 'l':
    if leader == '?':
      for v in p:
        if v in [47, 1047, 1049]: t.onAlt = final == 'h'
  of 'm':
    if leader == '>':
      if p.len == 0: t.modifyOtherKeys = 0  # CSI > m: every resource reset
      elif arg(0, -1) == 4: t.modifyOtherKeys = arg(1, 0)
  of 'n':
    if leader == '>' and arg(0, -1) == 4: t.modifyOtherKeys = 0
  of 'u':
    case leader
    of '>': t.kitty[t.onAlt].push(arg(0, 0))
    of '<': t.kitty[t.onAlt].pop(max(1, arg(0, 1)))
    of '=': t.kitty[t.onAlt].setFlags(arg(0, 0), arg(1, 1))
    else: discard
  else: discard

proc feed*(t: var KeyModeTracker; bytes: openArray[byte]) =
  ## Advance over one chunk of the child's output.
  for b in bytes:
    let c = char(b)
    case t.state
    of tsGround:
      if c == '\x1b': t.state = tsEsc
    of tsEsc:
      case c
      of '[':
        t.state = tsCsi
        t.csi.setLen(0)
      of 'c':
        # RIS: a full reset returns both protocols to their defaults.
        t.modifyOtherKeys = 0
        t.kitty = default(array[bool, KittyStack])
        t.onAlt = false
        t.state = tsGround
      of '\x1b': discard
      else: t.state = tsGround
    of tsCsi:
      case c
      of '\x40'..'\x7E':
        t.dispatch(c)
        t.state = tsGround
      of '\x1b': t.state = tsEsc
      of '\x18', '\x1a': t.state = tsGround  # CAN / SUB cancel
      of '\x20'..'\x3F':
        if t.csi.len >= MaxCsiLen: t.state = tsGround
        else: t.csi.add c
      else: discard  # C0 controls inside a CSI execute; they do not end it
