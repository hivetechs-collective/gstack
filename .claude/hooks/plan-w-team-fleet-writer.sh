#!/bin/bash
# plan-w-team Fleet State Writer Hook
#
# Fired by SubagentStart and SubagentStop to record agent lifecycle events
# into .claude/state/plan-w-team-fleet-<SLUG>.jsonl. The SLUG is derived from
# the active workflow lock so the hook participates in /plan-w-team runs
# without requiring lead-side env wiring.
#
# Spec: docs/specs/pwt-supervisor-goal.md
# Reader: .claude/scripts/plan-w-team-fleet-query.sh
# Kill switch: PLAN_W_TEAM_FLEET_DISABLE=1
#
# Contract: NEVER block agent workflow. All error paths exit 0.

set -u

[ "${PLAN_W_TEAM_FLEET_DISABLE:-}" = "1" ] && exit 0

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
STATE_DIR="$PROJECT_ROOT/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

INPUT=$(cat 2>/dev/null || echo "{}")
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if command -v jq >/dev/null 2>&1; then
    EVENT_NAME=$(echo "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null)
    AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)
    AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null)
    CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
    LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null | head -c 100 | tr -d '\n\r' | sed 's/"/\\"/g')
else
    EVENT_NAME=""
    AGENT_ID=""
    AGENT_TYPE=""
    CWD=""
    LAST_MSG=""
fi

# Fall back to positional arg ($1 = start|stop) when hook_event_name absent
if [ -z "$EVENT_NAME" ]; then
    case "${1:-}" in
        start) EVENT_NAME="SubagentStart" ;;
        stop)  EVENT_NAME="SubagentStop"  ;;
    esac
fi

case "$EVENT_NAME" in
    SubagentStart) EVENT="spawn"    ;;
    SubagentStop)  EVENT="complete" ;;
    *)             exit 0           ;;
esac

# Derive SLUG from active workflow lock(s)
SLUG=""
shopt -s nullglob
LOCK_DIRS=("$STATE_DIR"/plan-w-team-workflow-*.lock)
shopt -u nullglob

if [ "${#LOCK_DIRS[@]}" -eq 0 ]; then
    exit 0
elif [ "${#LOCK_DIRS[@]}" -eq 1 ]; then
    LOCK_BASENAME=$(basename "${LOCK_DIRS[0]}")
    SLUG="${LOCK_BASENAME#plan-w-team-workflow-}"
    SLUG="${SLUG%.lock}"
else
    NEWEST_LOCK=$(ls -t -d "${LOCK_DIRS[@]}" 2>/dev/null | head -1)
    LOCK_BASENAME=$(basename "$NEWEST_LOCK")
    SLUG="${LOCK_BASENAME#plan-w-team-workflow-}"
    SLUG="${SLUG%.lock}"
    echo "[fleet-writer] WARN: ${#LOCK_DIRS[@]} active workflow locks; using newest ($SLUG)" >&2
fi

FLEET_FILE="$STATE_DIR/plan-w-team-fleet-${SLUG}.jsonl"

# If agent_id is missing, write an error row so retro can surface the gap
if [ -z "$AGENT_ID" ]; then
    printf '{"ts":"%s","event":"error","slug":"%s","reason":"missing agent_id in %s payload"}\n' \
        "$TS" "$SLUG" "$EVENT_NAME" >> "$FLEET_FILE" 2>/dev/null
    exit 0
fi

if [ "$EVENT" = "spawn" ]; then
    printf '{"ts":"%s","event":"spawn","slug":"%s","agent_id":"%s","agent_type":"%s","cwd":"%s"}\n' \
        "$TS" "$SLUG" "$AGENT_ID" "$AGENT_TYPE" "$CWD" >> "$FLEET_FILE" 2>/dev/null
else
    printf '{"ts":"%s","event":"complete","slug":"%s","agent_id":"%s","last_msg":"%s"}\n' \
        "$TS" "$SLUG" "$AGENT_ID" "$LAST_MSG" >> "$FLEET_FILE" 2>/dev/null
fi

exit 0
