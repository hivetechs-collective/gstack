#!/usr/bin/env bash
# plan-w-team-goal-evaluator-dead-worker.test.sh
#
# Regression test for the 2.1.145 background_tasks integration in
# plan-w-team-goal-evaluator.sh.
#
# Bug class: when a /plan-w-team worker dies without writing terminal_state
# to its goal-state JSON, the parent's child-state propagation loop sets
# ALL_TERMINAL=false forever and the parent stalls indefinitely.
#
# Fix: hook input from Claude Code 2.1.145+ includes a `background_tasks`
# array. The evaluator extracts active SIDs and treats a registered child
# whose SID is NOT in that set (AND has no terminal_state) as DEAD →
# propagates as LOW_CONFIDENCE_STREAK so user investigates.
#
# Tests cover: dead child detected (SID missing from background_tasks),
# alive child stalls correctly (SID present, no terminal_state), backward
# compat (no background_tasks field → original behavior), live child
# with terminal_state propagates correctly.
set -u

EVALUATOR="${EVALUATOR:-$(cd "$(dirname "$0")" && pwd)/../hooks/plan-w-team-goal-evaluator.sh}"
PASS=0
FAIL=0
PARENT_SLUG="ac-test-parent"
CHILD_SLUG="ac-test-child"
CHILD_SID="deadbeef"

assert_block_decision() {
    local label="$1"
    local input_json="$2"
    local expected="$3"  # "block" or "allow"
    local out
    out=$(printf '%s' "$input_json" | bash "$EVALUATOR_ABS" 2>&1)
    if [ "$expected" = "allow" ]; then
        if [ -z "$out" ] || ! echo "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
            echo "  ✓ $label"
            PASS=$((PASS + 1))
        else
            echo "  ✗ $label — expected allow but got block: $out"
            FAIL=$((FAIL + 1))
        fi
    else
        if echo "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
            echo "  ✓ $label"
            PASS=$((PASS + 1))
        else
            echo "  ✗ $label — expected block but got: $out"
            FAIL=$((FAIL + 1))
        fi
    fi
}

# Build an isolated sandbox state dir so test goals don't collide with real ones.
# Critical: evaluator reads goals from BOTH $PWD/.claude/state AND $CLAUDE_PROJECT_DIR.
# We must cd into the sandbox to keep $PWD aligned.
SANDBOX=$(mktemp -d)
ORIG_PWD="$PWD"
trap 'cd "$ORIG_PWD"; rm -rf "$SANDBOX"' EXIT
export CLAUDE_PROJECT_DIR="$SANDBOX"
STATE_DIR="$SANDBOX/.claude/state"
mkdir -p "$STATE_DIR"
cd "$SANDBOX"

# Resolve evaluator path now that we've moved (was relative; lock to absolute)
EVALUATOR_ABS=$(cd "$ORIG_PWD" && cd "$(dirname "$EVALUATOR")" && pwd)/$(basename "$EVALUATOR")

reset_parent_state() {
    cat > "$STATE_DIR/plan-w-team-goal-${PARENT_SLUG}.json" <<EOF2
{"slug":"$PARENT_SLUG","started_at":"2026-05-22T15:00:00Z","terminal_state":null}
EOF2
}

reset_child_state() {
    cat > "$STATE_DIR/plan-w-team-goal-${CHILD_SLUG}.json" <<EOF2
{"slug":"$CHILD_SLUG","started_at":"2026-05-22T15:00:00Z","terminal_state":null}
EOF2
}

# Empty transcript file
TRANSCRIPT="$SANDBOX/transcript.jsonl"
: > "$TRANSCRIPT"

# Registry pointing parent → child (constant across all AC blocks)
cat > "$STATE_DIR/plan-w-team-spawned-children-${PARENT_SLUG}.jsonl" <<EOF
{"ts":"2026-05-22T15:00:00Z","session_id":"$CHILD_SID","slug":"$CHILD_SLUG","spawned_by":"pwt-goal.sh --worker-only"}
EOF

reset_parent_state
reset_child_state

echo "AC1: dead-worker propagation (SID NOT in background_tasks → propagate LOW_CONFIDENCE)"
INPUT_DEAD=$(jq -n --arg t "$TRANSCRIPT" '{
  transcript_path: $t,
  stop_hook_active: false,
  background_tasks: [{session_id: "abcd1234"}, {session_id: "ef567890"}]
}')
# First pass: parent detects dead child + writes terminal to BOTH goal files.
# Stop may still block on first pass because child's loop iteration happens BEFORE
# parent's (alphabetical glob order) so child's BLOCK_REASON is queued. On the
# SECOND pass the child file is now terminal → both allow stop. 2-pass convergence
# is acceptable (vs infinite stall in pre-fix behavior).
out1=$(printf '%s' "$INPUT_DEAD" | bash "$EVALUATOR_ABS" 2>&1)
parent_after_pass1=$(jq -r '.terminal_state' "$STATE_DIR/plan-w-team-goal-${PARENT_SLUG}.json")
child_after_pass1=$(jq -r '.terminal_state' "$STATE_DIR/plan-w-team-goal-${CHILD_SLUG}.json")
if [ "$parent_after_pass1" = "LOW_CONFIDENCE_STREAK" ]; then
    echo "  ✓ pass 1: parent propagated to LOW_CONFIDENCE_STREAK"
    PASS=$((PASS + 1))
