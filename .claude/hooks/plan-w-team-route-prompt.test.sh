#!/usr/bin/env bash
# Tests for plan-w-team-route-prompt.sh
#
# Contract (current): hook is NON-BLOCKING by design (returns rc=0 always when
# kill-switch is not engaged). On trigger phrases, it spawns a bg worker via
# pwt-goal.sh --worker-only and emits a JSON payload containing
# additionalContext + systemMessage; the origin assistant turn proceeds with
# that context injected. The old "block + spawn detached supervisor" contract
# (rc=2) was retired in 904759f. See the hook header for the fail-open contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/plan-w-team-route-prompt.sh"

PASS=0
FAIL=0

assert_rc() {
    local name="$1" expected_rc="$2" actual_rc="$3"
    if [ "$expected_rc" = "$actual_rc" ]; then
        echo "  ✓ $name (rc=$actual_rc)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name (expected rc=$expected_rc, got $actual_rc)"
        FAIL=$((FAIL + 1))
    fi
}

assert_match() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name (needle '$needle' missing)"
        echo "    haystack: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_no_match() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "  ✗ $name (needle '$needle' present but should not be)"
        echo "    haystack: $haystack"
        FAIL=$((FAIL + 1))
    else
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    fi
}

# Stub pwt-goal.sh that emits the worker_sid format the hook parses.
make_stub_dir() {
    local d
    d=$(mktemp -d)
    mkdir -p "$d/.claude/scripts"
    cat > "$d/.claude/scripts/pwt-goal.sh" <<'STUB'
#!/usr/bin/env bash
# Stub: emit worker_sid=<8-hex> on stdout (the hook greps for this pattern).
echo "worker_sid=deadbeef"
exit 0
STUB
    chmod +x "$d/.claude/scripts/pwt-goal.sh"
    printf '%s' "$d"
}

# Always invoke the hook with PWT kill-switch unset so the tests exercise
# real trigger behavior regardless of parent-session env state.
run_hook() {
    env -u PLAN_W_TEAM_DISABLE_PROMPT_ROUTE "$@"
}

TMPDIR_TEST=$(make_stub_dir)
trap 'rm -rf "$TMPDIR_TEST" "${TMPDIR_NO_PWT:-}"' EXIT

# Test 1: non-trigger prompt → exit 0, no JSON output
echo "Test 1: non-trigger prompt"
RC=0
OUT=$(echo '{"prompt":"hello there"}' | run_hook CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" 2>&1) || RC=$?
assert_rc "non-trigger allows through" "0" "$RC"
assert_no_match "non-trigger emits no additionalContext" "additionalContext" "$OUT"

# Test 2: trigger phrase "use /plan-w-team to" → exit 0 with additionalContext
echo "Test 2: 'use /plan-w-team to' trigger"
RC=0
OUT=$(echo '{"prompt":"Use /plan-w-team to do a realistic audit"}' \
    | run_hook CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" 2>&1) || RC=$?
assert_rc "'use /plan-w-team to' rc=0 (non-blocking)" "0" "$RC"
assert_match "'use /plan-w-team to' emits additionalContext" "additionalContext" "$OUT"

# Test 3: case-insensitive
echo "Test 3: case-insensitive match"
RC=0
OUT=$(echo '{"prompt":"USE /PLAN-W-TEAM TO DO X"}' \
    | run_hook CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" 2>&1) || RC=$?
assert_rc "uppercase still rc=0" "0" "$RC"
assert_match "uppercase emits additionalContext" "additionalContext" "$OUT"

# Test 4: "using /plan-w-team" trigger
echo "Test 4: 'using /plan-w-team' trigger"
RC=0
OUT=$(echo '{"prompt":"Using /plan-w-team build the audit system"}' \
    | run_hook CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" 2>&1) || RC=$?
assert_rc "'using /plan-w-team' rc=0" "0" "$RC"
assert_match "'using /plan-w-team' emits additionalContext" "additionalContext" "$OUT"

# Test 5: in-session opt-in escapes the trigger (no additionalContext)
echo "Test 5: in-session opt-in escapes"
RC=0
OUT=$(echo '{"prompt":"use /plan-w-team in this session to build X"}' \
    | run_hook CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" 2>&1) || RC=$?
assert_rc "'in this session' opt-in rc=0" "0" "$RC"
assert_no_match "'in this session' emits no additionalContext" "additionalContext" "$OUT"

# Test 6: kill-switch env
echo "Test 6: PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1"
RC=0
OUT=$(echo '{"prompt":"use /plan-w-team to do X"}' \
    | PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" 2>&1) || RC=$?
assert_rc "disable env rc=0" "0" "$RC"
assert_no_match "disable env emits no additionalContext" "additionalContext" "$OUT"

# Test 7: 'definition of done' + /plan-w-team triggers (documented combined trigger)
echo "Test 7: 'definition of done' + /plan-w-team trigger"
RC=0
OUT=$(echo '{"prompt":"please run /plan-w-team. definition of done: tests pass"}' \
    | run_hook CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" 2>&1) || RC=$?
assert_rc "'definition of done' + slash rc=0" "0" "$RC"
assert_match "'definition of done' + slash emits additionalContext" "additionalContext" "$OUT"

# Test 8: bare slash invocation does NOT trigger (slash-guard exits early)
echo "Test 8: bare /plan-w-team should pass through"
RC=0
OUT=$(echo '{"prompt":"/plan-w-team add auth flow"}' \
    | run_hook CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" 2>&1) || RC=$?
assert_rc "bare /plan-w-team rc=0" "0" "$RC"
assert_no_match "bare /plan-w-team emits no additionalContext" "additionalContext" "$OUT"

# Test 9: trigger output mentions launch info (worker SID + protocol)
echo "Test 9: trigger output mentions launch info"
OUT=$(echo '{"prompt":"use /plan-w-team to do X"}' \
    | run_hook CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" 2>&1 || true)
assert_match "trigger output contains worker SID" "deadbeef" "$OUT"

# Test 10: missing pwt-goal.sh → fail-open (rc=0, no additionalContext)
echo "Test 10: missing pwt-goal.sh falls back to allow"
TMPDIR_NO_PWT=$(mktemp -d)
mkdir -p "$TMPDIR_NO_PWT/.claude/scripts"
RC=0
OUT=$(echo '{"prompt":"use /plan-w-team to do X"}' \
    | run_hook CLAUDE_PROJECT_DIR="$TMPDIR_NO_PWT" "$HOOK" 2>&1) || RC=$?
assert_rc "missing pwt-goal rc=0" "0" "$RC"
assert_no_match "missing pwt-goal emits no additionalContext" "additionalContext" "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
