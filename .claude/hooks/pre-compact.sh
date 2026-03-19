#!/bin/bash
# Autonomous Pipeline: Save session state before context compaction
# Ensures no gaps when conversation is compacted
# Generic template - reads from .claude/project.json

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_FILE="$PROJECT_ROOT/.claude/state/session-state.md"
STATE_DIR="$PROJECT_ROOT/.claude/state"
LOG_FILE="$PROJECT_ROOT/.claude/state/compact-log.txt"
LIB_DIR="$PROJECT_ROOT/.claude/lib"
CONFIG_FILE="$PROJECT_ROOT/.claude/project.json"

# Source configuration helper
if [ -f "$LIB_DIR/config.sh" ]; then
    source "$LIB_DIR/config.sh"
fi

# Create state directory if needed
mkdir -p "$STATE_DIR"

# Read JSON input from Claude Code (if available)
INPUT=$(cat 2>/dev/null || echo "{}")
TRIGGER=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('trigger','unknown'))" 2>/dev/null || echo "unknown")
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','unknown'))" 2>/dev/null || echo "unknown")

# Get project info from config
PROJECT_NAME="${PROJECT_NAME:-$(get_project_name 2>/dev/null || echo 'Project')}"

# Get current git status
BRANCH=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || echo "unknown")
LAST_COMMIT=$(git -C "$PROJECT_ROOT" log -1 --format="%h %s" 2>/dev/null || echo "unknown")
UNCOMMITTED=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

# Get current timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Log this execution for verification
echo "[$TIMESTAMP] PreCompact triggered: $TRIGGER (session: $SESSION_ID)" >> "$LOG_FILE"

# Generate features section from config
generate_features_section() {
    if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
        local count=$(jq '.features | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
        if [ "$count" != "0" ] && [ "$count" != "" ]; then
            echo "## Features Status"
            echo ""
            jq -r '.features[] | "- \(.name) (\(.id)) \(if .status == "unblocked" then "✅ UNBLOCKED" else "⚠️ BLOCKED" end)"' "$CONFIG_FILE" 2>/dev/null
            echo ""
        else
            echo "## All Features Unblocked"
            echo ""
            echo "No feature restrictions configured. Build everything!"
            echo ""
        fi
    else
        echo "## All Features Unblocked"
        echo ""
        echo "No feature restrictions configured. Build everything!"
        echo ""
    fi
}

# Write session state
cat > "$STATE_FILE" << EOF
# $PROJECT_NAME Session State

> **Auto-saved:** $TIMESTAMP
> **Trigger:** $TRIGGER (manual=/compact, auto=context limit)
> **Session:** $SESSION_ID
> **IMPORTANT:** Read this file after compaction to restore context

---

## Git State

| Attribute | Value |
|-----------|-------|
| Branch | \`$BRANCH\` |
| Last Commit | \`$LAST_COMMIT\` |
| Uncommitted Files | $UNCOMMITTED |

---

$(generate_features_section)
---

## Build Everything Philosophy

- **No phase restrictions**: ALL features are actionable NOW
- **No deadline waiting**: Deadlines are targets, not "start dates"
- **Continue until stopped**: Only stop on Ctrl+C or zero remaining work
- **Use parallel agents**: When context ≤55%, spawn multiple agents

---

## Active Enforcement

All hooks remain active after compaction:
- SessionStart → Auto-displays context
- UserPromptSubmit → Warns on blocked keywords
- PreToolUse → Blocks protected paths
- Pre-commit → Validates stub format

---

## Post-Compaction Instructions

After compaction, the agent should:
1. Read this file (.claude/state/session-state.md)
2. Check .claude/project.json for feature status
3. Check git status for any uncommitted work
4. Continue with the task at hand

---

*This file is auto-generated before context compaction.*
EOF

echo "==============================================================="
echo "  SESSION STATE SAVED (Pre-Compaction)"
echo "==============================================================="
echo ""
echo "Project: $PROJECT_NAME"
echo "State saved to: .claude/state/session-state.md"
echo "Branch: $BRANCH"
echo "Last commit: $LAST_COMMIT"
echo "Uncommitted files: $UNCOMMITTED"

# =================================================================
# UNCOMMITTED WORK WARNING (100% reliable via hook)
# =================================================================
if [ "$UNCOMMITTED" -gt 0 ]; then
    echo ""
    echo "  WARNING: $UNCOMMITTED uncommitted files will persist after compaction"
    echo "---------------------------------------------------------------"
    git -C "$PROJECT_ROOT" status --short 2>/dev/null | head -5
    if [ "$UNCOMMITTED" -gt 5 ]; then
        echo "   ... and $((UNCOMMITTED - 5)) more files"
    fi
    echo ""
    echo " RECOMMENDATION:"
    echo "   Consider committing work-in-progress before compaction:"
    echo "   git add . && git commit -m 'wip: pre-compact checkpoint'"
    echo "---------------------------------------------------------------"
fi

echo ""
echo "After compaction, context will be restored from:"
echo "  1. CLAUDE.md (governance rules)"
echo "  2. .claude/state/session-state.md (session state)"
echo "  3. SessionStart hook (uncommitted work + CI status)"
echo "==============================================================="

exit 0
