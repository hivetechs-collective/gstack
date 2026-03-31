#!/bin/bash
# Strategic Compact Suggester (PreToolUse: Edit|Write)
# Suggests /compact at logical intervals rather than relying on arbitrary auto-compaction

set -e

UTILS_DIR="$(cd "$(dirname "$0")/utils" && pwd)"
source "$UTILS_DIR/hook-profile.sh"
hook_gate "pre:edit:suggest-compact" "standard,strict"

INPUT=$(cat)

SESSION_ID="${CLAUDE_SESSION_ID:-default}"
# Sanitize session ID for filename
SAFE_ID=$(echo "$SESSION_ID" | sed 's/[^a-zA-Z0-9_-]/_/g')
COUNTER_FILE="/tmp/claude-tool-count-${SAFE_ID}"
THRESHOLD="${COMPACT_THRESHOLD:-50}"

# Read and increment counter
if [ -f "$COUNTER_FILE" ]; then
    COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
    COUNT=$((COUNT + 1))
else
    COUNT=1
fi

# Write updated count
echo "$COUNT" > "$COUNTER_FILE"

# Suggest at threshold
if [ "$COUNT" -eq "$THRESHOLD" ]; then
    echo "[StrategicCompact] $THRESHOLD tool calls reached - consider /compact if transitioning phases" >&2
fi

# Remind every 25 calls after threshold
if [ "$COUNT" -gt "$THRESHOLD" ] && [ $(( (COUNT - THRESHOLD) % 25 )) -eq 0 ]; then
    echo "[StrategicCompact] $COUNT tool calls - good checkpoint for /compact if context is stale" >&2
fi

echo "$INPUT"
