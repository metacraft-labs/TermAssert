## Justfile - TermAssert.

alias t := test
alias fmt := format

# Path-based deps to sibling repos in the workspace.
src-paths := "--path:src --path:tests --path:../nim-pty/src --path:../nim-libvterm/src --path:../nim-termctl/src --path:../TermAssertClient/src"

nim-flags := "--styleCheck:usages --styleCheck:error --passC:-w"

# Test list. The order is deliberate: cheapest tests first, modern-protocol
# tests at the end.
tests := "tests/test_harness_spawn_echo.nim tests/test_harness_pilot_typing.nim tests/test_harness_region_text.nim tests/test_harness_wait_for_region_change.nim tests/test_harness_drain_output.nim tests/test_harness_signal_cleanup.nim tests/test_harness_tmux_sanitization.nim tests/test_harness_six_format_snapshot.nim tests/test_harness_screenshot_ipc.nim tests/test_harness_exit_ipc.nim tests/test_harness_mouse_events.nim tests/test_harness_hyperlink_assertion.nim tests/test_harness_notification_received.nim tests/test_harness_window_op_capture.nim tests/test_harness_synchronized_render_assertion.nim tests/test_harness_image_kitty.nim tests/test_harness_image_sixel.nim tests/test_harness_image_iterm2.nim tests/test_harness_image_assertion_workflow.nim tests/test_harness_parallel.nim"

build:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "Building $t"; \
      nim c {{nim-flags}} {{src-paths}} --mm:orc -d:release --threads:on \
          -o:test-logs/$(basename $t .nim) $t 2>&1 | tee -a test-logs/build.log; \
    done

test: test-orc

test-orc:
    just _matrix orc release on

test-arc:
    just _matrix arc release on

test-refc:
    just _matrix refc release on

test-threads-off:
    just _matrix orc release off

test-all: test-orc test-arc test-refc test-threads-off

_matrix mm mode threads:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "[{{mm}}/{{mode}}/threads:{{threads}}] $t"; \
      nim c {{nim-flags}} {{src-paths}} \
        --mm:{{mm}} -d:{{mode}} --threads:{{threads}} \
        -r $t 2>&1 | tee -a test-logs/{{mm}}-{{mode}}-threads-{{threads}}.log; \
    done

lint: lint-nim lint-nix

lint-nim:
    @mkdir -p test-logs
    nim check {{nim-flags}} {{src-paths}} --mm:orc src/term_assert.nim 2>&1 | tee test-logs/lint-nim.log
    @for t in {{tests}}; do \
      echo "Checking $t"; \
      nim check {{nim-flags}} {{src-paths}} --mm:orc --threads:on $t 2>&1 | tee -a test-logs/lint-nim.log; \
    done

lint-nix:
    nixfmt --check flake.nix

format: format-nim format-nix

format-nim:
    @if command -v nimpretty >/dev/null 2>&1; then \
      nimpretty src/term_assert.nim src/term_assert/*.nim tests/*.nim; \
    else \
      echo "nimpretty not available; skipping Nim formatting"; \
    fi

format-nix:
    nixfmt flake.nix

bump-version version:
    sed -i 's/^version[[:space:]]*=.*/version       = "{{version}}"/' term_assert.nimble

bench:
    @mkdir -p test-logs bench-results
    nim c {{nim-flags}} {{src-paths}} --mm:orc -d:release --threads:on \
        -r bench/bench_harness_spawn.nim 2>&1 | tee test-logs/bench.log

bench-quick:
    just bench

clean:
    rm -rf test-logs nim-cache bench-results
    find tests -maxdepth 1 -type f -executable -name "test_*" -not -name "*.nim" -delete
