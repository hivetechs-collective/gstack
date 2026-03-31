#!/bin/bash
# Governance Audit Hook (PostToolUse: Bash|Write|Edit)
# Observational-only: logs governance events to JSONL for analysis.
# NEVER blocks operations. Only runs when CLAUDE_GOVERNANCE_CAPTURE=1.
#
# Logged events:
#   - File modifications (Write/Edit) with path and tool
#   - Bash commands with command text
#   - Timestamps and session context
#
# Output: ~/.claude/metrics/governance-audit.jsonl

set -e

UTILS_DIR="$(cd "$(dirname "$0")/utils" && pwd)"
source "$UTILS_DIR/hook-profile.sh"
hook_gate "post:edit:governance-audit" "strict"

# Additional gate: only active when explicitly enabled
if [ "${CLAUDE_GOVERNANCE_CAPTURE:-0}" != "1" ]; then
    cat
    exit 0
fi

INPUT=$(cat)

# Extract tool name from hook context
TOOL_NAME="${CLAUDE_TOOL_NAME:-unknown}"
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Extract relevant fields based on tool type
case "$TOOL_NAME" in
    Write|Edit)
        FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "unknown")
        EVENT_TYPE="file_modification"
        DETAIL="$FILE_PATH"
        ;;
    Bash)
        COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "unknown")
        EVENT_TYPE="command_execution"
        # Truncate long commands for log readability
        DETAIL=$(echo "$COMMAND" | head -c 200)
        ;;
    *)
        EVENT_TYPE="tool_use"
        DETAIL="$TOOL_NAME"
        ;;
esac

# Ensure metrics directory exists
METRICS_DIR="$HOME/.claude/metrics"
mkdir -p "$METRICS_DIR"

# Escape detail for JSON (basic: replace quotes and newlines)
SAFE_DETAIL=$(echo "$DETAIL" | tr '\n' ' ' | sed 's/"/\\"/g' | head -c 200)

# Append JSONL entry (never blocks, fire-and-forget)
echo "{\"timestamp\":\"$TIMESTAMP\",\"session_id\":\"$SESSION_ID\",\"event\":\"$EVENT_TYPE\",\"tool\":\"$TOOL_NAME\",\"detail\":\"$SAFE_DETAIL\"}" >> "$METRICS_DIR/governance-audit.jsonl" 2>/dev/null || true

echo "$INPUT"
