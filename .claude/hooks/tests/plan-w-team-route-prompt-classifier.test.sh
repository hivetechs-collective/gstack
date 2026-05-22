#!/usr/bin/env bash
# Tests for the intent classifier in plan-w-team-route-prompt.sh (BUG 1 fix).
#
# Spec: docs/specs/pwt-route-hook-fixes.md §"Intent Classifier (BUG 1 design)"
#
# Each case covers one of the 7 classes listed in AC3 (imperative, descriptive,
# interrogative, negation, conditional, embedded-quote, slash-prefix). The test
# sandbox is the same as plan-w-team-route-prompt.test.sh: a temp
# CLAUDE_PROJECT_DIR with a shim pwt-goal.sh that records invocation.
#
# A "LAUNCH" verdict means the shim was invoked. A "SKIP" verdict means it
# was not (the classifier suppressed the spawn).

set -u

export PLAN_W_TEAM_HOOK_TEST_MODE=1

HOOK="$(cd "$(dirname "$0")/.." && pwd)/plan-w-team-route-prompt.sh"
[ -x "$HOOK" ] || { echo "FAIL: hook not executable: $HOOK"; exit 1; }

PASS=0
FAIL=0
FAIL_NAMES=()

setup_sandbox() {
    SANDBOX=$(mktemp -d -t pwt-classifier-test.XXXXXX)
    mkdir -p "$SANDBOX/.claude/scripts" "$SANDBOX/.claude/state"
    cat > "$SANDBOX/.claude/scripts/pwt-goal.sh" <<'SHIM'
#!/usr/bin/env bash
echo "INVOKED: $*" > "$(dirname "$0")/../state/shim-invoked.marker"
printf '%s\n' "$*" > "$(dirname "$0")/../state/shim-args.txt"
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

# run_case <name> <expect_invoke yes|no> <prompt_json>
run_case() {
    local name="$1" expect_invoke="$2" prompt_json="$3"
    setup_sandbox
    local out exit_code actual_invoke
    out=$(printf '%s' "$prompt_json" | bash "$HOOK" 2>/dev/null)
    exit_code=$?
    actual_invoke="no"
    shim_was_invoked && actual_invoke="yes"

    local ok=1
    [ "$exit_code" -ne 0 ] && ok=0
    [ "$actual_invoke" != "$expect_invoke" ] && ok=0

    if [ "$ok" = "1" ]; then
        PASS=$((PASS+1))
        printf "  \033[32m✓\033[0m %s\n" "$name"
    else
        FAIL=$((FAIL+1))
        FAIL_NAMES+=("$name")
        printf "  \033[31m✗\033[0m %s\n" "$name"
        printf "      expected invoke=%s actual invoke=%s exit=%s\n" \
            "$expect_invoke" "$actual_invoke" "$exit_code"
        [ -n "$out" ] && printf "      stdout: %s\n" "$out"
    fi
    teardown_sandbox
}

echo "Testing intent classifier in plan-w-team-route-prompt.sh"
echo

# ─── Class 1: IMPERATIVE — must LAUNCH ───────────────────────────────────────
run_case "imperative: bare verb at start" yes \
  '{"prompt":"use /plan-w-team to ship the payment API","session_id":"x"}'

run_case "imperative: pleasantry prefix" yes \
  '{"prompt":"please use /plan-w-team to fix the login bug","session_id":"x"}'

run_case "imperative: pre-clause cue (lets test)" yes \
  '{"prompt":"now lets test it, use /plan-w-team to ship X","session_id":"x"}'

run_case "imperative: definition-of-done qualifier" yes \
  '{"prompt":"use /plan-w-team to ship X.\nDefinition of done: tests pass","session_id":"x"}'

# ─── Class 2: DESCRIPTIVE — must SKIP ────────────────────────────────────────
run_case "descriptive: my idea was to" no \
  '{"prompt":"my idea was to use /plan-w-team to fix it but I changed my mind","session_id":"x"}'

run_case "descriptive: noun-reference with definite article" no \
  '{"prompt":"the /plan-w-team route hook is broken and definition of done is unclear","session_id":"x"}'

run_case "descriptive: reported speech" no \
  '{"prompt":"he said use /plan-w-team to fix bugs but he is wrong","session_id":"x"}'

run_case "descriptive: bug-doc label" no \
  '{"prompt":"BUG 1: the hook substring-matches use /plan-w-team to anywhere","session_id":"x"}'

# ─── Class 3: INTERROGATIVE — must SKIP ──────────────────────────────────────
run_case "interrogative: should-question" no \
  '{"prompt":"should I use /plan-w-team to ship X?","session_id":"x"}'

run_case "interrogative: how-question" no \
  '{"prompt":"how do we use /plan-w-team to ship features?","session_id":"x"}'

# ─── Class 4: NEGATION — must SKIP ───────────────────────────────────────────
run_case "negation: dont-contraction" no \
  '{"prompt":"don'\''t use /plan-w-team to do this manually","session_id":"x"}'

run_case "negation: do-not-spelled-out" no \
  '{"prompt":"do not use /plan-w-team to ship this branch","session_id":"x"}'

# ─── Class 5: CONDITIONAL — must SKIP ────────────────────────────────────────
run_case "conditional: if-clause" no \
  '{"prompt":"if we use /plan-w-team to ship X, will it auto-push?","session_id":"x"}'

run_case "conditional: whether-clause" no \
  '{"prompt":"the question is whether to use /plan-w-team to ship X","session_id":"x"}'

run_case "conditional: hypothetical-modal (would)" no \
  '{"prompt":"it would be cool if we would use /plan-w-team to ship features","session_id":"x"}'

# ─── Class 6: EMBEDDED-QUOTE — must SKIP ─────────────────────────────────────
run_case "embedded-quote: double quotes" no \
  '{"prompt":"the docs say \"use /plan-w-team to ship X\" but it does not work","session_id":"x"}'

run_case "embedded-quote: backticks" no \
  '{"prompt":"the trigger phrase is `use /plan-w-team to` and it is too broad","session_id":"x"}'

run_case "embedded-quote: single quotes" no \
  '{"prompt":"the spec quotes '\''use /plan-w-team to'\'' as the matcher pattern","session_id":"x"}'

# ─── Class 7: SLASH-PREFIX — must SKIP (existing guard, regression coverage) ─
run_case "slash-prefix: bare slash command" no \
  '{"prompt":"/plan-w-team add auth flow","session_id":"x"}'

run_case "slash-prefix: /goal bootstrap" no \
  '{"prompt":"/goal Use /plan-w-team to ship X. Done when: tests pass.","session_id":"x"}'

# ─── Class 8 (bonus): NESTED descriptive in a quote inside an imperative ─────
# When the trigger appears ONLY inside quotes, we skip. This proves the
# quote rule fires before the imperative cue at the outer level.
run_case "nested: trigger only inside quotes is still a SKIP" no \
  '{"prompt":"please review the phrase \"use /plan-w-team to fix bugs\" for clarity","session_id":"x"}'

echo
echo "─────────────────────────────────────────"
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed cases:"
    for n in "${FAIL_NAMES[@]}"; do echo "  - $n"; done
    exit 1
fi
exit 0
