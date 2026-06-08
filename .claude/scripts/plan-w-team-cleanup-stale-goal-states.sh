#!/usr/bin/env bash
# plan-w-team-cleanup-stale-goal-states.sh
#
# Remove `.claude/state/plan-w-team-goal-<SLUG>.json` files whose
# `terminal_state` equals `"SUCCESS"`. These files SHOULD have been deleted
# by `07-retro.md` §8j-quater on `RETRO_SUCCESS=1` but commit 409e265
# (which added that cleanup path) only handles runs going forward. Files
# from earlier successful runs persist on disk as dead weight — they don't
# block the goal-evaluator hook (it iterates all files and naturally skips
# terminated ones), but they accumulate forever without GC.
#
# PRESERVED states (signal worth keeping for inspection):
#   - null                       — run still in flight
#   - USER_ESCALATION_HALT       — hard-gate pause site needs user attention
#   - LOW_CONFIDENCE_STREAK      — supervisor escalation needs investigation
#   - DEAD                       — worker died unexpectedly
#
# REMOVED states:
#   - SUCCESS                    — retro completed, file should already be gone
#
# Usage:
#   plan-w-team-cleanup-stale-goal-states.sh                    # silent unless removals
#   plan-w-team-cleanup-stale-goal-states.sh --verbose          # log every action
#   plan-w-team-cleanup-stale-goal-states.sh --quiet            # suppress even the summary
#   plan-w-team-cleanup-stale-goal-states.sh --dry-run          # list, don't delete
#   STATE_DIR=/path/to/state plan-w-team-cleanup-stale-goal-states.sh   # override
#
# This is the SINGLE stale-goal-state janitor (reconciled 2026-06-08): both
# session-start (no args) and 07-retro.md (--quiet) call it. It only ever removes
# terminal_state=SUCCESS and PRESERVES escalation/dead/null, so neither caller can
# delete a goal-state another run left for inspection. (Replaces the second
# all-terminal cleaner plan-w-team-cleanup-stale-goals.sh, removed in the same change.)
#
# Exit code: always 0 (best-effort; never block session start)

set -u

STATE_DIR="${STATE_DIR:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}/.claude/state}"
VERBOSE=0
DRY_RUN=0
QUIET=0

for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=1 ;;
        --quiet|-q) QUIET=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --help|-h)
            sed -nE 's/^# ?//; 1,/^$/p' "$0" | head -40
            exit 0
            ;;
        *) ;;  # ignore unknown args (best-effort caller)
    esac
done

[ -d "$STATE_DIR" ] || exit 0

REMOVED=0

# bash 3.2 + nullglob-safe iteration
for f in "$STATE_DIR"/plan-w-team-goal-*.json; do
    [ -f "$f" ] || continue

    # Extract terminal_state without requiring jq. The field is a string
    # value on its own line in our writer's output, but we also handle
    # compact JSON. Prefer jq when available for correctness, fall back to
    # grep+sed for portability (matches the same fallback chain used in
    # plan-w-team-goal-evaluator.sh).
    STATE=""
    if command -v jq >/dev/null 2>&1; then
        STATE=$(jq -r '.terminal_state // empty' "$f" 2>/dev/null || echo "")
    fi
    if [ -z "$STATE" ]; then
        STATE=$(grep -oE '"terminal_state"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null \
            | head -1 \
            | sed -E 's/.*"terminal_state"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' \
            || echo "")
    fi

    if [ "$STATE" = "SUCCESS" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "[dry-run] would remove $f (terminal_state=SUCCESS)"
        else
            rm -f "$f" 2>/dev/null && REMOVED=$((REMOVED + 1))
            [ "$VERBOSE" = "1" ] && echo "removed $f (terminal_state=SUCCESS)"
        fi
    elif [ "$VERBOSE" = "1" ]; then
        echo "kept $f (terminal_state=${STATE:-null})"
    fi
done

if [ "$REMOVED" -gt 0 ] && [ "$DRY_RUN" != "1" ] && [ "$QUIET" != "1" ]; then
    echo "🧹 cleaned $REMOVED stale SUCCESS goal-state file(s)"
fi

exit 0
