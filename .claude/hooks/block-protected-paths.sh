#!/bin/bash
# Autonomous Pipeline: Path protection hook
# Blocks writes to protected paths based on .claude/project.json configuration
# Generic template - reads from .claude/project.json

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/.claude/project.json"
LIB_DIR="$PROJECT_ROOT/.claude/lib"

# Source configuration helper
if [ -f "$LIB_DIR/config.sh" ]; then
    source "$LIB_DIR/config.sh"
fi

# Read tool input from stdin
INPUT=$(cat 2>/dev/null || echo "{}")

# Extract file path from input
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; data=json.load(sys.stdin); print(data.get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")

if [ -z "$FILE_PATH" ]; then
    # No file path in input, allow operation
    exit 0
fi

# Check if file is in a protected path
if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
    PROTECTED_PATHS=$(jq -r '.governance.protectedPaths[]?' "$CONFIG_FILE" 2>/dev/null)

    while IFS= read -r protected; do
        if [ -n "$protected" ]; then
            # Convert glob pattern to regex
            pattern=$(echo "$protected" | sed 's/\*/.*/g')
            if echo "$FILE_PATH" | grep -qE "$pattern"; then
                # Output JSON with systemMessage (Claude Code v1.0.64+)
                # This provides better integration with Claude's context display
                cat << JSONEOF
{
  "decision": "block",
  "reason": "Protected path: $protected",
  "systemMessage": "⛔ BLOCKED: $FILE_PATH is in protected path ($protected). Check .claude/project.json governance.protectedPaths to modify permissions."
}
JSONEOF
                exit 1
            fi
        fi
    done <<< "$PROTECTED_PATHS"

    # Check blocked features' paths
    BLOCKED_PATHS=$(jq -r '.features[] | select(.status == "blocked") | .path' "$CONFIG_FILE" 2>/dev/null)

    while IFS= read -r blocked; do
        if [ -n "$blocked" ]; then
            pattern=$(echo "$blocked" | sed 's/\*/.*/g')
            if echo "$FILE_PATH" | grep -qE "$pattern"; then
                FEATURE_NAME=$(jq -r ".features[] | select(.path == \"$blocked\") | .name" "$CONFIG_FILE" 2>/dev/null)
                # Output JSON with systemMessage (Claude Code v1.0.64+)
                cat << JSONEOF
{
  "decision": "block",
  "reason": "Feature not approved: $FEATURE_NAME",
  "systemMessage": "⛔ BLOCKED: Feature '$FEATURE_NAME' requires approval. Path $FILE_PATH is blocked until feature is unblocked in .claude/project.json."
}
JSONEOF
                exit 1
            fi
        fi
    done <<< "$BLOCKED_PATHS"
fi

# Allow operation
exit 0
