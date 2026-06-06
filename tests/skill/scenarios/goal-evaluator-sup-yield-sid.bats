#!/usr/bin/env bats
# tests/skill/scenarios/goal-evaluator-sup-yield-sid.bats
#
# PWT-SUP-YIELD-SID (2026-06-03): identity-based supervisor yield in the goal
# evaluator. The pre-existing yield was env-only (PLAN_W_TEAM_SUPERVISOR_SESSION=1),
# which cannot exempt an ORIGIN chat that BECOMES a supervisor mid-session (it can't
# set its own launch env) — so it got dragged into Stop-hook busy-poll every turn,
# worsened by PWT-WT2 reliably seeding the goal-state where the hook finds it.
#
# Fix: only the OWNING worker (session_id prefix == goal-state worker_sid) is blocked
# to run to terminal; any other session (supervisor/observer) YIELDS. Safety
# invariants verified here:
#   1. owning worker            → BLOCK   (worker runs to terminal — unchanged)
#   2. supervisor (other SID)   → YIELD   (the fix)
#   3. goal with no worker_sid  → BLOCK   (un-ownable → fail safe; covers in-session)
#   4. empty session_id         → BLOCK   (older harness; SID matching disabled)
#   5. env-flag supervisor      → YIELD   (regression: env path preserved)
#   6. multi-goal, owns one     → BLOCK   (must run its own to terminal)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

EVALUATOR="$REPO_ROOT/.claude/hooks/plan-w-team-goal-evaluator.sh"
SLUG="sidyield-feature"
WORKER_SID="5de5b9ac"   # 8-hex short SID as recorded by pwt-goal PWT-WT2

setup() {
  sandbox
  STATE="$SANDBOX_DIR/.claude/state"
  mkdir -p "$STATE"
  GOAL="$STATE/plan-w-team-goal-${SLUG}.json"
  # Non-terminal transcript (no retro-complete / AC anchors) so the goal BLOCKS,
  # which is the precondition for the yield-vs-block decision under test.
  TRANSCRIPT="$SANDBOX_DIR/transcript.jsonl"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"still building, no terminal anchors"}]}}\n' > "$TRANSCRIPT"
  export CLAUDE_PROJECT_DIR="$SANDBOX_DIR"
  unset PLAN_W_TEAM_DISABLE_GOAL PLAN_W_TEAM_SUPERVISOR_SESSION
}
teardown() { teardown_sandbox; }

# $1 = worker_sid (empty string → omit the field, simulating a legacy/in-session goal)
write_goal() {
  if [ -n "$1" ]; then
    printf '{"slug":"%s","started_at":"2026-06-03T00:00:00Z","terminal_state":null,"terminal_reason":null,"worker_sid":"%s","feature_specific_done_criteria":[]}\n' "$SLUG" "$1" > "$GOAL"
  else
    printf '{"slug":"%s","started_at":"2026-06-03T00:00:00Z","terminal_state":null,"terminal_reason":null,"feature_specific_done_criteria":[]}\n' "$SLUG" > "$GOAL"
  fi
}

# $1 = session_id (empty → omit). $2 = optional inline env (e.g. VAR=1).
run_eval() {
  local sid="$1" envass="${2:-}" input
  if [ -n "$sid" ]; then
    input=$(jq -n --arg t "$TRANSCRIPT" --arg s "$sid" '{transcript_path:$t, stop_hook_active:false, session_id:$s}')
  else
    input=$(jq -n --arg t "$TRANSCRIPT" '{transcript_path:$t, stop_hook_active:false}')
  fi
  run bash -c "printf '%s' '$input' | $envass bash '$EVALUATOR' 2>&1"
}

# A blocked stop emits the JSON {"decision":"block",...} on stdout. A yield emits
# only a stderr note (which itself contains the word "block" in "not block"), so
# match the JSON key, not the bare word.
is_blocked() { grep -q '"decision"' <<<"$output"; }

@test "1. owning worker (session_id prefix == worker_sid) is BLOCKED" {
  write_goal "$WORKER_SID"
  run_eval "${WORKER_SID}-4c4d-4870-8e6b-3b4a1b570638"
  assert_success
  is_blocked || { echo "expected BLOCK; got:\n$output" >&2; false; }
}

