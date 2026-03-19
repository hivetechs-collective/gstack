#!/bin/bash
# Autonomous Pipeline: User prompt check hook
# Checks for blocked features based on .claude/project.json configuration
# Generic template - reads from .claude/project.json

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/.claude/project.json"
LIB_DIR="$PROJECT_ROOT/.claude/lib"

# Source configuration helper
if [ -f "$LIB_DIR/config.sh" ]; then
    source "$LIB_DIR/config.sh"
fi

# Read user prompt from stdin
PROMPT=$(cat)

# Check if any features are blocked
if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
    BLOCKED_COUNT=$(jq '[.features[] | select(.status == "blocked")] | length' "$CONFIG_FILE" 2>/dev/null || echo "0")

    if [ "$BLOCKED_COUNT" != "0" ] && [ "$BLOCKED_COUNT" != "" ]; then
        # Get blocked feature keywords
        BLOCKED_NAMES=$(jq -r '.features[] | select(.status == "blocked") | .name' "$CONFIG_FILE" 2>/dev/null)

        # Check if prompt mentions any blocked features
        while IFS= read -r feature; do
            if echo "$PROMPT" | grep -qi "$feature"; then
                echo ""
                echo "  WARNING: Feature '$feature' is currently BLOCKED"
                echo "---------------------------------------------------------------"
                echo "This feature requires executive review before implementation."
                echo "Check .claude/project.json for feature status."
                echo "---------------------------------------------------------------"
                echo ""
                # Note: We warn but don't block (exit 0)
            fi
        done <<< "$BLOCKED_NAMES"
    fi
fi

# Allow all prompts through
exit 0
