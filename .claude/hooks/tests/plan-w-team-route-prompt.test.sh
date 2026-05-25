#!/usr/bin/env bash
# Tests for plan-w-team-route-prompt.sh
#
# Updated for origin-chat live supervisor (docs/specs/pwt-origin-chat-live-supervisor.md):
# - Hook now calls `pwt-goal.sh --worker-only` SYNCHRONOUSLY
# - Hook returns exit 0 with additionalContext (NOT exit 2 / decision=block)
# - Worker SID is parsed from "worker_sid=<SID>" on stdout (shim emits this)
#
# Strategy: build an isolated $CLAUDE_PROJECT_DIR with a SHIM pwt-goal.sh that
# records its invocation and emits the worker_sid= line. Each case sends a
# JSON prompt on stdin and asserts:
#   - exit code (0 for trigger match in new world; 0 for no-match too)
#   - whether the shim was invoked (marker file presence)
#   - whether stdout is valid JSON with additionalContext + supervisor protocol
#   - whether --worker-only was passed (regression guard for AC2)
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
# Shim: record invocation + emit machine-readable "worker_sid=" line that
# the synchronous --worker-only path in pwt-goal.sh produces.
echo "INVOKED: $*" > "$(dirname "$0")/../state/shim-invoked.marker"
# Mirror the args verbatim so tests can assert --worker-only was passed.
printf '%s\n' "$*" > "$(dirname "$0")/../state/shim-args.txt"
echo "Launching: claude --bg <derived /goal>" >&2
echo "worker_sid=deadbeef"
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

shim_received_worker_only() {
    # The hook spawns a single foreground-supervised worker. It may pass either
    # --worker-only OR --supervisor-goal: the latter is a strict SUPERSET of the
    # former (sets WORKER_ONLY=1 plus an origin goal-state mirror — see
    # pwt-goal.sh "--supervisor-goal ... Same as --worker-only PLUS ..."). The
    # origin-chat live-supervisor path (route-prompt.sh "Foreground worker spawn
    # (--supervisor-goal mode)") now uses --supervisor-goal. Both satisfy this
    # test's intent: a worker-only spawn (NOT a detached --launch). Accept either.
    [ -f "$SANDBOX/.claude/state/shim-args.txt" ] && \
        grep -qE -- '--worker-only|--supervisor-goal' "$SANDBOX/.claude/state/shim-args.txt"
}

run_case() {
    local name="$1" expect_exit="$2" expect_invoke="$3" prompt_json="$4"
    setup_sandbox
    local out exit_code
    out=$(printf '%s' "$prompt_json" | bash "$HOOK" 2>/dev/null)
    exit_code=$?
    local actual_invoke="no"
    if shim_was_invoked; then
        actual_invoke="yes"
    fi

    local ok=1
    [ "$exit_code" -ne "$expect_exit" ] && ok=0
    [ "$actual_invoke" != "$expect_invoke" ] && ok=0

    # If trigger expected to fire, output must be valid JSON with
    # additionalContext (NEW contract — was decision=block in pre-2026-05-21).
    if [ "$expect_invoke" = "yes" ] && [ -n "$out" ]; then
        echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
# AC1: non-blocking — no 'decision' field, or explicitly omitted
if d.get('decision') == 'block':
    raise SystemExit('decision=block must NOT be present')
# AC1+AC3: additionalContext present and contains supervisor protocol marker
ctx = d.get('additionalContext','')
if 'PWT-O1' not in ctx:
    raise SystemExit('additionalContext missing PWT-O1 protocol marker')
if 'deadbeef' not in ctx:
    raise SystemExit('worker SID not embedded in additionalContext')
" 2>/dev/null || ok=0

        # AC2: shim must have been invoked with --worker-only
        if ! shim_received_worker_only; then
            ok=0
        fi
    fi

    if [ "$ok" = "1" ]; then
        PASS=$((PASS+1))
        printf "  \033[32m✓\033[0m %s\n" "$name"
    else
        FAIL=$((FAIL+1))
        FAIL_NAMES+=("$name")
        printf "  \033[31m✗\033[0m %s\n" "$name"
        printf "      expected exit=%s invoke=%s\n" "$expect_exit" "$expect_invoke"
        printf "      actual   exit=%s invoke=%s worker_only=%s\n" \
            "$exit_code" "$actual_invoke" "$(shim_received_worker_only && echo yes || echo no)"
        [ -n "$out" ] && printf "      stdout: %s\n" "$out"
    fi
    teardown_sandbox
}

