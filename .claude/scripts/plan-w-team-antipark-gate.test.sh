#!/bin/bash
# Tests for the PWT-ANTIPARK gate in plan-w-team-goal-evaluator.sh.
# Usage: bash .claude/scripts/plan-w-team-antipark-gate.test.sh
#
# Covers the four brief invariants:
#   AC1  supervisor yield is BLOCKED on STALL-ALERT + backlog>0 (anti-park).
#   AC1-SID  the SID-based supervisor yield (PWT-SUP-YIELD-SID) is ALSO anti-park
#            guarded — a non-owning mid-session origin-chat supervisor (the dominant
#            case) is blocked, not silently parked. Regression for the 2026-06-08
#            CORR-1 fix: the SID path used to exit 0 before the anti-park block.
#   AC2  empty/missing AC contract treated as not-done while backlog>0 (no SUCCESS).
#   AC3  a single blocked item does not flip the whole run terminal (stays non-terminal).
#   AC4  supervisor-progress-check.sh returns STALL-ALERT/exit 2 after N flat ticks + backlog>0.
#   AC5  kill switch (PLAN_W_TEAM_DISABLE_ANTIPARK=1) + fail-open (no/corrupt progress file).
#
# bash 3.2 compatible. Fail-open is asserted explicitly so a future change that
# made the gate hard-fail (crash / block with no signal) would turn this red.

set -u
# Scrub leaked worker kill-switches (pwt-goal --worker-only exports
# PLAN_W_TEAM_DISABLE_* into the session env; they would change hook behavior —
# e.g. PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 flips the evaluator into worker-mode
# C3 anti-spoof, withholding SUCCESS without a ship-verdict). See memory
# project_pwt_worker_disable_env_leak. Tests must run in a clean gate env.
unset PLAN_W_TEAM_DISABLE_PROMPT_ROUTE PLAN_W_TEAM_DISABLE_GOAL \
      PLAN_W_TEAM_DISABLE_ANTIPARK PLAN_W_TEAM_SUPERVISOR_SESSION 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_ROOT/.claude/hooks/plan-w-team-goal-evaluator.sh"
PROGRESS_CHECK="$PROJECT_ROOT/.claude/scripts/supervisor-progress-check.sh"
STATE_DIR="$PROJECT_ROOT/.claude/state"

TEST_SLUG="antipark-test-$$"
GOAL_FILE="$STATE_DIR/plan-w-team-goal-${TEST_SLUG}.json"
# Slug-scoped (2026-06-07 hermeticity fix): the reader __antipark_state reads ONLY
# the current run's supervisor-progress-<slug>.json, so this test owns a uniquely
# named, test-private progress file. A stray GLOBAL supervisor-progress.json in the
# real state dir can no longer contaminate this test — the slug-scope IS the
# isolation. (No global-file backup/restore needed anymore.)
PROGRESS_FILE="$STATE_DIR/supervisor-progress-${TEST_SLUG}.json"
TRANSCRIPT="/tmp/antipark-transcript-$$.jsonl"
QUARANTINE_DIR="/tmp/antipark-quarantine-$$"

PASS=0
FAIL=0

# Isolation: move OTHER active goal files + any real progress file aside.
mkdir -p "$QUARANTINE_DIR"
shopt -s nullglob
for f in "$STATE_DIR"/plan-w-team-goal-*.json; do
    base=$(basename "$f")
    [ "$base" != "plan-w-team-goal-${TEST_SLUG}.json" ] && mv "$f" "$QUARANTINE_DIR/$base"
done
shopt -u nullglob

