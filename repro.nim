## Reprobuild project file for TermAssert.
##
## **Typed-Cross-Project-Deps rollout — a CONSUMER repo (SC-11 develop-mode
## Nim library-source consumption).** TermAssert is the high-level TUI test
## harness that layers over the Wave-0 leaves ``nim-pty`` (L1) and
## ``nim-libvterm`` (L2), plus the child-side ``TermAssertClient`` IPC
## library. It is NOT a leaf: ``src/term_assert.nim`` does
## ``import nim_pty`` + ``import nim_libvterm`` and ``src/term_assert/
## snapshot.nim`` does ``import nim_libvterm`` — modules that live in the
## sibling repos' ``src/`` trees, resolvable at build time ONLY via the
## ``Justfile``'s ``--path:../nim-pty/src --path:../nim-libvterm/src`` (see
## ``Justfile:7``, ``src-paths``). Both siblings are METACRAFT repos with a
## landed ``repro.nim`` that exports ``library nim_pty`` / ``library
## nim_libvterm``, so this file consumes them with the SC-11 develop-mode
## pattern per ``reprobuild-specs/Cross-Repo-Source-Consumption.md`` §4.2a: a
## ``uses: "<sibling>"`` selector names each producer and reprobuild threads
## the sibling's ``src/`` onto this consumer's ``nim c --path:`` through the
## ``nimPathDirs`` aux channel — NO hardcoded ``../nim-pty/src``, NO direnv.
##
## The third sibling, ``TermAssertClient`` (``library term_assert_client``),
## is consumed at RUN TIME rather than at test-compile time: two of the
## child apps under ``tests/`` (``test_app_exit_ipc.nim`` /
## ``test_app_screenshot.nim``) ``import term_assert_client``, and the
## harness tests compile those child apps on demand by shelling out to a
## fresh ``nim c`` from ``tests/test_helpers.nim``'s ``compileChildApp``
## (keyed off ``currentSourcePath()``, threading
## ``--path:../TermAssertClient/src``). Declaring
## ``uses: "term_assert_client"`` makes reprobuild build that sibling from
## source and expose its ``src/`` on the ``nim c --path:`` of THIS package's
## edges; the run-time child-app compile picks the sibling ``src/`` up the
## same way the repo's own ``just test`` does (relative to the real source
## tree under path-mode provisioning). NO hardcoded ``../TermAssertClient/src``.
##
## **``nim-termctl`` is NOT a dependency.** The ``Justfile`` ``src-paths``
## also lists ``--path:../nim-termctl/src``, but NOTHING under ``src/``,
## ``tests/``, or ``bench/`` imports ``nim_termctl`` (verified by grep) — it
## is a stale path entry. So there is NO ``uses: "nim_termctl"`` edge; adding
## one would pull an unused sibling into the graph.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical ``runquota/repro.nim`` / ``reprobuild/repro.nim`` recipes and
## the landed SC-11 consumer shape (``term-assert-cmd/repro.nim``):
##
## * Declares the upstream tool floor + the three sibling producers via
##   ``uses:``: the ``nim`` / ``gcc`` toolchain (matching the nimble file's
##   ``requires "nim >= 2.0.0"``) plus ``uses: "nim_pty"`` /
##   ``uses: "nim_libvterm"`` / ``uses: "term_assert_client"`` (the SC-11 Nim
##   library-source producers).
## * Declares ``library term_assert`` so downstream consumers can express a
##   workspace dependency on this repo. The umbrella is
##   ``src/term_assert.nim`` (consumers ``import term_assert``); the
##   submodules under ``src/term_assert/`` (``ipc``, ``snapshot``) are
##   importable too.
## * Emits, per runnable test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>`` and
##   an EXECUTE edge (``edge.testBinary.run``) that runs it — the two-edge
##   test template from ``reprobuild-specs/Package-Model.md`` §"The test
##   template". BUILD halves collect into ``test-builds``; EXECUTE halves
##   collect into ``test`` so ``repro build test`` / ``repro test``
##   materialise the runnable closure (each execute edge transitively depends
##   on its build edge).
##
## **Module search path + compile flags.** TermAssert ships no
## ``config.nims`` / ``nim.cfg``; its ``Justfile`` supplies
## ``--path:src --path:tests --path:../nim-pty/src --path:../nim-libvterm/src
## --path:../nim-termctl/src --path:../TermAssertClient/src`` on every
## ``nim c``. Of those:
##   * ``--path:../nim-pty/src`` + ``--path:../nim-libvterm/src`` are the
##     SIBLING import paths for the test compile (each test ``import
##     term_assert`` → ``import nim_pty`` + ``import nim_libvterm``) — NOT
##     hardcoded here; the SC-11 ``uses:`` channels thread them onto the test
##     BUILD edges' ``nim c --path:``.
##   * ``--path:../TermAssertClient/src`` is consumed at RUN TIME by the
##     child-app compile (also threaded by the SC-11 ``uses:`` channel, not
##     hardcoded).
##   * ``--path:../nim-termctl/src`` is unused (see the note above).
##   * ``--path:src`` is load-bearing for ``import term_assert`` — passed via
##     ``paths = @["src"]`` on every test BUILD edge.
##   * ``--path:tests`` supplies ``import test_helpers``, which most tests
##     use — passed via ``paths = @["src", "tests"]``. (``import
##     test_helpers`` also resolves from the compiled file's own ``tests/``
##     dir, but ``--path:tests`` is included to mirror the repo's own compile
##     exactly.)
##
## Each test BUILD edge reproduces the repo's DEFAULT matrix point —
## ``just test`` → ``test-orc`` → ``_matrix orc release on`` → ``nim c …
## --mm:orc -d:release --threads:on``: ``--mm:orc`` via ``mm:``, ``-d:release``
## via ``defines:``, ``--threads:on`` via ``threadsOn`` (the wrapper default).
## The ``--passC:-w`` from ``nim-flags`` (silence the vendored libvterm C
## warnings that ride in through ``import nim_libvterm``) rides in via
## ``extraPassC:``. The ``--styleCheck:usages --styleCheck:error`` switches
## are style toggles that don't change the produced binary and aren't part of
## the typed ``nim c`` surface, so they're omitted — the corpus compiles +
## runs identically without them.
##
## **Linking.** ``import nim_pty`` pulls in the POSIX pty backend, which on
## Linux calls glibc ``openpty``/``forkpty`` — glibc splits those into
## ``libutil``, so the compile needs ``-lutil``. nim-pty's own nimble file
## adds this ``passL`` under ``when defined(linux)``; the DSL ``nim.c`` edge
## does not run the sibling's nimble file, so the Linux test BUILD edges pass
## ``extraPassL = @["-lutil"]`` explicitly. Gated ``when defined(linux)`` at
## extraction — macOS folds ``openpty`` into libc and needs no ``-lutil``.
##
## **Per-test platform gating.** Every ``tests/test_harness_*.nim`` file
## ``import term_assert``, and ``term_assert`` transitively pulls in
## ``src/term_assert/ipc.nim`` which builds a ``Sockaddr_un`` AF_UNIX
## Unix-domain IPC server (``std/posix``). ``Sockaddr_un`` / ``AF_UNIX`` are
## POSIX constructs absent from Nim's Windows ``std/posix`` surface, and no
## test carries an in-``test`` ``when defined(windows): skip()`` fallback, so
## the WHOLE harness corpus is genuinely POSIX-only: gated
## ``when not defined(windows)`` at extraction so the edges are present on
## Linux/macOS (where they compile + run to exit 0) and absent on Windows.
## On this Linux host all of them are in the graph and are real runs. There
## is no further per-file partition — none of the harness tests carries a
## Linux-only or macOS-only module guard; they all self-adapt within the
## POSIX family.
##
## The ``tests/test_app_*.nim`` files are CHILD APPS, not suites: each has a
## ``when isMainModule`` body and no ``suite`` / ``unittest`` harness, and
## the harness tests spawn them (compiled on demand via ``compileChildApp``).
## They are never ``nim c -r``'d as standalone tests by the repo's own
## ``just test`` and get NO edge here — they enter the graph transitively as
## the run-time inputs of the harness tests that compile+spawn them.
## Likewise ``tests/test_helpers.nim`` is a shared utility module (no
## ``suite`` / no ``isMainModule`` entrypoint) and gets no edge.
## ``bench/bench_harness_spawn.nim`` is a benchmark (``just bench``), not part
## of the test set, and gets no edge.
##
## **Test scheduling — capacity-1 serial pool.** Every harness test does two
## resource-heavy things: it (a) shells out to a fresh ``nim c`` at run time
## to compile its child app (``compileChildApp``), and (b) allocates a real
## pty and forks+execs the child process, then asserts on timed reads of that
## child's output (``drainOutput``/``waitFor*`` with sub-second deadlines).
## Running the whole 20-test corpus concurrently — each spawning its own
## ``nim`` compiler AND a pty child — saturates the host and makes the
## timing-sensitive reads flake. The EXECUTE edges are therefore serialised
## through a capacity-1 build pool (``buildPool("term_assert.serial", 1)`` +
## ``pool = "term_assert.serial"`` on each ``.run``), exactly the nim-pty
## recipe's pattern. This changes ONLY scheduling: no ``check`` is skipped,
## relaxed, or removed — every test still runs in full to exit 0. The BUILD
## (compile) edges stay unpooled and parallel.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``
## (and SC-11 sibling resolution runs in path mode). Without it
## ``repro build`` refuses to run with "typed tool provisioning is required
## for uses declarations".

