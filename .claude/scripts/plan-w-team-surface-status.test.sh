#!/bin/bash
# Tests for plan-w-team-surface-status.sh
# Usage: bash .claude/scripts/plan-w-team-surface-status.test.sh
# Exits 0 on all pass, 1 on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$SCRIPT_DIR/plan-w-team-surface-status.sh"
STATE_DIR="$PROJECT_ROOT/.claude/state"

TEST_SLUG="surface-status-test-$$"
LOCK_DIR="$STATE_DIR/plan-w-team-workflow-${TEST_SLUG}.lock"
SUP_LOG="$STATE_DIR/plan-w-team-supervisor-actions-${TEST_SLUG}.jsonl"
FLEET_LOG="$STATE_DIR/plan-w-team-fleet-${TEST_SLUG}.jsonl"

PASS=0
FAIL=0

cleanup() {
    rm -rf "$LOCK_DIR"
    rm -f "$SUP_LOG" "$FLEET_LOG"
}
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

# Extract JSON between ```status fences from helper output
extract_json() {
    awk '/^```status$/{flag=1; next} /^```$/{flag=0} flag'
}

echo "U1: missing slug → exit 1 + usage stderr"
"$HELPER" 2>/tmp/serr-$$ >/dev/null
EXIT=$?
assert_eq "exit code" "1" "$EXIT"
assert_eq "usage in stderr" "1" "$(grep -c 'Usage:' /tmp/serr-$$ || echo 0)"
rm -f /tmp/serr-$$

echo "U2: no state → block with workflow_lock=missing, empty arrays, exit 0"
cleanup
OUT=$("$HELPER" "$TEST_SLUG" "test-stage" 2>/dev/null)
EXIT=$?
assert_eq "exit code" "0" "$EXIT"
JSON=$(echo "$OUT" | extract_json)
assert_eq "valid JSON" "1" "$(echo "$JSON" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)"
assert_eq "workflow_lock=missing" "missing" "$(echo "$JSON" | jq -r '.workflow_lock')"
assert_eq "pending_escalations empty" "0" "$(echo "$JSON" | jq -r '.pending_escalations | length')"
assert_eq "low_confidence_routes=0" "0" "$(echo "$JSON" | jq -r '.low_confidence_routes')"
assert_eq "stage matches" "test-stage" "$(echo "$JSON" | jq -r '.stage')"
assert_eq "slug matches" "$TEST_SLUG" "$(echo "$JSON" | jq -r '.slug')"

echo "U3: workflow lock dir present → workflow_lock=active"
mkdir -p "$LOCK_DIR"
echo "$$" > "$LOCK_DIR/pid"
JSON=$("$HELPER" "$TEST_SLUG" "execute" 2>/dev/null | extract_json)
assert_eq "workflow_lock=active" "active" "$(echo "$JSON" | jq -r '.workflow_lock')"

echo "U4: 3 low-confidence rows in supervisor-actions → low_confidence_routes=3"
cat > "$SUP_LOG" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"supervisor_start","slug":"$TEST_SLUG","supervisor_agent_id":"AGT-1"}
{"ts":"2026-05-19T22:01:00Z","event":"route_delegation","slug":"$TEST_SLUG","call_site":"qa-tier-selection","router_choice":"standard","router_confidence":"low"}
{"ts":"2026-05-19T22:02:00Z","event":"route_delegation","slug":"$TEST_SLUG","call_site":"version-bump-major-vs-minor","router_choice":"minor","router_confidence":"low"}
{"ts":"2026-05-19T22:03:00Z","event":"route_delegation","slug":"$TEST_SLUG","call_site":"agent-roster-selection","router_choice":"react-typescript-specialist","router_confidence":"high"}
{"ts":"2026-05-19T22:04:00Z","event":"route_delegation","slug":"$TEST_SLUG","call_site":"ship-readiness-gate","router_choice":"PASS","router_confidence":"low"}
EOF
JSON=$("$HELPER" "$TEST_SLUG" "ship" 2>/dev/null | extract_json)
assert_eq "low_confidence_routes=3" "3" "$(echo "$JSON" | jq -r '.low_confidence_routes')"
assert_eq "ship_readiness_gate=PASS" "PASS" "$(echo "$JSON" | jq -r '.ship_readiness_gate')"

echo "U5: fleet log present → fleet object populated"
cat > "$FLEET_LOG" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"spawn","slug":"$TEST_SLUG","agent_id":"AGT-A","agent_type":"builder","cwd":"/r"}
{"ts":"2026-05-19T22:00:05Z","event":"spawn","slug":"$TEST_SLUG","agent_id":"AGT-B","agent_type":"builder","cwd":"/r"}
{"ts":"2026-05-19T22:05:00Z","event":"complete","slug":"$TEST_SLUG","agent_id":"AGT-A","last_msg":"done"}
EOF
JSON=$("$HELPER" "$TEST_SLUG" "execute" 2>/dev/null | extract_json)
assert_eq "fleet.spawned=2" "2" "$(echo "$JSON" | jq -r '.fleet.spawned')"
assert_eq "fleet.completed=1" "1" "$(echo "$JSON" | jq -r '.fleet.completed')"
assert_eq "fleet.running=1" "1" "$(echo "$JSON" | jq -r '.fleet.running')"

echo 'U6: status block emits to stdout inside fenced wrapper, JSON parseable'
OUT=$("$HELPER" "$TEST_SLUG" "verify" 2>/dev/null)
FENCE_OPEN=$(echo "$OUT" | grep -c '^```status$' || echo 0)
FENCE_CLOSE=$(echo "$OUT" | grep -c '^```$' || echo 0)
assert_eq "opening fence" "1" "$FENCE_OPEN"
assert_eq "closing fence" "1" "$FENCE_CLOSE"
PARSED=$(echo "$OUT" | extract_json | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)
assert_eq "inner JSON parses" "1" "$PARSED"

echo 'U7: retro-complete stage -> workflow_lock=done (success anchor)'
JSON=$("$HELPER" "$TEST_SLUG" "retro-complete" 2>/dev/null | extract_json)
assert_eq "workflow_lock=done" "done" "$(echo "$JSON" | jq -r '.workflow_lock')"

echo "U8: escalation rows surface in pending_escalations"
cat >> "$SUP_LOG" <<EOF
{"ts":"2026-05-19T22:06:00Z","event":"escalation","slug":"$TEST_SLUG","call_site":"push-ack","reason":"hard-gate"}
EOF
JSON=$("$HELPER" "$TEST_SLUG" "ship" 2>/dev/null | extract_json)
ESC_COUNT=$(echo "$JSON" | jq -r '.pending_escalations | length')
ESC_FIRST=$(echo "$JSON" | jq -r '.pending_escalations[0]')
assert_eq "pending_escalations has 1" "1" "$ESC_COUNT"
assert_eq "escalation is push-ack" "push-ack" "$ESC_FIRST"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
