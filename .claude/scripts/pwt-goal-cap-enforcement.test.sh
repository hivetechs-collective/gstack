#!/usr/bin/env bash
# pwt-goal-cap-enforcement.test.sh
#
# Regression test for the /goal 4000-char cap pre-flight in pwt-goal.sh.
#
# Bug history (2026-05-21): a 4442-char /goal directive was spawned via
# `claude --bg "/goal …"`. Anthropic's /goal silently rejected it with
# "Goal condition is limited to 4000 characters" and the worker session
# wedged at the prompt indefinitely. Supervisor caught the failure mode
# only after polling for ~1 hour, by which point all the launch tokens
# were already burned.
#
# This test asserts pwt-goal.sh refuses oversized directives before
# spawning a bg session — fail fast at the gate, no wedged workers.
set -u

PWT_GOAL="${PWT_GOAL:-$(cd "$(dirname "$0")" && pwd)/pwt-goal.sh}"
PASS=0
FAIL=0

assert_eq() {
    local label="$1"
    local want="$2"
    local got="$3"
    if [ "$want" = "$got" ]; then
        echo "  ✓ $label"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label  want=$want got=$got"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1"
    local needle="$2"
    local haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  ✓ $label"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label  needle missing: $needle"
        FAIL=$((FAIL + 1))
    fi
}

echo "AC1: short directive passes (no cap violation)"
short_req="fix a typo in README"
out=$("$PWT_GOAL" "$short_req" 2>&1)
rc=$?
assert_eq "exit code is 0" "0" "$rc"
assert_contains "output contains the /goal prefix" "/goal Use /plan-w-team to fix a typo in README" "$out"

echo ""
echo "AC2: oversized directive aborts with exit 2"
long_req=$(python3 -c "print('lorem ipsum dolor sit amet ' * 200)")
"$PWT_GOAL" "$long_req" >/dev/null 2>/tmp/pwt-goal-cap.err
rc=$?
assert_eq "exit code is 2" "2" "$rc"
err=$(cat /tmp/pwt-goal-cap.err)
assert_contains "stderr cites the 4000-char cap" "4000-char runtime cap" "$err"
assert_contains "stderr cites the actual byte count" "exceeds Anthropic" "$err"
assert_contains "stderr suggests shortening" "Shorten the REQUEST" "$err"

echo ""
echo "AC3: PLAN_W_TEAM_GOAL_MAX env override raises the cap"
PLAN_W_TEAM_GOAL_MAX=100000 "$PWT_GOAL" "$long_req" >/dev/null 2>/tmp/pwt-goal-cap.err
rc=$?
assert_eq "exit code is 0 with raised cap" "0" "$rc"

echo ""
echo "AC4: directive right at the boundary (under 4000 chars) passes"
# Skeleton overhead is ~930 chars, so a 3000-char REQUEST yields ~3930 chars total.
boundary_req=$(python3 -c "print('x' * 3000)")
"$PWT_GOAL" "$boundary_req" >/dev/null 2>/tmp/pwt-goal-cap.err
rc=$?
# Must NOT abort with 2 (may pass with 0; minor wording variance is fine)
if [ "$rc" = "2" ]; then
    echo "  ✗ exit code 2 at boundary (should pass under cap)"
    FAIL=$((FAIL + 1))
else
    echo "  ✓ exit code is not 2 at boundary (got $rc)"
    PASS=$((PASS + 1))
fi

echo ""
echo "════════════════════════════════════════"
echo "  Pass: $PASS  Fail: $FAIL"
echo "════════════════════════════════════════"
rm -f /tmp/pwt-goal-cap.err
[ "$FAIL" = "0" ]
