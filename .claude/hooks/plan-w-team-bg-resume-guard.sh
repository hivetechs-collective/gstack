#!/usr/bin/env bash
# plan-w-team-bg-resume-guard.sh — SessionStart hook (AC4: bg-worker resume staleness self-exit)
#
# The Claude Code bg-session daemon auto-resumes persisted `claude --bg` workers on
# restart (e.g. after a CLI version bump). A worker whose `/plan-w-team` directive
# ALREADY shipped (open PR / merged) then starts churning again and can push a
# duplicate/conflicting commit to that PR's branch (2026-06-06 incident). This hook
# fires on SessionStart and, for a resumed worker whose goal-state is terminal OR
# whose target branch is already shipped, STOPS the session (self-exit) instead of
# letting it re-run.
#
# Mechanism: delegate the reconciliation to `pwt-goal.sh --resume-staleness-check`
# (the canonical staleness predicate, tied to shared/goal-conditions.md terminal
# anchors). On a STALE verdict (exit 0) for THIS session id, request a stop via
# `claude stop <sid>` (backgrounded — a hook cannot synchronously stop its own
# session) and emit a systemMessage so the transcript records the self-exit.
#
# Self-limiting: the staleness check returns UNKNOWN (exit 2) unless a goal-state
# row whose worker_sid matches this session id exists, so non-pwt sessions (and the
# user's own interactive session) are never touched. A freshly-spawned worker is
# never STALE (terminal_state null + branch not shipped → LIVE), so first-run
# workers proceed normally.
#
# Input: SessionStart hook JSON on stdin: { session_id, source, cwd, ... }.
# Output: exit 0 always (SessionStart cannot block); side effect is the stop request.
#
# Env:
#   PLAN_W_TEAM_BG_RESUME_GUARD_DISABLE=1   no-op (exit 0)
#   PWT_RESUME_GUARD_CHECK_CMD              override the staleness-check command (tests)
#   PWT_RESUME_GUARD_STOP_CMD               override the stop command (default: claude stop) (tests)
#   CLAUDE_BIN                              claude binary (default: claude)
#
# Tests: .claude/hooks/plan-w-team-bg-resume-guard.test.sh

set -u

[ "${PLAN_W_TEAM_BG_RESUME_GUARD_DISABLE:-0}" = "1" ] && exit 0

# ─── read hook input (JSON on stdin) ──────────────────────────────────────
INPUT="$(cat 2>/dev/null || echo "")"
extract() {  # $1 = json key → value or empty (python; jq may be absent)
    printf '%s' "$INPUT" | python3 -c '
import json,sys
key=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: print(""); sys.exit(0)
v=d.get(key)
print(v if isinstance(v,str) else (json.dumps(v) if v is not None else ""))' "$1" 2>/dev/null
}

SID="$(extract session_id)"
[ -z "$SID" ] && SID="$(extract sessionId)"
SOURCE="$(extract source)"
HOOK_CWD="$(extract cwd)"
[ -z "$HOOK_CWD" ] && HOOK_CWD="$PWD"

# Nothing to check without a session id.
[ -z "$SID" ] && exit 0

# ─── locate pwt-goal.sh (sibling scripts dir; cwd; main checkout) ──────────
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PWT_GOAL=""
for cand in \
    "$SELF_DIR/../scripts/pwt-goal.sh" \
    "$HOOK_CWD/.claude/scripts/pwt-goal.sh"; do
    if [ -x "$cand" ]; then PWT_GOAL="$cand"; break; fi
done

# ─── run the staleness check (delegated; overridable for tests) ────────────
if [ -n "${PWT_RESUME_GUARD_CHECK_CMD:-}" ]; then
    ( cd "$HOOK_CWD" 2>/dev/null && eval "$PWT_RESUME_GUARD_CHECK_CMD" >/dev/null 2>&1 )
    VERDICT_RC=$?
elif [ -n "$PWT_GOAL" ]; then
    ( cd "$HOOK_CWD" 2>/dev/null && "$PWT_GOAL" --resume-staleness-check --sid "$SID" >/dev/null 2>&1 )
    VERDICT_RC=$?
else
    exit 0   # cannot resolve the checker → fail-open (never block a resume)
fi

# Exit codes: 0 STALE, 1 LIVE, 2 UNKNOWN. Only STALE triggers self-exit.
if [ "$VERDICT_RC" = "0" ]; then
    STOP_CMD="${PWT_RESUME_GUARD_STOP_CMD:-${CLAUDE_BIN:-claude} stop}"
    # Background the stop so the hook returns promptly; a hook cannot synchronously
    # terminate its own session.
    ( $STOP_CMD "$SID" >/dev/null 2>&1 & ) 2>/dev/null || true
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"⛔ /plan-w-team resume guard: this bg worker's directive is ALREADY shipped/terminal (resume-staleness-check STALE). Stopping the session to avoid a duplicate/conflicting push. Do NOT re-run the directive."},"systemMessage":"⛔ /plan-w-team bg-resume-guard: directive already shipped — self-exiting resumed worker ${SID} (source=${SOURCE:-unknown})."}
EOF
    exit 0
fi

exit 0
