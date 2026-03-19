#!/bin/bash
# Claude Code CLI: Stop hook
# Logs when Claude finishes responding (after each turn)
# Useful for tracking response patterns and session activity

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.claude/state"
STOP_LOG="$STATE_DIR/response-log.txt"

# Create state directory if needed
mkdir -p "$STATE_DIR"

# Read JSON input from Claude Code
INPUT=$(cat 2>/dev/null || echo "{}")

# Parse input fields
if command -v jq &> /dev/null; then
    REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"' 2>/dev/null)
    TURN_COUNT=$(echo "$INPUT" | jq -r '.turn_count // ""' 2>/dev/null)
    TOOLS_USED=$(echo "$INPUT" | jq -r '.tools_used // []' 2>/dev/null)
else
    REASON=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason','unknown'))" 2>/dev/null || echo "unknown")
    TURN_COUNT=""
    TOOLS_USED="[]"
fi

# Get timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Only log significant stops (not every message)
# Reasons: end_turn, max_tokens, stop_sequence, tool_use, etc.
if [ "$REASON" = "end_turn" ] || [ "$REASON" = "max_tokens" ]; then
    cat >> "$STOP_LOG" << EOF
[$TIMESTAMP] RESPONSE_COMPLETE
  Reason: $REASON
  Turn: $TURN_COUNT
EOF
    echo "---" >> "$STOP_LOG"
fi

exit 0
