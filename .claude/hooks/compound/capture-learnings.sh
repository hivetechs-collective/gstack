#!/bin/bash
# Compound: Capture learnings at session end
# Analyzes git commits and extracts patterns automatically

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.claude/state"
LEARNINGS_FILE="$STATE_DIR/learnings.jsonl"
PATTERNS_FILE="$STATE_DIR/patterns-detected.md"

mkdir -p "$STATE_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SESSION_ID="${CLAUDE_SESSION_ID:-$(date +%s)}"

# Get commits from this session (last 2 hours as proxy)
COMMITS=$(git -C "$PROJECT_ROOT" log --since="2 hours ago" --oneline 2>/dev/null || echo "")

if [ -z "$COMMITS" ]; then
    exit 0
fi

COMMIT_COUNT=$(echo "$COMMITS" | wc -l | tr -d ' ')

# Analyze commit patterns
FEAT_COUNT=$(echo "$COMMITS" | grep -c "^[a-f0-9]* feat" || echo "0")
FIX_COUNT=$(echo "$COMMITS" | grep -c "^[a-f0-9]* fix" || echo "0")
REFACTOR_COUNT=$(echo "$COMMITS" | grep -c "^[a-f0-9]* refactor" || echo "0")

# Get files changed
FILES_CHANGED=$(git -C "$PROJECT_ROOT" diff --name-only HEAD~${COMMIT_COUNT}..HEAD 2>/dev/null | head -20 || echo "")

# Detect file type patterns
TS_FILES=$(echo "$FILES_CHANGED" | grep -c "\.tsx\?$" || echo "0")
RS_FILES=$(echo "$FILES_CHANGED" | grep -c "\.rs$" || echo "0")
HOOK_FILES=$(echo "$FILES_CHANGED" | grep -c "hooks/" || echo "0")
AGENT_FILES=$(echo "$FILES_CHANGED" | grep -c "agents/" || echo "0")

# Extract component patterns (new files in specific directories)
NEW_COMPONENTS=$(git -C "$PROJECT_ROOT" diff --name-status HEAD~${COMMIT_COUNT}..HEAD 2>/dev/null | grep "^A" | awk '{print $2}' || echo "")
NEW_COMPONENT_COUNT=$(echo "$NEW_COMPONENTS" | grep -v "^$" | wc -l | tr -d ' ')

# Build learning entry
LEARNING_TYPE="session_summary"
TAGS="[]"

# Determine primary work type
if [ "$HOOK_FILES" -gt 2 ]; then
    LEARNING_TYPE="hook_development"
    TAGS='["hooks", "automation"]'
elif [ "$AGENT_FILES" -gt 0 ]; then
    LEARNING_TYPE="agent_development"
    TAGS='["agents", "orchestration"]'
elif [ "$FIX_COUNT" -gt "$FEAT_COUNT" ]; then
    LEARNING_TYPE="bug_fixing"
    TAGS='["fixes", "debugging"]'
elif [ "$FEAT_COUNT" -gt 0 ]; then
    LEARNING_TYPE="feature_development"
    TAGS='["features", "implementation"]'
fi

# Create learning entry
cat >> "$LEARNINGS_FILE" << EOF
{"timestamp":"$TIMESTAMP","session_id":"$SESSION_ID","type":"$LEARNING_TYPE","commits":$COMMIT_COUNT,"features":$FEAT_COUNT,"fixes":$FIX_COUNT,"refactors":$REFACTOR_COUNT,"new_components":$NEW_COMPONENT_COUNT,"ts_files":$TS_FILES,"rs_files":$RS_FILES,"tags":$TAGS}
EOF

# Check for actionable patterns (3+ similar entries)
if [ -f "$LEARNINGS_FILE" ]; then
    # Count similar learning types in last 7 days
    SIMILAR_COUNT=$(grep "\"type\":\"$LEARNING_TYPE\"" "$LEARNINGS_FILE" | tail -10 | wc -l | tr -d ' ')

    if [ "$SIMILAR_COUNT" -ge 3 ]; then
        # Pattern detected - add to patterns file for session start
        cat >> "$PATTERNS_FILE" << EOF

## Pattern Detected: $LEARNING_TYPE ($TIMESTAMP)
- Occurrences: $SIMILAR_COUNT in recent sessions
- Suggestion: Consider creating a specialized workflow or agent
- Tags: $TAGS
EOF
    fi
fi

exit 0