final_cleanup() {
    rm -f "$GOAL_FILE" "$TRANSCRIPT" "$PROGRESS_FILE"
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

write_goal() {
    # $1 = feature_specific_done_criteria JSON (default [])
    local crit="${1:-[]}"
    cat > "$GOAL_FILE" <<EOF
{"slug":"${TEST_SLUG}","started_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","terminal_state":null,"terminal_reason":null,"feature_specific_done_criteria":${crit}}
EOF
}
write_progress() {
    # $1=backlogKnown $2=backlog $3=verdict $4=stallStreak
    # Slug-keyed + carries the current TEST_SLUG so the reader's foreign-slug guard
    # accepts it. ts=now so it is never stale (max-age guard).
    cat > "$PROGRESS_FILE" <<EOF
{"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","slug":"${TEST_SLUG}","mainCommits":0,"acsPassed":0,"acsTotal":${2},"backlog":${2},"backlogKnown":${1},"openPRs":0,"inflight":0,"stallStreak":${4},"verdict":"${3}"}
EOF
}
write_transcript_empty() { : > "$TRANSCRIPT"; }
write_transcript_success() {
    # generic SUCCESS anchors colocated on one line for slug
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"```status\\n{\\"slug\\":\\"%s\\",\\"stage\\":\\"retro-complete\\",\\"workflow_lock\\":\\"done\\"}\\n```"}]}}\n' "$TEST_SLUG" > "$TRANSCRIPT"
}
# Run hook as a SUPERVISOR session (env flag). No session_id → SID-yield disabled,
# so PWT-SUP-YIELD (env) is the path exercised. Returns stdout (block JSON or empty).
run_supervisor() {
    echo "{\"transcript_path\":\"$TRANSCRIPT\",\"session_id\":\"\"}" \
        | PLAN_W_TEAM_SUPERVISOR_SESSION=1 "$HOOK" 2>/dev/null
}
write_goal_sid() {
    # $1 = worker_sid recorded on the (blocking) goal; $2 = AC contract JSON (default [])
    local wsid="$1" crit="${2:-[]}"
    cat > "$GOAL_FILE" <<EOF
{"slug":"${TEST_SLUG}","started_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","terminal_state":null,"terminal_reason":null,"worker_sid":"${wsid}","feature_specific_done_criteria":${crit}}
EOF
}
# Run hook as a NON-owning SID session: a real session_id whose 8-char prefix differs
# from the goal's worker_sid → OWNS_BLOCKING=0 AND BLOCKING_GOAL_UNOWNABLE=0, so the
# PWT-SUP-YIELD-SID path decides. NOT a PLAN_W_TEAM_SUPERVISOR_SESSION env session —
# this is the mid-session origin-chat supervisor that cannot set that flag.
run_sid_session() {
    local sid="${1:-aaaaaaaa-0000-0000-0000-000000000000}"
    echo "{\"transcript_path\":\"$TRANSCRIPT\",\"session_id\":\"$sid\"}" | "$HOOK" 2>/dev/null
}
terminal_state() { jq -r '.terminal_state // "null"' "$GOAL_FILE" 2>/dev/null; }

echo "════════════════════════════════════════"
echo "  PWT-ANTIPARK gate tests"
echo "════════════════════════════════════════"

# ── AC1: supervisor yield BLOCKED on STALL-ALERT + backlog>0 ──────────────────
echo "AC1: supervisor yield blocked when STALL-ALERT + backlog>0"
write_goal '[]'
write_transcript_empty
write_progress 1 5 "STALL-ALERT" 2
OUT=$(run_supervisor)
assert_contains "emits a block (not a silent yield)" '"decision": "block"' "$OUT"
assert_contains "block reason cites ANTI-PARK" "ANTI-PARK" "$OUT"

# ── AC1-control: supervisor yields freely when PROGRESSING (not parked) ────────
echo "AC1-control: supervisor yields when verdict=PROGRESSING (backlog>0, work cooking)"
write_goal '[]'
write_transcript_empty
write_progress 1 5 "PROGRESSING" 0
OUT=$(run_supervisor)
assert_eq "yields (empty output, no anti-park block)" "" "$OUT"

# ── AC1-SID: SID-based (non-env) supervisor yield is ALSO anti-park guarded ────
# Regression for the 2026-06-08 CORR-1 fix. Before it, the PWT-SUP-YIELD-SID path
# exit-0'd for any non-owning session BEFORE the anti-park block was emitted — so a
# mid-session origin-chat supervisor (which cannot set PLAN_W_TEAM_SUPERVISOR_SESSION)
# silently parked with backlog>0, defeating PWT-ANTIPARK on its dominant path. This
# case FAILS against the pre-fix hook (yields empty) and passes once the SID-yield
# condition carries `&& [ "$ANTIPARK_BLOCK" != "1" ]`.
echo "AC1-SID: non-owning SID supervisor BLOCKED on STALL-ALERT + backlog>0 (anti-park guards the SID-yield path)"
write_goal_sid "bbbbbbbb" '[]'   # worker_sid prefix bbbbbbbb != session aaaaaaaa → non-owning, ownable
write_transcript_empty
write_progress 1 5 "STALL-ALERT" 2
OUT=$(run_sid_session)
assert_contains "SID yield emits a block (not a silent park)" '"decision": "block"' "$OUT"
assert_contains "SID-path block reason cites ANTI-PARK" "ANTI-PARK" "$OUT"

# ── AC1-SID-control: same non-owning SID session yields freely when PROGRESSING ─
# Proves the guard is inert off the anti-park path (no regression to normal SID yield).
echo "AC1-SID-control: non-owning SID supervisor yields when verdict=PROGRESSING (guard inert)"
write_goal_sid "bbbbbbbb" '[]'
write_transcript_empty
write_progress 1 5 "PROGRESSING" 0
OUT=$(run_sid_session)
assert_eq "SID yield permitted (empty output) when not parked" "" "$OUT"

