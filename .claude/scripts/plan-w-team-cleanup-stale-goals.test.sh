#!/usr/bin/env bash
# Tests for plan-w-team-cleanup-stale-goals.sh
#
# Coverage:
#   T1  removes SUCCESS-terminal file
#   T2  removes USER_ESCALATION_HALT, LOW_CONFIDENCE_STREAK, DEAD
#   T3  keeps pending (terminal_state=null) file
#   T4  keeps corrupt JSON file
#   T5  --dry-run does NOT delete
#   T6  missing state dir → exit 0
#   T7  empty state dir → exit 0
#   T8  re-run is idempotent (second run reports 0 removed)

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/plan-w-team-cleanup-stale-goals.sh"

PASS=0
FAIL=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

make_tmp() {
    local d
    d=$(mktemp -d)
    mkdir -p "$d/.claude/state"
    echo "$d/.claude/state"
}

write_goal() {
    local path="$1" slug="$2" terminal="$3"
    if [ "$terminal" = "null" ]; then
        cat > "$path" <<EOF
{"slug":"$slug","started_at":"2026-05-21T00:00:00Z","terminal_state":null,"terminal_reason":null}
EOF
    else
        cat > "$path" <<EOF
{"slug":"$slug","started_at":"2026-05-21T00:00:00Z","terminated_at":"2026-05-21T01:00:00Z","terminal_state":"$terminal","terminal_reason":"test"}
EOF
    fi
}

# ─── T1 — removes SUCCESS-terminal file ──────────────────────────────────────
echo "T1: removes SUCCESS-terminal file"
D=$(make_tmp)
write_goal "$D/plan-w-team-goal-foo.json" "foo" "SUCCESS"
OUT=$("$HELPER" --state-dir "$D" --quiet 2>&1)
[ -f "$D/plan-w-team-goal-foo.json" ] && EXISTS=1 || EXISTS=0
assert "SUCCESS file removed" "0" "$EXISTS"
rm -rf "$(dirname "$(dirname "$D")")"

# ─── T2 — removes other terminal states ──────────────────────────────────────
echo "T2: removes USER_ESCALATION_HALT, LOW_CONFIDENCE_STREAK, DEAD"
D=$(make_tmp)
write_goal "$D/plan-w-team-goal-halt.json" "halt" "USER_ESCALATION_HALT"
write_goal "$D/plan-w-team-goal-low.json"  "low"  "LOW_CONFIDENCE_STREAK"
write_goal "$D/plan-w-team-goal-dead.json" "dead" "DEAD"
"$HELPER" --state-dir "$D" --quiet >/dev/null 2>&1
COUNT=$(ls "$D"/plan-w-team-goal-*.json 2>/dev/null | wc -l | tr -d ' ')
assert "all three terminal states removed" "0" "$COUNT"
rm -rf "$(dirname "$(dirname "$D")")"

# ─── T3 — keeps pending file ─────────────────────────────────────────────────
echo "T3: keeps pending (terminal_state=null)"
D=$(make_tmp)
write_goal "$D/plan-w-team-goal-pending.json" "pending" "null"
"$HELPER" --state-dir "$D" --quiet >/dev/null 2>&1
[ -f "$D/plan-w-team-goal-pending.json" ] && EXISTS=1 || EXISTS=0
assert "pending file kept" "1" "$EXISTS"
rm -rf "$(dirname "$(dirname "$D")")"

# ─── T4 — keeps corrupt JSON ─────────────────────────────────────────────────
echo "T4: keeps corrupt JSON file"
D=$(make_tmp)
echo "{not valid json" > "$D/plan-w-team-goal-corrupt.json"
"$HELPER" --state-dir "$D" --quiet >/dev/null 2>&1
[ -f "$D/plan-w-team-goal-corrupt.json" ] && EXISTS=1 || EXISTS=0
assert "corrupt JSON kept" "1" "$EXISTS"
rm -rf "$(dirname "$(dirname "$D")")"

# ─── T5 — --dry-run does NOT delete ──────────────────────────────────────────
echo "T5: --dry-run does NOT delete"
D=$(make_tmp)
write_goal "$D/plan-w-team-goal-dry.json" "dry" "SUCCESS"
"$HELPER" --state-dir "$D" --dry-run --quiet >/dev/null 2>&1
[ -f "$D/plan-w-team-goal-dry.json" ] && EXISTS=1 || EXISTS=0
assert "dry-run kept file" "1" "$EXISTS"
rm -rf "$(dirname "$(dirname "$D")")"

# ─── T6 — missing state dir → exit 0 ─────────────────────────────────────────
echo "T6: missing state dir"
RC=0
"$HELPER" --state-dir "/tmp/does-not-exist-$$" --quiet >/dev/null 2>&1 || RC=$?
assert "missing dir exit code" "0" "$RC"

# ─── T7 — empty state dir → exit 0 ───────────────────────────────────────────
echo "T7: empty state dir"
D=$(make_tmp)
RC=0
"$HELPER" --state-dir "$D" --quiet >/dev/null 2>&1 || RC=$?
assert "empty dir exit code" "0" "$RC"
rm -rf "$(dirname "$(dirname "$D")")"

# ─── T8 — idempotent re-run ──────────────────────────────────────────────────
echo "T8: idempotent re-run"
D=$(make_tmp)
write_goal "$D/plan-w-team-goal-once.json" "once" "SUCCESS"
"$HELPER" --state-dir "$D" --quiet >/dev/null 2>&1
RC=0
"$HELPER" --state-dir "$D" --quiet >/dev/null 2>&1 || RC=$?
assert "second run exit code" "0" "$RC"
rm -rf "$(dirname "$(dirname "$D")")"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
