#!/bin/bash
# pwt-status — diagnostic listing utility for /plan-w-team runs
#
# Read-only enumeration of active workflow locks, goal-state files, and their
# terminal status. Useful when multiple /plan-w-team runs are concurrent or
# one is suspected stuck.
#
# Spec: docs/specs/pwt-status-utility.md
# Usage: pwt-status.sh [-h|--help]
# Exit: 0 = listing emitted (including the "no active runs" case)
#       2 = missing dependency (jq)

set -u

usage() {
    cat <<'EOF'
Usage: pwt-status.sh [-h|--help]

Lists active /plan-w-team runs by inspecting .claude/state/ for workflow
locks and goal-state files. Read-only: makes no state modifications.

Columns:
  SLUG          — feature slug from the goal-state filename
  LOCK          — active (PID alive) | stale (PID dead) | missing
  LOCK_PID      — owning process ID, or '-' if no lock
  GOAL_TERMINAL — SUCCESS | USER_ESCALATION_HALT | LOW_CONFIDENCE_STREAK | pending | (corrupt)

Exits 0 always (including the no-runs case) unless a hard dependency is
missing (exit 2 for jq).
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
    echo "pwt-status: jq required — install with 'brew install jq'" >&2
    exit 2
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
STATE_DIR="$PROJECT_ROOT/.claude/state"

if [ ! -d "$STATE_DIR" ]; then
    echo "No active /plan-w-team runs"
    exit 0
fi

# Collect SLUGs from both lock dirs and goal-state files
SLUGS=$(
    {
        find "$STATE_DIR" -maxdepth 1 -type d -name 'plan-w-team-workflow-*.lock' \
            -exec basename {} .lock \; 2>/dev/null | sed 's/^plan-w-team-workflow-//'
        find "$STATE_DIR" -maxdepth 1 -type f -name 'plan-w-team-goal-*.json' \
            -exec basename {} .json \; 2>/dev/null | sed 's/^plan-w-team-goal-//'
    } | sort -u
)

if [ -z "$SLUGS" ]; then
    echo "No active /plan-w-team runs"
    exit 0
fi

# Header row
printf '%-32s  %-8s  %-10s  %s\n' "SLUG" "LOCK" "LOCK_PID" "GOAL_TERMINAL"
printf '%-32s  %-8s  %-10s  %s\n' "----" "----" "--------" "-------------"

while IFS= read -r SLUG; do
    [ -z "$SLUG" ] && continue
    LOCK_DIR="$STATE_DIR/plan-w-team-workflow-${SLUG}.lock"
    GOAL_FILE="$STATE_DIR/plan-w-team-goal-${SLUG}.json"

    # Lock state
    LOCK_STATE="missing"
    LOCK_PID="-"
    if [ -d "$LOCK_DIR" ]; then
        LOCK_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "?")
        if [ "$LOCK_PID" != "?" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
            LOCK_STATE="active"
        else
            LOCK_STATE="stale"
        fi
    fi

    # Goal terminal state
    if [ -f "$GOAL_FILE" ]; then
        if jq -e . "$GOAL_FILE" >/dev/null 2>&1; then
            TERMINAL=$(jq -r '.terminal_state // "pending"' "$GOAL_FILE")
        else
            TERMINAL="(corrupt)"
        fi
    else
        TERMINAL="(no goal file)"
    fi

    printf '%-32s  %-8s  %-10s  %s\n' "$SLUG" "$LOCK_STATE" "$LOCK_PID" "$TERMINAL"
done <<< "$SLUGS"

exit 0
