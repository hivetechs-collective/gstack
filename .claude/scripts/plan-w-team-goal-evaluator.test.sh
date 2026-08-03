#!/bin/bash
# Tests for plan-w-team-goal-evaluator.sh
# Usage: bash .claude/scripts/plan-w-team-goal-evaluator.test.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_ROOT/.claude/hooks/plan-w-team-goal-evaluator.sh"
STATE_DIR="$PROJECT_ROOT/.claude/state"
# Pin the evaluator's MAIN-checkout resolution to this same tree. Without it the
# hook's git-common-dir fallback (added for recursive-followup row 1) reaches the
# REAL main checkout whenever a scenario deliberately leaves the local scope empty
# (U1: "no active goal"), and blocks on another run's live goal-state. This is the
# documented isolation mechanism — the override always wins over git-common-dir.
export PWT_PROJECT_ROOT_OVERRIDE="$PROJECT_ROOT"

TEST_SLUG="goal-eval-test-$$"
GOAL_FILE="$STATE_DIR/plan-w-team-goal-${TEST_SLUG}.json"
TRANSCRIPT="/tmp/goal-eval-transcript-$$.jsonl"
QUARANTINE_DIR="/tmp/goal-test-quarantine-$$"

PASS=0
FAIL=0

# Test isolation: move any OTHER active goal files out of the state dir
# before running so they don't interfere with the test's goal evaluation.
mkdir -p "$QUARANTINE_DIR"
shopt -s nullglob
for f in "$STATE_DIR"/plan-w-team-goal-*.json; do
    base=$(basename "$f")
    if [ "$base" != "plan-w-team-goal-${TEST_SLUG}.json" ]; then
        mv "$f" "$QUARANTINE_DIR/$base"
    fi
done
shopt -u nullglob

cleanup() {
    # SHIP_VERDICT_FILE too: it lives in the live state tree next to the goal
    # file (that adjacency is the contract the evaluator reads), so leaving one
    # behind trips run.sh's state-leak guard and fails the whole shell phase.
    rm -f "$GOAL_FILE" "$TRANSCRIPT" "${SHIP_VERDICT_FILE:-}"
}

