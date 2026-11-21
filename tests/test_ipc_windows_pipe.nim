## test_ipc_windows_pipe - the Windows named-pipe endpoint of term_assert/ipc.nim.
##
## Runs only on Windows (the body is compiled only there; the Justfile lists
## this file for Windows alone). The peer is a real Win32 client opened with
## CreateFileW, the same call TermAssertClient's `connectHarness` makes. No
## mock or fake of the server is used: the bytes cross a real named pipe.
## The contract under test is TermAssert-pm/spec/Testing/TermAssert-Windows-IPC.md.

import std/[unittest, os, strutils, json]

when defined(windows):
  import std/[winlean, widestrs]
  import term_assert/ipc

  proc clientWriteFile(h: Handle; buf: pointer; n: uint32; got: ptr uint32;
      ov: pointer): int32
    {.stdcall, dynlib: "kernel32", importc: "WriteFile".}
  proc clientReadFile(h: Handle; buf: pointer; n: uint32; got: ptr uint32;
      ov: pointer): int32
    {.stdcall, dynlib: "kernel32", importc: "ReadFile".}

  proc connectClient(path: string): Handle =
    ## Opens the endpoint the way TermAssertClient does.
    let h = createFileW(newWideCString(path),
      GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, Handle(0))
    doAssert h != INVALID_HANDLE_VALUE, "CreateFileW failed: " & $int(osLastError())
    result = h

  proc sendLine(h: Handle; line: string) =
    var written: uint32 = 0
    let data = line & "\n"
    doAssert clientWriteFile(h, unsafeAddr data[0], uint32(data.len),
      addr written, nil) != 0
    doAssert int(written) == data.len

  proc readLineClient(h: Handle): string =
    ## Reads one newline-terminated line, byte by byte, from the reply stream.
    var one: array[1, byte]
    while true:
      var got: uint32 = 0
      doAssert clientReadFile(h, addr one[0], 1, addr got, nil) != 0
      doAssert got == 1, "reply stream ended before a newline"
      if one[0] == byte('\n'): return
      result.add char(one[0])

  proc acceptWithin(s: var IpcServer; ms: int): bool =
    ## Polls acceptClientNb for up to `ms` milliseconds.
    for _ in 0 ..< ms div 10:
      if acceptClientNb(s): return true
      sleep(10)
    result = acceptClientNb(s)

  proc readUntil(s: var IpcServer; cmds: var seq[IpcCmd]; want: int;
      ms: int): bool =
    ## Reads until `cmds` holds `want` commands or the bound expires.
    for _ in 0 ..< ms div 10:
      discard readPendingNb(s, cmds)
      if cmds.len >= want: return true
      sleep(10)
    result = cmds.len >= want

  suite "Windows named-pipe IPC endpoint":

    test "allocated endpoint names are local pipes, distinct per session":
      let a = allocSocketPath()
      let b = allocSocketPath()
      check a.startsWith(r"\\.\pipe\TermAssert-")
      check a != b

    test "explicit non-pipe paths are refused before any Win32 call":
      expect IpcError:
        discard startIpcServer(r"C:\not\a\pipe.sock")

    test "ping, screenshot, exit then a second client after disconnect":
      var s = startIpcServer()
      defer: closeServer(s)
      let h = connectClient(s.socketPath)
      check acceptWithin(s, 5000)

      sendLine(h, """{"cmd":"ping"}""")
      sendLine(h, """{"cmd":"screenshot","label":"main"}""")
      sendLine(h, """{"cmd":"exit","code":0}""")
      var cmds: seq[IpcCmd]
      check readUntil(s, cmds, 3, 5000)
      check cmds[0].kind == icPing
      check cmds[1].kind == icScreenshot and cmds[1].label == "main"
      check cmds[2].kind == icExit and cmds[2].code == 0

      # Replies travel back on the same pipe in order.
      sendReply(s, true, %*{"pong": true})
      check readLineClient(h) == """{"ok":true,"pong":true}"""

      # The client goes away; the server reports it, and a new client attaches.
      check closeHandle(h) != 0
      var more: seq[IpcCmd]
      var gone = false
      for _ in 0 ..< 500:
        if not readPendingNb(s, more):
          gone = true
          break
        sleep(10)
      check gone

      let h2 = connectClient(s.socketPath)
      check acceptWithin(s, 5000)
      sendLine(h2, """{"cmd":"ping"}""")
      var again: seq[IpcCmd]
      check readUntil(s, again, 1, 5000)
      check again[0].kind == icPing
      check closeHandle(h2) != 0
