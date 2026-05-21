#!/bin/bash
# Tests for plan-w-team-fleet-query.sh
# Usage: bash .claude/scripts/plan-w-team-fleet-query.test.sh
# Exits 0 on all tests pass, 1 on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QUERY="$SCRIPT_DIR/plan-w-team-fleet-query.sh"
STATE_DIR="$PROJECT_ROOT/.claude/state"

TEST_SLUG="fleet-query-test-$$"
FLEET_FILE="$STATE_DIR/plan-w-team-fleet-${TEST_SLUG}.jsonl"
INTENT_FILE="$STATE_DIR/plan-w-team-fleet-intent-${TEST_SLUG}.jsonl"
TASKS_DIR_BACKUP=""

PASS=0
FAIL=0

cleanup() {
    rm -f "$FLEET_FILE" "$INTENT_FILE"
    if [ -n "$TASKS_DIR_BACKUP" ] && [ -d "$TASKS_DIR_BACKUP" ]; then
        rm -rf "$TASKS_DIR_BACKUP/tasks-test-$$"
    fi
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

ISOLATED_LIST="tasks-isolated-$$"
# Override CLAUDE_PROJECT_DIR so the script reads from $STATE_DIR (where the test
# writes fixtures), not from an inherited parent-session value pointing elsewhere.
run() { CLAUDE_PROJECT_DIR="$PROJECT_ROOT" CLAUDE_CODE_TASK_LIST_ID="$ISOLATED_LIST" "$QUERY" "$@" 2>/dev/null; }

echo "U1: missing file → empty arrays / zero counts"
cleanup
assert_eq "summary missing"   "0" "$(run summary "$TEST_SLUG" | jq -r '.spawned')"
assert_eq "running missing"   "0" "$(run running "$TEST_SLUG" | jq 'length')"
assert_eq "completed missing" "0" "$(run completed "$TEST_SLUG" | jq 'length')"
assert_eq "next-spawnable missing" "[]" "$(run next-spawnable "$TEST_SLUG")"

echo "U2: empty file → empty arrays"
mkdir -p "$STATE_DIR"
: > "$FLEET_FILE"
assert_eq "summary empty"  "0" "$(run summary "$TEST_SLUG" | jq -r '.spawned')"
assert_eq "running empty"  "0" "$(run running "$TEST_SLUG" | jq 'length')"

echo "U3: corrupt row skipped with stderr warning"
cat > "$FLEET_FILE" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"spawn","slug":"$TEST_SLUG","agent_id":"AGT-1","agent_type":"builder","cwd":"/r"}
this is not json
{"ts":"2026-05-19T22:00:01Z","event":"spawn","slug":"$TEST_SLUG","agent_id":"AGT-2","agent_type":"builder","cwd":"/r"}
EOF
STDERR=$(CLAUDE_PROJECT_DIR="$PROJECT_ROOT" "$QUERY" summary "$TEST_SLUG" 2>&1 >/dev/null)
assert_eq "corrupt warn present" "1" "$(echo "$STDERR" | grep -c 'corrupt' || true)"
assert_eq "corrupt rows still parsed" "2" "$(run summary "$TEST_SLUG" | jq -r '.spawned')"

echo "U4: max_concurrent computed correctly"
cat > "$FLEET_FILE" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"spawn","slug":"$TEST_SLUG","agent_id":"AGT-1","agent_type":"builder","cwd":"/r"}
{"ts":"2026-05-19T22:00:01Z","event":"spawn","slug":"$TEST_SLUG","agent_id":"AGT-2","agent_type":"builder","cwd":"/r"}
{"ts":"2026-05-19T22:00:02Z","event":"spawn","slug":"$TEST_SLUG","agent_id":"AGT-3","agent_type":"builder","cwd":"/r"}
{"ts":"2026-05-19T22:05:00Z","event":"complete","slug":"$TEST_SLUG","agent_id":"AGT-1","last_msg":"done"}
{"ts":"2026-05-19T22:06:00Z","event":"complete","slug":"$TEST_SLUG","agent_id":"AGT-2","last_msg":"done"}
{"ts":"2026-05-19T22:07:00Z","event":"complete","slug":"$TEST_SLUG","agent_id":"AGT-3","last_msg":"done"}
EOF
assert_eq "max_concurrent=3" "3" "$(run summary "$TEST_SLUG" | jq -r '.max_concurrent')"
assert_eq "running=0 after all complete" "0" "$(run running "$TEST_SLUG" | jq 'length')"

