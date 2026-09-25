#!/usr/bin/env bash
# Tests for plan-w-team-fleet-writer.sh (SubagentStart/SubagentStop hook)
#
# Strategy: sandbox CLAUDE_PROJECT_DIR with a mock .claude/state/ containing
# 0/1/2 plan-w-team-workflow-*.lock dirs. Pipe representative hook payloads
# into the REAL writer and assert the emitted JSONL rows (event/slug,
# missing-agent_id error row, positional-arg fallback, jq-absent branch);
# then feed the writer's actual output through fleet-query.sh and assert the
# summary/running reads parse it — the true writer→reader contract that
# fleet-query.test.sh (which writes its own fixtures) cannot see.
#
# Review r3 (L3): a subagent is credited to a run only when the hook input's
# `session_id` is the lock owner's `session=` and the lock is held (not released,
# owner pid present with its recorded start). make_lock therefore builds a lock held
# by session S-LEAD (this shell's pid and start time), and the payloads carry that
# session; legacy_lock builds the bare pre-row-191 dir, which is never credited.

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/plan-w-team-fleet-writer.sh"
QUERY="$(cd "$(dirname "$0")/../../scripts" && pwd)/plan-w-team-fleet-query.sh"
[ -x "$HOOK" ] || { echo "FAIL: hook not executable: $HOOK"; exit 1; }
[ -x "$QUERY" ] || { echo "FAIL: reader not executable: $QUERY"; exit 1; }

# Worker sessions may export the fleet kill switch; scrub so each test
# controls it explicitly (see project_pwt_worker_disable_env_leak).
unset PLAN_W_TEAM_FLEET_DISABLE

PASS=0
FAIL=0
FAIL_NAMES=()

setup_sandbox() {
    SANDBOX=$(mktemp -d -t pwt-fleet-writer-test.XXXXXX)
    mkdir -p "$SANDBOX/.claude/state"
    export CLAUDE_PROJECT_DIR="$SANDBOX"
}

