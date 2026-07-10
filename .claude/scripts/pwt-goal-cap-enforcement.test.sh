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

# NOTE: as of 2026-05-22, pwt-goal.sh has a "directive overflow to disk"
# feature that intercepts oversized REQUESTs BEFORE the 4000-char /goal cap.
# To test the cap itself, disable overflow by setting the threshold absurdly
# high. Overflow has its own test (pwt-goal-overflow.test.sh); the cap
# remains the last-resort guard for pathologically large rendered goal text
# (e.g. a huge DONE_CRITERIA template).
DISABLE_OVERFLOW="PLAN_W_TEAM_OVERFLOW_THRESHOLD=10000000"

echo "AC1: short directive passes (no cap violation)"
short_req="fix a typo in README"
out=$(env $DISABLE_OVERFLOW "$PWT_GOAL" "$short_req" 2>&1)
rc=$?
assert_eq "exit code is 0" "0" "$rc"
assert_contains "output contains the /goal prefix" "/goal Use /plan-w-team to fix a typo in README" "$out"

echo ""
echo "AC2: oversized directive aborts with exit 2 (overflow disabled)"
long_req=$(python3 -c "print('lorem ipsum dolor sit amet ' * 200)")
env $DISABLE_OVERFLOW "$PWT_GOAL" "$long_req" >/dev/null 2>/tmp/pwt-goal-cap.err
rc=$?
assert_eq "exit code is 2" "2" "$rc"
err=$(cat /tmp/pwt-goal-cap.err)
assert_contains "stderr cites the 4000-char cap" "4000-char runtime cap" "$err"
assert_contains "stderr cites the actual byte count" "exceeds Anthropic" "$err"
assert_contains "stderr suggests shortening" "Shorten the REQUEST" "$err"

echo ""
echo "AC3: PLAN_W_TEAM_GOAL_MAX env override raises the cap"
env $DISABLE_OVERFLOW PLAN_W_TEAM_GOAL_MAX=100000 "$PWT_GOAL" "$long_req" >/dev/null 2>/tmp/pwt-goal-cap.err
rc=$?
assert_eq "exit code is 0 with raised cap" "0" "$rc"

echo ""
echo "AC4: directive right at the boundary (under 4000 chars) passes"
# MEASURE the wrapper skeleton overhead instead of hardcoding it (1.54.0: the
# injected SLUG block + emitter-named DONE_CRITERIA grew the skeleton and broke
# the old "~930 chars" assumption). Probe with a 1000-char request (slug body is
# length-capped well before that, so overhead is constant for large requests),
# then size the boundary request to land ~50 chars under the 4000 cap.
probe_req=$(python3 -c "print('x' * 1000)")
probe_len=$(env $DISABLE_OVERFLOW PLAN_W_TEAM_GOAL_MAX=100000 "$PWT_GOAL" "$probe_req" 2>/dev/null | wc -c | tr -d ' ')
overhead=$((probe_len - 1000))
boundary_size=$((4000 - overhead - 50))
boundary_req=$(python3 -c "print('x' * ${boundary_size})")
env $DISABLE_OVERFLOW "$PWT_GOAL" "$boundary_req" >/dev/null 2>/tmp/pwt-goal-cap.err
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
echo "AC5: oversized directive WITH overflow enabled gracefully overflows to disk"
# Same large REQUEST as AC2, but with overflow active (default threshold).
# Behavior contract: exit 0, pointer text in goal, overflow file under
# .claude/state/. We use a sandbox via PWT_PROJECT_ROOT_OVERRIDE so we don't
# pollute the real repo state dir.
ac5_sandbox=$(mktemp -d -t pwt-cap-ac5.XXXXXX)
mkdir -p "$ac5_sandbox/.claude/state"
PWT_PROJECT_ROOT_OVERRIDE="$ac5_sandbox" "$PWT_GOAL" "$long_req" >/tmp/pwt-goal-cap.out 2>/tmp/pwt-goal-cap.err
rc=$?
assert_eq "exit code is 0 with overflow enabled" "0" "$rc"
assert_contains "goal output contains pointer text" "Read full directive at" "$(cat /tmp/pwt-goal-cap.out)"
overflow_count=$(ls "$ac5_sandbox"/.claude/state/plan-w-team-directive-*.txt 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exactly one overflow file written" "1" "$overflow_count"
rm -rf "$ac5_sandbox"
rm -f /tmp/pwt-goal-cap.out

echo ""
echo "════════════════════════════════════════"
echo "  Pass: $PASS  Fail: $FAIL"
echo "════════════════════════════════════════"
rm -f /tmp/pwt-goal-cap.err
[ "$FAIL" = "0" ]
