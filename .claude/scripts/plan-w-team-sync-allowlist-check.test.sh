#!/usr/bin/env bash
# plan-w-team-sync-allowlist-check.test.sh
#
# Tests for plan-w-team-sync-allowlist-check.sh.
# Covers pass case (no drift) and fail case (synthetic drift script).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/plan-w-team-sync-allowlist-check.sh"

PASS=0
FAIL=0

assert_eq() {
    local expected="$1"
    local actual="$2"
    local name="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

# Test 1: Smoke — current repo passes
echo "Test 1: smoke (current repo should pass)"
if "$CHECK_SCRIPT" >/dev/null 2>&1; then
    assert_eq "0" "0" "current repo state passes check"
else
    rc=$?
    assert_eq "0" "$rc" "current repo state passes check"
fi

# Test 2: Drift — synthetic offender file triggers exit 1
echo "Test 2: synthetic drift triggers fail"
SYNTHETIC="$SCRIPT_DIR/plan-w-team-zzz-test-drift-do-not-commit.sh"
trap 'rm -f "$SYNTHETIC"' EXIT
cat > "$SYNTHETIC" <<'EOF'
#!/usr/bin/env bash
# synthetic drift test file
true
EOF
chmod +x "$SYNTHETIC"

if "$CHECK_SCRIPT" >/dev/null 2>&1; then
    assert_eq "1" "0" "synthetic offender triggers exit 1"
else
    rc=$?
    assert_eq "1" "$rc" "synthetic offender triggers exit 1"
fi

# Test 3: Drift output names the offender
echo "Test 3: drift output names the offender"
OUTPUT=$("$CHECK_SCRIPT" 2>&1 || true)
if echo "$OUTPUT" | grep -q "plan-w-team-zzz-test-drift-do-not-commit.sh"; then
    assert_eq "0" "0" "offender named in stderr output"
else
    echo "  ✗ offender not named in output"
    echo "    output was: $OUTPUT"
    FAIL=$((FAIL + 1))
fi

# Cleanup
rm -f "$SYNTHETIC"
trap - EXIT

# Test 4: Soft-skip when sync-to-project.sh missing
echo "Test 4: soft-skip when sync-to-project.sh absent"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
mkdir -p "$TMPDIR_TEST/.claude/scripts"
cp "$CHECK_SCRIPT" "$TMPDIR_TEST/.claude/scripts/"
(cd "$TMPDIR_TEST" && git init -q 2>/dev/null && git commit --allow-empty -q -m "init" 2>/dev/null) || true
if (cd "$TMPDIR_TEST" && bash .claude/scripts/plan-w-team-sync-allowlist-check.sh >/dev/null 2>&1); then
    assert_eq "0" "0" "soft-skip exit 0 when sync-to-project.sh missing"
else
    rc=$?
    assert_eq "0" "$rc" "soft-skip exit 0 when sync-to-project.sh missing"
fi
rm -rf "$TMPDIR_TEST"
trap - EXIT

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