final_cleanup() {
    cleanup
    # Restore quarantined goal files
    shopt -s nullglob
    for f in "$QUARANTINE_DIR"/*.json; do
        mv "$f" "$STATE_DIR/$(basename "$f")"
    done
    shopt -u nullglob
    rmdir "$QUARANTINE_DIR" 2>/dev/null || true
}
trap final_cleanup EXIT

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

# Run helper: feeds JSON input to the hook, returns decision (block|empty)
run_hook() {
    local input="$1"
    echo "$input" | "$HOOK" 2>/dev/null
}

# PWT-TERM1 anti-spoof (1.46.0+): generic SUCCESS anchors alone are NOT enough —
# the evaluator withholds SUCCESS until Step 6 has written a PASS ship-verdict
# next to the goal file. These fixtures predate that contract, so each
# SUCCESS-expecting scenario stages the artifact the real pipeline would have
# produced. BLOCK-expecting scenarios must NOT have one: a PASS verdict alone
# also satisfies the PWT-TERM2 runaway guard and would flip them to SUCCESS.
SHIP_VERDICT_FILE="$STATE_DIR/plan-w-team-ship-verdict-${TEST_SLUG}.json"
write_ship_verdict() {
    cat > "$SHIP_VERDICT_FILE" <<EOF
{"slug":"$TEST_SLUG","verdict":"PASS","ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
}
clear_ship_verdict() { rm -f "$SHIP_VERDICT_FILE"; }

write_state() {
    clear_ship_verdict
    # Legacy positional args (turns, cap) accepted for backward compat with
    # existing test calls — ignored, since the hook no longer tracks them.
    local started="${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    cat > "$GOAL_FILE" <<EOF
{
  "slug": "$TEST_SLUG",
  "started_at": "$started",
  "terminal_state": null,
  "terminal_reason": null
}
EOF
}

write_transcript() {
    cat > "$TRANSCRIPT"
}

echo "U1: no active goal → exit 0, no output"
cleanup
OUT=$(echo '{"transcript_path":"/dev/null"}' | "$HOOK" 2>/dev/null)
assert_eq "no decision output" "" "$OUT"

echo "U2: kill switch → exit 0 immediately, no state read"
write_state 5 200
OUT=$(echo '{"transcript_path":"/dev/null"}' | PLAN_W_TEAM_DISABLE_GOAL=1 "$HOOK" 2>/dev/null)
assert_eq "kill switch silences" "" "$OUT"
# State should NOT have been modified at all (terminal_state stays null)
TERMINAL_AFTER=$(jq -r '.terminal_state' "$GOAL_FILE")
assert_eq "kill switch does not modify state" "null" "$TERMINAL_AFTER"

echo "U3: stop_hook_active=true → exit 0 (block-cap protection)"
OUT=$(echo '{"transcript_path":"/dev/null","stop_hook_active":true}' | "$HOOK" 2>/dev/null)
assert_eq "stop_hook_active honored" "" "$OUT"

echo "U4: goal active, no transcript signals → block with reason"
write_state 1 200
write_transcript <<'EOF'
some random output
no status block here
EOF
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
DECISION=$(echo "$OUT" | jq -r '.decision // ""' 2>/dev/null)
assert_eq "decision=block" "block" "$DECISION"
# Hook no longer tracks turns_evaluated — confirm the field was not added
TURNS_FIELD=$(jq -r 'has("turns_evaluated")' "$GOAL_FILE")
assert_eq "no turn counter field" "false" "$TURNS_FIELD"

echo "U5: SUCCESS — stage=retro-complete + workflow_lock=done → allow stop"
write_state 5 200
write_ship_verdict
cat > "$TRANSCRIPT" <<EOF
some earlier output
{"slug":"$TEST_SLUG","stage":"retro-complete","workflow_lock":"done","ts":"2026-05-19T22:00:00Z"}
EOF
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
assert_eq "SUCCESS allows stop" "" "$OUT"
TERMINAL=$(jq -r '.terminal_state' "$GOAL_FILE")
assert_eq "terminal_state=SUCCESS" "SUCCESS" "$TERMINAL"

echo "U6: USER_ESCALATION_HALT — pending_escalations has push-ack → allow stop"
write_state 3 200
cat > "$TRANSCRIPT" <<EOF
status block:
{"slug":"$TEST_SLUG","stage":"ship","pending_escalations":["push-ack"],"low_confidence_routes":0}
EOF
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
assert_eq "USER_ESCALATION_HALT allows stop" "" "$OUT"
TERMINAL=$(jq -r '.terminal_state' "$GOAL_FILE")
assert_eq "terminal_state=USER_ESCALATION_HALT" "USER_ESCALATION_HALT" "$TERMINAL"

echo "U7: LOW_CONFIDENCE_STREAK — low_confidence_routes=3 → allow stop"
write_state 10 200
cat > "$TRANSCRIPT" <<EOF
status block:
{"slug":"$TEST_SLUG","stage":"execute","pending_escalations":[],"low_confidence_routes":3}
EOF
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
assert_eq "LOW_CONFIDENCE_STREAK allows stop" "" "$OUT"
TERMINAL=$(jq -r '.terminal_state' "$GOAL_FILE")
assert_eq "terminal_state=LOW_CONFIDENCE_STREAK" "LOW_CONFIDENCE_STREAK" "$TERMINAL"

echo "U8: NO wall-clock or turn cap — long-running pipeline keeps blocking"
# Removed by design: TIME_OR_TURN_CAP terminal state. A pipeline with no
# terminal anchors must continue blocking — there is no time-based escape.
write_state 999 200  # legacy args ignored; field not written
write_transcript <<'EOF'
nothing terminal here, lots of work pending
EOF
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
DECISION=$(echo "$OUT" | jq -r '.decision // ""' 2>/dev/null)
assert_eq "still blocks when no terminal anchor" "block" "$DECISION"
TERMINAL=$(jq -r '.terminal_state' "$GOAL_FILE")
assert_eq "no terminal set" "null" "$TERMINAL"

echo "U9: already-terminal goal → exit 0 (no re-evaluation)"
write_ship_verdict
# Manually set the goal to terminal to verify the early-return path
jq '.terminal_state = "SUCCESS" | .terminal_reason = "prev run"' "$GOAL_FILE" > "$GOAL_FILE.tmp" && mv "$GOAL_FILE.tmp" "$GOAL_FILE"
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
assert_eq "no re-eval when terminal" "" "$OUT"

echo "U10: corrupt state file → skip, no crash"
echo "{not valid json" > "$GOAL_FILE"
OUT=$(echo '{"transcript_path":"/dev/null"}' | "$HOOK" 2>&1)
# Should not output a decision block (corrupt file = skip)
DECISION=$(echo "$OUT" | jq -r '.decision // ""' 2>/dev/null)
assert_eq "corrupt file handled" "" "$DECISION"

echo "U11: block reason cites the terminal-state options"
write_state 2 200
write_transcript <<'EOF'
random
EOF
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
REASON=$(echo "$OUT" | jq -r '.reason // ""')
[ -n "$REASON" ] && [[ "$REASON" == *"retro-complete"* ]] && [[ "$REASON" == *"push-ack"* ]] \
    && echo "  ✓ reason cites both anchors" && PASS=$((PASS + 1)) \
    || { echo "  ✗ reason missing anchors: $REASON"; FAIL=$((FAIL + 1)); }

echo ""
echo "=== PWT-T5c: feature-specific definition-of-done criteria ==="

write_state_with_criteria() {
    clear_ship_verdict
    local criteria_json="$1"
    # Legacy positional args (turns, cap) accepted for backward compat — ignored.
    cat > "$GOAL_FILE" <<EOF
{
  "slug": "$TEST_SLUG",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "terminal_state": null,
  "terminal_reason": null,
  "feature_specific_done_criteria": $criteria_json
}
EOF
}

echo "U18: criteria=[] → T5b backward compat (SUCCESS fires on generic anchors alone)"
write_state_with_criteria '[]' 5 200
write_ship_verdict
cat > "$TRANSCRIPT" <<EOF
{"slug":"$TEST_SLUG","stage":"retro-complete","workflow_lock":"done","ts":"2026-05-19T22:00:00Z"}
EOF
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
assert_eq "backward-compat SUCCESS" "SUCCESS" "$(jq -r '.terminal_state' "$GOAL_FILE")"

echo "U19: criteria + generic absent → block citing pipeline incomplete"
write_state_with_criteria '[{"pattern":"AC1.*PASS","description":"thing one","met":false,"met_at":null}]' 1 200
cat > "$TRANSCRIPT" <<EOF
some output but no terminal anchors
EOF
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
assert_eq "blocks when generic absent" "block" "$(echo "$OUT" | jq -r '.decision // ""' 2>/dev/null)"

echo "U20: criteria + generic + all met → SUCCESS terminal"
write_state_with_criteria '[{"pattern":"AC1.*PASS","description":"thing one","met":false,"met_at":null}]' 5 200
write_ship_verdict
cat > "$TRANSCRIPT" <<EOF
AC1: PASS verified by Step 5 review
{"slug":"$TEST_SLUG","stage":"retro-complete","workflow_lock":"done","ts":"2026-05-19T22:00:00Z"}
EOF
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
assert_eq "all met fires SUCCESS" "SUCCESS" "$(jq -r '.terminal_state' "$GOAL_FILE")"
assert_eq "criterion marked met" "true" "$(jq -r '.feature_specific_done_criteria[0].met' "$GOAL_FILE")"

echo "U21: criteria + generic + some unmet → block citing unmet descriptions"
write_state_with_criteria '[{"pattern":"AC1.*PASS","description":"first criterion","met":false,"met_at":null},{"pattern":"AC2.*PASS","description":"second criterion","met":false,"met_at":null}]' 5 200
cat > "$TRANSCRIPT" <<EOF
AC1: PASS verified
{"slug":"$TEST_SLUG","stage":"retro-complete","workflow_lock":"done","ts":"2026-05-19T22:00:00Z"}
EOF
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
assert_eq "blocks when partial met" "block" "$(echo "$OUT" | jq -r '.decision // ""' 2>/dev/null)"
REASON=$(echo "$OUT" | jq -r '.reason // ""' 2>/dev/null)
[[ "$REASON" == *"second criterion"* ]] \
    && echo "  ✓ reason cites unmet description" && PASS=$((PASS + 1)) \
    || { echo "  ✗ reason missing 'second criterion': $REASON"; FAIL=$((FAIL + 1)); }
assert_eq "AC1 marked met" "true" "$(jq -r '.feature_specific_done_criteria[0].met' "$GOAL_FILE")"
assert_eq "AC2 still unmet" "false" "$(jq -r '.feature_specific_done_criteria[1].met' "$GOAL_FILE")"

echo "U22: criterion met persists across invocations (first match wins)"
write_ship_verdict
# AC1 is already marked met from previous invocation. Run again with extended transcript.
cat > "$TRANSCRIPT" <<EOF
AC1: PASS verified
AC2: PASS verified
{"slug":"$TEST_SLUG","stage":"retro-complete","workflow_lock":"done","ts":"2026-05-19T22:00:00Z"}
EOF
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
assert_eq "all met now → SUCCESS" "SUCCESS" "$(jq -r '.terminal_state' "$GOAL_FILE")"
# AC1's met_at should be from the FIRST match, not overwritten
MET_AT_1=$(jq -r '.feature_specific_done_criteria[0].met_at' "$GOAL_FILE")
[ -n "$MET_AT_1" ] && [ "$MET_AT_1" != "null" ] && echo "  ✓ AC1 met_at preserved" && PASS=$((PASS + 1)) \
    || { echo "  ✗ AC1 met_at lost: $MET_AT_1"; FAIL=$((FAIL + 1)); }

echo "U23: malformed regex → other criteria still evaluated"
write_state_with_criteria '[{"pattern":"[unclosed","description":"bad regex","met":false,"met_at":null},{"pattern":"AC2.*PASS","description":"second","met":false,"met_at":null}]' 5 200
cat > "$TRANSCRIPT" <<EOF
AC2: PASS verified
{"slug":"$TEST_SLUG","stage":"retro-complete","workflow_lock":"done","ts":"2026-05-19T22:00:00Z"}
EOF
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
# AC2 should be evaluated and marked met (bad regex on AC1 doesn't crash)
assert_eq "AC2 still evaluated despite bad regex on AC1" "true" \
    "$(jq -r '.feature_specific_done_criteria[1].met' "$GOAL_FILE")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
