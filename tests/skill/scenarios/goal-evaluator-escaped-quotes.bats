#!/usr/bin/env bats
# tests/skill/scenarios/goal-evaluator-escaped-quotes.bats
#
# Scenario: the /plan-w-team Stop hook (plan-w-team-goal-evaluator.sh) must
#           recognize terminal status blocks regardless of WHERE they appear in
#           the transcript JSONL — assistant text (escaped quotes), fenced
#           ```json code blocks, tool_result strings/arrays, AND the raw
#           direct-write form. It must NOT false-positive on documentation text
#           that merely quotes the anchor strings, and must not crash on
#           malformed JSONL.
#
# Originating bug (2026-05-25): the detectors ran `grep -F '"stage":"retro-
# complete"'` against the raw transcript file. Claude Code stores assistant
# message content as JSON-encoded strings, so a status block emitted as
# assistant text lands on disk with ESCAPED quotes (\"stage\":\"retro-complete\")
# which the fixed-string grep never matched → false-negative → autonomous run
# trapped. The cleanscale agent had to hand-write terminal_state into the goal
# state file as a workaround.
#
# Fix: decode each transcript entry with jq (decode_transcript) and match the
# UNESCAPED text, while OR-ing in the raw tail for backward-compat. See the
# rationale block in the hook for why the "just add an escaped grep" approach
# (Approach B) was rejected.
#
# Spec/directive: .claude/state/plan-w-team-directive-1dc8ca6e10e2.txt

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

EVALUATOR="$REPO_ROOT/.claude/hooks/plan-w-team-goal-evaluator.sh"
FX="$BATS_TEST_DIRNAME/fixtures/goal-evaluator-escaped-quotes"
SLUG="escq-feature"

setup() {
  sandbox
  STATE="$SANDBOX_DIR/.claude/state"
  mkdir -p "$STATE"
  GOAL="$STATE/plan-w-team-goal-${SLUG}.json"
  # Active, non-terminal goal for this run's slug.
  cat > "$GOAL" <<EOF
{
  "slug": "$SLUG",
  "started_at": "2026-05-25T00:00:00Z",
  "terminal_state": null,
  "terminal_reason": null,
  "feature_specific_done_criteria": []
}
EOF
  export CLAUDE_PROJECT_DIR="$SANDBOX_DIR"
  # sandbox() cd's into $SANDBOX_DIR, so $PWD/.claude/state == $STATE. No real
  # production goal file can leak in. PLAN_W_TEAM_DISABLE_GOAL must be unset.
  unset PLAN_W_TEAM_DISABLE_GOAL
}

teardown() { teardown_sandbox; }

# ── helpers ──────────────────────────────────────────────────────────────────

# Run the evaluator with a given fixture as the transcript. Captures stdout
# (the decision JSON, empty when stop is allowed) into $output and exit in
# $status via bats `run`.
run_evaluator() {
  local fixture="$1"
  local input
  input=$(jq -n --arg t "$fixture" '{transcript_path:$t, stop_hook_active:false}')
  run bash -c "printf '%s' '$input' | bash '$EVALUATOR' 2>/dev/null"
}

# terminal_state currently persisted in the goal file ("" if none).
goal_terminal() { jq -r '.terminal_state // ""' "$GOAL"; }

# Assert the hook ALLOWED the stop (terminal reached): no block decision on
# stdout AND the goal file got the expected terminal_state. (The decision JSON
# is jq-pretty-printed, so match the un-spaced key and the "block" value
# separately to be robust to formatting.)
assert_terminal() {
  local expected="$1"
  assert_success
  assert_output_not_contains '"decision"'
  local got; got=$(goal_terminal)
  if [ "$got" != "$expected" ]; then
    printf 'expected terminal_state=%s, got=%s\n' "$expected" "$got" >&2
    return 1
  fi
}

# Assert the hook BLOCKED the stop (still pending): emits a block decision AND
# the goal file was NOT marked terminal.
assert_not_terminal() {
  assert_success
  assert_output_contains '"decision"'
  assert_output_contains 'block'
  local got; got=$(goal_terminal)
  if [ -n "$got" ] && [ "$got" != "null" ]; then
    printf 'expected NO terminal_state, got=%s\n' "$got" >&2
    return 1
  fi
}

# ── SUCCESS detector across transcript shapes ───────────────────────────────

@test "escaped-quotes AC1: SUCCESS from escaped assistant text status block" {
  run_evaluator "$FX/success-escaped-assistant-text.jsonl"
  assert_terminal "SUCCESS"
}

@test "escaped-quotes AC2: SUCCESS from fenced \`\`\`json code block in assistant text" {
  run_evaluator "$FX/success-fenced-codeblock.jsonl"
  assert_terminal "SUCCESS"
}

@test "escaped-quotes AC3: SUCCESS from raw direct-write form (backward-compat)" {
  run_evaluator "$FX/success-raw-direct-write.jsonl"
  assert_terminal "SUCCESS"
}

@test "escaped-quotes AC4: SUCCESS from tool_result content string" {
  run_evaluator "$FX/success-tool-result-string.jsonl"
  assert_terminal "SUCCESS"
}

@test "escaped-quotes AC5: SUCCESS from tool_result content array" {
  run_evaluator "$FX/success-tool-result-array.jsonl"
  assert_terminal "SUCCESS"
}