echo "U5: kill switch returns empty without reading files"
cat > "$FLEET_FILE" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"spawn","slug":"$TEST_SLUG","agent_id":"AGT-1","agent_type":"builder","cwd":"/r"}
EOF
assert_eq "kill switch summary" "0" "$(PLAN_W_TEAM_FLEET_DISABLE=1 run summary "$TEST_SLUG" | jq -r '.spawned')"
assert_eq "kill switch running"  "[]" "$(PLAN_W_TEAM_FLEET_DISABLE=1 run running "$TEST_SLUG")"
assert_eq "kill switch next"     "[]" "$(PLAN_W_TEAM_FLEET_DISABLE=1 run next-spawnable "$TEST_SLUG")"

echo "U6: spawn without complete → running, with task_id via sidecar"
cat > "$FLEET_FILE" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"spawn","slug":"$TEST_SLUG","agent_id":"AGT-X","agent_type":"builder","cwd":"/r"}
EOF
cat > "$INTENT_FILE" <<EOF
{"ts":"2026-05-19T22:00:00Z","agent_id":"AGT-X","task_id":"42","blocks":[]}
EOF
assert_eq "running surfaces task_id" "42" "$(run running "$TEST_SLUG" | jq -r '.[0].task_id')"

echo "U7: error event counted as failed, not running"
cat > "$FLEET_FILE" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"spawn","slug":"$TEST_SLUG","agent_id":"AGT-Y","agent_type":"builder","cwd":"/r"}
{"ts":"2026-05-19T22:00:01Z","event":"error","slug":"$TEST_SLUG","reason":"missing agent_id"}
EOF
SUM=$(run summary "$TEST_SLUG")
assert_eq "spawned=1"   "1" "$(echo "$SUM" | jq -r '.spawned')"
assert_eq "failed=1"    "1" "$(echo "$SUM" | jq -r '.failed')"
assert_eq "running=0"   "0" "$(echo "$SUM" | jq -r '.running')"

echo "U8: next-spawnable respects task store deps (dynamic test fixture)"
TASKS_TEST_DIR="$HOME/.claude/tasks/tasks-test-$$"
TASKS_DIR_BACKUP="$HOME/.claude/tasks"
mkdir -p "$TASKS_TEST_DIR"
cat > "$TASKS_TEST_DIR/100.json" <<EOF
{"id":"100","subject":"root","status":"pending","blockedBy":[],"blocks":["101"]}
EOF
cat > "$TASKS_TEST_DIR/101.json" <<EOF
{"id":"101","subject":"child","status":"pending","blockedBy":["100"],"blocks":[]}
EOF
: > "$FLEET_FILE"; : > "$INTENT_FILE"
RESULT=$(CLAUDE_CODE_TASK_LIST_ID="tasks-test-$$" "$QUERY" next-spawnable "$TEST_SLUG" 2>/dev/null)
assert_eq "only root (100) spawnable" "100" "$(echo "$RESULT" | jq -r '.[0]')"
assert_eq "only one task in list" "1" "$(echo "$RESULT" | jq 'length')"

# Mark 100 completed in store; 101 should now be spawnable
cat > "$TASKS_TEST_DIR/100.json" <<EOF
{"id":"100","subject":"root","status":"completed","blockedBy":[],"blocks":["101"]}
EOF
RESULT=$(CLAUDE_CODE_TASK_LIST_ID="tasks-test-$$" "$QUERY" next-spawnable "$TEST_SLUG" 2>/dev/null)
assert_eq "after 100 completed, 101 spawnable" "101" "$(echo "$RESULT" | jq -r '.[0]')"

rm -rf "$TASKS_TEST_DIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
