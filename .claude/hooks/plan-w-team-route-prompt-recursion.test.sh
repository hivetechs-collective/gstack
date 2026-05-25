#!/usr/bin/env bash
# Regression test for Bug 1: slash-guard recursion via supervisor bootstrap.
#
# History:
#   Production incident 2026-05-21 (sids 0b5856d7 → 4bbb2cb8 → f2ec9cb9 →
#   7a4c658b cascade). The supervisor bg session's first prompt is a
#   markdown-formatted bootstrap that:
#     (1) starts with `#` (heading) — bypasses the slash-guard at the head
#         of route-prompt.sh (slash-guard only fires on leading `/`)
#     (2) embeds the verbatim user request via `__REQUEST_SAFE__` templating,
#         so the substring `use /plan-w-team to <…>` appears in the bootstrap
#   When the UserPromptSubmit hook fires on this bootstrap inside the
#   supervisor session, the natural-language trigger detection at lines
#   114–128 matches the embedded request and re-launches another bg session
#   via pwt-goal.sh --worker-only. Infinite cascade.
#
# Fix: pwt-goal.sh now sets PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 in the env
# of every claude --bg it spawns (worker, supervisor, worker-only). The
# route hook honors this env var and exits 0 immediately, regardless of
# trigger-phrase matches.
#
# What this test asserts:
#   A. Without the env var, the supervisor-bootstrap-shaped prompt
#      (markdown leading char + embedded "use /plan-w-team to ...") DOES
#      trigger the hook (rc 0 with launch evidence — the bug we fixed).
#   B. With PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1, the SAME prompt does NOT
#      trigger (rc 0 with NO launch evidence) — the regression guard.
#   C. The kill-switch is effective for arbitrary bootstrap shapes, not
#      just the exact supervisor bootstrap (matrix over three bootstrap
#      shapes that all embed the trigger phrase).
#
# This test runs WITHOUT spawning real claude --bg processes. It exercises
# the hook in isolation with a stub pwt-goal.sh that records its invocation
# to a sentinel file. The test asserts the sentinel was/wasn't written.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/plan-w-team-route-prompt.sh"

# Test isolation: this test runs the route hook WITHOUT the kill-switch in
# Test A to prove the bypass reproduces. If this test is invoked from inside a
# /plan-w-team worker/supervisor session, the ambient environment already
# carries PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 (and AUTO_APPROVE_PUSH=1), which
# would leak into the inline-env hook invocation below and make Test A's hook
# honor the kill-switch — a spurious failure that has nothing to do with the
# product. Scrub both vars up front so Test A controls the env explicitly.
# (The companion plan-w-team-route-prompt-supervisor-env.test.sh does the same.)
unset PLAN_W_TEAM_DISABLE_PROMPT_ROUTE
unset PLAN_W_TEAM_AUTO_APPROVE_PUSH

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

# ─── Test harness: per-test sandboxed PROJECT_DIR with stub pwt-goal.sh ──────
make_sandbox() {
    local d
    d=$(mktemp -d -t pwt-recursion-XXXXXX)
    mkdir -p "$d/.claude/scripts"
    cat > "$d/.claude/scripts/pwt-goal.sh" <<'STUB'
#!/usr/bin/env bash
# Stub: record invocation to sentinel and emit a fake worker_sid.
# This is what would happen on a successful re-launch — the bug we're guarding.
SENTINEL="${PWT_TEST_SENTINEL:-/tmp/pwt-recursion-sentinel-$$}"
{
    echo "pwt-goal invoked args: $*"
    echo "env PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-unset}"
} >> "$SENTINEL"
# Emit fake worker_sid so the hook believes the spawn succeeded.
echo "worker_sid=deadbeef"
exit 0
STUB
    chmod +x "$d/.claude/scripts/pwt-goal.sh"
    echo "$d"
}

# Supervisor-bootstrap-shaped prompt (matches the production failure verbatim
# enough to demonstrate the bypass). Note leading `#` and embedded request.
SUPERVISOR_BOOTSTRAP='# /plan-w-team Outer Supervisor