import repro_project_dsl

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by every test BUILD edge below and the
# ``edge.testBinary.run(...)`` UFCS dispatch for the EXECUTE edges. It
# re-exports ``repro_project_dsl`` so the import order is unimportant. Like
# the ``nim-pty`` / ``term-assert-cmd`` recipes this file does NOT import
# ``ct_test_runner_install`` (engine-coupled, reprobuild-internal): the
# execute edges route through the engine's default direct-binary runner (run
# the binary, key on exit status), which is exactly the exit-0 verification
# this corpus needs — Nim ``unittest`` prints per-suite results and exits
# non-zero on failure.
import ct_test_nim_unittest

type
  HarnessTestSpec = object
    ## One entry per runnable harness test file. ``source`` is the
    ## repo-relative ``.nim`` path; ``binary`` is the
    ## ``build/test-bin/<stem>`` output.
    source: string
    binary: string

# POSIX-only harness corpus — every file ``import term_assert`` whose IPC
# layer builds a ``Sockaddr_un`` AF_UNIX server, so each compiles + runs only
# off Windows. Gated ``when not defined(windows)`` at extraction below. This
# is the full ``tests/test_harness_*.nim`` set (20 files) — a superset of the
# ``Justfile`` ``tests`` list, which omits ``test_harness_image_iterm2.nim``;
# that file is a real end-to-end test with live pixel assertions and runs to
# exit 0 on this host, so it is INCLUDED here (a stale ``Justfile`` list is
# not a reason to drop a host-runnable test).
const posixHarnessSpecs: seq[HarnessTestSpec] = @[
  HarnessTestSpec(source: "tests/test_harness_spawn_echo.nim",
    binary: "build/test-bin/test_harness_spawn_echo"),
  HarnessTestSpec(source: "tests/test_harness_pilot_typing.nim",
    binary: "build/test-bin/test_harness_pilot_typing"),
  HarnessTestSpec(source: "tests/test_harness_region_text.nim",
    binary: "build/test-bin/test_harness_region_text"),
  HarnessTestSpec(source: "tests/test_harness_wait_for_region_change.nim",
    binary: "build/test-bin/test_harness_wait_for_region_change"),
  HarnessTestSpec(source: "tests/test_harness_drain_output.nim",
    binary: "build/test-bin/test_harness_drain_output"),
  HarnessTestSpec(source: "tests/test_harness_signal_cleanup.nim",
    binary: "build/test-bin/test_harness_signal_cleanup"),
  HarnessTestSpec(source: "tests/test_harness_tmux_sanitization.nim",
    binary: "build/test-bin/test_harness_tmux_sanitization"),
  HarnessTestSpec(source: "tests/test_harness_six_format_snapshot.nim",
    binary: "build/test-bin/test_harness_six_format_snapshot"),
  HarnessTestSpec(source: "tests/test_harness_screenshot_ipc.nim",
    binary: "build/test-bin/test_harness_screenshot_ipc"),
  HarnessTestSpec(source: "tests/test_harness_exit_ipc.nim",
    binary: "build/test-bin/test_harness_exit_ipc"),
  HarnessTestSpec(source: "tests/test_harness_mouse_events.nim",
    binary: "build/test-bin/test_harness_mouse_events"),
  HarnessTestSpec(source: "tests/test_harness_hyperlink_assertion.nim",
    binary: "build/test-bin/test_harness_hyperlink_assertion"),
  HarnessTestSpec(source: "tests/test_harness_notification_received.nim",
    binary: "build/test-bin/test_harness_notification_received"),
  HarnessTestSpec(source: "tests/test_harness_window_op_capture.nim",
    binary: "build/test-bin/test_harness_window_op_capture"),
  HarnessTestSpec(source: "tests/test_harness_synchronized_render_assertion.nim",
    binary: "build/test-bin/test_harness_synchronized_render_assertion"),
  HarnessTestSpec(source: "tests/test_harness_image_kitty.nim",
    binary: "build/test-bin/test_harness_image_kitty"),
  HarnessTestSpec(source: "tests/test_harness_image_sixel.nim",
    binary: "build/test-bin/test_harness_image_sixel"),
  HarnessTestSpec(source: "tests/test_harness_image_iterm2.nim",
    binary: "build/test-bin/test_harness_image_iterm2"),
  HarnessTestSpec(source: "tests/test_harness_image_assertion_workflow.nim",
    binary: "build/test-bin/test_harness_image_assertion_workflow"),
  HarnessTestSpec(source: "tests/test_harness_parallel.nim",
    binary: "build/test-bin/test_harness_parallel"),
]

