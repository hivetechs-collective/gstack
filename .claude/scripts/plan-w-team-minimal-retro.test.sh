#!/bin/bash
# Tests for plan-w-team-minimal-retro.sh
# Usage: bash .claude/scripts/plan-w-team-minimal-retro.test.sh
# Exits 0 on all pass, 1 on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$SCRIPT_DIR/plan-w-team-minimal-retro.sh"
STATE_DIR="$PROJECT_ROOT/.claude/state"

TEST_SLUG="minimal-retro-test-$$"
RETRO="$STATE_DIR/plan-w-team-retro-${TEST_SLUG}.json"

PASS=0
FAIL=0

cleanup() {
    rm -f "$RETRO"
}
trap cleanup EXIT

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name"
        echo "    expected: [$expected]"
        echo "    actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# AC5a: helper writes minimal retro when none exists
# ───────────────────────────────────────────────────────────────────────────
echo "U1: helper writes minimal retro when none exists"
rm -f "$RETRO"
"$HELPER" "$TEST_SLUG" "ship" "test-reason"
RC=$?
assert_eq "exit code" "0" "$RC"
[ -f "$RETRO" ]
assert_eq "retro file written" "0" "$?"
TERMINAL=$(jq -r '.terminal_state' "$RETRO" 2>/dev/null)
assert_eq "terminal_state=EARLY_EXIT" "EARLY_EXIT" "$TERMINAL"
MINIMAL=$(jq -r '.minimal' "$RETRO" 2>/dev/null)
assert_eq "minimal=true" "true" "$MINIMAL"
STAGE=$(jq -r '.stage' "$RETRO" 2>/dev/null)
assert_eq "stage echoed" "ship" "$STAGE"
SLUG_FIELD=$(jq -r '.slug' "$RETRO" 2>/dev/null)
assert_eq "slug echoed" "$TEST_SLUG" "$SLUG_FIELD"
REASON=$(jq -r '.early_exit_reason' "$RETRO" 2>/dev/null)
assert_eq "reason echoed" "test-reason" "$REASON"

# Metrics must be null but present (so downstream readers don't NPE)
COMMITS=$(jq -r '.metrics.commits' "$RETRO" 2>/dev/null)
assert_eq "metrics.commits=null" "null" "$COMMITS"
AC_COUNT=$(jq -r '.metrics.ac_count' "$RETRO" 2>/dev/null)
assert_eq "metrics.ac_count=null" "null" "$AC_COUNT"
SCORE=$(jq -r '.self_assessment.score' "$RETRO" 2>/dev/null)
assert_eq "self_assessment.score=null" "null" "$SCORE"

# ───────────────────────────────────────────────────────────────────────────
# AC5b: helper does NOT clobber an existing complete retro
# ───────────────────────────────────────────────────────────────────────────
echo "U2: helper preserves existing complete retro (no clobber)"
rm -f "$RETRO"
# Write a "complete" retro that does NOT have minimal:true
cat > "$RETRO" <<EOF
{
  "slug": "$TEST_SLUG",
  "stage": "retro-complete",
  "terminal_state": "SUCCESS",
  "metrics": {"commits": 5, "ac_count": 8, "ac_passing": 8},
  "self_assessment": {"score": 9}
}
EOF

"$HELPER" "$TEST_SLUG" "ship" "would-have-been-early-exit"
RC=$?
assert_eq "exit code" "0" "$RC"

# The complete retro must be unchanged
TERMINAL=$(jq -r '.terminal_state' "$RETRO" 2>/dev/null)
assert_eq "terminal_state stays SUCCESS" "SUCCESS" "$TERMINAL"
COMMITS=$(jq -r '.metrics.commits' "$RETRO" 2>/dev/null)
assert_eq "metrics.commits preserved" "5" "$COMMITS"
SCORE=$(jq -r '.self_assessment.score' "$RETRO" 2>/dev/null)
assert_eq "self_assessment.score preserved" "9" "$SCORE"
HAS_MINIMAL=$(jq -r 'has("minimal")' "$RETRO" 2>/dev/null)
assert_eq "minimal key not added" "false" "$HAS_MINIMAL"

