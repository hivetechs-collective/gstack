#!/bin/bash
# Tests for pwt-status.sh — the /plan-w-team diagnostic listing utility.
# Mirrors the test pattern in plan-w-team-goal-evaluator.test.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PROJECT_ROOT/.claude/scripts/pwt-status.sh"

PASS=0
FAIL=0

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

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name (needle not found: $needle)"
        echo "    haystack:"
        echo "$haystack" | sed 's/^/      /'
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        echo "  ✗ $name (forbidden needle found: $needle)"
        FAIL=$((FAIL + 1))
    else
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    fi
}

setup_fake_root() {
    FAKE_ROOT=$(mktemp -d)
    mkdir -p "$FAKE_ROOT/.claude/state"
    export CLAUDE_PROJECT_DIR="$FAKE_ROOT"
}

teardown_fake_root() {
    rm -rf "$FAKE_ROOT"
    unset CLAUDE_PROJECT_DIR
}

echo "T1: help flag prints usage and exits 0"
OUT=$("$SCRIPT" --help 2>&1)
RC=$?
assert_eq "exit 0 on --help" "0" "$RC"
assert_contains "help mentions usage" "Usage:" "$OUT"
assert_contains "help mentions columns" "Columns:" "$OUT"

echo "T2: empty state dir → no runs message"
setup_fake_root
OUT=$("$SCRIPT" 2>&1)
RC=$?
assert_eq "exit 0 on empty" "0" "$RC"
assert_contains "no-runs message" "No active /plan-w-team runs" "$OUT"
teardown_fake_root

echo "T3: missing state dir → no runs message (treats as empty)"
FAKE_ROOT=$(mktemp -d)
export CLAUDE_PROJECT_DIR="$FAKE_ROOT"  # no .claude/state
OUT=$("$SCRIPT" 2>&1)
assert_contains "no-runs message" "No active /plan-w-team runs" "$OUT"
teardown_fake_root

echo "T4: one pending goal file → row with pending terminal"
setup_fake_root
cat > "$FAKE_ROOT/.claude/state/plan-w-team-goal-feature-x.json" <<EOF
{"slug":"feature-x","started_at":"2026-05-19T00:00:00Z","terminal_state":null,"terminal_reason":null}
EOF
OUT=$("$SCRIPT" 2>&1)
assert_contains "feature-x listed" "feature-x" "$OUT"
assert_contains "pending terminal" "pending" "$OUT"
assert_contains "missing lock state" "missing" "$OUT"
teardown_fake_root

echo "T5: terminal goal + active lock → SUCCESS row, active LOCK"
setup_fake_root
cat > "$FAKE_ROOT/.claude/state/plan-w-team-goal-feature-y.json" <<EOF
{"slug":"feature-y","started_at":"2026-05-19T00:00:00Z","terminal_state":"SUCCESS","terminal_reason":"done"}
EOF
LOCK_DIR="$FAKE_ROOT/.claude/state/plan-w-team-workflow-feature-y.lock"
mkdir "$LOCK_DIR"
echo "$$" > "$LOCK_DIR/pid"  # current PID (alive)
OUT=$("$SCRIPT" 2>&1)
assert_contains "feature-y listed" "feature-y" "$OUT"
assert_contains "SUCCESS terminal" "SUCCESS" "$OUT"
assert_contains "active lock" "active" "$OUT"
teardown_fake_root

echo "T6: two runs (one terminal, one pending) → both listed"
setup_fake_root
cat > "$FAKE_ROOT/.claude/state/plan-w-team-goal-alpha.json" <<EOF
{"slug":"alpha","started_at":"2026-05-19T00:00:00Z","terminal_state":"USER_ESCALATION_HALT","terminal_reason":"push-ack"}
EOF
cat > "$FAKE_ROOT/.claude/state/plan-w-team-goal-beta.json" <<EOF
{"slug":"beta","started_at":"2026-05-19T00:00:00Z","terminal_state":null,"terminal_reason":null}
EOF
OUT=$("$SCRIPT" 2>&1)
assert_contains "alpha listed" "alpha" "$OUT"
assert_contains "beta listed" "beta" "$OUT"
assert_contains "USER_ESCALATION_HALT shown" "USER_ESCALATION_HALT" "$OUT"
assert_contains "pending shown" "pending" "$OUT"
teardown_fake_root

echo "T7: corrupt JSON → (corrupt) marker, no crash"
setup_fake_root
echo "{not valid json" > "$FAKE_ROOT/.claude/state/plan-w-team-goal-bad.json"
OUT=$("$SCRIPT" 2>&1)
RC=$?
assert_eq "still exits 0 on corrupt" "0" "$RC"
assert_contains "corrupt marker" "(corrupt)" "$OUT"
teardown_fake_root

echo "T8: stale lock (dead PID) → stale state"
setup_fake_root
# Use a very high PID that's almost certainly not alive
DEAD_PID=999999
cat > "$FAKE_ROOT/.claude/state/plan-w-team-goal-stuck.json" <<EOF
{"slug":"stuck","started_at":"2026-05-19T00:00:00Z","terminal_state":null,"terminal_reason":null}
EOF
LOCK_DIR="$FAKE_ROOT/.claude/state/plan-w-team-workflow-stuck.lock"
mkdir "$LOCK_DIR"
echo "$DEAD_PID" > "$LOCK_DIR/pid"
OUT=$("$SCRIPT" 2>&1)
assert_contains "stale lock detected" "stale" "$OUT"
teardown_fake_root

echo "T9: AC6 — output contains no reserved /plan-w-team status-block field names"
setup_fake_root
cat > "$FAKE_ROOT/.claude/state/plan-w-team-goal-test.json" <<EOF
{"slug":"test","started_at":"2026-05-19T00:00:00Z","terminal_state":null,"terminal_reason":null}
EOF
OUT=$("$SCRIPT" 2>&1)
# These are reserved status-block names; the diagnostic must not emit them
# (case-sensitive since the evaluator greps for them literally)
assert_not_contains "no 'stage' field" '"stage"' "$OUT"
assert_not_contains "no 'workflow_lock' field" '"workflow_lock"' "$OUT"
assert_not_contains "no 'ship_readiness_gate' field" '"ship_readiness_gate"' "$OUT"
assert_not_contains "no 'pending_escalations' field" '"pending_escalations"' "$OUT"
assert_not_contains "no 'low_confidence_routes' field" '"low_confidence_routes"' "$OUT"
teardown_fake_root

echo "T10: AC5 — missing jq returns exit 2 with install hint"
# Run via PATH shim that hides jq
SHIM_DIR=$(mktemp -d)
# A PATH with NO jq — just a minimal set of standard utilities
PATH_NO_JQ="$SHIM_DIR"
# Need basic utils available
for util in bash sh cat sed find grep ls mkdir basename dirname date kill rm pwd; do
    src=$(command -v "$util" 2>/dev/null) || continue
    ln -s "$src" "$SHIM_DIR/$util" 2>/dev/null || true
done
OUT=$(PATH="$PATH_NO_JQ" "$SCRIPT" 2>&1)
RC=$?
assert_eq "exit 2 when jq missing" "2" "$RC"
assert_contains "jq install hint" "brew install jq" "$OUT"
rm -rf "$SHIM_DIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
