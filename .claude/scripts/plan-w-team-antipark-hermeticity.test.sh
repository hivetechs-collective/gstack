#!/bin/bash
# Tests for the SLUG-SCOPED anti-park progress read in
# plan-w-team-goal-evaluator.sh (__antipark_state). 2026-06-07 hermeticity fix.
# Usage: bash .claude/scripts/plan-w-team-antipark-hermeticity.test.sh
#
# The defect this guards: __antipark_state used to read a GLOBAL, non-slug-keyed
# supervisor-progress.json, so a stale/foreign run's snapshot drove the CURRENT
# run's Stop decision (a stale May-28 file with verdict STALLED/backlog 9 made
# goal-evaluator U18 return null — a false anti-park block). The fix slug-keys the
# snapshot and adds foreign-slug + stale guards (all fail-open).
#
# This test plants exactly that contamination — a stray GLOBAL file, a FOREIGN-slug
# file, and a STALE same-slug file — in the REAL .claude/state/ and asserts the
# current run is UNAFFECTED. It is the concrete regression for the brief's
# headline: "the full suite must pass even with a stray supervisor-progress.json
# present." bash 3.2 compatible.

set -u
# Scrub leaked worker kill-switches (see project_pwt_worker_disable_env_leak).
unset PLAN_W_TEAM_DISABLE_PROMPT_ROUTE PLAN_W_TEAM_DISABLE_GOAL \
      PLAN_W_TEAM_DISABLE_ANTIPARK PLAN_W_TEAM_SUPERVISOR_SESSION 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_ROOT/.claude/hooks/plan-w-team-goal-evaluator.sh"
STATE_DIR="$PROJECT_ROOT/.claude/state"

TEST_SLUG="antipark-herm-$$"
OTHER_SLUG="someother-run-$$"
GOAL_FILE="$STATE_DIR/plan-w-team-goal-${TEST_SLUG}.json"
GLOBAL_FILE="$STATE_DIR/supervisor-progress.json"             # the stray (no slug)
FOREIGN_FILE="$STATE_DIR/supervisor-progress-${OTHER_SLUG}.json"
SELF_FILE="$STATE_DIR/supervisor-progress-${TEST_SLUG}.json"  # current run's own
TRANSCRIPT="/tmp/antipark-herm-transcript-$$.jsonl"
QUARANTINE_DIR="/tmp/antipark-herm-quarantine-$$"
GLOBAL_BAK="$STATE_DIR/.supervisor-progress.json.herm-bak-$$"

PASS=0
FAIL=0

# Isolation: move OTHER active goal files aside; back up any real global file so a
# developer's live supervisor-progress.json is untouched after the run.
mkdir -p "$QUARANTINE_DIR"
shopt -s nullglob
for f in "$STATE_DIR"/plan-w-team-goal-*.json; do
    base=$(basename "$f")
    [ "$base" != "plan-w-team-goal-${TEST_SLUG}.json" ] && mv "$f" "$QUARANTINE_DIR/$base"
done
shopt -u nullglob
[ -f "$GLOBAL_FILE" ] && mv "$GLOBAL_FILE" "$GLOBAL_BAK"

