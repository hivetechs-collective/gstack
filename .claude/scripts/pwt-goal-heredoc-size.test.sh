#!/usr/bin/env bash
# Tests for pwt-goal.sh supervisor heredoc size + runtime length check.
#
# The 2026-05-20 routing-verification cascade root-caused to /goal's ~4000-char
# bootstrap ceiling. Supervisor sessions whose bootstrap exceeded the ceiling
# were silently rejected, triggering re-spawning. These tests verify:
#
#   1. The rendered SUPERVISOR_BOOTSTRAP stays below 4000 chars in normal use.
#   2. The runtime length check aborts cleanly when forced past the limit
#      (override via PWT_GOAL_SUPERVISOR_LIMIT to simulate a too-large prompt).
#
# Usage: bash .claude/scripts/pwt-goal-heredoc-size.test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/pwt-goal.sh"

SANDBOX=$(mktemp -d -t pwt-goal-size.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/.claude/state"
mkdir -p "$SANDBOX/bin"

# Fake `claude` that emits a deterministic backgrounded line. Counter so we
# can distinguish worker (call 1) from supervisor (call 2). Records each
# invocation's args for size measurement.
cat > "$SANDBOX/bin/claude" <<'FAKE'
#!/usr/bin/env bash
COUNTER_FILE="$SANDBOX_DIR/.claude/state/counter"
N=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
N=$((N + 1))
echo "$N" > "$COUNTER_FILE"

# Persist the rendered prompt (always the second positional after --bg) so
# the test can measure it.
if [ "$1" = "--bg" ]; then
    PROMPT_FILE="$SANDBOX_DIR/.claude/state/prompt-call-$N.txt"
    printf '%s' "$2" > "$PROMPT_FILE"
fi

if [ "$N" = "1" ]; then
    echo "backgrounded · 11111111"
elif [ "$N" = "2" ]; then
    echo "backgrounded · 22222222"
else
    echo "backgrounded · xx$(printf '%06d' $N)"
fi
exit 0
FAKE
chmod +x "$SANDBOX/bin/claude"

export PATH="$SANDBOX/bin:$PATH"
export SANDBOX_DIR="$SANDBOX"
unset CLAUDE_JOB_DIR
unset PLAN_W_TEAM_AUTO_APPROVE_PUSH

PASS=0
FAIL=0

note_pass() { PASS=$((PASS+1)); printf "  ✓ %s\n" "$1"; }
note_fail() { FAIL=$((FAIL+1)); printf "  ✗ %s\n" "$1"; }

# ───────────────────────────────────────────────────────────────────────────
# AC-HS1: rendered supervisor bootstrap stays below 4000 chars
# ───────────────────────────────────────────────────────────────────────────
echo "U1: rendered supervisor bootstrap is below 4000 chars"
rm -f "$SANDBOX/.claude/state/counter" "$SANDBOX"/.claude/state/prompt-call-*.txt
bash "$SCRIPT" --launch "ship the payment API" >/dev/null 2>&1

SUPERVISOR_PROMPT="$SANDBOX/.claude/state/prompt-call-2.txt"
if [ ! -f "$SUPERVISOR_PROMPT" ]; then
    note_fail "supervisor prompt file not captured at $SUPERVISOR_PROMPT"
else
    SIZE=$(wc -c < "$SUPERVISOR_PROMPT" | tr -d ' ')
    if [ "$SIZE" -lt 4000 ]; then
        note_pass "supervisor bootstrap is $SIZE chars (<4000 ceiling)"
    else
        note_fail "supervisor bootstrap is $SIZE chars (>= 4000 — exceeds /goal ceiling)"
    fi

    # Sanity: prompt must contain the required anchors (worker sid, goal,
    # terminal-state names, summary path, goal-state JSON protocol, hard rules).
    if grep -q "11111111" "$SUPERVISOR_PROMPT"; then
        note_pass "supervisor bootstrap references worker sid"
    else
        note_fail "supervisor bootstrap missing worker sid"
    fi
    if grep -q "ship the payment API" "$SUPERVISOR_PROMPT"; then
        note_pass "supervisor bootstrap embeds goal text"
    else
        note_fail "supervisor bootstrap missing goal text"
    fi
    for anchor in SUCCESS ESCALATION LOW-CONFIDENCE DEAD; do
        if grep -q "$anchor" "$SUPERVISOR_PROMPT"; then
            note_pass "terminal-state anchor '$anchor' present"
        else
            note_fail "terminal-state anchor '$anchor' missing"
        fi
    done
    if grep -q "pwt-completion-summary-" "$SUPERVISOR_PROMPT"; then
        note_pass "supervisor bootstrap references completion-summary path"
    else
        note_fail "supervisor bootstrap missing completion-summary path"
    fi
    if grep -q "plan-w-team-goal-" "$SUPERVISOR_PROMPT"; then
        note_pass "supervisor bootstrap references goal-state JSON path"
    else
        note_fail "supervisor bootstrap missing goal-state JSON reference"
    fi
    if grep -q "Hard rules" "$SUPERVISOR_PROMPT"; then
        note_pass "supervisor bootstrap retains Hard rules section"
    else
        note_fail "supervisor bootstrap missing Hard rules"
    fi
fi

# ───────────────────────────────────────────────────────────────────────────
# AC-HS2: runtime length check aborts when forced past the limit
# ───────────────────────────────────────────────────────────────────────────
echo "U2: PWT_GOAL_SUPERVISOR_LIMIT override triggers a clean abort"
rm -f "$SANDBOX/.claude/state/counter" "$SANDBOX"/.claude/state/prompt-call-*.txt

# Force a very low limit (rendered prompt is ~2800-3100 chars) so the abort
# branch must fire.
ABORT_OUT=$(PWT_GOAL_SUPERVISOR_LIMIT=100 bash "$SCRIPT" --launch "trigger the abort branch" 2>&1)
ABORT_RC=$?

if [ "$ABORT_RC" = "2" ]; then
    note_pass "abort exit code is 2 (length check)"
else
    note_fail "expected exit 2 from length check, got $ABORT_RC"
fi

if printf '%s' "$ABORT_OUT" | grep -q "FATAL: supervisor bootstrap is"; then
    note_pass "abort message contains FATAL banner"
else
    note_fail "abort message missing FATAL banner. Output: $ABORT_OUT"
fi

if printf '%s' "$ABORT_OUT" | grep -q "limit 100"; then
    note_pass "abort message reports the configured limit"
else
    note_fail "abort message did not echo the limit value"
fi

# Supervisor should NOT have been spawned (we abort before the second claude --bg).
SUP_PROMPT="$SANDBOX/.claude/state/prompt-call-2.txt"
if [ ! -f "$SUP_PROMPT" ]; then
    note_pass "supervisor was not spawned (abort fired before --bg)"
else
    note_fail "supervisor was spawned despite abort"
fi

# ───────────────────────────────────────────────────────────────────────────
# AC-HS3: default limit (no override) leaves rendered prompt under 3800
# ───────────────────────────────────────────────────────────────────────────
echo "U3: default limit (3800) is not exceeded in normal operation"
rm -f "$SANDBOX/.claude/state/counter" "$SANDBOX"/.claude/state/prompt-call-*.txt
bash "$SCRIPT" --launch "validate the default limit is safe" >/dev/null 2>&1
DEFAULT_RC=$?
DEFAULT_SUP="$SANDBOX/.claude/state/prompt-call-2.txt"

if [ "$DEFAULT_RC" = "0" ]; then
    note_pass "default-limit invocation exits 0"
else
    note_fail "default-limit invocation exited $DEFAULT_RC (expected 0)"
fi

if [ -f "$DEFAULT_SUP" ]; then
    DEFAULT_SIZE=$(wc -c < "$DEFAULT_SUP" | tr -d ' ')
    if [ "$DEFAULT_SIZE" -lt 3800 ]; then
        note_pass "default-limit prompt is $DEFAULT_SIZE chars (<3800 safety margin)"
    else
        note_fail "default-limit prompt is $DEFAULT_SIZE chars (>=3800 — too close to /goal ceiling)"
    fi
fi

echo ""
echo "════════════════════════════════════════"
echo "  Pass: $PASS  Fail: $FAIL"
echo "════════════════════════════════════════"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
