#!/usr/bin/env bash
# Regression test for Bug 2: residual duplicate-worker spawn from pwt-goal.sh.
#
# History:
#   2026-05-21 — even after the slash-guard recursion fix landed (a1edd2a,
#   commit "fix(plan-w-team): system-tag prompt guard + stale SUCCESS goal-state
#   GC"), a single `pwt-goal.sh --launch` call could still produce a third
#   bg worker. Root cause: the supervisor bootstrap text starts with `#`
#   (markdown heading), bypassing the slash-guard, and embeds the verbatim
#   user request which contains the literal trigger phrase. The route-prompt
#   hook honors PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1, but pwt-goal.sh wasn't
#   setting that var on the supervisor (or worker) `claude --bg` invocation.
#
# Companion: plan-w-team-route-prompt-recursion.test.sh asserts the HOOK
# honors the kill-switch. This test asserts the SPAWNER (pwt-goal.sh) sets
# the kill-switch on every claude --bg it invokes. Both must hold for the
# defense to be intact end-to-end.
#
# Approach:
#   Intercept the `claude` binary via a PATH-shadowed stub that records its
#   argv and the value of PLAN_W_TEAM_DISABLE_PROMPT_ROUTE in the env, then
#   exits with a synthesized "backgrounded · <sid>" line so pwt-goal.sh
#   continues through both worker and supervisor spawn paths. Assert the env
#   var was "1" on every recorded invocation.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PWT_GOAL="$REPO_ROOT/.claude/scripts/pwt-goal.sh"

PASS=0
FAIL=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Sandbox: stub `claude` binary that records argv + env var ───────────────
SANDBOX=$(mktemp -d -t pwt-supenv-XXXXXX)
STUB_BIN="$SANDBOX/bin"
CAPTURE="$SANDBOX/capture.log"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
# Stub that records what env it was called with and emits a fake backgrounded sid.
# Only handles `claude --bg <prompt>` since that's the only invocation pwt-goal makes.
echo "---" >> "$PWT_CAPTURE_FILE"
echo "argv: $*" >> "$PWT_CAPTURE_FILE"
echo "PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-UNSET}" >> "$PWT_CAPTURE_FILE"
echo "PLAN_W_TEAM_AUTO_APPROVE_PUSH=${PLAN_W_TEAM_AUTO_APPROVE_PUSH:-UNSET}" >> "$PWT_CAPTURE_FILE"
# Synthesize a unique 8-hex sid so pwt-goal's parser succeeds for both spawns.
SID=$(printf '%08x' $((RANDOM * RANDOM)))
echo "backgrounded · $SID"
exit 0
STUB
chmod +x "$STUB_BIN/claude"

cleanup() {
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

# grep -c always emits a single line "N" even with no matches; the trailing
# `|| true` keeps `set -e` happy (we don't use it, but future-proof) without
# tacking on an extra "0" line that would corrupt comparisons.
count() { grep -c "$1" "$2" 2>/dev/null || true; }

# Unset env vars that might leak from the test runner's own environment
# (e.g., if this test runs inside a session that itself set
# PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 via --launch up the chain).
unset PLAN_W_TEAM_DISABLE_PROMPT_ROUTE
unset PLAN_W_TEAM_AUTO_APPROVE_PUSH

# ─── Test 1: pwt-goal.sh --launch — worker + supervisor BOTH carry env var ───
echo "Test 1: --launch invokes claude --bg with PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 for worker AND supervisor"
> "$CAPTURE"
PATH="$STUB_BIN:$PATH" \
    PWT_CAPTURE_FILE="$CAPTURE" \
    PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX" \
    env -u PLAN_W_TEAM_DISABLE_PROMPT_ROUTE -u PLAN_W_TEAM_AUTO_APPROVE_PUSH \
    "$PWT_GOAL" --launch "test request for supervisor env regression" \
    >/dev/null 2>&1

INVOCATIONS=$(count '^---$' "$CAPTURE")
assert "two claude --bg invocations (worker + supervisor)" "2" "$INVOCATIONS"

# Both invocations must show the kill-switch env var.
UNSET_COUNT=$(count 'PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=UNSET' "$CAPTURE")
SET_COUNT=$(count 'PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1' "$CAPTURE")
assert "neither invocation has UNSET env var" "0" "$UNSET_COUNT"
assert "both invocations have env var = 1" "2" "$SET_COUNT"

# ─── Test 2: --launch implies --auto-push (AUTO_PUSH=1 also set) ─────────────
echo
echo "Test 2: --launch also sets PLAN_W_TEAM_AUTO_APPROVE_PUSH=1"
AUTOPUSH_SET=$(count 'PLAN_W_TEAM_AUTO_APPROVE_PUSH=1' "$CAPTURE")
assert "AUTO_PUSH=1 on both invocations" "2" "$AUTOPUSH_SET"

# ─── Test 3: --launch --no-auto-push — kill-switch still set ─────────────────
# (We don't assert AUTO_PUSH=UNSET here because the env var can be inherited
# from the parent process — the kill-switch is the only invariant the test
# is responsible for.)
echo
echo "Test 3: --launch --no-auto-push keeps kill-switch"
> "$CAPTURE"
PATH="$STUB_BIN:$PATH" \
    PWT_CAPTURE_FILE="$CAPTURE" \
    PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX" \
    env -u PLAN_W_TEAM_DISABLE_PROMPT_ROUTE -u PLAN_W_TEAM_AUTO_APPROVE_PUSH \
    "$PWT_GOAL" --launch --no-auto-push "no-push test" \
    >/dev/null 2>&1
SET_COUNT=$(count 'PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1' "$CAPTURE")
assert "kill-switch still set (=1) on both" "2" "$SET_COUNT"

# ─── Test 4: --worker-only — single claude --bg call, env var present ────────
echo
echo "Test 4: --worker-only invokes claude --bg ONCE with env var"
> "$CAPTURE"
PATH="$STUB_BIN:$PATH" \
    PWT_CAPTURE_FILE="$CAPTURE" \
    PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX" \
    env -u PLAN_W_TEAM_DISABLE_PROMPT_ROUTE -u PLAN_W_TEAM_AUTO_APPROVE_PUSH \
    "$PWT_GOAL" --worker-only "worker-only env test" \
    >/dev/null 2>&1
INVOCATIONS=$(count '^---$' "$CAPTURE")
SET_COUNT=$(count 'PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1' "$CAPTURE")
assert "one claude --bg invocation (worker only)" "1" "$INVOCATIONS"
assert "the invocation has env var = 1" "1" "$SET_COUNT"

# ─── Test 5: source-grep guard — the literal token must appear in pwt-goal.sh ─
echo
echo "Test 5: source contains the kill-switch token (defense against regression)"
TOKEN_HITS=$(count 'PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1' "$PWT_GOAL")
# Must be at least 2: the LAUNCH_ENV initializer (line ~194) AND the bare-claude
# fallback (line ~240). If either disappears, the env var could be dropped on
# one spawn path silently. Tight check pins both.
if [ "$TOKEN_HITS" -ge 2 ]; then
    assert "pwt-goal.sh references kill-switch token in ≥2 places" "yes" "yes"
else
    assert "pwt-goal.sh references kill-switch token in ≥2 places" "yes" "no ($TOKEN_HITS hits)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
