#!/usr/bin/env bash
# Tests for plan-w-team-route-prompt.sh
#
# Strategy: build an isolated $CLAUDE_PROJECT_DIR with a SHIM pwt-goal.sh that
# records its invocation to a marker file instead of spawning claude --bg.
# Each case sends a JSON prompt on stdin and asserts:
#   - exit code
#   - whether the shim was invoked (marker file presence)
#   - whether stdout is valid JSON with the expected decision
#
# Run: bash .claude/hooks/tests/plan-w-team-route-prompt.test.sh
# Exit 0 if all pass, 1 if any fail.

set -u

# Enable hook fast-test mode: short polling, no completion-watcher spawn
export PLAN_W_TEAM_HOOK_TEST_MODE=1

HOOK="$(cd "$(dirname "$0")/.." && pwd)/plan-w-team-route-prompt.sh"
[ -x "$HOOK" ] || { echo "FAIL: hook not executable: $HOOK"; exit 1; }

PASS=0
FAIL=0
FAIL_NAMES=()

setup_sandbox() {
    SANDBOX=$(mktemp -d -t pwt-route-test.XXXXXX)
    mkdir -p "$SANDBOX/.claude/scripts" "$SANDBOX/.claude/state"
    cat > "$SANDBOX/.claude/scripts/pwt-goal.sh" <<'SHIM'
#!/usr/bin/env bash
# Shim: record invocation AND emit the "backgrounded · <id>" line that
# pwt-goal.sh produces in real use. Lets us test the session-ID parsing path.
echo "INVOKED: $*" > "$(dirname "$0")/../state/shim-invoked.marker"
echo "Launching: claude --bg <derived /goal>"
echo "backgrounded · deadbeef"
exit 0
SHIM
    chmod +x "$SANDBOX/.claude/scripts/pwt-goal.sh"
    export CLAUDE_PROJECT_DIR="$SANDBOX"
    unset PLAN_W_TEAM_DISABLE_PROMPT_ROUTE
}