@test "2. supervisor (different session_id) YIELDS, not block" {
  write_goal "$WORKER_SID"
  run_eval "aaaaaaaa-1111-2222-3333-444444444444"
  assert_success
  ! is_blocked || { echo "expected YIELD; got:\n$output" >&2; false; }
  assert_output_contains "non-owning session"
}

@test "3. blocking goal with NO worker_sid → BLOCK even for a different session (fail-safe)" {
  write_goal ""
  run_eval "aaaaaaaa-1111-2222-3333-444444444444"
  assert_success
  is_blocked || { echo "expected BLOCK (un-ownable); got:\n$output" >&2; false; }
}

@test "4. empty session_id (older harness) → BLOCK (SID matching disabled)" {
  write_goal "$WORKER_SID"
  run_eval ""
  assert_success
  is_blocked || { echo "expected BLOCK (no SID); got:\n$output" >&2; false; }
}

@test "5. env-flag supervisor still YIELDS (regression: env path preserved)" {
  write_goal "$WORKER_SID"
  run_eval "${WORKER_SID}-4c4d-4870-8e6b-3b4a1b570638" "PLAN_W_TEAM_SUPERVISOR_SESSION=1"
  assert_success
  ! is_blocked || { echo "expected env-supervisor YIELD; got:\n$output" >&2; false; }
  assert_output_contains "PLAN_W_TEAM_SUPERVISOR_SESSION=1"
}

@test "6. multi-goal: session owns ONE blocking goal → BLOCK (must run its own to terminal)" {
  write_goal "$WORKER_SID"
  # A second, concurrent goal owned by a DIFFERENT worker, also non-terminal.
  printf '{"slug":"other-feat","started_at":"2026-06-03T00:00:00Z","terminal_state":null,"terminal_reason":null,"worker_sid":"bbbbbbbb","feature_specific_done_criteria":[]}\n' \
    > "$STATE/plan-w-team-goal-other-feat.json"
  # This session IS the owner of the first goal → must block.
  run_eval "${WORKER_SID}-4c4d-4870-8e6b-3b4a1b570638"
  assert_success
  is_blocked || { echo "expected BLOCK (owns one); got:\n$output" >&2; false; }
}

# ── Adversarial-verify hardening: malformed worker_sid must fail safe to BLOCK ──
# (workflow wf_9cab85b2 CRITICAL: whitespace/padded worker_sid defeated the guard)

@test "7. whitespace-only worker_sid → BLOCK (un-ownable after trim, not a wrong yield)" {
  write_goal "   "
  run_eval "aaaaaaaa-1111-2222-3333-444444444444"
  assert_success
  is_blocked || { echo "expected BLOCK (whitespace un-ownable); got:\n$output" >&2; false; }
}

@test "8. CASE J: leading-whitespace worker_sid + GENUINE owner → BLOCK (owner must run to terminal)" {
  write_goal "  ${WORKER_SID}"
  run_eval "${WORKER_SID}-4c4d-4870-8e6b-3b4a1b570638"
  assert_success
  is_blocked || { echo "expected BLOCK (owner, ws-padded sid); got:\n$output" >&2; false; }
}

@test "9. uppercase worker_sid + owner lowercase session_id → BLOCK (case-normalized owner match)" {
  write_goal "5DE5B9AC"
  run_eval "5de5b9ac-4c4d-4870-8e6b-3b4a1b570638"
  assert_success
  is_blocked || { echo "expected BLOCK (owner via case-normalize); got:\n$output" >&2; false; }
}

@test "10. non-hex worker_sid (not a valid SID) → BLOCK (un-ownable, fail-safe)" {
  # Note: trim collapses leading/trailing/internal whitespace, so "5de5 b9ac"
  # would RECOVER to the valid 5de5b9ac (owner blocks / non-owner yields — correct).
  # This case uses a token that cannot normalize to >=8 hex → un-ownable → BLOCK.
  write_goal "zzzzzzzz"
  run_eval "aaaaaaaa-1111-2222-3333-444444444444"
  assert_success
  is_blocked || { echo "expected BLOCK (non-hex un-ownable); got:\n$output" >&2; false; }
}
