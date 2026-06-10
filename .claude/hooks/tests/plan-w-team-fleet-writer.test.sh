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

make_lock() {
    mkdir -p "$SANDBOX/.claude/state/plan-w-team-workflow-${1}.lock"
}

fleet_file() {
    echo "$SANDBOX/.claude/state/plan-w-team-fleet-${1}.jsonl"
}

run_hook() {
    # $1 = stdin payload; remaining args pass through (positional fallback)
    local payload="$1"
    shift
    printf '%s' "$payload" | bash "$HOOK" "$@" 2>/dev/null
}

ok()  { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); FAIL_NAMES+=("$1"); printf "  \033[31m✗\033[0m %s\n" "$1"; }

echo "Testing plan-w-team-fleet-writer.sh"
echo

# ─── 1. SubagentStart + single lock → spawn row with derived slug ────────────
setup_sandbox
make_lock "run-a"
run_hook '{"hook_event_name":"SubagentStart","agent_id":"AGT-1","agent_type":"builder","cwd":"/repo"}'
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
run_hook "{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"AGT-1\",\"last_assistant_message\":\"$LONG_MSG\"}"
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
run_hook '{"hook_event_name":"SubagentStart","agent_id":"AGT-1"}'
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
ERR=$(printf '%s' '{"hook_event_name":"SubagentStart","agent_id":"AGT-2","agent_type":"builder","cwd":"/r"}' \
    | bash "$HOOK" 2>&1 >/dev/null)
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
run_hook '{"hook_event_name":"SubagentStart","agent_type":"builder"}'
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
run_hook '{"agent_id":"AGT-P1"}' start
run_hook '{"agent_id":"AGT-P1"}' stop
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
printf '%s' '{"hook_event_name":"SubagentStart","agent_id":"AGT-1"}' \
    | PLAN_W_TEAM_FLEET_DISABLE=1 bash "$HOOK" 2>/dev/null
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
run_hook '{"hook_event_name":"SessionStart","agent_id":"AGT-1"}'
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
run_hook '{"hook_event_name":"SubagentStart","agent_id":"AGT-1","agent_type":"builder","cwd":"/r"}'
run_hook '{"hook_event_name":"SubagentStart","agent_id":"AGT-2","agent_type":"builder","cwd":"/r"}'
sleep 1  # distinct ts so the complete sorts after the spawns in max_concurrent
run_hook '{"hook_event_name":"SubagentStop","agent_id":"AGT-1","last_assistant_message":"done"}'
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
printf '%s' '{"agent_id":"AGT-NOJQ"}' \
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
    ok "T10: jq absent → exit 0, error row via positional fallback"
else
    bad "T10: jq-absent branch"
    printf "      exit=%s row: %s\n" "$EXIT" "$ROW"
fi
teardown_sandbox

echo
echo "─────────────────────────────────────────"
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed cases:"
    for n in "${FAIL_NAMES[@]}"; do echo "  - $n"; done
    exit 1
fi
exit 0
