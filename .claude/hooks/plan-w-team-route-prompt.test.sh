#!/usr/bin/env bash
# Tests for plan-w-team-route-prompt.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/plan-w-team-route-prompt.sh"

PASS=0
FAIL=0

assert() {
    local name="$1" expected_rc="$2" actual_rc="$3"
    if [ "$expected_rc" = "$actual_rc" ]; then
        echo "  ✓ $name (rc=$actual_rc)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name (expected rc=$expected_rc, got $actual_rc)"
        FAIL=$((FAIL + 1))
    fi
}

# Stub pwt-goal.sh in a temp PROJECT_DIR so the hook calls our stub instead of the real script
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
mkdir -p "$TMPDIR_TEST/.claude/scripts"
cat > "$TMPDIR_TEST/.claude/scripts/pwt-goal.sh" <<'STUB'
#!/usr/bin/env bash
# Stub: echo args so we can assert what the hook tried to launch.
echo "STUB pwt-goal --launch called with: $*"
exit 0
STUB
chmod +x "$TMPDIR_TEST/.claude/scripts/pwt-goal.sh"

# Test 1: non-trigger prompt → exit 0
echo "Test 1: non-trigger prompt"
RC=0
echo '{"prompt":"hello there"}' | CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" >/dev/null 2>&1 || RC=$?
assert "non-trigger allows through" "0" "$RC"

# Test 2: trigger phrase "use /plan-w-team to" → block (rc=2)
echo "Test 2: 'use /plan-w-team to' trigger"
RC=0
echo '{"prompt":"Use /plan-w-team to do a realistic audit"}' \
    | CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" >/dev/null 2>&1 || RC=$?
assert "'use /plan-w-team to' triggers block" "2" "$RC"

# Test 3: case-insensitive
echo "Test 3: case-insensitive match"
RC=0
echo '{"prompt":"USE /PLAN-W-TEAM TO DO X"}' \
    | CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" >/dev/null 2>&1 || RC=$?
assert "uppercase still triggers block" "2" "$RC"

# Test 4: "using /plan-w-team" trigger
echo "Test 4: 'using /plan-w-team' trigger"
RC=0
echo '{"prompt":"Using /plan-w-team build the audit system"}' \
    | CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" >/dev/null 2>&1 || RC=$?
assert "'using /plan-w-team' triggers block" "2" "$RC"

# Test 5: in-session opt-in escapes the trigger
echo "Test 5: in-session opt-in escapes"
RC=0
echo '{"prompt":"use /plan-w-team in this session to build X"}' \
    | CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" >/dev/null 2>&1 || RC=$?
assert "'in this session' opt-in allows through" "0" "$RC"

# Test 6: kill-switch env
echo "Test 6: PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1"
RC=0
echo '{"prompt":"use /plan-w-team to do X"}' \
    | PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" >/dev/null 2>&1 || RC=$?
assert "disable env allows through" "0" "$RC"

# Test 7: 'definition of done' + /plan-w-team
echo "Test 7: 'definition of done' + /plan-w-team trigger"
RC=0
echo '{"prompt":"please run /plan-w-team. definition of done: tests pass"}' \
    | CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" >/dev/null 2>&1 || RC=$?
assert "'definition of done' + slash triggers block" "2" "$RC"

# Test 8: bare slash invocation does NOT trigger (verb is missing)
echo "Test 8: bare /plan-w-team should pass through"
RC=0
echo '{"prompt":"/plan-w-team add auth flow"}' \
    | CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" >/dev/null 2>&1 || RC=$?
assert "bare /plan-w-team allows through" "0" "$RC"

# Test 9: trigger output contains launch confirmation
echo "Test 9: trigger output mentions claude agents"
OUT=$(echo '{"prompt":"use /plan-w-team to do X"}' \
    | CLAUDE_PROJECT_DIR="$TMPDIR_TEST" "$HOOK" 2>&1 || true)
if echo "$OUT" | grep -q "claude agents"; then
    assert "output contains 'claude agents'" "0" "0"
else
    echo "  ✗ output does not mention 'claude agents'"
    echo "    raw: $OUT"
    FAIL=$((FAIL + 1))
fi

# Test 10: missing pwt-goal.sh → allow through with warning
echo "Test 10: missing pwt-goal.sh falls back to allow"
TMPDIR_NO_PWT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_NO_PWT"' EXIT
mkdir -p "$TMPDIR_NO_PWT/.claude/scripts"
RC=0
echo '{"prompt":"use /plan-w-team to do X"}' \
    | CLAUDE_PROJECT_DIR="$TMPDIR_NO_PWT" "$HOOK" >/dev/null 2>&1 || RC=$?
assert "missing pwt-goal allows through" "0" "$RC"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
