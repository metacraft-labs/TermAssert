## term_assert/ipc.nim - IPC layer for the TermAssert harness.
##
## Hosts a Unix domain socket per harness session. Each session allocates
## its own socket path under `$TMPDIR` so parallel tests can run without
## colliding. The wire protocol is line-delimited JSON; the harness side
## of every client message is processed synchronously by a loop driven
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
## * `IpcServer` is a value `object` that owns the listening FD and accepts
##   one client at a time (the child under test). `=copy` is disabled.
## * `=destroy` releases the FD and unlinks the socket file.
## * No raw `ptr` is exposed.

import std/[json, os, posix, options, tables]

type
  IpcCmdKind* = enum
    icScreenshot, icExit, icPing

  IpcCmd* = object
    case kind*: IpcCmdKind
    of icScreenshot: label*: string
    of icExit: code*: int
    of icPing: discard

  IpcServer* = object
    ## Listening Unix socket + state for one TermAssert session.
    ## We store the FD as `cint` for uniformity with nim-pty; conversion
    ## to/from `posix.SocketHandle` happens at the boundary.
    listenFd*: cint
    clientFd*: cint
    socketPath*: string
    closed*: bool
    rxBuf*: string

  IpcError* = object of CatchableError

proc `=copy`*(dest: var IpcServer; src: IpcServer) {.error.}

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

when defined(gcDestructors):
  proc `=destroy`*(s: IpcServer) =
    ipcDestroyBody(s)
else:
  proc `=destroy`*(s: var IpcServer) =
    ipcDestroyBody(s)

proc raiseIpc(ctx: string) {.noreturn.} =
  raise newException(IpcError,
    ctx & ": " & osErrorMsg(osLastError()) & " (errno=" & $int(osLastError()) & ")")

proc allocSocketPath*(): string =
  ## Pick a unique socket path under `$TMPDIR` (or `/tmp`). Includes the
  ## current PID and a process-local counter for parallel-safety.
  var counter {.global.}: int = 0
  inc counter
  var dir = getEnv("TMPDIR")
  if dir.len == 0: dir = "/tmp"
  result = dir / ("TermAssert-" & $getCurrentProcessId() & "-" & $counter & ".sock")

proc startIpcServer*(path: string = ""): IpcServer =
  ## Bind a Unix-socket listener on `path` (auto-allocated if empty).
  ## The listener is non-blocking; one client connection at a time is
  ## accepted on demand from `acceptClientNb`.
  var p = path
  if p.len == 0: p = allocSocketPath()
  # Best-effort: remove any stale file at this path. AF_UNIX bind fails
  # if the path already exists.
  discard unlink(cstring(p))
  let sh = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  if sh.cint == -1:
    raiseIpc("socket")
  let fd = sh.cint
  var addrUn: Sockaddr_un
  addrUn.sun_family = AF_UNIX.cushort
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

proc readPendingNb*(s: var IpcServer; commands: var seq[IpcCmd]): bool =
  ## Drain any pending bytes from the client FD into `s.rxBuf` and pull
  ## complete (newline-terminated) commands into `commands`. Returns
  ## false if the client closed; true otherwise. No blocking.
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
  while true:
    let nl = s.rxBuf.find('\n')
    if nl < 0: break
    let line = s.rxBuf[0 ..< nl]
    s.rxBuf = s.rxBuf[nl + 1 .. ^1]
    let cmd = parseLine(line)
    if cmd.isSome:
      commands.add cmd.get
  return s.clientFd >= 0 or s.rxBuf.len == 0

proc sendReply*(s: var IpcServer; ok: bool; extra: JsonNode = nil) =
  ## Send `{"ok": ok, ...extra}` as one JSON line.
  if s.clientFd < 0: return
  var node = %*{"ok": ok}
  if extra != nil and extra.kind == JObject:
    for k, v in extra.fields: node[k] = v
  let line = $node & "\n"
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
    if s.clientFd > 2:
      discard posix.close(s.clientFd); s.clientFd = -1
    if s.listenFd > 2:
      discard posix.close(s.listenFd); s.listenFd = -1
    if s.socketPath.len > 0:
      discard unlink(cstring(s.socketPath))
    s.closed = true