package term_assert:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs. ``nim``
    # compiles every test binary (matching the nimble file's ``requires
    # "nim >= 2.0.0"``) and the run-time child-app compiles; ``gcc`` is the C
    # back-end ``nim c`` shells out to (it also compiles the vendored libvterm
    # C sources pulled in by ``import nim_libvterm``) and the linker that
    # consumes ``-lutil`` on Linux.
    "nim >=2.0"
    "gcc >=12"
    # SC-11 Nim library-source producers, named by their WORKSPACE-PROJECT
    # (directory) names — the selector reprobuild matches against the develop
    # override / committed ``LockedDep`` — NOT the library idents. Each sibling
    # exports a ``library`` whose ``src/`` reprobuild threads onto this
    # package's ``nim c --path:`` via the ``nimPathDirs`` aux channel — NO
    # hardcoded ``../<sib>/src``:
    #   * ``nim-pty``          exports ``library nim_pty`` — ``import nim_pty``
    #     in ``src/term_assert.nim`` (umbrella ``src/nim_pty.nim``).
    #   * ``nim-libvterm``     exports ``library nim_libvterm`` —
    #     ``import nim_libvterm`` in ``src/term_assert.nim`` +
    #     ``src/term_assert/snapshot.nim`` (umbrella ``src/nim_libvterm.nim``;
    #     brings the vendored libvterm C).
    #   * ``TermAssertClient`` exports ``library term_assert_client`` —
    #     ``import term_assert_client`` in the ``test_app_exit_ipc`` /
    #     ``test_app_screenshot`` child apps that the harness tests compile at
    #     run time (umbrella ``src/term_assert_client.nim``).
    "nim-pty"
    "nim-libvterm"
    "TermAssertClient"

  # Library declaration — the ``src/`` tree is importable when this package is
  # consumed via ``uses: "term_assert"``. The umbrella is
  # ``src/term_assert.nim``; consumers may also import the submodules under
  # ``src/term_assert/`` (``ipc``, ``snapshot``) directly.
  library term_assert

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile BUILD edge + one EXECUTE edge per harness test file. BUILD
    # halves collect into ``test-builds`` (compile verification); EXECUTE
    # halves collect into ``test`` so ``repro test`` / ``repro build test``
    # materialise the runnable closure (each execute edge transitively depends
    # on its build edge).
    #
    # ``paths = @["src", "tests"]`` supplies ``--path:src`` (for ``import
    # term_assert``) and ``--path:tests`` (for ``import test_helpers``); the
    # sibling ``nim-pty`` / ``nim-libvterm`` ``src/`` trees are threaded by
    # the SC-11 ``uses:`` channels, NOT hardcoded. Flags reproduce the repo's
    # default matrix point (``_matrix orc release on``): ``mm = "orc"``,
    # ``defines = @["release"]``, ``threadsOn`` (default). ``extraPassC =
    # @["-w"]`` silences the vendored libvterm C warnings; ``extraPassL`` adds
    # ``-lutil`` on Linux for the pty backend's ``openpty``/``forkpty``.
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    # ``-lutil`` is Linux-only (glibc splits ``openpty``/``forkpty`` into
    # ``libutil``, pulled in by ``import nim_pty``); gated at extraction so
    # macOS compiles omit it.
    const linuxPassL =
      when defined(linux): @["-lutil"]
      else: @[]

    # Serialise the EXECUTE edges through a capacity-1 build pool: every
    # harness test compiles a child app via a run-time ``nim c`` AND allocates
    # a pty + forks the child, then asserts on timed reads. Serialising gives
    # each the CPU/scheduler headroom its compile+fork+read timing needs. This
    # changes ONLY scheduling — no assertion is skipped or weakened. The BUILD
    # (compile) edges stay unpooled and parallel.
    let harnessPool = buildPool("term_assert.serial", 1'u32)
    discard harnessPool

    proc emitTestPair(source, binary: string;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        defines = @["release"],
        paths = @["src", "tests"],
        mm = "orc",
        extraPassC = @["-w"],
        extraPassL = linuxPassL,
        extraInputs = @["src"],
        actionId = "term_assert.test_build." & stem)
      buildActions.add(edge.action)
      # ``registerImplicitName = false`` because the BUILD edge already owns
      # the binary basename as the implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (two-edge shape).
      let executeEdge = edge.testBinary.run(
        actionId = "term_assert.test_execute." & stem,
        pool = "term_assert.serial",
        registerImplicitName = false)
      executeActions.add(executeEdge)

    # POSIX-only harness tests — the AF_UNIX IPC server in ``term_assert``
    # compiles + runs only off Windows; gated at extraction so they never
    # enter the graph on Windows.
    when not defined(windows):
      for spec in posixHarnessSpecs:
        emitTestPair(spec.source, spec.binary,
          testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
