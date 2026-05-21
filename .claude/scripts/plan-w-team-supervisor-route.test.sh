#!/bin/bash
# Tests for plan-w-team-supervisor-route.sh
# Usage: bash .claude/scripts/plan-w-team-supervisor-route.test.sh
# Exits 0 on all pass, 1 on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Override inherited CLAUDE_PROJECT_DIR so the wrapper writes to $STATE_DIR (the
# path the test reads), not an inherited parent-session value pointing elsewhere.
export CLAUDE_PROJECT_DIR="$PROJECT_ROOT"
WRAPPER="$SCRIPT_DIR/plan-w-team-supervisor-route.sh"
STATE_DIR="$PROJECT_ROOT/.claude/state"

TEST_SLUG="supervisor-test-$$"
ACTIONS_LOG="$STATE_DIR/plan-w-team-supervisor-actions-${TEST_SLUG}.jsonl"

PASS=0
FAIL=0

cleanup() { rm -f "$ACTIONS_LOG"; }
trap cleanup EXIT

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

run() {
    # Run wrapper with explicitly cleared env unless the caller exported flags
    "$WRAPPER" "$@" 2>/dev/null
    echo $?
}

run_with_stderr() {
    "$WRAPPER" "$@" 2>&1 >/dev/null
}

echo "U1: default (no env) → exit 0 + supervisor_start row appended"
rm -f "$ACTIONS_LOG"
EXIT=$(unset PLAN_W_TEAM_DISABLE_SUPERVISOR; run "$TEST_SLUG")
assert_eq "exit code" "0" "$EXIT"
assert_eq "log file exists" "1" "$( [ -f "$ACTIONS_LOG" ] && echo 1 || echo 0)"

echo "U2: kill switch → exit 2 + stderr 'kill switch set'"
EXIT=$(PLAN_W_TEAM_DISABLE_SUPERVISOR=1 run "$TEST_SLUG")
assert_eq "exit code" "2" "$EXIT"
STDERR=$(PLAN_W_TEAM_DISABLE_SUPERVISOR=1 run_with_stderr "$TEST_SLUG")
assert_eq "stderr message" "1" "$(echo "$STDERR" | grep -c 'kill switch set' || true)"

echo "U3: missing slug → exit 1 + usage on stderr"
EXIT=$(run)
assert_eq "exit code" "1" "$EXIT"
STDERR=$(run_with_stderr)
assert_eq "stderr usage" "1" "$(echo "$STDERR" | grep -c 'Usage:' || true)"

echo "U4: row content + schema"
rm -f "$ACTIONS_LOG"
run "$TEST_SLUG" >/dev/null
assert_eq "one row appended" "1" "$(wc -l < "$ACTIONS_LOG" | tr -d ' ')"
ROW=$(head -1 "$ACTIONS_LOG")
assert_eq "row is valid JSON" "1" "$(echo "$ROW" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)"
assert_eq "event=supervisor_start" "supervisor_start" "$(echo "$ROW" | jq -r '.event')"
assert_eq "slug matches" "$TEST_SLUG" "$(echo "$ROW" | jq -r '.slug')"

echo "U5: idempotency — second invocation appends second row, no corruption"
EXIT=$(run "$TEST_SLUG")
assert_eq "second exit code" "0" "$EXIT"
assert_eq "two rows now" "2" "$(wc -l < "$ACTIONS_LOG" | tr -d ' ')"
INVALID=$(while IFS= read -r line; do echo "$line" | jq -e . >/dev/null 2>&1 || echo "bad"; done < "$ACTIONS_LOG" | wc -l | tr -d ' ')
assert_eq "no corrupt rows" "0" "$INVALID"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
