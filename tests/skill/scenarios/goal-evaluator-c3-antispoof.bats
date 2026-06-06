#!/usr/bin/env bats
# tests/skill/scenarios/goal-evaluator-c3-antispoof.bats
#
# Scenario (audit C3): inside a bg /plan-w-team worker (marked by
# PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1), the /goal completion contract must NOT be
# spoofable. Two attack surfaces are closed:
#   1. SUCCESS decided from transcript text alone — a worker emits a
#      retro-complete status block but never crossed the ship gate. SUCCESS is
#      withheld until Step 6 wrote a deterministic PASS ship-verdict artifact.
#   2. A self-written terminal_state in the goal file — a worker jq-writes
#      terminal_state=SUCCESS to stop the loop. Honored only when the EVALUATOR
#      wrote it (terminal_state_source=evaluator).
# Interactive runs (no worker marker) keep transcript-only detection and the
# unrestricted escape hatch — a human is watching.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

EVALUATOR="$REPO_ROOT/.claude/hooks/plan-w-team-goal-evaluator.sh"
FX="$BATS_TEST_DIRNAME/fixtures/goal-evaluator-escaped-quotes"
SLUG="escq-feature"

setup() {
  sandbox
  STATE="$SANDBOX_DIR/.claude/state"
  mkdir -p "$STATE"
  GOAL="$STATE/plan-w-team-goal-${SLUG}.json"
  cat > "$GOAL" <<EOF
{
  "slug": "$SLUG",
  "started_at": "2026-06-02T00:00:00Z",
  "terminal_state": null,
  "terminal_reason": null,
  "feature_specific_done_criteria": []
}
EOF
  export CLAUDE_PROJECT_DIR="$SANDBOX_DIR"
  unset PLAN_W_TEAM_DISABLE_GOAL
}
teardown() { teardown_sandbox; }

goal_terminal() { jq -r '.terminal_state // ""' "$GOAL"; }

# Run the evaluator in WORKER mode (PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1).
run_worker() {
  local input; input=$(jq -n --arg t "$1" '{transcript_path:$t, stop_hook_active:false}')
  run bash -c "printf '%s' '$input' | PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 bash '$EVALUATOR' 2>/dev/null"
}
write_ship_verdict() { printf '{"slug":"%s","verdict":"PASS","ts":"x"}\n' "$SLUG" > "$STATE/plan-w-team-ship-verdict-${SLUG}.json"; }

@test "C3-1: worker SUCCESS anchors WITHOUT a ship-verdict → stop BLOCKED (anti-spoof)" {
  run_worker "$FX/success-pretty-printed-spaced.jsonl"
  assert_success
  assert_output_contains '"decision"'
  assert_output_contains 'block'
}

@test "C3-2: worker SUCCESS anchors WITH a PASS ship-verdict → terminal SUCCESS" {
  write_ship_verdict
  run_worker "$FX/success-pretty-printed-spaced.jsonl"
  assert_success
  assert_output_not_contains '"decision"'
  [ "$(goal_terminal)" = "SUCCESS" ]
}

@test "C3-3: worker self-written terminal_state (no provenance) is IGNORED → blocked" {
  jq '.terminal_state = "SUCCESS" | .terminal_reason = "worker self-write"' "$GOAL" > "$GOAL.tmp" && mv "$GOAL.tmp" "$GOAL"
  run_worker "$FX/non-terminal-plain.jsonl"
  assert_success
  assert_output_contains 'block'
}

@test "C3-4: worker terminal_state WITH evaluator provenance IS honored → allow stop" {
  jq '.terminal_state = "USER_ESCALATION_HALT" | .terminal_reason = "real escalation" | .terminal_state_source = "evaluator"' \
    "$GOAL" > "$GOAL.tmp" && mv "$GOAL.tmp" "$GOAL"
  run_worker "$FX/non-terminal-plain.jsonl"
  assert_success
  assert_output_not_contains '"decision"'
}

@test "C3-5: INTERACTIVE self-written terminal_state still short-circuits (escape hatch intact)" {
  jq '.terminal_state = "USER_ESCALATION_HALT" | .terminal_reason = "manual"' "$GOAL" > "$GOAL.tmp" && mv "$GOAL.tmp" "$GOAL"
  local input; input=$(jq -n --arg t "$FX/non-terminal-plain.jsonl" '{transcript_path:$t, stop_hook_active:false}')
  run bash -c "printf '%s' '$input' | bash '$EVALUATOR' 2>/dev/null"
  assert_success
  assert_output_not_contains '"decision"'
}

# ── PWT-SUP-YIELD: supervisor sessions yield; the owning worker still blocks ──

@test "SUP-YIELD: supervisor session (flag=1) YIELDS on a non-terminal goal (no block)" {
  # Non-terminal goal-state + non-terminal transcript would normally block.
  # With PLAN_W_TEAM_SUPERVISOR_SESSION=1 the session is allowed to sleep.
  local input; input=$(jq -n --arg t "$FX/non-terminal-plain.jsonl" '{transcript_path:$t, stop_hook_active:false}')
  run bash -c "printf '%s' '$input' | PLAN_W_TEAM_SUPERVISOR_SESSION=1 bash '$EVALUATOR' 2>/dev/null"
  assert_success
  assert_output_not_contains '"decision"'
}

@test "SUP-YIELD: a NON-supervisor session (no flag) STILL BLOCKS the same goal (worker invariant)" {
  local input; input=$(jq -n --arg t "$FX/non-terminal-plain.jsonl" '{transcript_path:$t, stop_hook_active:false}')
  run bash -c "printf '%s' '$input' | bash '$EVALUATOR' 2>/dev/null"
  assert_success
  assert_output_contains 'block'
}

@test "SUP-YIELD: a worker (flag explicitly 0, as pwt-goal forces) STILL BLOCKS" {
  local input; input=$(jq -n --arg t "$FX/non-terminal-plain.jsonl" '{transcript_path:$t, stop_hook_active:false}')
  run bash -c "printf '%s' '$input' | PLAN_W_TEAM_SUPERVISOR_SESSION=0 bash '$EVALUATOR' 2>/dev/null"
  assert_success
  assert_output_contains 'block'
}
