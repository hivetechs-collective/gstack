#!/usr/bin/env bash
# Tests for pwt-goal.sh supervisor heredoc size + runtime length check.
#
# The 2026-05-20 routing-verification cascade root-caused to /goal's ~4000-char
# bootstrap ceiling: a supervisor session whose bootstrap exceeded the ceiling
# was silently rejected, triggering re-spawning. The invariant this test guards
# is that the detached `--launch` supervisor bootstrap stays under that ceiling
# and that the runtime length check aborts cleanly when forced past a limit.
#
# 2026-05-25 (complexity audit): the rich supervisor PROTOCOL (worker sid,
# terminal-state anchors, completion-summary path, goal-state ref, Hard rules)
# moved OUT of the detached `--launch` supervisor bootstrap and INTO the
# route-prompt hook's `additionalContext` (the origin-chat live-supervisor
# protocol — see plan-w-team-route-prompt.sh and its tests). The detached
# `--launch` supervisor bootstrap is now intentionally minimal (~1 KB). The old
# content-sanity assertions and the arbitrary 3800-char sub-limit asserted that
# superseded architecture and were removed; cap/abort coverage for the worker
# /goal directive lives in pwt-goal-cap-enforcement.test.sh + the
# goal-cap-aborts-spawn.bats scenario. This test now guards only the two live
# invariants: the rendered bootstrap stays under the 4000 ceiling, and the
# PWT_GOAL_SUPERVISOR_LIMIT override aborts cleanly before spawning.
#
# Usage: bash .claude/scripts/pwt-goal-heredoc-size.test.sh

set -u

# Test isolation (rule 1a — isolate shared state): neutralize machine-capacity
# gates so spawn-logic assertions do not flake on a busy machine or inside a
# worker session. Mirrors pwt-goal-launch.test.sh / pwt-goal-worker-only.test.sh.
export PLAN_W_TEAM_DISABLE_FAIR_SHARE=1
export PLAN_W_TEAM_DISABLE_RAM_GATE=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/pwt-goal.sh"

SANDBOX=$(mktemp -d -t pwt-goal-size.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/.claude/state"
mkdir -p "$SANDBOX/bin"

# Fake `claude` that emits a deterministic backgrounded line. Counter so we can
# distinguish worker (call 1) from supervisor (call 2). Records each
# invocation's --bg prompt for size measurement.
cat > "$SANDBOX/bin/claude" <<'FAKE'
#!/usr/bin/env bash
COUNTER_FILE="$SANDBOX_DIR/.claude/state/counter"
N=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
N=$((N + 1))
echo "$N" > "$COUNTER_FILE"
if [ "$1" = "--bg" ]; then
    # The --bg prompt is always the LAST positional. Capture it by walking to the
    # last arg so the test stays robust to flags inserted between --bg and the
    # prompt (e.g. --fallback-model <model>, added in skill 1.6.0).
    for _prompt_arg in "$@"; do :; done
    printf '%s' "$_prompt_arg" > "$SANDBOX_DIR/.claude/state/prompt-call-$N.txt"
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
# Scrub pwt control vars that would otherwise divert pwt-goal.sh down the
# cascade-guard (exit 4) or force-spawn paths when this test runs inside a
# /plan-w-team worker session. (run.sh's Phase 2 also scrubs these; doing it
# here too keeps the test correct when invoked standalone from any session.)
unset PLAN_W_TEAM_AUTO_APPROVE_PUSH
unset PLAN_W_TEAM_DISABLE_PROMPT_ROUTE
unset PLAN_W_TEAM_FORCE_SPAWN

PASS=0
FAIL=0
note_pass() { PASS=$((PASS+1)); printf "  ✓ %s\n" "$1"; }
note_fail() { FAIL=$((FAIL+1)); printf "  ✗ %s\n" "$1"; }

# ───────────────────────────────────────────────────────────────────────────
# AC-HS1: rendered supervisor bootstrap stays below the 4000-char /goal ceiling
# ───────────────────────────────────────────────────────────────────────────
echo "U1: rendered supervisor bootstrap is below the 4000-char /goal ceiling"
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
    # The detached supervisor bootstrap must still embed the user's goal text so
    # the bg supervisor knows what it is watching. (The rich protocol now lives
    # in the route-hook additionalContext, not here — see header note.)
    if grep -q "ship the payment API" "$SUPERVISOR_PROMPT"; then
        note_pass "supervisor bootstrap embeds goal text"
    else
        note_fail "supervisor bootstrap missing goal text"
    fi
fi

# ───────────────────────────────────────────────────────────────────────────
# AC-HS2: runtime length check aborts cleanly when forced past the limit
# ───────────────────────────────────────────────────────────────────────────
echo "U2: PWT_GOAL_SUPERVISOR_LIMIT override triggers a clean abort"
rm -f "$SANDBOX/.claude/state/counter" "$SANDBOX"/.claude/state/prompt-call-*.txt

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

echo ""
echo "════════════════════════════════════════"
echo "  Pass: $PASS  Fail: $FAIL"
echo "════════════════════════════════════════"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