teardown_sandbox() {
    [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
    unset CLAUDE_PROJECT_DIR
}

shim_was_invoked() {
    [ -f "$SANDBOX/.claude/state/shim-invoked.marker" ]
}

# Wait briefly for the background nohup launcher to complete (it writes the marker).
# 1.5s is plenty since the shim just touches a file.
wait_for_shim() {
    for _ in $(seq 1 30); do
        shim_was_invoked && return 0
        sleep 0.05
    done
    return 1
}

run_case() {
    local name="$1" expect_exit="$2" expect_invoke="$3" prompt_json="$4"
    setup_sandbox
    local out exit_code
    out=$(printf '%s' "$prompt_json" | bash "$HOOK" 2>/dev/null)
    exit_code=$?
    local actual_invoke="no"
    if [ "$expect_invoke" = "yes" ]; then
        wait_for_shim && actual_invoke="yes"
    else
        # give the launcher a moment in case it would have fired wrongly
        sleep 0.1
        shim_was_invoked && actual_invoke="yes"
    fi

    local ok=1
    [ "$exit_code" -ne "$expect_exit" ] && ok=0
    [ "$actual_invoke" != "$expect_invoke" ] && ok=0

    # If launch expected, output must be valid JSON with decision=block
    if [ "$expect_exit" = "2" ] && [ -n "$out" ]; then
        echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('decision')=='block'" 2>/dev/null || ok=0
    fi

    if [ "$ok" = "1" ]; then
        PASS=$((PASS+1))
        printf "  \033[32m✓\033[0m %s\n" "$name"
    else
        FAIL=$((FAIL+1))
        FAIL_NAMES+=("$name")
        printf "  \033[31m✗\033[0m %s\n" "$name"
        printf "      expected exit=%s invoke=%s\n" "$expect_exit" "$expect_invoke"
        printf "      actual   exit=%s invoke=%s\n" "$exit_code" "$actual_invoke"
        [ -n "$out" ] && printf "      stdout: %s\n" "$out"
    fi
    teardown_sandbox
}

echo "Testing plan-w-team-route-prompt.sh"
echo

# ─── Trigger at start (canonical autonomous-run pattern) ─────────────────────
run_case "trigger at start launches" 2 yes \
  '{"prompt":"use /plan-w-team to ship the payment API","session_id":"x"}'

# ─── Trigger with pleasantry prefix still fires ──────────────────────────────
run_case "trigger with 'please' prefix launches" 2 yes \
  '{"prompt":"please use /plan-w-team to fix the login bug","session_id":"x"}'

# ─── Multi-line prompt with trigger at start ─────────────────────────────────
run_case "multi-line prompt with trigger at start launches" 2 yes \
  '{"prompt":"use /plan-w-team to ship X.\nDefinition of done: tests pass","session_id":"x"}'

# ─── Trigger mid-prompt LAUNCHES (natural-language is sacred) ────────────────
# User principle: any natural phrasing of "use /plan-w-team to" routes,
# regardless of position. Lead-in content like "now lets test it," or
# "I was reviewing the docs that say to" does not block invocation.
# Opt-out via "in this session" or the sentinel/env kill switches.
run_case "trigger mid-prompt LAUNCHES (no anchor)" 2 yes \
  '{"prompt":"now lets test it, use /plan-w-team to holistically review the routing hook","session_id":"x"}'

# ─── Meta-discussion without trigger phrase does NOT launch ──────────────────
# The trigger phrase list is specific. Just mentioning /plan-w-team isn't
# enough — there must be an action phrase like "use /plan-w-team to".
run_case "meta-mention without action verb does NOT launch" 0 no \
  '{"prompt":"the /plan-w-team route hook is broken and definition of done is unclear","session_id":"x"}'

# ─── Explicit in-session opt-in suppresses launch ────────────────────────────
run_case "in-session opt-in suppresses launch" 0 no \
  '{"prompt":"use /plan-w-team to ship X in this session","session_id":"x"}'

# ─── Sentinel file kills the hook ────────────────────────────────────────────
setup_sandbox
touch "$SANDBOX/.claude/.pwt-route-disabled"
out=$(printf '%s' '{"prompt":"use /plan-w-team to ship X","session_id":"x"}' | bash "$HOOK" 2>/dev/null)
exit_code=$?
sleep 0.1
if [ "$exit_code" = "0" ] && ! shim_was_invoked; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "sentinel file disables hook"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("sentinel file disables hook")
    printf "  \033[31m✗\033[0m %s (exit=%s invoke=%s)\n" "sentinel file disables hook" "$exit_code" "$(shim_was_invoked && echo yes || echo no)"
fi
teardown_sandbox

# ─── Env var kills the hook ──────────────────────────────────────────────────
setup_sandbox
export PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1
out=$(printf '%s' '{"prompt":"use /plan-w-team to ship X","session_id":"x"}' | bash "$HOOK" 2>/dev/null)
exit_code=$?
sleep 0.1
if [ "$exit_code" = "0" ] && ! shim_was_invoked; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "env var disables hook"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("env var disables hook")
    printf "  \033[31m✗\033[0m %s (exit=%s)\n" "env var disables hook" "$exit_code"
fi
unset PLAN_W_TEAM_DISABLE_PROMPT_ROUTE
teardown_sandbox

# ─── Missing pwt-goal.sh fails open ──────────────────────────────────────────
setup_sandbox
rm -f "$SANDBOX/.claude/scripts/pwt-goal.sh"
out=$(printf '%s' '{"prompt":"use /plan-w-team to ship X","session_id":"x"}' | bash "$HOOK" 2>/dev/null)
exit_code=$?
sleep 0.1
if [ "$exit_code" = "0" ] && ! shim_was_invoked; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "missing pwt-goal.sh fails open"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("missing pwt-goal.sh fails open")
    printf "  \033[31m✗\033[0m %s (exit=%s)\n" "missing pwt-goal.sh fails open" "$exit_code"
fi
teardown_sandbox

# ─── Malformed JSON fails open ───────────────────────────────────────────────
run_case "malformed JSON fails open" 0 no \
  'this is not json {{{'

# ─── Empty prompt fails open ─────────────────────────────────────────────────
run_case "empty prompt fails open" 0 no \
  '{"prompt":"","session_id":"x"}'

# ─── No trigger at all → allow ───────────────────────────────────────────────
run_case "ordinary prompt with no trigger passes through" 0 no \
  '{"prompt":"list the files in this directory","session_id":"x"}'

# ─── Trigger phrase inside quotes (still counts — we don't try to be too clever) ───
# Documented behavior: trigger anywhere fires. If you literally type a
# trigger, even quoted, we launch. Users have the opt-in escape.
run_case "trigger at start (quoted) still launches" 2 yes \
  '{"prompt":"\"use /plan-w-team to ship X\"","session_id":"x"}'

# ─── RECURSION KILLER: /goal bootstrap must NOT relaunch ─────────────────────
# This is the bug that spawned 19 cascading agents on 2026-05-20.
# The autonomous agent's first prompt is the /goal text generated by
# pwt-goal.sh, which contains "Use /plan-w-team to" — the hook must NOT
# fire on slash-prefixed prompts.
run_case "/goal bootstrap does NOT relaunch (recursion guard)" 0 no \
  '{"prompt":"/goal Use /plan-w-team to ship the payment API.\nPipeline is complete when ALL of: ...","session_id":"x"}'

# ─── User invoking /plan-w-team slash directly is also a passthrough ─────────
run_case "/plan-w-team slash direct invocation does NOT relaunch" 0 no \
  '{"prompt":"/plan-w-team start a new run","session_id":"x"}'

# ─── Other slash commands always pass through ────────────────────────────────
run_case "arbitrary slash command passes through" 0 no \
  '{"prompt":"/develop --continuous","session_id":"x"}'

# ─── Leading whitespace before slash still triggers guard ────────────────────
run_case "indented /goal bootstrap also bypassed" 0 no \
  '{"prompt":"   /goal Use /plan-w-team to do X","session_id":"x"}'

# ─── Session ID is parsed and embedded in systemMessage ──────────────────────
setup_sandbox
out=$(printf '%s' '{"prompt":"use /plan-w-team to verify session id parsing"}' | bash "$HOOK" 2>/dev/null)
exit_code=$?
wait_for_shim
sid_in_msg=$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); m=d.get('systemMessage',''); print('deadbeef' if 'deadbeef' in m else '')" 2>/dev/null)
if [ "$exit_code" = "2" ] && [ "$sid_in_msg" = "deadbeef" ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "session ID parsed into systemMessage"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("session ID parsed into systemMessage")
    printf "  \033[31m✗\033[0m %s (exit=%s sid_in_msg=%s)\n" "session ID parsed into systemMessage" "$exit_code" "$sid_in_msg"
    printf "      stdout: %s\n" "$out"
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
