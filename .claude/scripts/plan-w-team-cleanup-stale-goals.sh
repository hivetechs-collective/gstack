#!/usr/bin/env bash
# plan-w-team-cleanup-stale-goals.sh
#
# Removes goal state files (.claude/state/plan-w-team-goal-*.json) whose
# `terminal_state` is non-null — i.e., runs that already reached a terminal
# state (SUCCESS, USER_ESCALATION_HALT, LOW_CONFIDENCE_STREAK, or DEAD).
#
# Why this exists:
#   Retro stage §8j-quater (07-retro.md line 581) removes the per-SLUG goal
#   state file when RETRO_SUCCESS=1. But runs that stop before retro (early
#   halt, crash, manual termination) or with mismatched SLUG leave the state
#   file behind. Over time, stale terminal files accumulate and clutter
#   `.claude/state/`. This script is the periodic janitor that drops them.
#
# Idempotent: re-runs on the same directory are no-ops. Missing directory or
# zero matches is not an error.
#
# Usage:
#   plan-w-team-cleanup-stale-goals.sh [--state-dir DIR] [--dry-run] [--quiet]
#
# Exit codes:
#   0  always (fail-open — never block the caller)
#
# Output:
#   Per-deletion lines like "removed: <path> (terminal=SUCCESS, slug=…)"
#   Final summary "cleanup: removed=N, kept_pending=M, kept_corrupt=K"
#   Suppress all but errors with --quiet.

set -u

STATE_DIR=""
DRY_RUN=0
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --state-dir) STATE_DIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --quiet) QUIET=1; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 0 ;;
    esac
done

# Default: $PWD/.claude/state, falling back to git-toplevel for callers that
# run this from a subdir.
if [ -z "$STATE_DIR" ]; then
    if [ -d "$PWD/.claude/state" ]; then
        STATE_DIR="$PWD/.claude/state"
    else
        TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [ -n "$TOPLEVEL" ] && [ -d "$TOPLEVEL/.claude/state" ]; then
            STATE_DIR="$TOPLEVEL/.claude/state"
        else
            [ "$QUIET" = "1" ] || echo "cleanup: no state dir found (PWD=$PWD); exit 0"
            exit 0
        fi
    fi
fi

if [ ! -d "$STATE_DIR" ]; then
    [ "$QUIET" = "1" ] || echo "cleanup: state dir $STATE_DIR not found; exit 0"
    exit 0
fi

# jq required — if missing, fail-open silently.
if ! command -v jq >/dev/null 2>&1; then
    [ "$QUIET" = "1" ] || echo "cleanup: jq not available; skipping"
    exit 0
fi

REMOVED=0
KEPT_PENDING=0
KEPT_CORRUPT=0

shopt -s nullglob
for f in "$STATE_DIR"/plan-w-team-goal-*.json; do
    [ -f "$f" ] || continue
    if ! jq -e . "$f" >/dev/null 2>&1; then
        KEPT_CORRUPT=$((KEPT_CORRUPT + 1))
        [ "$QUIET" = "1" ] || echo "kept (corrupt JSON): $f"
        continue
    fi
    TERMINAL=$(jq -r '.terminal_state // ""' "$f")
    SLUG=$(jq -r '.slug // "?"' "$f")
    if [ -n "$TERMINAL" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            [ "$QUIET" = "1" ] || echo "would remove: $f (terminal=$TERMINAL, slug=$SLUG)"
        else
            rm -f "$f"
            [ "$QUIET" = "1" ] || echo "removed: $f (terminal=$TERMINAL, slug=$SLUG)"
        fi
        REMOVED=$((REMOVED + 1))
    else
        KEPT_PENDING=$((KEPT_PENDING + 1))
    fi
done
shopt -u nullglob

[ "$QUIET" = "1" ] || echo "cleanup: removed=$REMOVED, kept_pending=$KEPT_PENDING, kept_corrupt=$KEPT_CORRUPT (state_dir=$STATE_DIR, dry_run=$DRY_RUN)"
exit 0
