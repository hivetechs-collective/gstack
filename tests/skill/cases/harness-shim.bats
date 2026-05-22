#!/usr/bin/env bats
# tests/skill/cases/harness-shim.bats
#
# Unit tests for tests/skill/harness-shim.sh — the fake Claude Code harness
# used by the E2E scenarios. These tests pin the shim's own CLI contract
# (flags, exit codes, sim-ctx schema) so a refactor doesn't silently change
# the contract every scenario depends on.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SHIM="$REPO_ROOT/tests/skill/harness-shim.sh"

setup() { sandbox; }
teardown() { teardown_sandbox; }

# ── CLI surface ─────────────────────────────────────────────────────────────

@test "harness-shim: given --help flag, when invoked, then usage prints and exit code is 0" {
  run "$SHIM" --help
  assert_success
  assert_output_contains "harness-shim.sh --prompt"
}

@test "harness-shim: given no prompt argument, when invoked, then exits 2 with ShimError" {
  run "$SHIM"
  assert_failure 2
  assert_output_contains "ShimError: missing prompt fixture"
}

@test "harness-shim: given unknown arg, when invoked, then exits 2 with ShimError" {
  run "$SHIM" --bogus-flag whatever
  assert_failure 2
  assert_output_contains "ShimError: unknown arg"
}

@test "harness-shim: given missing prompt-file, when invoked, then exits 2 with ShimError" {
  run "$SHIM" --prompt-file "$SANDBOX_DIR/does-not-exist.txt"
  assert_failure 2
  assert_output_contains "prompt-file not readable"
}

# ── Sim-ctx schema (happy path with trigger phrase) ─────────────────────────

@test "harness-shim: given a trigger-phrase prompt, when invoked, then sim-ctx JSON has all required top-level keys" {
  run "$SHIM" --prompt "Use /plan-w-team to add a thing."
  assert_success
  # Schema check — every top-level key must be present.
  for k in sandbox hook delivered_to_assistant side_effects; do
    if ! jq -e "has(\"$k\")" <<<"$output" >/dev/null 2>&1; then
      printf 'sim-ctx missing top-level key: %s\n--- output ---\n%s\n' "$k" "$output" >&2
      return 1
    fi
  done
}

@test "harness-shim: given a trigger-phrase prompt, when invoked, then delivered_to_assistant captures systemMessage and drops additionalContext" {
  run "$SHIM" --prompt "Use /plan-w-team to add a thing."
  assert_success
  local sysmsg addctx_dropped
  sysmsg=$(jq -r '.delivered_to_assistant.hook_system_message // ""' <<<"$output")
  addctx_dropped=$(jq -r '.delivered_to_assistant.additionalContext_dropped' <<<"$output")
  if [ -z "$sysmsg" ]; then
    printf 'expected sysmsg to be delivered, got empty\n--- output ---\n%s\n' "$output" >&2; return 1
  fi
  if [ "$addctx_dropped" != "true" ]; then
    printf 'expected additionalContext_dropped=true, got %s\n' "$addctx_dropped" >&2; return 1
  fi
}

@test "harness-shim: given a trigger-phrase prompt, when invoked, then bg session is recorded with /goal in argv" {
  run "$SHIM" --prompt "Use /plan-w-team to add a thing."
  assert_success
  local bg_count argv0
  bg_count=$(jq '.side_effects.bg_sessions_spawned | length' <<<"$output")
  argv0=$(jq -r '.side_effects.bg_sessions_spawned[0].argv[0]' <<<"$output")
  if [ "$bg_count" != "1" ]; then
    printf 'expected bg_count=1, got %s\n' "$bg_count" >&2; return 1
  fi
  if [ "$argv0" != "--bg" ]; then
    printf 'expected argv[0]=--bg, got %s\n' "$argv0" >&2; return 1
  fi
}

# ── Sim-ctx schema (no-trigger path) ────────────────────────────────────────

@test "harness-shim: given a non-trigger prompt, when invoked, then no bg session is recorded and hook exits 0" {
  run "$SHIM" --prompt "Hello, what is your favorite color?"
  assert_success
  local bg_count hook_exit
  bg_count=$(jq '.side_effects.bg_sessions_spawned | length' <<<"$output")
  hook_exit=$(jq '.hook.exit_code' <<<"$output")
  if [ "$bg_count" != "0" ]; then
    printf 'expected bg_count=0, got %s\n' "$bg_count" >&2; return 1
  fi
  if [ "$hook_exit" != "0" ]; then
    printf 'expected hook_exit=0, got %s\n' "$hook_exit" >&2; return 1
  fi
}

@test "harness-shim: given a non-trigger prompt, when invoked, then additionalContext_dropped is false (nothing was dropped)" {
  run "$SHIM" --prompt "Hello there."
  assert_success
  local dropped
  dropped=$(jq -r '.delivered_to_assistant.additionalContext_dropped' <<<"$output")
  if [ "$dropped" != "false" ]; then
    printf 'expected additionalContext_dropped=false on no-trigger path, got %s\n' "$dropped" >&2; return 1
  fi
}

# ── --prompt-file source ────────────────────────────────────────────────────

@test "harness-shim: given a prompt via --prompt-file, when invoked, then it is processed identically to --prompt" {
  echo "Use /plan-w-team to add a thing." > "$SANDBOX_DIR/fixture.txt"
  run "$SHIM" --prompt-file "$SANDBOX_DIR/fixture.txt"
  assert_success
  local bg_count
  bg_count=$(jq '.side_effects.bg_sessions_spawned | length' <<<"$output")
  if [ "$bg_count" != "1" ]; then
    printf 'expected bg_count=1 from --prompt-file, got %s\n--- output ---\n%s\n' \
      "$bg_count" "$output" >&2; return 1
  fi
}