You are the **outer supervisor** for an autonomous /plan-w-team run.

## Your worker

- **Session ID:** abc12345
- **Goal (verbatim user request):**

> use /plan-w-team to fix all bugs in the system

- **Started:** 2026-05-21T19:29:00Z

The worker is a separate `claude --bg` session executing /plan-w-team.'

# JSON-escape the prompt for stdin to the hook.
escape_json() {
    python3 -c "import sys,json; print(json.dumps({'prompt': sys.stdin.read()}))" 2>/dev/null
}

# ─── A: BEFORE-FIX BEHAVIOR — confirm bypass without the env var ─────────────
# This MUST trigger the hook (sentinel written). If it doesn't, the test is
# broken (the trigger pattern no longer matches the supervisor bootstrap).
echo "A: bypass reproduces without PLAN_W_TEAM_DISABLE_PROMPT_ROUTE"
SAND=$(make_sandbox)
SENTINEL=$(mktemp -t pwt-sentinel-XXXXXX)
rm -f "$SENTINEL"  # start empty (sentinel must not exist)
echo "$SUPERVISOR_BOOTSTRAP" | escape_json | \
    CLAUDE_PROJECT_DIR="$SAND" \
    PWT_TEST_SENTINEL="$SENTINEL" \
    PLAN_W_TEAM_HOOK_TEST_MODE=1 \
    "$HOOK" >/dev/null 2>&1
if [ -f "$SENTINEL" ]; then
    assert "supervisor bootstrap WITHOUT kill-switch DOES trigger" "yes" "yes"
else
    assert "supervisor bootstrap WITHOUT kill-switch DOES trigger" "yes" "no"
fi
rm -f "$SENTINEL"
rm -rf "$SAND"

# ─── B: AFTER-FIX BEHAVIOR — kill-switch suppresses re-trigger ───────────────
echo "B: kill-switch suppresses re-trigger"
SAND=$(make_sandbox)
SENTINEL=$(mktemp -t pwt-sentinel-XXXXXX)
rm -f "$SENTINEL"
echo "$SUPERVISOR_BOOTSTRAP" | escape_json | \
    CLAUDE_PROJECT_DIR="$SAND" \
    PWT_TEST_SENTINEL="$SENTINEL" \
    PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 \
    PLAN_W_TEAM_HOOK_TEST_MODE=1 \
    "$HOOK" >/dev/null 2>&1
if [ -f "$SENTINEL" ]; then
    assert "supervisor bootstrap WITH kill-switch does NOT trigger" "no" "yes"
else
    assert "supervisor bootstrap WITH kill-switch does NOT trigger" "no" "no"
fi
rm -f "$SENTINEL"
rm -rf "$SAND"

# ─── C: matrix — three bootstrap shapes that embed the trigger phrase ────────
echo "C: matrix — three shapes embedding the trigger phrase, all suppressed"
SAND=$(make_sandbox)

for shape in \
    "# heading prefix\n\nThe goal: use /plan-w-team to ship the thing" \
    "<!-- bootstrap -->\nuse /plan-w-team to fix something embedded" \
    "Status report: the user said \"use /plan-w-team to investigate logs\""; do
    SENTINEL=$(mktemp -t pwt-sentinel-XXXXXX)
    rm -f "$SENTINEL"
    printf '%b' "$shape" | escape_json | \
        CLAUDE_PROJECT_DIR="$SAND" \
        PWT_TEST_SENTINEL="$SENTINEL" \
        PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 \
        PLAN_W_TEAM_HOOK_TEST_MODE=1 \
        "$HOOK" >/dev/null 2>&1
    if [ -f "$SENTINEL" ]; then
        assert "shape suppressed: ${shape:0:40}…" "no" "yes"
    else
        assert "shape suppressed: ${shape:0:40}…" "no" "no"
    fi
    rm -f "$SENTINEL"
done
rm -rf "$SAND"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
