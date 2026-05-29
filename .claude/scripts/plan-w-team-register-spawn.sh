#!/usr/bin/env bash
# plan-w-team-register-spawn.sh
#
# Records a `claude --bg` child session to a per-SLUG registry so the parent
# /plan-w-team run can stop orphaned children at retro time.
#
# Usage:
#   plan-w-team-register-spawn.sh <session_id> <purpose> <slug> [parent_session_id] [spawned_by]
#
# Arguments:
#   session_id        8-char or full session id (matches `claude agents` / `claude stop`)
#   purpose           pwt-goal-launch | supervisor-spawn | stage-spawn | deep-audit-spawn | other
#   slug              feature slug used by the rest of the /plan-w-team pipeline
#   parent_session_id (optional) parent session id; pass empty string to skip
#   spawned_by        (optional) caller name (script basename or "supervisor")
#
# === FAIL-OPEN CONTRACT ===
# Registry write failures NEVER block the caller. Any internal error → exit 0
# silently so the parent spawn proceeds. The registry is observability for
# self-cleanup, never a gate.
#
# Spec: docs/specs/plan-w-team-self-cleanup.md
# Reader: .claude/commands/plan-w-team/07-retro.md §8j-sexies (cleanup loop)
# Cleanup: 07-retro.md removes the file on RETRO_SUCCESS=1.

set -u

fail_open() { exit 0; }
trap fail_open ERR

SESSION_ID="${1:-}"
PURPOSE="${2:-other}"
SLUG="${3:-}"
PARENT_SESSION_ID="${4:-}"
SPAWNED_BY="${5:-$(basename "${0##*-register-spawn.sh}" 2>/dev/null || echo unknown)}"

[ -z "$SESSION_ID" ] && exit 0
[ -z "$SLUG" ] && exit 0

# Validate purpose (loose — unknown values fold to "other")
case "$PURPOSE" in
    pwt-goal-launch|supervisor-spawn|stage-spawn|deep-audit-spawn|other) ;;
    *) PURPOSE="other" ;;
esac

# Worktree-aware state-dir resolution (mirrors surface-status.sh + minimal-retro.sh).
# Under `claude --bg`, CLAUDE_PROJECT_DIR points at the main checkout, but the
# active /plan-w-team run lives in a worktree under .claude/worktrees/<name>/.
# Use $PWD when it looks like a checkout (has its own .claude/) so writes land
# alongside the run's other state files.
PWD_STATE_DIR="$PWD/.claude/state"
FALLBACK_PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
FALLBACK_STATE_DIR="${FALLBACK_PROJECT_ROOT}/.claude/state"

if [ -d "$PWD/.claude" ]; then
    STATE_DIR="$PWD_STATE_DIR"
elif [ -n "$FALLBACK_PROJECT_ROOT" ]; then
    STATE_DIR="$FALLBACK_STATE_DIR"
else
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

REGISTRY="$STATE_DIR/plan-w-team-spawned-children-${SLUG}.jsonl"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build the row with jq for safe escaping; fall back to printf if jq is missing.
if command -v jq >/dev/null 2>&1; then
    LINE=$(jq -cn \
        --arg ts "$TS" \
        --arg session_id "$SESSION_ID" \
        --arg parent_session_id "$PARENT_SESSION_ID" \
        --arg purpose "$PURPOSE" \
        --arg slug "$SLUG" \
        --arg spawned_by "$SPAWNED_BY" \
        '{ts:$ts, session_id:$session_id, parent_session_id:$parent_session_id, purpose:$purpose, slug:$slug, spawned_by:$spawned_by}' \
        2>/dev/null) || LINE=""
else
    # Best-effort fallback. Strip quotes from inputs to keep JSON valid.
    sid_clean=${SESSION_ID//\"/}
    psid_clean=${PARENT_SESSION_ID//\"/}
    pur_clean=${PURPOSE//\"/}
    slug_clean=${SLUG//\"/}
    by_clean=${SPAWNED_BY//\"/}
    LINE=$(printf '{"ts":"%s","session_id":"%s","parent_session_id":"%s","purpose":"%s","slug":"%s","spawned_by":"%s"}' \
        "$TS" "$sid_clean" "$psid_clean" "$pur_clean" "$slug_clean" "$by_clean")
fi

[ -z "$LINE" ] && exit 0

# Append with atomic semantics — short writes on JSONL are tolerated by readers
# (jq -c reads line-by-line), but a torn write would still produce a bad row.
# Use `printf >>` which is atomic for writes under PIPE_BUF (4096 bytes on macOS/Linux).
printf '%s\n' "$LINE" >> "$REGISTRY" 2>/dev/null || true

exit 0
