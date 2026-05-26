#!/usr/bin/env bash
# supervisor-progress-check.test.sh — tests for the generic step-0 supervisor self-check.
# Builds throwaway git-repo fixtures, drives ticks, asserts verdict + exit code.
# Usage: ./supervisor-progress-check.test.sh   Exit: 0 pass, 1 fail.

set -u
SCRIPT="$(cd "$(dirname "$0")" && pwd)/supervisor-progress-check.sh"
PASS=0; FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; echo "    $2"; FAIL=$((FAIL + 1)); }
ROOTS=()
cleanup() { for r in "${ROOTS[@]:-}"; do [ -n "${r:-}" ] && [ -d "$r" ] && rm -rf "$r"; done; }
trap cleanup EXIT

# Fixture repo with N ACs in a spec and M AC-PASS lines in a transcript.
newfix() { # acs_total acs_pass → echoes root
    local total="$1" pass="$2" r; r="$(mktemp -d -t spc.XXXXXX)"; ROOTS+=("$r")
    git -C "$r" init -q; git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
    echo seed > "$r/seed"; git -C "$r" add seed; git -C "$r" commit -qm seed
    mkdir -p "$r/.claude/state" "$r/.claude/worktrees"
    : > "$r/ac.md"; i=1; while [ "$i" -le "$total" ]; do echo "AC$i: criterion" >> "$r/ac.md"; i=$((i+1)); done
    : > "$r/tx.txt"; i=1; while [ "$i" -le "$pass" ]; do echo "AC$i: PASS" >> "$r/tx.txt"; i=$((i+1)); done
    echo "$r"
}
# run tick in fixture; sets global RC + STATEFILE
tick() { # root [extra-args...]
    local r="$1"; shift
    STATEFILE="$r/.claude/state/sp.json"
    ( cd "$r" && STALL_THRESHOLD=2 "$SCRIPT" --state "$STATEFILE" --spec "$r/ac.md" --transcript "$r/tx.txt" "$@" >/dev/null 2>&1 )
    RC=$?
}
verdict_of() { python3 -c "import json;print(json.load(open('$1')).get('verdict'))" 2>/dev/null; }
streak_of() { python3 -c "import json;print(json.load(open('$1')).get('stallStreak'))" 2>/dev/null; }

echo "── supervisor-progress-check tests ──"

# [1] first run = baseline PROGRESSING, exit 0
R=$(newfix 5 2); tick "$R"
[ "$(verdict_of "$STATEFILE")" = "PROGRESSING" ] && pass "first run → PROGRESSING" || fail "first run" "got $(verdict_of "$STATEFILE")"
[ "$RC" -eq 0 ] && pass "first run exit 0" || fail "first run exit" "rc=$RC"

# [2] flat tick (no new commit/AC) with backlog>0 → STALLED (streak 1), exit 0
tick "$R"
[ "$(verdict_of "$STATEFILE")" = "STALLED" ] && pass "flat tick → STALLED" || fail "flat tick" "got $(verdict_of "$STATEFILE")"
[ "$(streak_of "$STATEFILE")" = "1" ] && pass "stallStreak=1" || fail "streak" "got $(streak_of "$STATEFILE")"

# [3] second flat tick → STALL-ALERT, exit 2
tick "$R"
[ "$(verdict_of "$STATEFILE")" = "STALL-ALERT" ] && pass "2nd flat → STALL-ALERT" || fail "stall-alert" "got $(verdict_of "$STATEFILE")"
[ "$RC" -eq 2 ] && pass "STALL-ALERT exits 2 (forces action)" || fail "stall-alert exit" "rc=$RC"

# [4] a new commit moves the metric → PROGRESSING, streak resets
echo more > "$R/x"; git -C "$R" add x; git -C "$R" commit -qm more
tick "$R"
[ "$(verdict_of "$STATEFILE")" = "PROGRESSING" ] && pass "new commit → PROGRESSING (streak reset)" || fail "commit progress" "got $(verdict_of "$STATEFILE")"
[ "$(streak_of "$STATEFILE")" = "0" ] && pass "streak reset to 0" || fail "streak reset" "got $(streak_of "$STATEFILE")"

# [5] in-flight guard: agent worktree touched < 30 min → IN-FLIGHT, not a stall
mkdir -p "$R/.claude/worktrees/agent-live"
tick "$R"   # flat commit, but agent-live is fresh
[ "$(verdict_of "$STATEFILE")" = "IN-FLIGHT" ] && pass "fresh agent worktree → IN-FLIGHT" || fail "in-flight" "got $(verdict_of "$STATEFILE")"
rm -rf "$R/.claude/worktrees/agent-live"

# [6] all ACs passing → BACKLOG-CLEAR (not a stall)
R2=$(newfix 3 3); tick "$R2"        # baseline
tick "$R2"                          # flat, but backlog=0
[ "$(verdict_of "$STATEFILE")" = "BACKLOG-CLEAR" ] && pass "all ACs pass → BACKLOG-CLEAR" || fail "backlog-clear" "got $(verdict_of "$STATEFILE")"

# [7] no AC source → STALLED-UNKNOWN, never exit 2 (no false alerts)
R3="$(mktemp -d -t spc.XXXXXX)"; ROOTS+=("$R3")
git -C "$R3" init -q; git -C "$R3" config user.email t@t.t; git -C "$R3" config user.name t
echo s > "$R3/s"; git -C "$R3" add s; git -C "$R3" commit -qm s; mkdir -p "$R3/.claude/state" "$R3/.claude/worktrees"
SF="$R3/.claude/state/sp.json"
( cd "$R3" && STALL_THRESHOLD=1 "$SCRIPT" --state "$SF" >/dev/null 2>&1 )   # baseline (no --spec)
( cd "$R3" && STALL_THRESHOLD=1 "$SCRIPT" --state "$SF" >/dev/null 2>&1 ); RC=$?
[ "$(verdict_of "$SF")" = "STALLED-UNKNOWN" ] && pass "no AC source → STALLED-UNKNOWN" || fail "unknown" "got $(verdict_of "$SF")"
[ "$RC" -eq 0 ] && pass "STALLED-UNKNOWN never exits 2" || fail "unknown exit" "rc=$RC"

# [8] bash 3.2 compatibility (macOS /bin/bash) — runtime guard, not bash -n
echo "[8] runs clean under bash 3.2 (/bin/bash on macOS)"
if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
    R4=$(newfix 4 1); ERRF="$R4/err"
    ( cd "$R4" && /bin/bash "$SCRIPT" --state "$R4/.claude/state/sp.json" --spec "$R4/ac.md" --transcript "$R4/tx.txt" >/dev/null 2>"$ERRF" )
    if grep -qiE 'invalid option|declare:|unbound variable|bad substitution|syntax error' "$ERRF" 2>/dev/null; then
        fail "bash 3.2 clean" "$(cat "$ERRF")"
    else pass "bash 3.2: no bash-4 error signature"; fi
else
    echo "  ⊘ skipped (no bash 3.2 at /bin/bash)"
fi

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