# ── USER_ESCALATION_HALT + LOW_CONFIDENCE_STREAK detectors ──────────────────

@test "escaped-quotes AC6: USER_ESCALATION_HALT from escaped pending_escalations:[push-ack]" {
  run_evaluator "$FX/escalation-push-ack.jsonl"
  assert_terminal "USER_ESCALATION_HALT"
}

@test "escaped-quotes AC7: LOW_CONFIDENCE_STREAK from escaped low_confidence_routes:4" {
  run_evaluator "$FX/low-confidence-streak.jsonl"
  assert_terminal "LOW_CONFIDENCE_STREAK"
}

# ── False-positive defenses (must NOT terminate) ────────────────────────────

@test "escaped-quotes AC8: does NOT fire on a status block for a DIFFERENT slug" {
  run_evaluator "$FX/false-positive-different-slug.jsonl"
  assert_not_terminal
}

@test "escaped-quotes AC9: does NOT fire when escalation site is not colocated with this slug" {
  run_evaluator "$FX/false-positive-anchor-elsewhere.jsonl"
  assert_not_terminal
}

@test "escaped-quotes AC10: does NOT fire on ordinary non-terminal chatter" {
  run_evaluator "$FX/non-terminal-plain.jsonl"
  assert_not_terminal
}

# ── Robustness ───────────────────────────────────────────────────────────────

@test "escaped-quotes AC11: malformed JSONL does not crash; stays non-terminal" {
  run_evaluator "$FX/malformed.jsonl"
  assert_not_terminal
}

@test "escaped-quotes AC12: empty transcript stays non-terminal, no crash" {
  empty="$SANDBOX_DIR/empty.jsonl"
  : > "$empty"
  run_evaluator "$empty"
  assert_not_terminal
}

# ── Backward-compat: terminal_state state-file short-circuit ────────────────

@test "escaped-quotes AC13: pre-existing terminal_state in goal file short-circuits to allow stop" {
  # Simulate the documented workaround: terminal_state written directly.
  jq '.terminal_state = "USER_ESCALATION_HALT" | .terminal_reason = "manual halt"' \
    "$GOAL" > "$GOAL.tmp" && mv "$GOAL.tmp" "$GOAL"
  run_evaluator "$FX/non-terminal-plain.jsonl"
  # Allowed stop (no block) even though the transcript itself is non-terminal.
  assert_success
  assert_output_not_contains '"decision"'
  [ "$(goal_terminal)" = "USER_ESCALATION_HALT" ]
}

# ── Debug mode ───────────────────────────────────────────────────────────────

@test "escaped-quotes AC14: --debug / PWT_GOAL_EVALUATOR_DEBUG emits structured diagnostics to stderr" {
  input=$(jq -n --arg t "$FX/non-terminal-plain.jsonl" \
    '{transcript_path:$t, stop_hook_active:false}')
  run bash -c "printf '%s' '$input' | PWT_GOAL_EVALUATOR_DEBUG=1 bash '$EVALUATOR' 2>&1 1>/dev/null"
  assert_success
  assert_output_contains "[goal-evaluator:debug]"
  assert_output_contains "(1) SUCCESS not matched"
  assert_output_contains "NOT terminal"
}

@test "escaped-quotes AC15: replay of cleanscale hard-gate escalation releases stop without manual file edit" {
  # Regression anchor for the originating incident: a worker emits a hard-gate
  # pending_escalations block as escaped assistant text. Pre-fix, the hook
  # silently blocked and the agent had to hand-write terminal_state. Post-fix,
  # the hook must release the stop on its own.
  run_evaluator "$FX/escalation-push-ack.jsonl"
  assert_terminal "USER_ESCALATION_HALT"
  reason=$(jq -r '.terminal_reason' "$GOAL")
  echo "$reason" | grep -qF "push-ack"
  echo "AC15: PASS goal-evaluator releases USER_ESCALATION_HALT from escaped transcript without manual terminal_state edit"
}

# ── Realistic PRETTY-PRINTED (colon-SPACE) form ──────────────────────────────
# surface-status.sh emits jq-pretty-printed JSON (`"stage": "retro-complete"`,
# colon-SPACE), and decode_transcript only collapses newlines — inner spacing is
# preserved. A fixed-string grep for the COMPACT `"stage":"retro-complete"` form
# matched the (compact) fixtures above but NEVER the real spaced block the retro
# actually emits. These two cases pin the space-tolerant ERE detectors so the
# production signal is covered, not just the synthetic compact form.

@test "escaped-quotes AC16: SUCCESS from REAL pretty-printed (colon-space) status block" {
  run_evaluator "$FX/success-pretty-printed-spaced.jsonl"
  assert_terminal "SUCCESS"
  echo "AC16: PASS goal-evaluator detects the real pretty-printed retro-complete block surface-status.sh emits"
}

@test "escaped-quotes AC17: USER_ESCALATION_HALT from REAL pretty-printed multi-line pending_escalations" {
  run_evaluator "$FX/escalation-pretty-printed-spaced.jsonl"
  assert_terminal "USER_ESCALATION_HALT"
  reason=$(jq -r '.terminal_reason' "$GOAL")
  echo "$reason" | grep -qF "secret-scan-allow"
  echo "AC17: PASS goal-evaluator detects the real pretty-printed multi-line escalation block"
}