# ───────────────────────────────────────────────────────────────────────────
# AC5c: helper exits 0 on missing SLUG (fail-open)
# ───────────────────────────────────────────────────────────────────────────
echo "U3: missing SLUG → exit 0 silently, no file written"
rm -f "$RETRO"
"$HELPER" "" "ship" "test"
RC=$?
assert_eq "exit code" "0" "$RC"
[ ! -f "$RETRO" ]
assert_eq "no file written" "0" "$?"

# ───────────────────────────────────────────────────────────────────────────
# Integration check: trap pattern works from inside a shell flow
# ───────────────────────────────────────────────────────────────────────────
echo "U4: trap fires on exit 1, writes minimal retro"
TRAP_TEST_SLUG="trap-test-$$"
TRAP_RETRO="$STATE_DIR/plan-w-team-retro-${TRAP_TEST_SLUG}.json"
rm -f "$TRAP_RETRO"

# Spawn a subshell that installs the trap then exits 1
( cd "$PROJECT_ROOT" && bash -c "
SLUG='$TRAP_TEST_SLUG'
PWT_CURRENT_STAGE='ship'
trap '.claude/scripts/plan-w-team-minimal-retro.sh \"\$SLUG\" \"\$PWT_CURRENT_STAGE\" \"ship-early-exit-\$?\"' EXIT
exit 1
" ) || true

[ -f "$TRAP_RETRO" ]
assert_eq "trap fired and wrote retro" "0" "$?"
if [ -f "$TRAP_RETRO" ]; then
    TERMINAL=$(jq -r '.terminal_state' "$TRAP_RETRO" 2>/dev/null)
    assert_eq "trap-written retro terminal=EARLY_EXIT" "EARLY_EXIT" "$TERMINAL"
    REASON=$(jq -r '.early_exit_reason' "$TRAP_RETRO" 2>/dev/null)
    # Reason should contain the exit code 1
    if printf '%s' "$REASON" | grep -q "1"; then
        echo "  ✓ trap-written reason mentions exit code"
        PASS=$((PASS + 1))
    else
        echo "  ✗ trap-written reason missing exit code: $REASON"
        FAIL=$((FAIL + 1))
    fi
fi
rm -f "$TRAP_RETRO"

# ───────────────────────────────────────────────────────────────────────────
# Edge: trap chains with existing trap (the 05-ship.md pattern)
# ───────────────────────────────────────────────────────────────────────────
echo "U5: trap chains with pre-existing EXIT handler"
CHAIN_SLUG="chain-test-$$"
CHAIN_RETRO="$STATE_DIR/plan-w-team-retro-${CHAIN_SLUG}.json"
CHAIN_TOUCH="/tmp/pwt-chain-touch-$$"
rm -f "$CHAIN_RETRO" "$CHAIN_TOUCH"

( cd "$PROJECT_ROOT" && bash -c "
SLUG='$CHAIN_SLUG'
PWT_CURRENT_STAGE='ship'
# Pre-existing trap (simulates push-lock release)
trap 'touch $CHAIN_TOUCH' EXIT
# Add minimal-retro trap with the documented chain pattern
EXISTING_TRAP=\$(trap -p EXIT | sed -E \"s/^trap -- '(.*)' EXIT\$/\\\\1/\")
trap \"\${EXISTING_TRAP:+\${EXISTING_TRAP}; }.claude/scripts/plan-w-team-minimal-retro.sh \\\"\\\$SLUG\\\" \\\"\\\$PWT_CURRENT_STAGE\\\" 'chain-test-exit'\" EXIT
exit 1
" ) || true

[ -f "$CHAIN_TOUCH" ]
assert_eq "pre-existing trap still fired" "0" "$?"
[ -f "$CHAIN_RETRO" ]
assert_eq "chained minimal-retro fired" "0" "$?"
rm -f "$CHAIN_RETRO" "$CHAIN_TOUCH"

# ───────────────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
