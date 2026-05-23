#!/usr/bin/env bats
# tests/skill/scenarios/parallel-worker-gate-idle-counted.bats
#
# Scenario: parallel-worker gate counts IDLE workers, not just BUSY.
#           Production evidence 2026-05-22: a SUCCESS-terminal worker
#           remained alive in `claude agents --json` with status="idle"
#           and the gate failed to count it, allowing silent double-spawn.
#
# Spec: docs/specs/parallel-worker-gate-idle-counted.md
# Extends: tests/skill/scenarios/parallel-worker-gate.bats (which only
#          covers status="busy"; helper hardcodes that value).

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"
load "$BATS_TEST_DIRNAME/../helpers/scenario_helper.bash"

setup() {
  scenario_sandbox
  IMPERATIVE_PROMPT='Use /plan-w-team to ship a thing.'
  DESCRIPTIVE_PROMPT="Should I use /plan-w-team to add foo?"
}

teardown() { scenario_teardown; }

# ─── Helper: build a fixture worker entry with parameterised status ──────────
# Args: sid, slug-suffix-for-name, status (busy|idle|completed|unknown)
make_worker_status() {
  local sid="$1"; local suffix="${2:-thing}"; local status="${3:-busy}"
  local cwd="$SANDBOX_DIR/some/sub/dir"
  jq -nc --arg sid "$sid" --arg cwd "$cwd" \
    --arg name "/goal Use /plan-w-team to $suffix" --arg status "$status" \
    '{
      pid: 12345,
      cwd: $cwd,
      kind: "background",
      startedAt: 1779000000000,
      sessionId: $sid,
      name: $name,
      status: $status
    }'
}

# ─── AC1: one idle worker + imperative trigger → gate fires ─────────────────

@test "parallel-worker-gate-idle-counted AC1: given one idle worker and imperative trigger, when shim runs hook, then 0 bg workers are spawned and disambiguation fires" {
  local worker; worker=$(make_worker_status "94d6ba9c" "feature-x" "idle")
  export SHIM_AGENTS_JSON="[$worker]"
  run_shim "$IMPERATIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_bg_count 0
  assert_simctx_marker "workers already active in this project"
  assert_simctx_marker "94d6ba9c"
  assert_simctx_marker "status: idle"
}

# ─── AC2: one busy + one idle + trigger → gate fires with both listed ───────

@test "parallel-worker-gate-idle-counted AC2: given one busy + one idle worker and imperative trigger, when shim runs hook, then sysmsg lists both with their statuses" {
  local w_busy w_idle
  w_busy=$(make_worker_status "94d6ba9c" "feature-a" "busy")
  w_idle=$(make_worker_status "7138429d" "feature-b" "idle")
  export SHIM_AGENTS_JSON="[$w_busy,$w_idle]"
  run_shim "$IMPERATIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_bg_count 0
  assert_simctx_marker "94d6ba9c"
  assert_simctx_marker "7138429d"
  assert_simctx_marker "status: busy"
  assert_simctx_marker "status: idle"
}

# ─── AC3: zero active + trigger → gate passes through (greenfield unchanged) ─

@test "parallel-worker-gate-idle-counted AC3: given zero workers and imperative trigger, when shim runs hook, then exactly 1 bg worker is spawned (gate quiet)" {
  export SHIM_AGENTS_JSON='[]'
  run_shim "$IMPERATIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_bg_count 1
  assert_simctx_marker "/plan-w-team origin-chat supervisor active"
}

# ─── AC4: zero active + descriptive prose → no spawn (classifier rejects) ───

@test "parallel-worker-gate-idle-counted AC4: given zero workers and descriptive prose, when shim runs hook, then 0 bg workers are spawned (classifier rejected before gate)" {
  export SHIM_AGENTS_JSON='[]'
  run_shim "$DESCRIPTIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_bg_count 0
  run jq -r '.delivered_to_assistant.hook_system_message // ""' "$SCENARIO_OUT_FILE"
  [[ "$output" != *"workers already active in this project"* ]]
}
