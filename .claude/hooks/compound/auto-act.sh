#!/bin/bash
# Compound: Auto-act on mature patterns
# Creates agents, validators, or commands when patterns reach threshold

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.claude/state"
LEARNINGS_FILE="$STATE_DIR/learnings.jsonl"
PATTERNS_FILE="$STATE_DIR/patterns-detected.md"
ACTIONS_LOG="$STATE_DIR/compound-actions.log"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Thresholds for auto-action
PATTERN_THRESHOLD=5  # 5 occurrences before suggesting action
ERROR_THRESHOLD=3    # 3 similar errors before adding validator

mkdir -p "$STATE_DIR"

# Skip if no learnings
if [ ! -f "$LEARNINGS_FILE" ]; then
    exit 0
fi

# Function to log actions taken
log_action() {
    echo "[$TIMESTAMP] $1" >> "$ACTIONS_LOG"
}

# Function to check if action already taken
action_exists() {
    grep -q "$1" "$ACTIONS_LOG" 2>/dev/null
}

# Analyze for auto-actionable patterns
echo ""
echo "🔄 Compound Auto-Analysis..."

# Pattern 1: Repeated TypeScript component creation
if command -v jq &> /dev/null; then
    TS_COMPONENT_SESSIONS=$(jq -r 'select(.ts_files > 3 and .type == "feature_development") | .session_id' "$LEARNINGS_FILE" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$TS_COMPONENT_SESSIONS" -ge "$PATTERN_THRESHOLD" ]; then
        if ! action_exists "ts-component-agent"; then
            echo "   📦 Pattern: Frequent TypeScript component development"
            echo "      → Suggesting: Create a ts-component-agent"
            echo ""
            echo "   To create: Add .claude/agents/specialists/ts-component-agent.md"
            echo "   Purpose: Scaffold React/TypeScript components with your patterns"
            log_action "SUGGESTED: ts-component-agent (ts_components: $TS_COMPONENT_SESSIONS)"
        fi
    fi

    # Pattern 2: Repeated Rust development
    RS_SESSIONS=$(jq -r 'select(.rs_files > 2) | .session_id' "$LEARNINGS_FILE" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$RS_SESSIONS" -ge "$PATTERN_THRESHOLD" ]; then
        if ! action_exists "rust-patterns"; then
            echo "   🦀 Pattern: Frequent Rust development ($RS_SESSIONS sessions)"
            echo "      → Consider documenting common Rust patterns"
            log_action "SUGGESTED: rust-patterns documentation (rs_sessions: $RS_SESSIONS)"
        fi
    fi

    # Pattern 3: High refactor rate
    REFACTOR_TOTAL=$(jq -r '.refactors' "$LEARNINGS_FILE" 2>/dev/null | awk '{sum+=$1} END {print sum}')
    REFACTOR_TOTAL=${REFACTOR_TOTAL:-0}

    if [ "$REFACTOR_TOTAL" -ge 10 ]; then
        if ! action_exists "refactor-guide"; then
            echo "   🔧 Pattern: High refactoring activity ($REFACTOR_TOTAL refactors)"
            echo "      → Consider creating refactoring guidelines"
            log_action "SUGGESTED: refactor-guide (total_refactors: $REFACTOR_TOTAL)"
        fi
    fi
fi

# Check security log for repeated blocks that might need pattern adjustment
SECURITY_LOG="$HOME/.claude/logs/security.jsonl"
if [ -f "$SECURITY_LOG" ] && command -v jq &> /dev/null; then
    # Find repeated block reasons
    REPEATED_BLOCKS=$(jq -r 'select(.action == "block") | .pattern' "$SECURITY_LOG" 2>/dev/null | sort | uniq -c | sort -rn | head -1)

    if [ -n "$REPEATED_BLOCKS" ]; then
        BLOCK_COUNT=$(echo "$REPEATED_BLOCKS" | awk '{print $1}')
        BLOCK_PATTERN=$(echo "$REPEATED_BLOCKS" | awk '{$1=""; print $0}' | xargs)

        if [ "$BLOCK_COUNT" -ge "$ERROR_THRESHOLD" ]; then
            echo "   🔒 Repeated blocks: \"$BLOCK_PATTERN\" ($BLOCK_COUNT times)"
            echo "      → Review if this should be allowed or pattern adjusted"
        fi
    fi
fi

echo ""
echo "   See: .claude/state/compound-actions.log for history"
echo ""

exit 0
