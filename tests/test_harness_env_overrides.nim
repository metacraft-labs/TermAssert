## test_harness_env_overrides — `envSet` beats `envRemove`, and the blocklist
## filters the INHERITED environment only.
##
## ## The defect this pins
##
## `effectiveEnv` applied the blocklist to `b.envOverrides` as well as to the
## inherited environment, so `.envRemove(X).envSet(X, v)` handed the child an
## environment with no `X` in it at all — the caller's explicit value discarded
## by the caller's own earlier line, silently.
##
## It is a natural pair of lines to write. A suite that wants a KNOWN
## environment removes the variables an inherited terminal might set and then
## sets the ones it needs; if one name appears in both lists, the set is lost.
## `codetracer`'s pty lifecycle suite hit exactly that: a handshake budget
## passed through an environment variable never arrived, the child used its own
## 30-second default, and the case measured 30,013 ms and 30,016 ms for budgets
## 4,500 ms apart.
##
## ## No mocks
##
## The assertion is read out of `env(1)`'s own output, printed by a real child
## process in a real pty and parsed by a real libvterm — i.e. the environment
## the CHILD received, which is the only thing that matters here. Nothing in
## this file inspects the harness's internals.

import std/[unittest, times, options, os, strutils]
import term_assert

proc requireBin(name: string): string =
  for dir in getEnv("PATH").split(':'):
    if dir.len == 0: continue
    let candidate = dir / name
    if fileExists(candidate): return candidate
  for fb in ["/bin/" & name, "/usr/bin/" & name]:
    if fileExists(fb): return fb
  raise newException(IOError, "binary not found: " & name)

proc childEnvText(b: TuiTestBuilder): string =
  ## Everything the child saw, as one string. `env` is spawned with a wide,
  ## tall screen so a long variable list cannot scroll the needles away.
  var sess = b.spawn()
  let _ = sess.drainOutput(200)
  result = sess.screenContents()
  let _ = sess.waitExit(initDuration(seconds = 5))
  sess.close()

suite "M28 harness: environment overrides beat the blocklist":

  test "envSet after envRemove reaches the child":
    let bin = requireBin("env")
    putEnv("TERM_ASSERT_ENV_PROBE", "inherited-value")
    let text = childEnvText(
      newTuiTest(bin, @[]).width(200).height(60)
        .envRemove("TERM_ASSERT_ENV_PROBE")
        .envSet("TERM_ASSERT_ENV_PROBE", "explicit-value"))
    # THE POSITIVE CONTROL. A child whose output never reached the screen
    # satisfies every "does not contain" below for free.
    check text.contains("TERM_ASSERT_URI=")
    check text.contains("TERM_ASSERT_ENV_PROBE=explicit-value")
    # …and it is the OVERRIDE that arrived, not the ambient value the block
    # was there to keep out.
    check not text.contains("TERM_ASSERT_ENV_PROBE=inherited-value")
    delEnv("TERM_ASSERT_ENV_PROBE")

  test "envRemove alone still removes, so the case above is about the override":
    let bin = requireBin("env")
    putEnv("TERM_ASSERT_ENV_PROBE", "inherited-value")
    let text = childEnvText(
      newTuiTest(bin, @[]).width(200).height(60)
        .envRemove("TERM_ASSERT_ENV_PROBE"))
    check text.contains("TERM_ASSERT_URI=")
    check not text.contains("TERM_ASSERT_ENV_PROBE=")
    delEnv("TERM_ASSERT_ENV_PROBE")

  test "an inherited variable nobody mentioned is still inherited":
    # The third arm of the same lookup: without it, "the override arrived"
    # would also be satisfied by a builder that had stopped inheriting at all.
    let bin = requireBin("env")
    putEnv("TERM_ASSERT_ENV_PROBE", "inherited-value")
    let text = childEnvText(newTuiTest(bin, @[]).width(200).height(60))
    check text.contains("TERM_ASSERT_ENV_PROBE=inherited-value")
    delEnv("TERM_ASSERT_ENV_PROBE")

  test "an explicit TMUX beats the default tmux blocklist":
    # The tmux defaults exist so an inherited `$TMUX` cannot make a child
    # believe it is inside a multiplexer. A caller that SETS `TMUX` is asking
    # for the opposite deliberately, and is the one who knows.
    let bin = requireBin("env")
    putEnv("TMUX", "/tmp/tmux-inherited")
    let text = childEnvText(
      newTuiTest(bin, @[]).width(200).height(60)
        .envSet("TMUX", "/tmp/tmux-explicit"))
    check text.contains("TMUX=/tmp/tmux-explicit")
    check not text.contains("TMUX=/tmp/tmux-inherited")
    delEnv("TMUX")