# ── AC5a: kill switch disables the gate (yields again) ────────────────────────
echo "AC5a: PLAN_W_TEAM_DISABLE_ANTIPARK=1 → yield permitted even on STALL-ALERT"
write_goal '[]'
write_transcript_empty
write_progress 1 5 "STALL-ALERT" 9
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\",\"session_id\":\"\"}" \
    | PLAN_W_TEAM_SUPERVISOR_SESSION=1 PLAN_W_TEAM_DISABLE_ANTIPARK=1 "$HOOK" 2>/dev/null)
assert_eq "yields with kill switch (empty output)" "" "$OUT"

# ── AC5b: fail-open when no progress file ─────────────────────────────────────
echo "AC5b: no supervisor-progress.json → fail-open (supervisor yields as pre-fix)"
write_goal '[]'
write_transcript_empty
rm -f "$PROGRESS_FILE"
OUT=$(run_supervisor)
assert_eq "yields with no progress signal (empty output)" "" "$OUT"

# ── AC5c: fail-open on corrupt progress JSON ──────────────────────────────────
echo "AC5c: corrupt supervisor-progress.json → fail-open (no crash, supervisor yields)"
write_goal '[]'
write_transcript_empty
printf '{not valid json' > "$PROGRESS_FILE"
OUT=$(run_supervisor)
assert_eq "yields on corrupt signal (empty output)" "" "$OUT"

# ── AC2: empty AC contract + generic SUCCESS + backlog>0 → SUCCESS withheld ────
echo "AC2: empty AC contract treated as not-done while backlog>0 (SUCCESS withheld)"
write_goal '[]'
write_transcript_success
write_progress 1 3 "STALLED" 1
# Non-supervisor session (owns the goal path is moot — no worker_sid → un-ownable → BLOCK).
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
assert_eq "terminal_state stays null (SUCCESS withheld)" "null" "$(terminal_state)"
assert_contains "block cites empty-AC/PWT-ANTIPARK" "PWT-ANTIPARK" "$OUT"

# ── AC2-control: empty AC contract + generic SUCCESS + NO backlog signal → SUCCESS
echo "AC2-control: empty AC + generic SUCCESS + no progress file → SUCCESS (backward-compat T5b)"
write_goal '[]'
write_transcript_success
rm -f "$PROGRESS_FILE"
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
assert_eq "terminal_state SUCCESS (generic anchors fire, no backlog signal)" "SUCCESS" "$(terminal_state)"

# ── AC3: single blocked item (backlog>0, no hard-gate) → run stays non-terminal
echo "AC3: backlog>0 + no hard-gate + no SUCCESS anchors → non-terminal (keep building rest)"
write_goal '[]'
write_transcript_empty
write_progress 1 4 "STALLED" 1
OUT=$(echo "{\"transcript_path\":\"$TRANSCRIPT\"}" | "$HOOK" 2>/dev/null)
assert_eq "terminal_state null (one block ≠ whole-run terminal)" "null" "$(terminal_state)"
assert_contains "blocks the stop (run keeps going)" '"decision": "block"' "$OUT"

# ── AC4: supervisor-progress-check.sh → STALL-ALERT after N flat ticks ─────────
echo "AC4: N flat ticks + backlog>0 → supervisor-progress-check STALL-ALERT (exit 2)"
AC4_STATE="/tmp/antipark-progress-$$.json"
AC4_SPEC="/tmp/antipark-spec-$$.md"
AC4_TR="/tmp/antipark-actr-$$.jsonl"
rm -f "$AC4_STATE"
printf '## Acceptance Criteria\n- [ ] AC1: thing\n- [ ] AC2: other\n' > "$AC4_SPEC"
: > "$AC4_TR"   # zero AC-PASS → backlog = acsTotal(2) - 0 = 2 > 0
# Tick 1 = baseline (PROGRESSING on first run), ticks 2+ flat → STALL after threshold 2.
STALL_THRESHOLD=2 "$PROGRESS_CHECK" --state "$AC4_STATE" --spec "$AC4_SPEC" --transcript "$AC4_TR" >/dev/null 2>&1
STALL_THRESHOLD=2 "$PROGRESS_CHECK" --state "$AC4_STATE" --spec "$AC4_SPEC" --transcript "$AC4_TR" >/dev/null 2>&1
STALL_THRESHOLD=2 "$PROGRESS_CHECK" --state "$AC4_STATE" --spec "$AC4_SPEC" --transcript "$AC4_TR" >/dev/null 2>&1
AC4_RC=$?
AC4_VERDICT=$(jq -r '.verdict' "$AC4_STATE" 2>/dev/null)
assert_eq "exit 2 on STALL-ALERT" "2" "$AC4_RC"
assert_eq "verdict STALL-ALERT" "STALL-ALERT" "$AC4_VERDICT"
rm -f "$AC4_STATE" "$AC4_SPEC" "$AC4_TR"

echo "════════════════════════════════════════"
echo "  Pass: $PASS  Fail: $FAIL"
echo "════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
