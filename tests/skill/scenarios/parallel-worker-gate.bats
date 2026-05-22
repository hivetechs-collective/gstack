#!/usr/bin/env bats
# tests/skill/scenarios/parallel-worker-gate.bats
#
# Scenario: parallel-worker gate (PWG). When the user types an imperative
#           /plan-w-team trigger but bg workers are already active in the
#           project, the route hook refuses to spawn and emits a
#           disambiguation systemMessage. Greenfield (zero workers) is
#           unaffected; kill switch bypasses the gate.
#
# Spec: docs/specs/parallel-worker-gate.md
# Originating evidence: 2026-05-22 cleanscale incident — silent parallel
#   spawn while an existing /plan-w-team worker was driving an autonomous run.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"
load "$BATS_TEST_DIRNAME/../helpers/scenario_helper.bash"

setup() {
  scenario_sandbox
  IMPERATIVE_PROMPT='Use /plan-w-team to ship a thing.'
  DESCRIPTIVE_PROMPT="Should I use /plan-w-team to add foo?"
}

teardown() { scenario_teardown; }

# ─── Helper: build a fixture worker JSON entry for SHIM_AGENTS_JSON ──────────
# Args: sid, slug-suffix-for-name
make_worker() {
  local sid="$1"; local suffix="${2:-thing}"
  local cwd="$SANDBOX_DIR/some/sub/dir"
  jq -nc --arg sid "$sid" --arg cwd "$cwd" --arg name "/goal Use /plan-w-team to $suffix" \
    '{
      pid: 12345,
      cwd: $cwd,
      kind: "background",
      startedAt: 1779000000000,
      sessionId: $sid,
      name: $name,
      status: "busy"
    }'
}

# ─── AC1: zero active workers + imperative trigger → spawn happens ──────────

@test "parallel-worker-gate AC1: given zero active workers and imperative trigger, when shim runs hook, then exactly 1 bg worker is spawned (greenfield unchanged)" {
  export SHIM_AGENTS_JSON='[]'
  run_shim "$IMPERATIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_bg_count 1
  assert_simctx_marker "/plan-w-team origin-chat supervisor active"
}

# ─── AC2: one active worker + imperative trigger → no spawn, sysmsg emitted ─

@test "parallel-worker-gate AC2: given one active worker and imperative trigger, when shim runs hook, then 0 bg workers are spawned" {
  local worker; worker=$(make_worker "aaaa1111" "feature-x")
  export SHIM_AGENTS_JSON="[$worker]"
  run_shim "$IMPERATIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_bg_count 0
}

@test "parallel-worker-gate AC2: given one active worker and imperative trigger, when shim runs hook, then disambiguation sysmsg is emitted" {
  local worker; worker=$(make_worker "aaaa1111" "feature-x")
  export SHIM_AGENTS_JSON="[$worker]"
  run_shim "$IMPERATIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_marker "workers already active in this project"
  assert_simctx_marker "aaaa1111"
  assert_simctx_marker "parallel | direct | cancel"
}

# ─── AC3: multi active workers → no spawn, all SIDs listed ──────────────────

@test "parallel-worker-gate AC3: given three active workers and imperative trigger, when shim runs hook, then 0 bg workers are spawned" {
  local w1 w2 w3
  w1=$(make_worker "aaaa1111" "feature-a")
  w2=$(make_worker "bbbb2222" "feature-b")
  w3=$(make_worker "cccc3333" "feature-c")
  export SHIM_AGENTS_JSON="[$w1,$w2,$w3]"
  run_shim "$IMPERATIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_bg_count 0
}

@test "parallel-worker-gate AC3: given three active workers and imperative trigger, when shim runs hook, then sysmsg lists all 3 SIDs" {
  local w1 w2 w3
  w1=$(make_worker "aaaa1111" "feature-a")
  w2=$(make_worker "bbbb2222" "feature-b")
  w3=$(make_worker "cccc3333" "feature-c")
  export SHIM_AGENTS_JSON="[$w1,$w2,$w3]"
  run_shim "$IMPERATIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_marker "aaaa1111"
  assert_simctx_marker "bbbb2222"
  assert_simctx_marker "cccc3333"
}

# ─── AC4: descriptive prose + active workers → no spawn (classifier path) ───

@test "parallel-worker-gate AC4: given descriptive prose and active workers, when shim runs hook, then 0 bg workers are spawned and no gate sysmsg fires (classifier already suppressed)" {
  local worker; worker=$(make_worker "aaaa1111" "feature-x")
  export SHIM_AGENTS_JSON="[$worker]"
  run_shim "$DESCRIPTIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_bg_count 0
  # Gate-specific sysmsg should NOT fire — the classifier suppressed the
  # trigger before the gate ran.
  run jq -r '.delivered_to_assistant.hook_system_message // ""' "$SCENARIO_OUT_FILE"
  [[ "$output" != *"workers already active in this project"* ]]
}

# ─── AC5: kill switch + active workers → bypass gate, spawn happens ─────────

@test "parallel-worker-gate AC5: given PLAN_W_TEAM_DISABLE_PARALLEL_GATE=1 and one active worker, when shim runs hook, then spawn happens (gate bypassed)" {
  local worker; worker=$(make_worker "aaaa1111" "feature-x")
  export SHIM_AGENTS_JSON="[$worker]"
  export PLAN_W_TEAM_DISABLE_PARALLEL_GATE=1
  run_shim "$IMPERATIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_bg_count 1
  assert_simctx_marker "/plan-w-team origin-chat supervisor active"
}

# ─── AC1-reinforcement: filter excludes kind=interactive ────────────────────

@test "parallel-worker-gate filter: given only interactive (non-background) agents, when shim runs hook, then gate does not fire and spawn happens" {
  local interactive
  interactive=$(jq -nc --arg cwd "$SANDBOX_DIR" \
    '{pid: 9, cwd: $cwd, kind: "interactive", sessionId: "intxxxxx", name: "/goal Use /plan-w-team to thing", status: "busy"}')
  export SHIM_AGENTS_JSON="[$interactive]"
  run_shim "$IMPERATIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_bg_count 1
}

# ─── AC1-reinforcement: filter excludes agents outside project root ─────────

@test "parallel-worker-gate filter: given workers in unrelated cwds, when shim runs hook, then gate does not fire and spawn happens" {
  local outside
  outside=$(jq -nc \
    '{pid: 9, cwd: "/some/other/project", kind: "background", sessionId: "outxxxxx", name: "/goal Use /plan-w-team to thing", status: "busy"}')
  export SHIM_AGENTS_JSON="[$outside]"
  run_shim "$IMPERATIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_bg_count 1
}

# ─── Filter sanity: name without /goal or /plan-w-team is ignored ───────────

@test "parallel-worker-gate filter: given bg agent without /goal or /plan-w-team in name, when shim runs hook, then gate does not fire and spawn happens" {
  local unrelated
  unrelated=$(jq -nc --arg cwd "$SANDBOX_DIR" \
    '{pid: 9, cwd: $cwd, kind: "background", sessionId: "bgxxxxxx", name: "running tests", status: "busy"}')
  export SHIM_AGENTS_JSON="[$unrelated]"
  run_shim "$IMPERATIVE_PROMPT" --sandbox "$SANDBOX_DIR"
  assert_success
  assert_simctx_bg_count 1
}
