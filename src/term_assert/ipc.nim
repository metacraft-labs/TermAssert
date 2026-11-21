## term_assert/ipc.nim - IPC layer for the TermAssert harness.
##
## Hosts one endpoint per harness session. Each session allocates its own
## endpoint name so parallel tests can run without colliding:
##   * POSIX: a Unix domain socket under `$TMPDIR`.
##   * Windows: a byte-mode named pipe `\\.\pipe\TermAssert-<pid>-<n>`, the
##     server half of the contract in
##     TermAssert-pm/spec/Testing/TermAssert-Windows-IPC.md. Its client is
##     TermAssertClient's `connectHarness`.
## The wire protocol is line-delimited JSON on both transports; the harness
## side of every client message is processed synchronously by a loop driven
## from the main `pumpEvents` cycle.
##
## Message types:
##   * `screenshot` - record the current Screen contents under a label
##   * `exit`       - the child wants to terminate; ack and let it quit
##   * `ping`       - heartbeat; reply with `pong`
##
## All replies carry `{"ok": bool}`. `ping` adds `{"pong": true}`.
##
## Public-API rules
## ----------------
## * `IpcServer` is a value `object` that owns the endpoint and accepts
##   one client at a time (the child under test). `=copy` is disabled.
## * `=destroy` releases the endpoint (and, on POSIX, unlinks the socket file).
## * No raw `ptr` is exposed.

import std/[json, os, options, tables]
when defined(windows):
  import std/[winlean, widestrs]
else:
  import std/posix

type
  IpcCmdKind* = enum
    icScreenshot, icExit, icPing

  IpcCmd* = object
    case kind*: IpcCmdKind
    of icScreenshot: label*: string
    of icExit: code*: int
    of icPing: discard

when defined(windows):
  const
    pipeAccessDuplex = 0x00000003'u32
    fileFlagOverlapped = 0x40000000'u32
    # Byte mode in both directions, blocking-mode wait: the same stream
    # semantics the POSIX socket gives the line reader.
    pipeTypeByte = 0x00000000'u32
    pipeReadModeByte = 0x00000000'u32
    pipeWait = 0x00000000'u32
    pipeBufferBytes = 4096'u32
    errBrokenPipe = 109
    errNoData = 232
    errPipeNotConnected = 233
    errIoPending = 997
    errPipeConnected = 535
    waitObject0 = 0x00000000'u32
    waitTimeout = 0x00000102'u32

  type
    # Mirrors the Win32 OVERLAPPED layout (ULONG_PTR fields, then the offsets
    # and the event handle). Declared here so the code does not depend on
    # which overlapped spelling std/winlean exports.
    WinOverlapped {.pure.} = object
      internal: uint
      internalHigh: uint
      offset: uint32
      offsetHigh: uint32
      hEvent: Handle

    ## The pipe instance and its pending overlapped connect. Kept on the heap
    ## so `ConnectNamedPipe`'s OVERLAPPED keeps one address while the
    ## `IpcServer` value is moved by the caller.
    WinPipeState = ref object
      pipe: Handle
      event: Handle
      ov: WinOverlapped
      connecting: bool
      connected: bool

  proc winCreateNamedPipe(name: WideCString; openMode, pipeMode, maxInstances,
      outBufSize, inBufSize, defaultTimeout: uint32; sa: pointer): Handle
    {.stdcall, dynlib: "kernel32", importc: "CreateNamedPipeW".}
  proc winConnectNamedPipe(h: Handle; ov: ptr WinOverlapped): int32
    {.stdcall, dynlib: "kernel32", importc: "ConnectNamedPipe".}
  proc winDisconnectNamedPipe(h: Handle): int32
    {.stdcall, dynlib: "kernel32", importc: "DisconnectNamedPipe".}
  proc winPeekNamedPipe(h: Handle; buf: pointer; bufSize: uint32;
      bytesRead: ptr uint32; totalAvail: ptr uint32;
      bytesLeft: ptr uint32): int32
    {.stdcall, dynlib: "kernel32", importc: "PeekNamedPipe".}
  proc winReadFile(h: Handle; buf: pointer; n: uint32; got: ptr uint32;
      ov: pointer): int32
    {.stdcall, dynlib: "kernel32", importc: "ReadFile".}
  proc winWriteFile(h: Handle; buf: pointer; n: uint32; written: ptr uint32;
      ov: pointer): int32
    {.stdcall, dynlib: "kernel32", importc: "WriteFile".}
  proc winCreateEvent(sa: pointer; manualReset: int32; initial: int32;
      name: WideCString): Handle
    {.stdcall, dynlib: "kernel32", importc: "CreateEventW".}
  proc winResetEvent(h: Handle): int32
    {.stdcall, dynlib: "kernel32", importc: "ResetEvent".}
  proc winWaitForSingleObject(h: Handle; ms: uint32): uint32
    {.stdcall, dynlib: "kernel32", importc: "WaitForSingleObject".}