echo "Testing plan-w-team-route-prompt.sh (origin-chat live supervisor)"
echo

# ─── Trigger at start: launches AS NON-BLOCKING (exit 0) ─────────────────────
# NEW contract: exit code 0 with additionalContext, not exit 2 with decision=block.
run_case "trigger at start launches non-blocking" 0 yes \
  '{"prompt":"use /plan-w-team to ship the payment API","session_id":"x"}'

# ─── Trigger with pleasantry prefix still fires ──────────────────────────────
run_case "trigger with 'please' prefix launches non-blocking" 0 yes \
  '{"prompt":"please use /plan-w-team to fix the login bug","session_id":"x"}'

# ─── Multi-line prompt with trigger ──────────────────────────────────────────
run_case "multi-line prompt with trigger launches non-blocking" 0 yes \
  '{"prompt":"use /plan-w-team to ship X.\nDefinition of done: tests pass","session_id":"x"}'

# ─── Trigger mid-prompt LAUNCHES (natural-language is sacred) ────────────────
run_case "trigger mid-prompt LAUNCHES non-blocking" 0 yes \
  '{"prompt":"now lets test it, use /plan-w-team to holistically review the routing hook","session_id":"x"}'

# ─── Meta-discussion without trigger does NOT launch ─────────────────────────
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
if [ "$exit_code" = "0" ] && ! shim_was_invoked; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "missing pwt-goal.sh fails open"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("missing pwt-goal.sh fails open")
    printf "  \033[31m✗\033[0m %s (exit=%s)\n" "missing pwt-goal.sh fails open" "$exit_code"
fi
teardown_sandbox

