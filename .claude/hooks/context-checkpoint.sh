#!/bin/bash
# Autonomous Pipeline: Context Checkpoint Script
# Saves current session state for recovery after compaction
# Generic template - works with any project
#
# Usage: Called by PreCompact hook or manually via /checkpoint

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.claude/state"
CHECKPOINT_DIR="$STATE_DIR/checkpoints"
LIB_DIR="$PROJECT_ROOT/.claude/lib"

# Source configuration helper
if [ -f "$LIB_DIR/config.sh" ]; then
    source "$LIB_DIR/config.sh"
fi

PROJECT_NAME="${PROJECT_NAME:-$(get_project_name 2>/dev/null || echo 'Project')}"

# Ensure directories exist
mkdir -p "$CHECKPOINT_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TIMESTAMP_FILE=$(date +%s)

# Get git state
BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "unknown")
LAST_COMMIT=$(git -C "$PROJECT_ROOT" log -1 --format="%h %s" 2>/dev/null || echo "unknown")
UNCOMMITTED=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

# Get uncommitted file list
UNCOMMITTED_FILES=$(git -C "$PROJECT_ROOT" status --short 2>/dev/null | head -20)

# Check for running background tasks (generic path pattern)
TASKS_DIR="/tmp/claude"
RUNNING_TASKS=0
if [ -d "$TASKS_DIR" ]; then
    RUNNING_TASKS=$(find "$TASKS_DIR" -name "*.pid" 2>/dev/null | wc -l | tr -d ' ')
fi

# Create checkpoint file
CHECKPOINT_FILE="$CHECKPOINT_DIR/checkpoint-$TIMESTAMP_FILE.json"

cat > "$CHECKPOINT_FILE" << EOF
{
  "project": "$PROJECT_NAME",
  "timestamp": "$TIMESTAMP",
  "branch": "$BRANCH",
  "last_commit": "$LAST_COMMIT",
  "uncommitted_count": $UNCOMMITTED,
  "running_tasks": $RUNNING_TASKS,
  "uncommitted_files": [
$(echo "$UNCOMMITTED_FILES" | while read -r line; do
  [ -n "$line" ] && echo "    \"$line\","
done | sed '$ s/,$//')
  ],
  "notes": "Auto-saved before context compaction"
}
EOF

# Keep only last 10 checkpoints
ls -t "$CHECKPOINT_DIR"/checkpoint-*.json 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null

echo "==============================================================="
echo "  CONTEXT CHECKPOINT SAVED"
echo "==============================================================="
echo ""
echo " Project: $PROJECT_NAME"
echo " Checkpoint: $CHECKPOINT_FILE"
echo " Branch: $BRANCH"
echo " Last Commit: $LAST_COMMIT"
echo " Uncommitted: $UNCOMMITTED files"
echo " Running Tasks: $RUNNING_TASKS"
echo ""

if [ "$UNCOMMITTED" -gt 0 ]; then
    echo " UNCOMMITTED FILES:"
    echo "$UNCOMMITTED_FILES" | head -10
    if [ "$UNCOMMITTED" -gt 10 ]; then
        echo "   ... and $((UNCOMMITTED - 10)) more"
    fi
    echo ""
    echo " RECOMMENDATION: Commit before compaction"
    echo "   git add . && git commit -m 'wip: pre-compact checkpoint'"
fi

echo "==============================================================="

exit 0
