#!/usr/bin/env bash
# tests/skill/helpers/scenario_helper.bash
#
# Helpers for E2E scenario tests (tests/skill/scenarios/*.bats).
#
# Scenario tests differ from unit tests in that they exercise the integration
# path: hook → harness-shim → pwt-goal.sh → claude --bg (stubbed). Where unit
# tests sandbox a single script and assert deterministic shell behavior,
# scenarios run the real shipping hook against a real prompt fixture through
# the shim, and assert on the simulated-assistant-context JSON the shim emits.
#
# Loaded alongside test_helper.bash:
#   load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"
#   load "$BATS_TEST_DIRNAME/../helpers/scenario_helper.bash"

# Path to the shim
SHIM_BIN="$REPO_ROOT/tests/skill/harness-shim.sh"
export SHIM_BIN

# ─── Scenario sandbox ────────────────────────────────────────────────────────
# Wraps the standard sandbox helper but does NOT copy the hooks/scripts into
# it — the shim does that lazily inside its own sandbox. Tests can choose to
# preserve the shim's sandbox by passing --keep-sandbox to capture state for
# diagnostic output on failure.

scenario_sandbox() {
  sandbox
  SCENARIO_OUT_FILE="$SANDBOX_DIR/sim-ctx.json"
  SCENARIO_STDERR_FILE="$SANDBOX_DIR/shim.stderr"
  export SCENARIO_OUT_FILE SCENARIO_STDERR_FILE
}

scenario_teardown() {
  teardown_sandbox
}

# ─── Shim invocation wrapper ─────────────────────────────────────────────────
# Runs the shim with the given prompt; captures sim-ctx JSON to a file the
# helpers below can re-read across multiple assertions.

run_shim() {
  local prompt="$1"
  shift || true
  run "$SHIM_BIN" --prompt "$prompt" "$@"
  # Persist stdout for downstream helpers.
  printf '%s\n' "$output" > "$SCENARIO_OUT_FILE"
}

# ─── Sim-ctx assertion helpers (built on jq) ────────────────────────────────
# Each helper reads $SCENARIO_OUT_FILE and asserts on a field. Failures print
# the relevant field excerpt for fast triage.

_simctx() {
  # Internal: run a jq filter on the captured sim-ctx, fail with a helpful
  # diagnostic if the JSON itself is malformed.
  local filter="$1"
  if ! jq -e "$filter" "$SCENARIO_OUT_FILE" 2>/dev/null; then
    printf 'sim-ctx assertion failed: %s\n--- sim-ctx ---\n%s\n' \
      "$filter" "$(cat "$SCENARIO_OUT_FILE" 2>/dev/null)" >&2
    return 1
  fi
}

assert_simctx_bg_count() {
  local expected="$1"
  local actual
  actual=$(jq '.side_effects.bg_sessions_spawned | length' "$SCENARIO_OUT_FILE" 2>/dev/null || echo "?")
  if [ "$actual" != "$expected" ]; then
    printf 'bg_sessions_spawned: expected %s, got %s\n--- argv list ---\n%s\n' \
      "$expected" "$actual" \
      "$(jq '.side_effects.bg_sessions_spawned[].argv[0:3]' "$SCENARIO_OUT_FILE" 2>/dev/null)" >&2
    return 1
  fi
}

assert_simctx_marker() {
  local needle="$1"
  local sysmsg
  sysmsg=$(jq -r '.delivered_to_assistant.hook_system_message // ""' "$SCENARIO_OUT_FILE" 2>/dev/null)
  if ! printf '%s' "$sysmsg" | grep -qF -- "$needle"; then
    printf 'sysmsg marker not found: %s\n--- delivered sysmsg ---\n%s\n' \
      "$needle" "$sysmsg" >&2
    return 1
  fi
}

assert_simctx_no_marker() {
  # The hook should not have fired at all — sysmsg is null.
  local sysmsg
  sysmsg=$(jq -r '.delivered_to_assistant.hook_system_message // "<NULL>"' "$SCENARIO_OUT_FILE" 2>/dev/null)
  if [ "$sysmsg" != "<NULL>" ] && [ -n "$sysmsg" ]; then
    printf 'expected no sysmsg, got:\n%s\n' "$sysmsg" >&2
    return 1
  fi
}

assert_simctx_addctx_dropped() {
  # When the hook DID fire and emitted additionalContext, the shim records
  # that it was dropped (harness contract). When the hook didn't fire, the
  # field is false. Tests must specify expected (true/false).
  local expected="$1"
  local actual
  actual=$(jq -r '.delivered_to_assistant.additionalContext_dropped' "$SCENARIO_OUT_FILE" 2>/dev/null)
  if [ "$actual" != "$expected" ]; then
    printf 'additionalContext_dropped: expected %s, got %s\n' "$expected" "$actual" >&2
    return 1
  fi
}

assert_simctx_hook_exit() {
  local expected="$1"
  local actual
  actual=$(jq -r '.hook.exit_code' "$SCENARIO_OUT_FILE" 2>/dev/null)
  if [ "$actual" != "$expected" ]; then
    printf 'hook.exit_code: expected %s, got %s\n--- stderr ---\n%s\n' \
      "$expected" "$actual" \
      "$(jq -r '.hook.stderr' "$SCENARIO_OUT_FILE" 2>/dev/null)" >&2
    return 1
  fi
}

assert_simctx_bg_argv_contains() {
  # Asserts that the Nth bg_sessions_spawned record's argv contains the given
  # substring anywhere in any element.
  local idx="$1"; local needle="$2"
  local joined
  joined=$(jq -r --argjson i "$idx" '.side_effects.bg_sessions_spawned[$i].argv | join(" ")' "$SCENARIO_OUT_FILE" 2>/dev/null)
  if ! printf '%s' "$joined" | grep -qF -- "$needle"; then
    printf 'bg_sessions_spawned[%s].argv did not contain: %s\n--- argv ---\n%s\n' \
      "$idx" "$needle" "$joined" >&2
    return 1
  fi
}