type
  IpcServer* = object
    ## The listening endpoint and state for one TermAssert session.
    ## POSIX stores the socket FD in `listenFd`/`clientFd`; Windows keeps its
    ## pipe state in `win` and leaves both FDs at -1.
    listenFd*: cint
    clientFd*: cint
    socketPath*: string
    closed*: bool
    rxBuf*: string
    when defined(windows):
      win: WinPipeState

  IpcError* = object of CatchableError

proc `=copy`*(dest: var IpcServer; src: IpcServer) {.error.}

when defined(windows):
  proc winFail(ctx: string) {.noreturn.} =
    let code = osLastError()
    raise newException(IpcError,
      ctx & ": " & osErrorMsg(code) & " (win32=" & $int(code) & ")")

  proc validHandle(h: Handle): bool {.inline.} =
    h != Handle(0) and h != INVALID_HANDLE_VALUE

  proc closeWin(st: WinPipeState) =
    ## Closes every handle the state owns. Closing the pipe instance also
    ## cancels a pending overlapped connect.
    if st == nil: return
    if validHandle(st.pipe):
      discard closeHandle(st.pipe)
    if validHandle(st.event):
      discard closeHandle(st.event)
    st.pipe = INVALID_HANDLE_VALUE
    st.event = INVALID_HANDLE_VALUE
    st.connecting = false
    st.connected = false

  proc armConnect(st: WinPipeState) =
    ## Starts one overlapped ConnectNamedPipe unless a client is already
    ## connected or a connect is already pending. Never blocks.
    if st.connected or st.connecting: return
    discard winResetEvent(st.event)
    zeroMem(addr st.ov, sizeof(st.ov))
    st.ov.hEvent = st.event
    if winConnectNamedPipe(st.pipe, addr st.ov) != 0:
      st.connected = true
      return
    let e = int(osLastError())
    case e
    of errIoPending:
      st.connecting = true
    of errPipeConnected:
      st.connected = true
    of errNoData:
      # A client connected and went away before we armed: reset the instance
      # so the next poll can arm a fresh connect.
      discard winDisconnectNamedPipe(st.pipe)
    else:
      winFail("ConnectNamedPipe")

  proc pollConnect(st: WinPipeState): bool =
    ## True once a client is connected. Never blocks.
    if st.connected: return true
    armConnect(st)
    if st.connected: return true
    if not st.connecting: return false
    let w = winWaitForSingleObject(st.event, 0)
    if w == waitObject0:
      st.connecting = false
      st.connected = true
      return true
    if w == waitTimeout: return false
    winFail("WaitForSingleObject")

  proc disconnectWin(st: WinPipeState) =
    ## Drops the current client and immediately re-arms the connect. The
    ## spec keeps one connect pending whenever no client is attached: a client
    ## that opens the pipe in between would otherwise get ERROR_PIPE_BUSY.
    if st.connected or st.connecting:
      discard winDisconnectNamedPipe(st.pipe)
    st.connected = false
    st.connecting = false
    armConnect(st)

  proc isClientGone(e: int): bool {.inline.} =
    e == errBrokenPipe or e == errPipeNotConnected or e == errNoData

else:
  proc closeFdQuiet(fd: var cint) =
    if fd > 2:
      discard posix.close(fd)
      fd = -1

  template ipcDestroyBody(s: untyped) =
    if s.clientFd > 2:
      discard posix.close(s.clientFd)
    if s.listenFd > 2:
      discard posix.close(s.listenFd)
    if s.socketPath.len > 0:
      discard unlink(cstring(s.socketPath))

when defined(windows):
  template ipcDestroyBody(s: untyped) =
    closeWin(s.win)

when defined(gcDestructors):
  proc `=destroy`*(s: IpcServer) =
    ipcDestroyBody(s)
else:
  proc `=destroy`*(s: var IpcServer) =
    ipcDestroyBody(s)

when not defined(windows):
  proc raiseIpc(ctx: string) {.noreturn.} =
    raise newException(IpcError,
      ctx & ": " & osErrorMsg(osLastError()) & " (errno=" & $int(osLastError()) & ")")

proc allocSocketPath*(): string =
  ## Pick a unique endpoint name. Includes the current PID and a
  ## process-local counter for parallel-safety.
  var counter {.global.}: int = 0
  inc counter
  when defined(windows):
    result = r"\\.\pipe\TermAssert-" & $getCurrentProcessId() & "-" & $counter
  else:
    var dir = getEnv("TMPDIR")
    if dir.len == 0: dir = "/tmp"
    result = dir / ("TermAssert-" & $getCurrentProcessId() & "-" & $counter & ".sock")

