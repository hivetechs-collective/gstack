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

echo "T11: manifest enrichment — list mode shows live stage from the manifest"
setup_fake_root
MANIFEST_SH="$PROJECT_ROOT/.claude/scripts/pwt-manifest.sh"
SD="$FAKE_ROOT/.claude/state"
PWT_MANIFEST_STATE_DIR="$SD" bash "$MANIFEST_SH" init --slug rollup-x --run-sid 45c3dbba \
    --strategy parallel-builders --stage 3-execute >/dev/null 2>&1
PWT_MANIFEST_STATE_DIR="$SD" bash "$MANIFEST_SH" task --slug rollup-x --id T1 --status done --owner aaaa1111 >/dev/null 2>&1
OUT=$("$SCRIPT")
assert_contains "list shows slug"       "rollup-x"  "$OUT"
assert_contains "list shows live stage" "3-execute" "$OUT"
assert_not_contains "list has no JSON 'stage' field" '"stage"' "$OUT"

echo "T12: rollup mode joins manifest + fleet + tasks for one run"
# Plant a worktree-local fleet log; manifest points at the worktree.
WT="$FAKE_ROOT/.claude/worktrees/rollup-wt"
mkdir -p "$WT/.claude/state"
PWT_MANIFEST_STATE_DIR="$SD" bash "$MANIFEST_SH" set --slug rollup-x --worktree "$WT" >/dev/null 2>&1
printf '{"event":"spawn","agent_id":"a"}\n{"event":"complete","agent_id":"a","duration_s":9}\n' \
    > "$WT/.claude/state/plan-w-team-fleet-rollup-x.jsonl"
OUT=$("$SCRIPT" rollup-x)
assert_contains "rollup names the run"     "rollup-x"           "$OUT"
assert_contains "rollup shows strategy"    "parallel-builders"  "$OUT"
assert_contains "rollup shows stage"       "3-execute"          "$OUT"
assert_contains "rollup lists task T1"     "T1"                 "$OUT"
assert_contains "rollup shows builder roster" "spawned="        "$OUT"

echo "T13: rollup --json emits the joined object; unknown slug → exit 3"
JOUT=$("$SCRIPT" --json rollup-x)
assert_contains "json has manifest key" '"manifest"' "$JOUT"
assert_contains "json has fleet key"    '"fleet"'    "$JOUT"
assert_contains "json has sessions key" '"sessions"' "$JOUT"
"$SCRIPT" no-such-slug >/dev/null 2>&1
assert_eq "unknown slug → exit 3" "3" "$?"
teardown_fake_root

echo "T14: O1 — rollup corroborates lead liveness with pid; stale registry rows are counted and marked"
setup_fake_root
SD="$FAKE_ROOT/.claude/state"
WT="$FAKE_ROOT/.claude/worktrees/o1-wt"
mkdir -p "$WT/.claude/state"
PWT_MANIFEST_STATE_DIR="$SD" bash "$MANIFEST_SH" init --slug o1-run --run-sid deadbeef \
    --strategy parallel-builders --stage 3-execute >/dev/null 2>&1
PWT_MANIFEST_STATE_DIR="$SD" bash "$MANIFEST_SH" set --slug o1-run --worktree "$WT" >/dev/null 2>&1
LIVE_PID=$$
# 1 live lead (this shell) + 2 dead-pid leads → "1 lead (2 stale-registry)"
AGENTS_JSON=$(jq -n --argjson lp "$LIVE_PID" '[
  {kind:"background",  sessionId:"11111111-aaaa", status:"busy", pid:$lp},
  {kind:"background",  sessionId:"22222222-bbbb", status:"busy", pid:999998},
  {kind:"interactive", sessionId:"33333333-cccc", status:"idle", pid:999999}
]')
OUT=$(PWT_STATUS_AGENTS_OVERRIDE="$AGENTS_JSON" "$SCRIPT" o1-run 2>&1)
assert_contains "O1 counts 1 live lead, 2 stale" "1 lead (2 stale-registry)" "$OUT"
assert_contains "O1 marks a stale row" "[stale-registry]" "$OUT"
# a single live lead → no stale note
AGENTS_LIVE=$(jq -n --argjson lp "$LIVE_PID" '[{kind:"background", sessionId:"44444444-dddd", status:"busy", pid:$lp}]')
OUT2=$(PWT_STATUS_AGENTS_OVERRIDE="$AGENTS_LIVE" "$SCRIPT" o1-run 2>&1)
assert_contains "O1 one live lead prints no stale note" "1 lead, " "$OUT2"
assert_not_contains "O1 no stale-registry note when all live" "stale-registry" "$OUT2"
# C3 (Governor Contract phase 1): the lane-alive verdict line uses the ONE liveness truth via
# PWT_LANE_ALIVE_BIN; exit 2 (cannot-determine) → "unknown" (fail-closed), exit 0 → "alive".
LA2=$(mktemp -t pwt-status-la2.XXXXXX); printf '#!/bin/bash\nexit 2\n' > "$LA2"; chmod +x "$LA2"
OUT3=$(PWT_STATUS_AGENTS_OVERRIDE="$AGENTS_LIVE" PWT_LANE_ALIVE_BIN="$LA2" "$SCRIPT" o1-run 2>&1)
assert_contains "C3 pwt-status: cannot-determine (exit 2) → lane-alive unknown (fail-closed)" "lane-alive: unknown" "$OUT3"
LA0=$(mktemp -t pwt-status-la0.XXXXXX); printf '#!/bin/bash\nprintf %s "{\\"live_by_process\\":1,\\"live_by_registry\\":1}"\nexit 0\n' > "$LA0"; chmod +x "$LA0"
OUT4=$(PWT_STATUS_AGENTS_OVERRIDE="$AGENTS_LIVE" PWT_LANE_ALIVE_BIN="$LA0" "$SCRIPT" o1-run 2>&1)
assert_contains "C3 pwt-status: predicate alive (exit 0) → lane-alive alive" "lane-alive: alive" "$OUT4"
rm -f "$LA2" "$LA0"
teardown_fake_root

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
