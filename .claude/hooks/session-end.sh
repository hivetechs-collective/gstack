#!/bin/bash
# CleanScale: Session end monitoring
# Logs session completion for monitoring and verification

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.claude/state"
SESSION_LOG="$STATE_DIR/session-log.txt"
UTILS_DIR="$PROJECT_ROOT/.claude/hooks/utils"

# Source JSON logger if available
if [ -f "$UTILS_DIR/json-logger.sh" ]; then
    source "$UTILS_DIR/json-logger.sh"
    LOGGING_ENABLED=true
else
    LOGGING_ENABLED=false
fi

# Create state directory if needed
mkdir -p "$STATE_DIR"

# Read JSON input from Claude Code
INPUT=$(cat 2>/dev/null || echo "{}")
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','unknown'))" 2>/dev/null || echo "unknown")
REASON=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason','unknown'))" 2>/dev/null || echo "unknown")

# Get timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Get git state
BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "unknown")
UNCOMMITTED=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

# Log session end
cat >> "$SESSION_LOG" << EOF
[$TIMESTAMP] SESSION_END
  Session ID: $SESSION_ID
  Reason: $REASON
  Branch: $BRANCH
  Uncommitted: $UNCOMMITTED files
EOF

# JSON log session end
if [ "$LOGGING_ENABLED" = "true" ]; then
    log_session "end" "{\"reason\":\"$REASON\",\"branch\":\"$BRANCH\",\"uncommitted\":$UNCOMMITTED}"
fi

# Check if state was saved (for compaction verification)
STATE_FILE="$STATE_DIR/session-state.md"
COMPACT_LOG="$STATE_DIR/compact-log.txt"

# Verify compaction protection is working
if [ "$REASON" = "compact" ] || [ "$REASON" = "auto_compact" ]; then
    if [ -f "$STATE_FILE" ]; then
        echo "  Compaction State: SAVED ✓" >> "$SESSION_LOG"
    else
        echo "  Compaction State: MISSING ✗ (PreCompact hook may have failed)" >> "$SESSION_LOG"
    fi
fi

echo "---" >> "$SESSION_LOG"

# =================================================================
# COMPOUND: Capture learnings from this session
# =================================================================
COMPOUND_DIR="$PROJECT_ROOT/.claude/hooks/compound"

if [ -x "$COMPOUND_DIR/capture-learnings.sh" ]; then
    "$COMPOUND_DIR/capture-learnings.sh"
fi

exit 0