# ─── Worker spawn failure fails open ─────────────────────────────────────────
# If pwt-goal.sh runs but does NOT emit "worker_sid=", the hook must fail open
# so the origin assistant gets the unmodified prompt and can fall back to
# its skill-level routing.
setup_sandbox
cat > "$SANDBOX/.claude/scripts/pwt-goal.sh" <<'BROKENSHIM'
#!/usr/bin/env bash
# Broken shim: never emits worker_sid=
echo "INVOKED: $*" > "$(dirname "$0")/../state/shim-invoked.marker"
echo "Some random output that isn't a worker_sid"
exit 0
BROKENSHIM
chmod +x "$SANDBOX/.claude/scripts/pwt-goal.sh"
out=$(printf '%s' '{"prompt":"use /plan-w-team to ship X","session_id":"x"}' | bash "$HOOK" 2>/dev/null)
exit_code=$?
if [ "$exit_code" = "0" ] && [ -z "$out" ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "missing worker_sid fails open"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("missing worker_sid fails open")
    printf "  \033[31m✗\033[0m %s (exit=%s out=%s)\n" "missing worker_sid fails open" "$exit_code" "$out"
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

# ─── RECURSION KILLER: /goal bootstrap must NOT relaunch ─────────────────────
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

# ─── System-injected event tag prefixes do NOT re-trigger routing ────────────
# Production recursion (2026-05-21): Monitor tool re-emitted the original
# worker request inside <task-notification> events, which the route hook
# then matched as a fresh "use /plan-w-team to" trigger. Each system-tag
# prefix below must short-circuit BEFORE trigger detection runs.
#
# Each case puts the trigger phrase INSIDE the system event payload —
# without the guard, trigger detection would match and the shim would be
# invoked. With the guard, the shim must remain untouched.
run_case "<task-notification> wrapper does NOT relaunch" 0 no \
  '{"prompt":"<task-notification>\n<summary>worker terminal: use /plan-w-team to ship X</summary>","session_id":"x"}'

run_case "<system-reminder> wrapper does NOT relaunch" 0 no \
  '{"prompt":"<system-reminder>Reminder: use /plan-w-team to keep state files tidy</system-reminder>","session_id":"x"}'

run_case "<command-name> wrapper does NOT relaunch" 0 no \
  '{"prompt":"<command-name>/goal</command-name>\n<command-args>Use /plan-w-team to do X</command-args>","session_id":"x"}'

run_case "<command-message> wrapper does NOT relaunch" 0 no \
  '{"prompt":"<command-message>goal</command-message>","session_id":"x"}'

run_case "<command-args> wrapper does NOT relaunch" 0 no \
  '{"prompt":"<command-args>Use /plan-w-team to ship Y</command-args>","session_id":"x"}'

run_case "<local-command-stdout> wrapper does NOT relaunch" 0 no \
  '{"prompt":"<local-command-stdout>Goal set: use /plan-w-team to do X</local-command-stdout>","session_id":"x"}'

run_case "<local-command-stderr> wrapper does NOT relaunch" 0 no \
  '{"prompt":"<local-command-stderr>warning: use /plan-w-team to fix bug</local-command-stderr>","session_id":"x"}'

run_case "<bash-stdout> wrapper does NOT relaunch" 0 no \
  '{"prompt":"<bash-stdout>purpose: use /plan-w-team to fix all bugs</bash-stdout>","session_id":"x"}'

run_case "<bash-stderr> wrapper does NOT relaunch" 0 no \
  '{"prompt":"<bash-stderr>error: use /plan-w-team to recover</bash-stderr>","session_id":"x"}'

run_case "<user-prompt-submit-hook> wrapper does NOT relaunch" 0 no \
  '{"prompt":"<user-prompt-submit-hook>use /plan-w-team to ship X</user-prompt-submit-hook>","session_id":"x"}'

# ─── Verbatim production recursion payload (2026-05-21 bf7cf4e2) ─────────────
# The exact <task-notification> shape that triggered the cascade. Includes
# escaped quotes and embedded JSON, the way Monitor formats it.
run_case "verbatim production task-notification cascade payload" 0 no \
  '{"prompt":"<task-notification>\n<task-id>bt8vjgju5</task-id>\n<summary>Monitor event: PWT worker terminal signals (JSONL tail)</summary>\n<event>{\"purpose\":\"use /plan-w-team to fix all bugs\"}</event>\n</task-notification>","session_id":"x"}'

# ─── Supervisor protocol contains required AC anchors ────────────────────────
# AC3+AC4+AC5: the protocol must instruct the origin assistant on status block,
# polling loop, and terminal block.
setup_sandbox
out=$(printf '%s' '{"prompt":"use /plan-w-team to verify protocol anchors","session_id":"abc12345"}' | bash "$HOOK" 2>/dev/null)
exit_code=$?
proto_ok=$(echo "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ctx=d.get('additionalContext','')
# AC3 anchor: status block instruction
if 'STATUS BLOCK' not in ctx: raise SystemExit('missing STATUS BLOCK')
# AC4 anchor: polling loop
if 'POLLING LOOP' not in ctx: raise SystemExit('missing POLLING LOOP')
# AC5 anchor: terminal block
if 'TERMINAL BLOCK' not in ctx: raise SystemExit('missing TERMINAL BLOCK')
# AC6 anchor: hard-gate halt language
if 'hard-gate' not in ctx and 'push-ack' not in ctx: raise SystemExit('missing hard-gate halt language')
print('ok')
" 2>/dev/null)
if [ "$exit_code" = "0" ] && [ "$proto_ok" = "ok" ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "supervisor protocol has AC3/AC4/AC5/AC6 anchors"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("supervisor protocol has AC3/AC4/AC5/AC6 anchors")
    printf "  \033[31m✗\033[0m %s (exit=%s proto_ok=%s)\n" "supervisor protocol has AC3/AC4/AC5/AC6 anchors" "$exit_code" "$proto_ok"
    printf "      stdout: %s\n" "$out"
fi
teardown_sandbox

# ─── Worker SID is embedded in systemMessage too ─────────────────────────────
setup_sandbox
out=$(printf '%s' '{"prompt":"use /plan-w-team to verify session id parsing"}' | bash "$HOOK" 2>/dev/null)
exit_code=$?
sid_in_msg=$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); m=d.get('systemMessage',''); print('deadbeef' if 'deadbeef' in m else '')" 2>/dev/null)
if [ "$exit_code" = "0" ] && [ "$sid_in_msg" = "deadbeef" ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "worker SID parsed into systemMessage"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("worker SID parsed into systemMessage")
    printf "  \033[31m✗\033[0m %s (exit=%s sid_in_msg=%s)\n" "worker SID parsed into systemMessage" "$exit_code" "$sid_in_msg"
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