proc startIpcServer*(path: string = ""): IpcServer =
  ## Create the endpoint named `path` (auto-allocated if empty). The
  ## endpoint is non-blocking; one client connection at a time is accepted
  ## on demand from `acceptClientNb`.
  var p = path
  if p.len == 0: p = allocSocketPath()
  when defined(windows):
    const localPipePrefix = r"\\.\pipe\"
    if p.len <= localPipePrefix.len or p[0 ..< localPipePrefix.len] != localPipePrefix or
        '\0' in p:
      raise newException(IpcError,
        "IPC endpoint must be a local named pipe (\\\\.\\pipe\\...): " & p)
    let pipe = winCreateNamedPipe(newWideCString(p),
      pipeAccessDuplex or fileFlagOverlapped,
      pipeTypeByte or pipeReadModeByte or pipeWait,
      1, pipeBufferBytes, pipeBufferBytes, 0, nil)
    if pipe == INVALID_HANDLE_VALUE:
      winFail("CreateNamedPipeW(" & p & ")")
    let event = winCreateEvent(nil, 1, 0, nil)
    if not validHandle(event):
      discard closeHandle(pipe)
      winFail("CreateEventW")
    let st = WinPipeState(pipe: pipe, event: event)
    try:
      armConnect(st)
    except CatchableError:
      closeWin(st)
      raise
    result = IpcServer(
      listenFd: -1, clientFd: -1,
      socketPath: p, closed: false, rxBuf: "", win: st)
  else:
    # Best-effort: remove any stale file at this path. AF_UNIX bind fails
    # if the path already exists.
    discard unlink(cstring(p))
    let sh = posix.socket(AF_UNIX, SOCK_STREAM, 0)
    if sh.cint == -1:
      raiseIpc("socket")
    let fd = sh.cint
    var addrUn: Sockaddr_un
    # `sun_family` is a ushort on Linux and a uint8 on macOS (BSD keeps a
    # separate `sun_len` byte); take the field's own type so this compiles on
    # both.
    addrUn.sun_family = typeof(addrUn.sun_family)(AF_UNIX)
    if p.len >= sizeof(addrUn.sun_path):
      discard posix.close(fd)
      raise newException(IpcError, "socket path too long: " & p)
    copyMem(addr addrUn.sun_path[0], cstring(p), p.len)
    addrUn.sun_path[p.len] = '\0'
    if bindSocket(sh, cast[ptr SockAddr](addr addrUn),
                  SockLen(sizeof(addrUn))) == -1:
      let e = osLastError()
      discard posix.close(fd)
      raise newException(IpcError,
        "bind(" & p & "): " & osErrorMsg(e))
    if listen(sh, 1) == -1:
      let e = osLastError()
      discard posix.close(fd)
      discard unlink(cstring(p))
      raise newException(IpcError,
        "listen(" & p & "): " & osErrorMsg(e))
    # Mark non-blocking so accept doesn't stall the harness's polling loop.
    let flags = fcntl(fd, F_GETFL)
    if flags != -1:
      discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
    result = IpcServer(
      listenFd: fd, clientFd: -1,
      socketPath: p, closed: false, rxBuf: "")

proc socketPath*(s: IpcServer): string {.inline.} = s.socketPath

proc acceptClientNb*(s: var IpcServer): bool =
  ## Try to accept a client (non-blocking). Returns true if a client is
  ## now connected, false if no incoming connection is pending. Idempotent
  ## once a client is connected.
  when defined(windows):
    if s.win.connected:
      return true
    if not pollConnect(s.win):
      return false
    s.rxBuf.setLen(0)
    return true
  else:
    if s.clientFd >= 0: return true
    var addrUn: Sockaddr_un
    var alen = SockLen(sizeof(addrUn))
    let sh = posix.accept(SocketHandle(s.listenFd),
                          cast[ptr SockAddr](addr addrUn), addr alen)
    if sh.cint == -1:
      let e = osLastError()
      if cint(e) == EAGAIN: return false
      if cint(e) == EINTR: return false
      raiseIpc("accept")
    let fd = sh.cint
    # Mark client non-blocking too.
    let flags = fcntl(fd, F_GETFL)
    if flags != -1:
      discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
    s.clientFd = fd
    s.rxBuf.setLen(0)
    return true

