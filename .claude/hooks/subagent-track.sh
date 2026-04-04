#!/bin/bash
# Claude Code CLI: Subagent tracking hook
# Logs subagent start/stop events for coordination visibility
# Used by both SubagentStart and SubagentStop hooks

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.claude/state"
AGENT_LOG="$STATE_DIR/agent-activity.log"

# Create state directory if needed
mkdir -p "$STATE_DIR"

# Read JSON input from Claude Code
INPUT=$(cat 2>/dev/null || echo "{}")

# Parse input fields from actual SubagentStart/SubagentStop event schema:
#   SubagentStart: { session_id, agent_id, agent_type, cwd, hook_event_name }
#   SubagentStop:  { ...start, agent_transcript_path, last_assistant_message, permission_mode }
if command -v jq &> /dev/null; then
    EVENT_TYPE=$(echo "$INPUT" | jq -r '.hook_event_name // "unknown"' 2>/dev/null)
    AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // "unknown"' 2>/dev/null)
    AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "unknown"' 2>/dev/null)
    PERM_MODE=$(echo "$INPUT" | jq -r '.permission_mode // ""' 2>/dev/null)
    LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null | head -c 100)
else
    EVENT_TYPE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hook_event_name','unknown'))" 2>/dev/null || echo "unknown")
    AGENT_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent_id','unknown'))" 2>/dev/null || echo "unknown")
    AGENT_TYPE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent_type','unknown'))" 2>/dev/null || echo "unknown")
    PERM_MODE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('permission_mode',''))" 2>/dev/null || echo "")
    LAST_MSG=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('last_assistant_message','')[:100])" 2>/dev/null || echo "")
fi

# Get timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Determine event from hook_event_name or script arg
if [ "$EVENT_TYPE" = "SubagentStart" ] || [[ "$1" == "start" ]]; then
    EVENT_TYPE="START"
elif [ "$EVENT_TYPE" = "SubagentStop" ] || [[ "$1" == "stop" ]]; then
    EVENT_TYPE="STOP"
fi

# Log the event
if [ "$EVENT_TYPE" = "START" ]; then
    cat >> "$AGENT_LOG" << EOF
[$TIMESTAMP] SUBAGENT_START
  ID: $AGENT_ID
  Type: $AGENT_TYPE
EOF
elif [ "$EVENT_TYPE" = "STOP" ]; then
    cat >> "$AGENT_LOG" << EOF
[$TIMESTAMP] SUBAGENT_STOP
  ID: $AGENT_ID
  Type: $AGENT_TYPE
  Mode: $PERM_MODE
  Last: $LAST_MSG
EOF
else
    cat >> "$AGENT_LOG" << EOF
[$TIMESTAMP] SUBAGENT_EVENT
  ID: $AGENT_ID
  Raw: $INPUT
EOF
fi

echo "---" >> "$AGENT_LOG"

exit 0
