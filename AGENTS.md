# TermAssert

Standalone TUI test harness library for Nim. Combines
[nim-pty](../nim-pty) (L1) and [nim-libvterm](../nim-libvterm) (L2)
into a high-level harness that mirrors the 12 capabilities of
agent-harbor's `tui-testing` Rust crate, plus first-class assertions
for modern terminal protocols (images, hyperlinks, notifications,
synchronized output, kitty keyboard, mouse 1006/1016).

## What this library does

- Spawn a child process inside a pseudo-terminal.
- Parse the child's output through a real libvterm instance into a
  `Screen` value.
- Synthesize input (text, named keys, mouse SGR sequences).
- Block on conditions (`waitForText`, `waitForRegionChange`,
  `waitForNotification`, ...).
- Receive screenshot / exit / ping requests from the child via a Unix
  domain socket (the [TermAssertClient](../TermAssertClient) library
  is the child-side counterpart).
- Write six-format goldens that share the layout used by isonim-tui's
  in-process `TerminalTestHarness` from M2.

## Status

This library is the load-bearing deliverable of the IsoNim-TUI **M28**
milestone. The repo is public and MIT-licensed; once the API stabilises
across a few real-world consumers (M29 in particular), it will be
published to the Nimble registry.

### Deferred for follow-up

- **Windows ConPTY** is deferred to M28b. nim-pty's POSIX path is
  load-bearing; ConPTY is documented as a stub there.
- **Sixel and iTerm2 image-protocol tests** are scaffolded but the
  actual pixel decoders live in nim-libvterm and are tracked in its
  L2 deferred bullets. Kitty graphics is the priority test.
- **Real cryptographic hashing** (SHA-256) for `imageHash` is replaced
  by an FNV-1a-derived 32-byte fingerprint to keep the dependency
  graph at zero non-stdlib non-sibling-repo deps. Adding `nimcrypto`
  is a one-line change for users who need real SHA-256.

## Commands

```sh
just build           # compile every test as a smoke check
just test            # run the default matrix point (orc + release + threads:on)
just lint            # nim check + nixfmt --check
just format          # nimpretty + nixfmt
just bench           # spawn-1000-keys benchmark (target < 200 ms)
```

## Project structure

```
src/
  term_assert.nim                  # public top-level - builder + session
  term_assert/ipc.nim              # Unix-socket IPC server
  term_assert/snapshot.nim         # six-format golden writer
tests/
  test_harness_*.nim               # real-stack integration tests
  test_app_*.nim                   # tiny child apps used by the tests
bench/
  bench_harness_spawn.nim          # spawn + 1000 keystrokes + assert + close
.github/workflows/ci.yml           # lint + test
flake.nix                          # nix devShell + checks
Justfile                           # build/test/lint/format
term_assert.nimble                 # single-source-of-truth version
```

## Quick example

```nim
import std/times
import term_assert

var sess = newTuiTest("echo", @["hello"])
  .width(80).height(24)
  .spawn()
discard sess.drainOutput(50)
doAssert sess.screenContents().contains("hello")
sess.close()
```

## Architecture notes

- **No mocks.** Every test spawns a real subprocess and feeds its real
  pty bytes into a real libvterm. Per the nim-pty and nim-libvterm
  charters, that's the only acceptable test tier.
- **No async runtime.** `chronos` would add ~7 KiB of dependencies for
  no observable benefit - the harness's I/O is bounded by select/poll
  on the pty FD plus a non-blocking accept on the IPC listener.
- **Path-based deps.** The `Justfile` resolves `nim-pty`, `nim-libvterm`,
  `nim-termctl`, and `TermAssertClient` via `--path:../<sibling>/src`,
  matching the workspace layout. When published to Nimble, the
  `requires` lines in `term_assert.nimble` will pin specific versions.

## Specs

The authoritative spec for this library is the **M28** entry in
`Front-Ends/IsoNim/isonim-tui.milestones.org` in the
`codetracer-specs` repo. Repo-level conformance is governed by
`metacraft-specs/policies/repo-requirements.md`.
