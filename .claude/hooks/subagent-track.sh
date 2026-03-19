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

# Parse input fields (compatible with both jq and python)
if command -v jq &> /dev/null; then
    EVENT_TYPE=$(echo "$INPUT" | jq -r '.event_type // "unknown"' 2>/dev/null)
    AGENT_NAME=$(echo "$INPUT" | jq -r '.agent_name // .name // "unknown"' 2>/dev/null)
    AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // .id // "unknown"' 2>/dev/null)
    TASK=$(echo "$INPUT" | jq -r '.task // .prompt // ""' 2>/dev/null | head -c 100)
    MODEL=$(echo "$INPUT" | jq -r '.model // "inherit"' 2>/dev/null)
    DURATION=$(echo "$INPUT" | jq -r '.duration_ms // ""' 2>/dev/null)
    EXIT_CODE=$(echo "$INPUT" | jq -r '.exit_code // ""' 2>/dev/null)
else
    EVENT_TYPE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('event_type','unknown'))" 2>/dev/null || echo "unknown")
    AGENT_NAME=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent_name',d.get('name','unknown')))" 2>/dev/null || echo "unknown")
    AGENT_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('agent_id',d.get('id','unknown')))" 2>/dev/null || echo "unknown")
    TASK=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('task',d.get('prompt',''))[:100])" 2>/dev/null || echo "")
    MODEL=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('model','inherit'))" 2>/dev/null || echo "inherit")
    DURATION=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('duration_ms',''))" 2>/dev/null || echo "")
    EXIT_CODE=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('exit_code',''))" 2>/dev/null || echo "")
fi

# Get timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Determine event type from script name if not in input
SCRIPT_NAME=$(basename "$0")
if [ "$EVENT_TYPE" = "unknown" ]; then
    if [[ "$SCRIPT_NAME" == *"start"* ]] || [[ "$1" == "start" ]]; then
        EVENT_TYPE="START"
    elif [[ "$SCRIPT_NAME" == *"stop"* ]] || [[ "$1" == "stop" ]]; then
        EVENT_TYPE="STOP"
    fi
fi

# Log the event
if [ "$EVENT_TYPE" = "START" ] || [ "$EVENT_TYPE" = "start" ]; then
    cat >> "$AGENT_LOG" << EOF
[$TIMESTAMP] SUBAGENT_START
  Agent: $AGENT_NAME
  ID: $AGENT_ID
  Model: $MODEL
  Task: $TASK
EOF
elif [ "$EVENT_TYPE" = "STOP" ] || [ "$EVENT_TYPE" = "stop" ]; then
    # Format duration if available
    DURATION_STR=""
    if [ -n "$DURATION" ] && [ "$DURATION" != "" ] && [ "$DURATION" != "null" ]; then
        DURATION_SEC=$((DURATION / 1000))
        DURATION_STR=" (${DURATION_SEC}s)"
    fi

    # Format exit status
    STATUS="completed"
    if [ -n "$EXIT_CODE" ] && [ "$EXIT_CODE" != "0" ] && [ "$EXIT_CODE" != "" ] && [ "$EXIT_CODE" != "null" ]; then
        STATUS="failed (exit $EXIT_CODE)"
    fi

    cat >> "$AGENT_LOG" << EOF
[$TIMESTAMP] SUBAGENT_STOP
  Agent: $AGENT_NAME
  ID: $AGENT_ID
  Status: $STATUS$DURATION_STR
EOF
else
    cat >> "$AGENT_LOG" << EOF
[$TIMESTAMP] SUBAGENT_EVENT
  Agent: $AGENT_NAME
  ID: $AGENT_ID
  Raw: $INPUT
EOF
fi

echo "---" >> "$AGENT_LOG"

exit 0