else
    echo "  ✗ pass 1: expected LOW_CONFIDENCE_STREAK, got: $parent_after_pass1"
    FAIL=$((FAIL + 1))
fi
if [ "$child_after_pass1" = "LOW_CONFIDENCE_STREAK" ]; then
    echo "  ✓ pass 1: child terminal_state written (DEAD detection persisted)"
    PASS=$((PASS + 1))
else
    echo "  ✗ pass 1: expected child LOW_CONFIDENCE_STREAK, got: $child_after_pass1"
    FAIL=$((FAIL + 1))
fi

# Second pass: now that BOTH goal files are terminal, stop should be allowed
out2=$(printf '%s' "$INPUT_DEAD" | bash "$EVALUATOR_ABS" 2>&1)
if [ -z "$out2" ]; then
    echo "  ✓ pass 2: stop allowed (both goals terminal, no block decision)"
    PASS=$((PASS + 1))
else
    echo "  ✗ pass 2: stop still blocked unexpectedly: $out2"
    FAIL=$((FAIL + 1))
fi

# Reset for next test (parent state + child state, fresh)
reset_parent_state
reset_child_state

echo ""
echo "AC2: alive worker stalls correctly (SID IS in background_tasks, no terminal_state)"
INPUT_ALIVE=$(jq -n --arg t "$TRANSCRIPT" --arg sid "$CHILD_SID" '{
  transcript_path: $t,
  stop_hook_active: false,
  background_tasks: [{session_id: $sid}]
}')
assert_block_decision "alive child blocks parent stop" "$INPUT_ALIVE" "block"
parent_final=$(jq -r '.terminal_state' "$STATE_DIR/plan-w-team-goal-${PARENT_SLUG}.json")
if [ "$parent_final" = "null" ] || [ -z "$parent_final" ]; then
    echo "  ✓ parent terminal_state NOT prematurely set (alive child preserves stall)"
    PASS=$((PASS + 1))
else
    echo "  ✗ parent terminal_state incorrectly set to: $parent_final"
    FAIL=$((FAIL + 1))
fi

reset_parent_state
reset_child_state

echo ""
echo "AC3: backward compat (no background_tasks field → original stall behavior)"
INPUT_LEGACY=$(jq -n --arg t "$TRANSCRIPT" '{transcript_path: $t, stop_hook_active: false}')
assert_block_decision "legacy input blocks parent (no DEAD detection)" "$INPUT_LEGACY" "block"
parent_final=$(jq -r '.terminal_state' "$STATE_DIR/plan-w-team-goal-${PARENT_SLUG}.json")
if [ "$parent_final" = "null" ] || [ -z "$parent_final" ]; then
    echo "  ✓ parent terminal_state stays null (no false DEAD detection)"
    PASS=$((PASS + 1))
else
    echo "  ✗ parent terminal_state incorrectly set to: $parent_final"
    FAIL=$((FAIL + 1))
fi

reset_parent_state
reset_child_state

echo ""
echo "AC4: alive child with SUCCESS propagates correctly"
# Mark child SUCCESS
jq '.terminal_state = "SUCCESS" | .terminal_reason = "child done"' \
    "$STATE_DIR/plan-w-team-goal-${CHILD_SLUG}.json" > "$STATE_DIR/.tmp" \
    && mv "$STATE_DIR/.tmp" "$STATE_DIR/plan-w-team-goal-${CHILD_SLUG}.json"
INPUT_SUCCESS=$(jq -n --arg t "$TRANSCRIPT" --arg sid "$CHILD_SID" '{
  transcript_path: $t,
  stop_hook_active: false,
  background_tasks: [{session_id: $sid}]
}')
out=$(printf '%s' "$INPUT_SUCCESS" | bash "$EVALUATOR_ABS" 2>&1)
parent_final=$(jq -r '.terminal_state' "$STATE_DIR/plan-w-team-goal-${PARENT_SLUG}.json")
if [ "$parent_final" = "SUCCESS" ]; then
    echo "  ✓ parent propagated to SUCCESS"
    PASS=$((PASS + 1))
else
    echo "  ✗ expected SUCCESS, got: $parent_final"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "════════════════════════════════════════"
echo "  Pass: $PASS  Fail: $FAIL"
echo "════════════════════════════════════════"
[ "$FAIL" = "0" ]