final_cleanup() {
    rm -f "$GOAL_FILE" "$TRANSCRIPT" "$GLOBAL_FILE" "$FOREIGN_FILE" "$SELF_FILE"
    [ -f "$GLOBAL_BAK" ] && mv "$GLOBAL_BAK" "$GLOBAL_FILE"
    shopt -s nullglob
    for f in "$QUARANTINE_DIR"/*.json; do mv "$f" "$STATE_DIR/$(basename "$f")"; done
    shopt -u nullglob
    rmdir "$QUARANTINE_DIR" 2>/dev/null || true
}
trap final_cleanup EXIT

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS + 1))
    else echo "  ✗ $name"; echo "    expected: $expected"; echo "    actual:   $actual"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in *"$needle"*) echo "  ✓ $name"; PASS=$((PASS + 1)) ;;
        *) echo "  ✗ $name"; echo "    expected substring: $needle"; echo "    actual: $hay"; FAIL=$((FAIL + 1)) ;; esac
}

write_goal_empty_ac() {
    cat > "$GOAL_FILE" <<EOF
{"slug":"${TEST_SLUG}","started_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","terminal_state":null,"terminal_reason":null,"feature_specific_done_criteria":[]}
EOF
}
write_transcript_success() {
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"```status\\n{\\"slug\\":\\"%s\\",\\"stage\\":\\"retro-complete\\",\\"workflow_lock\\":\\"done\\"}\\n```"}]}}\n' "$TEST_SLUG" > "$TRANSCRIPT"
}
write_transcript_empty() { : > "$TRANSCRIPT"; }
# $1=file $2=slug $3=ts $4=verdict $5=backlog
write_progress_file() {
    cat > "$1" <<EOF
{"ts":"${3}","slug":"${2}","mainCommits":0,"acsPassed":0,"acsTotal":${5},"backlog":${5},"backlogKnown":1,"openPRs":0,"inflight":0,"stallStreak":9,"verdict":"${4}"}
EOF
}
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OLD="2020-01-01T00:00:00Z"   # far older than PWT_ANTIPARK_MAX_AGE_S

terminal_state() { jq -r '.terminal_state // "null"' "$GOAL_FILE" 2>/dev/null; }
run_plain()      { echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null; }
run_supervisor() { echo "{\"transcript_path\":\"$TRANSCRIPT\",\"session_id\":\"\"}" | PLAN_W_TEAM_SUPERVISOR_SESSION=1 "$HOOK" 2>/dev/null; }

echo "════════════════════════════════════════"
echo "  Anti-park slug-scope hermeticity tests"
echo "════════════════════════════════════════"

# ── AC1: stray GLOBAL + FOREIGN-slug snapshots are inert for the current run ───
echo "AC1: stray global supervisor-progress.json + foreign-slug file do NOT block current run"
write_goal_empty_ac
write_transcript_success
write_progress_file "$GLOBAL_FILE"  ""           "$NOW" "STALL-ALERT" 9   # stray global (May-28 shape)
write_progress_file "$FOREIGN_FILE" "$OTHER_SLUG" "$NOW" "STALL-ALERT" 9   # foreign slug
rm -f "$SELF_FILE"                                                          # no own snapshot
OUT=$(run_plain)
assert_eq "empty-AC SUCCESS fires (stray global + foreign ignored)" "SUCCESS" "$(terminal_state)"

# ── AC4: the same stray global present must NOT make the suite red ─────────────
# (Identical setup but asserting the supervisor yield path is also unaffected.)
echo "AC4: supervisor yields freely with only a stray global/foreign present (fail-open)"
write_goal_empty_ac
write_transcript_empty
OUT=$(run_supervisor)
assert_eq "supervisor yields (no anti-park block from foreign/global)" "" "$OUT"

# ── AC2: a STALE same-slug snapshot is ignored (fail-open) ─────────────────────
echo "AC2: stale same-slug STALL-ALERT is ignored (older than max-age → no block)"
write_goal_empty_ac
write_transcript_empty
rm -f "$GLOBAL_FILE" "$FOREIGN_FILE"
write_progress_file "$SELF_FILE" "$TEST_SLUG" "$OLD" "STALL-ALERT" 9   # stale same-slug
OUT=$(run_supervisor)
assert_eq "stale same-slug ignored → supervisor yields" "" "$OUT"

echo "AC2-stale: empty-AC SUCCESS still fires when only a stale same-slug snapshot exists"
write_goal_empty_ac
write_transcript_success
OUT=$(run_plain)
assert_eq "stale snapshot does not withhold SUCCESS" "SUCCESS" "$(terminal_state)"

# ── AC2-control: a FRESH same-slug STALL-ALERT DOES engage the gate ────────────
echo "AC2-control: fresh same-slug STALL-ALERT engages anti-park (proves the guard is not over-broad)"
write_goal_empty_ac
write_transcript_empty
write_progress_file "$SELF_FILE" "$TEST_SLUG" "$NOW" "STALL-ALERT" 9   # fresh same-slug
OUT=$(run_supervisor)
assert_contains "fresh same-slug → anti-park block" '"decision": "block"' "$OUT"
assert_contains "block cites ANTI-PARK" "ANTI-PARK" "$OUT"

echo "AC2-control-empty-ac: fresh same-slug STALL-ALERT withholds empty-AC SUCCESS"
write_goal_empty_ac
write_transcript_success
OUT=$(run_plain)
assert_eq "fresh same-slug backlog>0 withholds SUCCESS" "null" "$(terminal_state)"

# ── Kill switch still wins over the slug-scoped path ──────────────────────────
echo "AC-kill: PLAN_W_TEAM_DISABLE_ANTIPARK=1 → fresh same-slug STALL-ALERT ignored"
write_goal_empty_ac
write_transcript_empty
write_progress_file "$SELF_FILE" "$TEST_SLUG" "$NOW" "STALL-ALERT" 9
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\",\"session_id\":\"\"}" \
    | PLAN_W_TEAM_SUPERVISOR_SESSION=1 PLAN_W_TEAM_DISABLE_ANTIPARK=1 "$HOOK" 2>/dev/null)
assert_eq "kill switch yields even on fresh STALL-ALERT" "" "$OUT"

echo "════════════════════════════════════════"
echo "  Pass: $PASS  Fail: $FAIL"
echo "════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