teardown_sandbox() {
    [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
    unset CLAUDE_PROJECT_DIR
}

# This shell's start time, in the pre-flight's form (UTC, C locale, single spaces).
MYSTART=$(TZ=UTC LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')

legacy_lock() { # $1=slug → a bare lock dir with no owner record (pre-row-191)
    mkdir -p "$SANDBOX/.claude/state/plan-w-team-workflow-${1}.lock"
}

make_lock() { # $1=slug [$2=session, default S-LEAD] → a lock held by that session
    legacy_lock "$1"
    printf 'session=%s\npid=%s\nstart=%s\nkind=claude\nheartbeat=1\n' "${2-S-LEAD}" "$$" "$MYSTART" \
        > "$SANDBOX/.claude/state/plan-w-team-workflow-${1}.lock/owner"
    printf 'active\n' > "$SANDBOX/.claude/state/plan-w-team-workflow-${1}.lock/state"
}

fleet_file() {
    echo "$SANDBOX/.claude/state/plan-w-team-fleet-${1}.jsonl"
}

run_hook() {
    # $1 = stdin payload; remaining args pass through (positional fallback)
    local payload="$1"
    shift
    printf '%s' "$payload" | ${HOOK_BASH:-/bin/bash} "$HOOK" "$@" 2>/dev/null
}

ok()  { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); FAIL_NAMES+=("$1"); printf "  \033[31m✗\033[0m %s\n" "$1"; }

echo "Testing plan-w-team-fleet-writer.sh"
echo

# ─── 1. SubagentStart + single lock → spawn row with derived slug ────────────
setup_sandbox
make_lock "run-a"
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-1","agent_type":"builder","cwd":"/repo"}'
EXIT=$?
ROW=$(cat "$(fleet_file run-a)" 2>/dev/null)
if [ "$EXIT" = "0" ] && echo "$ROW" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['event'] == 'spawn', 'event'
assert d['slug'] == 'run-a', 'slug'
assert d['agent_id'] == 'AGT-1', 'agent_id'
assert d['agent_type'] == 'builder', 'agent_type'
assert d['cwd'] == '/repo', 'cwd'
assert d['ts'], 'ts'
" 2>/dev/null; then
    ok "T1: SubagentStart → spawn row with slug from single lock"
else
    bad "T1: SubagentStart spawn row"
    printf "      exit=%s row: %s\n" "$EXIT" "$ROW"
fi
teardown_sandbox

# ─── 2. SubagentStop → complete row, last_msg truncated to 100 chars ─────────
setup_sandbox
make_lock "run-a"
LONG_MSG=$(python3 -c "print('m' * 150)")
run_hook "{\"session_id\":\"S-LEAD\",\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"AGT-1\",\"last_assistant_message\":\"$LONG_MSG\"}"
EXIT=$?
ROW=$(cat "$(fleet_file run-a)" 2>/dev/null)
if [ "$EXIT" = "0" ] && echo "$ROW" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['event'] == 'complete', 'event'
assert d['slug'] == 'run-a', 'slug'
assert d['agent_id'] == 'AGT-1', 'agent_id'
assert len(d['last_msg']) <= 100, 'last_msg not truncated'
" 2>/dev/null; then
    ok "T2: SubagentStop → complete row, last_msg truncated"
else
    bad "T2: SubagentStop complete row"
    printf "      exit=%s row: %s\n" "$EXIT" "$ROW"
fi
teardown_sandbox

# ─── 3. Zero workflow locks → exit 0, no fleet file ──────────────────────────
setup_sandbox
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-1"}'
EXIT=$?
if [ "$EXIT" = "0" ] && ! ls "$SANDBOX/.claude/state/"plan-w-team-fleet-*.jsonl >/dev/null 2>&1; then
    ok "T3: no active lock → silent no-op (not a /plan-w-team spawn)"
else
    bad "T3: no active lock no-op"
fi
teardown_sandbox

# ─── 4. Two locks → newest wins + stderr WARN ────────────────────────────────
setup_sandbox
make_lock "old-run"
make_lock "new-run"
touch -t 202601010000 "$SANDBOX/.claude/state/plan-w-team-workflow-old-run.lock"
ERR=$(printf '%s' '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-2","agent_type":"builder","cwd":"/r"}' \
    | ${HOOK_BASH:-/bin/bash} "$HOOK" 2>&1 >/dev/null)
ROW=$(cat "$(fleet_file new-run)" 2>/dev/null)
if [ ! -f "$(fleet_file old-run)" ] && echo "$ROW" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['slug'] == 'new-run', 'slug'
assert d['agent_id'] == 'AGT-2', 'agent_id'
" 2>/dev/null && echo "$ERR" | grep -q "2 active workflow locks"; then
    ok "T4: two locks → newest slug wins, WARN on stderr"
else
    bad "T4: two locks newest wins"
    printf "      stderr: %s row: %s\n" "$ERR" "$ROW"
fi
teardown_sandbox

# ─── 5. Missing agent_id → error row, exit 0 ─────────────────────────────────
setup_sandbox
make_lock "run-a"
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_type":"builder"}'
EXIT=$?
ROW=$(cat "$(fleet_file run-a)" 2>/dev/null)
if [ "$EXIT" = "0" ] && echo "$ROW" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['event'] == 'error', 'event'
assert d['slug'] == 'run-a', 'slug'
assert d['reason'] == 'missing agent_id in SubagentStart payload', 'reason'
" 2>/dev/null; then
    ok "T5: missing agent_id → error row with reason"
else
    bad "T5: missing agent_id error row"
    printf "      exit=%s row: %s\n" "$EXIT" "$ROW"
fi
teardown_sandbox

# ─── 6. Positional-arg fallback (no hook_event_name) ─────────────────────────
setup_sandbox
make_lock "run-a"
run_hook '{"session_id":"S-LEAD","agent_id":"AGT-P1"}' start
run_hook '{"session_id":"S-LEAD","agent_id":"AGT-P1"}' stop
if python3 -c "
import json
rows = [json.loads(l) for l in open('$(fleet_file run-a)') if l.strip()]
assert len(rows) == 2, 'row count'
assert rows[0]['event'] == 'spawn', 'start arg'
assert rows[1]['event'] == 'complete', 'stop arg'
assert rows[0]['agent_id'] == rows[1]['agent_id'] == 'AGT-P1', 'agent_id'
" 2>/dev/null; then
    ok "T6: positional start/stop fallback → spawn/complete rows"
else
    bad "T6: positional-arg fallback"
    printf "      file: %s\n" "$(cat "$(fleet_file run-a)" 2>/dev/null)"
fi
teardown_sandbox

# ─── 7. Kill switch → exit 0, no write ───────────────────────────────────────
setup_sandbox
make_lock "run-a"
printf '%s' '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-1"}' \
    | PLAN_W_TEAM_FLEET_DISABLE=1 ${HOOK_BASH:-/bin/bash} "$HOOK" 2>/dev/null
EXIT=$?
if [ "$EXIT" = "0" ] && [ ! -f "$(fleet_file run-a)" ]; then
    ok "T7: PLAN_W_TEAM_FLEET_DISABLE=1 → no write, exit 0"
else
    bad "T7: kill switch"
fi
teardown_sandbox

# ─── 8. Unrelated event name → exit 0, no write ──────────────────────────────
setup_sandbox
make_lock "run-a"
run_hook '{"session_id":"S-LEAD","hook_event_name":"SessionStart","agent_id":"AGT-1"}'
EXIT=$?
if [ "$EXIT" = "0" ] && [ ! -f "$(fleet_file run-a)" ]; then
    ok "T8: non-subagent event → silent no-op"
else
    bad "T8: non-subagent event no-op"
fi
teardown_sandbox

# ─── 9. Writer→reader contract: query parses real writer output ──────────────
setup_sandbox
make_lock "contract"
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-1","agent_type":"builder","cwd":"/r"}'
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-2","agent_type":"builder","cwd":"/r"}'
sleep 1  # distinct ts so the complete sorts after the spawns in max_concurrent
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStop","agent_id":"AGT-1","last_assistant_message":"done"}'
SUM=$("$QUERY" summary contract 2>/dev/null)
RUN=$("$QUERY" running contract 2>/dev/null)
if echo "$SUM" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert sorted(d.keys()) == ['completed', 'failed', 'max_concurrent', 'running', 'spawned'], 'summary keys'
assert d['spawned'] == 2 and d['completed'] == 1 and d['failed'] == 0, 'counts'
assert d['running'] == 1 and d['max_concurrent'] == 2, 'running/max_concurrent'
" 2>/dev/null; then
    ok "T9a: summary parses writer output (counts + max_concurrent)"
else
    bad "T9a: summary on writer output"
    printf "      summary: %s\n" "$SUM"
fi
if echo "$RUN" | python3 -c "
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1, 'one in-flight agent'
assert rows[0]['agent_id'] == 'AGT-2', 'agent_id'
assert sorted(rows[0].keys()) == ['agent_id', 'task_id'], 'running row keys'
assert rows[0]['task_id'] is None, 'no sidecar -> task_id null'
" 2>/dev/null; then
    ok "T9b: running parses writer output ({agent_id, task_id?} rows)"
else
    bad "T9b: running on writer output"
    printf "      running: %s\n" "$RUN"
fi
# Disabled-path summary must stay key-identical to the active shape
DSUM=$(PLAN_W_TEAM_FLEET_DISABLE=1 "$QUERY" summary contract 2>/dev/null)
if [ "$(echo "$SUM" | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin).keys()))')" = \
     "$(echo "$DSUM" | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin).keys()))')" ]; then
    ok "T9c: kill-switch summary shape key-identical to active shape"
else
    bad "T9c: kill-switch summary shape drift"
    printf "      active: %s disabled: %s\n" "$SUM" "$DSUM"
fi
teardown_sandbox

# ─── 10. jq absent → positional fallback still writes (error row) ────────────
setup_sandbox
make_lock "nojq"
SHIM="$SANDBOX/bin"
mkdir -p "$SHIM"
for b in cat date mkdir basename ls head tr sed; do
    p=$(command -v "$b" 2>/dev/null) && ln -s "$p" "$SHIM/$b"
done
printf '%s' '{"session_id":"S-LEAD","agent_id":"AGT-NOJQ"}' \
    | env PATH="$SHIM" CLAUDE_PROJECT_DIR="$SANDBOX" /bin/bash "$HOOK" start 2>/dev/null
EXIT=$?
ROW=$(cat "$(fleet_file nojq)" 2>/dev/null)
if [ "$EXIT" = "0" ] && echo "$ROW" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['event'] == 'error', 'event'
assert d['slug'] == 'nojq', 'slug'
assert d['reason'] == 'missing agent_id in SubagentStart payload', 'reason'
" 2>/dev/null; then
    ok "T10: jq absent → exit 0, error row via positional fallback (session read without jq)"
else
    bad "T10: jq-absent branch"
    printf "      exit=%s row: %s\n" "$EXIT" "$ROW"
fi
teardown_sandbox

# ─── 11-14. Row 191: only a lock held by a live lead takes attribution ───────
# The lock now lives for the whole run and is left `released` at retro-complete, and
# its `owner` record names the lead's claude pid. A dead owner pid for these fixtures:
DEAD_OWNER=$( ( : ) & echo $! )
wait 2>/dev/null
own_lock() { # $1=slug $2=owner pid $3=state [$4=session, default S-LEAD] [$5=start]
    legacy_lock "$1"
    printf 'session=%s\npid=%s\nstart=%s\nkind=claude\nheartbeat=1\n' "${4-S-LEAD}" "$2" "${5-}" \
        > "$SANDBOX/.claude/state/plan-w-team-workflow-${1}.lock/owner"
    printf '%s\n' "$3" > "$SANDBOX/.claude/state/plan-w-team-workflow-${1}.lock/state"
}

setup_sandbox
own_lock "done-run" "$$" released
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-11","agent_type":"builder","cwd":"/r"}'
EXIT=$?
if [ "$EXIT" = "0" ] && [ ! -f "$(fleet_file done-run)" ]; then
    ok "T11: a released lock (run reached retro-complete) takes no attribution"
else
    bad "T11: released lock ignored"
fi
teardown_sandbox

setup_sandbox
own_lock "gone-run" "$DEAD_OWNER" active
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-12","agent_type":"builder","cwd":"/r"}'
EXIT=$?
if [ "$EXIT" = "0" ] && [ ! -f "$(fleet_file gone-run)" ]; then
    ok "T12: a lock whose owner pid is gone takes no attribution"
else
    bad "T12: dead-owner lock ignored"
fi
teardown_sandbox

setup_sandbox
own_lock "live-run" "$$" active
own_lock "newer-done" "$$" released
touch -t 202601010000 "$SANDBOX/.claude/state/plan-w-team-workflow-live-run.lock"
ERR=$(printf '%s' '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-13","agent_type":"builder","cwd":"/r"}' \
    | ${HOOK_BASH:-/bin/bash} "$HOOK" 2>&1 >/dev/null)
ROW=$(cat "$(fleet_file live-run)" 2>/dev/null)
if [ ! -f "$(fleet_file newer-done)" ] && ! echo "$ERR" | grep -q "active workflow locks" \
   && echo "$ROW" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['slug'] == 'live-run', 'slug'
assert d['agent_id'] == 'AGT-13', 'agent_id'
" 2>/dev/null; then
    ok "T13: an older held lock wins over a newer released one, with no multi-lock WARN"
else
    bad "T13: held lock beats newer released lock"
    printf "      stderr: %s row: %s\n" "$ERR" "$ROW"
fi
teardown_sandbox

setup_sandbox
own_lock "held-run" "$$" active
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStop","agent_id":"AGT-14","last_assistant_message":"ok"}'
EXIT=$?
ROW=$(cat "$(fleet_file held-run)" 2>/dev/null)
if [ "$EXIT" = "0" ] && echo "$ROW" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['event'] == 'complete', 'event'
assert d['slug'] == 'held-run', 'slug'
" 2>/dev/null; then
    ok "T14: a lock held by a live lead is attributed as before"
else
    bad "T14: held lock attributed"
    printf "      exit=%s row: %s\n" "$EXIT" "$ROW"
fi
teardown_sandbox

# ─── 15-22. Review r3 (L3): credit only the session that holds the lock ─────
# Another session in the same checkout (a review, an unrelated task) used to have its
# subagents logged into whatever run held a live lock.
no_fleet() { ! ls "$SANDBOX/.claude/state/"plan-w-team-fleet-*.jsonl >/dev/null 2>&1; }

setup_sandbox
make_lock "lead-run"
run_hook '{"session_id":"S-OTHER","hook_event_name":"SubagentStart","agent_id":"AGT-15","agent_type":"builder","cwd":"/r"}'
EXIT=$?
if [ "$EXIT" = "0" ] && no_fleet; then
    ok "T15: a subagent of a different session takes no attribution from a held lock"
else
    bad "T15: different session not credited"
    printf "      files: %s\n" "$(ls "$SANDBOX/.claude/state/")"
fi
teardown_sandbox

setup_sandbox
make_lock "run-sa" "S-A"
make_lock "run-sb" "S-B"
touch -t 202601010000 "$SANDBOX/.claude/state/plan-w-team-workflow-run-sa.lock"
ERR=$(printf '%s' '{"session_id":"S-A","hook_event_name":"SubagentStart","agent_id":"AGT-16","agent_type":"builder","cwd":"/r"}' \
    | ${HOOK_BASH:-/bin/bash} "$HOOK" 2>&1 >/dev/null)
ROW=$(cat "$(fleet_file run-sa)" 2>/dev/null)
if [ ! -f "$(fleet_file run-sb)" ] && ! echo "$ERR" | grep -q "active workflow locks" \
   && echo "$ROW" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['slug'] == 'run-sa', 'slug'
assert d['agent_id'] == 'AGT-16', 'agent_id'
" 2>/dev/null; then
    ok "T16: same session → its own (older) run is credited, not the newer run of another session"
else
    bad "T16: same-session run credited"
    printf "      stderr: %s row: %s\n" "$ERR" "$ROW"
fi
teardown_sandbox

setup_sandbox
legacy_lock "legacy-run"
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-17","agent_type":"builder","cwd":"/r"}'
EXIT=$?
if [ "$EXIT" = "0" ] && no_fleet; then
    ok "T17: a legacy lock (no owner record) cannot be tied to a session → no attribution"
else
    bad "T17: legacy lock not credited"
fi
teardown_sandbox

setup_sandbox
own_lock "nosid-run" "$$" active "" "$MYSTART"
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-18","agent_type":"builder","cwd":"/r"}'
run_hook '{"hook_event_name":"SubagentStart","agent_id":"AGT-18b","agent_type":"builder","cwd":"/r"}'
EXIT=$?
if [ "$EXIT" = "0" ] && no_fleet; then
    ok "T18: an owner with no session=, or an input with no session_id → no attribution"
else
    bad "T18: empty session not credited"
fi
teardown_sandbox
setup_sandbox
make_lock "lead-run"
run_hook '{"hook_event_name":"SubagentStart","agent_id":"AGT-18c","agent_type":"builder","cwd":"/r"}'
run_hook '{"session_id":"S-LEAD x","hook_event_name":"SubagentStart","agent_id":"AGT-18d","agent_type":"builder","cwd":"/r"}'
EXIT=$?
if [ "$EXIT" = "0" ] && no_fleet; then
    ok "T18b: an input with no session_id, or one that is not a session id → no attribution"
else
    bad "T18b: missing or malformed session_id not credited"
fi
teardown_sandbox

setup_sandbox
own_lock "gone-run" "$DEAD_OWNER" active "S-LEAD" "$MYSTART"
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-19","agent_type":"builder","cwd":"/r"}'
EXIT=$?
if [ "$EXIT" = "0" ] && no_fleet; then
    ok "T19: the owner session's own subagent takes no attribution once the owner pid is gone"
else
    bad "T19: dead-pid owner not credited"
fi
teardown_sandbox

setup_sandbox
own_lock "reused-run" "$$" active "S-LEAD" "Thu Jan 1 00:00:00 1970"
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-20","agent_type":"builder","cwd":"/r"}'
EXIT=$?
if [ "$EXIT" = "0" ] && no_fleet; then
    ok "T20: a reused owner pid (start= differs) is not the lead → no attribution"
else
    bad "T20: reused-pid owner not credited"
fi
teardown_sandbox

setup_sandbox
own_lock "pidzero-run" "0" active "S-LEAD"
run_hook '{"session_id":"S-OTHER","hook_event_name":"SubagentStart","agent_id":"AGT-21a","agent_type":"builder","cwd":"/r"}'
A_OK=0; no_fleet && A_OK=1
run_hook '{"session_id":"S-LEAD","hook_event_name":"SubagentStart","agent_id":"AGT-21b","agent_type":"builder","cwd":"/r"}'
ROW=$(cat "$(fleet_file pidzero-run)" 2>/dev/null)
if [ "$A_OK" = "1" ] && echo "$ROW" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['agent_id'] == 'AGT-21b', 'agent_id'
" 2>/dev/null; then
    ok "T21: an owner pid of 0 proves nothing (held, as the janitor reads it); the session decides"
else
    bad "T21: unusable owner pid decided by session"
    printf "      row: %s\n" "$ROW"
fi
teardown_sandbox

setup_sandbox
make_lock "nojq2"
SHIM="$SANDBOX/bin"
mkdir -p "$SHIM"
for b in cat date mkdir basename ls head tr sed ps; do
    p=$(command -v "$b" 2>/dev/null) && ln -s "$p" "$SHIM/$b"
done
printf '%s' '{"session_id":"S-OTHER","agent_id":"AGT-NOJQ2"}' \
    | env PATH="$SHIM" CLAUDE_PROJECT_DIR="$SANDBOX" ${HOOK_BASH:-/bin/bash} "$HOOK" start 2>/dev/null
A_OK=0; no_fleet && A_OK=1
printf '%s' '{"agent_id":"AGT-NOJQ3", "session_id" : "S-LEAD"}' \
    | env PATH="$SHIM" CLAUDE_PROJECT_DIR="$SANDBOX" ${HOOK_BASH:-/bin/bash} "$HOOK" start 2>/dev/null
ROW=$(cat "$(fleet_file nojq2)" 2>/dev/null)
if [ "$A_OK" = "1" ] && echo "$ROW" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
assert d['event'] == 'error', 'event'
assert d['slug'] == 'nojq2', 'slug'
" 2>/dev/null; then
    ok "T22: jq absent → the session is still compared (another session: nothing; the lead: its row)"
else
    bad "T22: jq-absent session match"
    printf "      A_OK=%s row: %s\n" "$A_OK" "$ROW"
fi
teardown_sandbox

# T23 — the fleet-manager doc states the rule T11-T22 pin: credit goes only to the held
# lock whose owner session= is the input's session_id, and the newest-lock WARN is left
# for one session holding several locks. The pre-fix doc said the SLUG came from any
# active lock, and that parallel runs on different slugs took the newest lock.
DOC="$(cd "$(dirname "$0")/../../commands/plan-w-team/shared" && pwd)/fleet-manager.md"
T23_WHY=""
[ -f "$DOC" ] || T23_WHY="doc missing: $DOC"
[ -n "$T23_WHY" ] || grep -qF 'whose owner `session=` is the input'"'"'s `session_id`' "$DOC" \
    || T23_WHY="Overview does not name the session match"
[ -n "$T23_WHY" ] || grep -qF 'an input with no usable `session_id`, a pre-row-191 lock with no' "$DOC" \
    || T23_WHY="the dropped cases (no session_id, no owner, empty session=) are not listed"
[ -n "$T23_WHY" ] || grep -qF 'ONE session holds several held locks' "$DOC" \
    || T23_WHY="the newest-lock WARN is not tied to one session holding several locks"
[ -n "$T23_WHY" ] || ! grep -qF 'Hook derives from active `plan-w-team-workflow-*.lock` dir' "$DOC" \
    || T23_WHY="stale: SLUG derived from any active lock"
[ -n "$T23_WHY" ] || ! grep -qF 'cross-run misattribution is rare' "$DOC" \
    || T23_WHY="stale: parallel runs on different slugs take the newest lock"
if [ -z "$T23_WHY" ]; then
    ok "T23: fleet-manager.md describes the session-matched attribution"
else
    bad "T23: fleet-manager.md out of date ($T23_WHY)"
fi

echo
echo "─────────────────────────────────────────"
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed cases:"
    for n in "${FAIL_NAMES[@]}"; do echo "  - $n"; done
    exit 1
fi
exit 0