proc parseLine(line: string): Option[IpcCmd] =
  if line.len == 0: return none(IpcCmd)
  var node: JsonNode
  try:
    node = parseJson(line)
  except CatchableError:
    return none(IpcCmd)
  if node.kind != JObject or not node.hasKey("cmd"):
    return none(IpcCmd)
  let cmd = node["cmd"].getStr()
  case cmd
  of "screenshot":
    let label = if node.hasKey("label"): node["label"].getStr() else: ""
    return some(IpcCmd(kind: icScreenshot, label: label))
  of "exit":
    let code = if node.hasKey("code"): node["code"].getInt() else: 0
    return some(IpcCmd(kind: icExit, code: code))
  of "ping":
    return some(IpcCmd(kind: icPing))
  else:
    return none(IpcCmd)

proc drainCommands(s: var IpcServer; commands: var seq[IpcCmd]) =
  ## Move every complete (newline-terminated) line of `s.rxBuf` into
  ## `commands`, keeping any partial line for the next read.
  while true:
    let nl = s.rxBuf.find('\n')
    if nl < 0: break
    let line = s.rxBuf[0 ..< nl]
    s.rxBuf = s.rxBuf[nl + 1 .. ^1]
    let cmd = parseLine(line)
    if cmd.isSome:
      commands.add cmd.get

proc readPendingNb*(s: var IpcServer; commands: var seq[IpcCmd]): bool =
  ## Drain any pending bytes from the client into `s.rxBuf` and pull
  ## complete (newline-terminated) commands into `commands`. Returns
  ## false if the client closed; true otherwise. No blocking.
  when defined(windows):
    let st = s.win
    if not st.connected: return true
    var chunk: array[4096, byte]
    while true:
      # PeekNamedPipe reports the bytes waiting without consuming them, so
      # the ReadFile below only runs when it cannot block.
      var avail: uint32 = 0
      if winPeekNamedPipe(st.pipe, nil, 0, nil, addr avail, nil) == 0:
        let e = int(osLastError())
        if isClientGone(e):
          drainCommands(s, commands)
          disconnectWin(st)
          return false
        winFail("PeekNamedPipe")
      if avail == 0: break
      var got: uint32 = 0
      let want = min(avail, uint32(chunk.len))
      if winReadFile(st.pipe, addr chunk[0], want, addr got, nil) == 0:
        let e = int(osLastError())
        if isClientGone(e):
          drainCommands(s, commands)
          disconnectWin(st)
          return false
        winFail("ReadFile")
      for i in 0 ..< int(got): s.rxBuf.add char(chunk[i])
    drainCommands(s, commands)
    return st.connected or s.rxBuf.len == 0
  else:
    if s.clientFd < 0: return true
    var chunk: array[4096, char]
    while true:
      let n = posix.read(s.clientFd, addr chunk[0], chunk.len)
      if n < 0:
        let e = osLastError()
        if cint(e) == EAGAIN:
          break
        if cint(e) == EINTR: continue
        # treat other errors as disconnect
        closeFdQuiet(s.clientFd)
        return false
      if n == 0:
        # EOF
        closeFdQuiet(s.clientFd)
        break
      for i in 0 ..< n: s.rxBuf.add chunk[i]
    drainCommands(s, commands)
    return s.clientFd >= 0 or s.rxBuf.len == 0

proc sendReply*(s: var IpcServer; ok: bool; extra: JsonNode = nil) =
  ## Send `{"ok": ok, ...extra}` as one JSON line.
  var node = %*{"ok": ok}
  if extra != nil and extra.kind == JObject:
    for k, v in extra.fields: node[k] = v
  let line = $node & "\n"
  when defined(windows):
    let st = s.win
    if not st.connected: return
    var off = 0
    while off < line.len:
      var written: uint32 = 0
      let n = uint32(line.len - off)
      if winWriteFile(st.pipe, unsafeAddr line[off], n, addr written, nil) == 0 or
          written == 0:
        disconnectWin(st)
        return
      off += int(written)
  else:
    if s.clientFd < 0: return
    var off = 0
    while off < line.len:
      let n = posix.write(s.clientFd,
                          unsafeAddr line[off], line.len - off)
      if n < 0:
        let e = osLastError()
        if cint(e) == EINTR: continue
        if cint(e) == EAGAIN:
          # The kernel buffer is full; busy-spin briefly. The replies are
          # tiny (<200B), so this is essentially a no-op in practice.
          continue
        closeFdQuiet(s.clientFd)
        return
      if n == 0:
        closeFdQuiet(s.clientFd)
        return
      off += n

proc closeServer*(s: var IpcServer) =
  if not s.closed:
    when defined(windows):
      closeWin(s.win)
    else:
      if s.clientFd > 2:
        discard posix.close(s.clientFd); s.clientFd = -1
      if s.listenFd > 2:
        discard posix.close(s.listenFd); s.listenFd = -1
      if s.socketPath.len > 0:
        discard unlink(cstring(s.socketPath))
    s.closed = true
