#!/bin/bash
# Compound: Surface learnings at session start
# Analyzes accumulated patterns and suggests actions

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.claude/state"
LEARNINGS_FILE="$STATE_DIR/learnings.jsonl"
PATTERNS_FILE="$STATE_DIR/patterns-detected.md"
ACTIONS_FILE="$STATE_DIR/compound-actions.md"

# Skip if no learnings
if [ ! -f "$LEARNINGS_FILE" ]; then
    exit 0
fi

# Count total learnings
TOTAL_LEARNINGS=$(wc -l < "$LEARNINGS_FILE" | tr -d ' ')

if [ "$TOTAL_LEARNINGS" -lt 3 ]; then
    exit 0
fi

echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  📊 COMPOUND INSIGHTS (from $TOTAL_LEARNINGS sessions)                    │"
echo "└─────────────────────────────────────────────────────────────┘"

# Analyze patterns
echo ""

# Most common work types
echo "📈 Work Patterns:"
if command -v jq &> /dev/null; then
    jq -r '.type' "$LEARNINGS_FILE" 2>/dev/null | sort | uniq -c | sort -rn | head -3 | while read count type; do
        echo "   • $type: $count sessions"
    done
else
    grep -o '"type":"[^"]*"' "$LEARNINGS_FILE" | sort | uniq -c | sort -rn | head -3 | while read count type; do
        echo "   • $type"
    done
fi

# Check for recurring patterns that need action
HOOK_SESSIONS=$(grep -c '"type":"hook_development"' "$LEARNINGS_FILE" 2>/dev/null || echo "0")
AGENT_SESSIONS=$(grep -c '"type":"agent_development"' "$LEARNINGS_FILE" 2>/dev/null || echo "0")
FIX_SESSIONS=$(grep -c '"type":"bug_fixing"' "$LEARNINGS_FILE" 2>/dev/null || echo "0")

# Surface actionable recommendations
ACTIONS_NEEDED=0

echo ""
echo "🎯 Recommendations:"

if [ "$FIX_SESSIONS" -ge 5 ]; then
    echo "   ⚠️  High bug-fixing rate ($FIX_SESSIONS sessions)"
    echo "      → Consider adding more validators or improving test coverage"
    ACTIONS_NEEDED=1
fi

if [ "$HOOK_SESSIONS" -ge 3 ]; then
    echo "   📌 Frequent hook development ($HOOK_SESSIONS sessions)"
    echo "      → Hook patterns may be ready for documentation"
    ACTIONS_NEEDED=1
fi

# Check for recent errors in security log
SECURITY_LOG="$HOME/.claude/logs/security.jsonl"
if [ -f "$SECURITY_LOG" ]; then
    RECENT_BLOCKS=$(tail -50 "$SECURITY_LOG" 2>/dev/null | grep -c '"action":"block"' || echo "0")
    if [ "$RECENT_BLOCKS" -ge 5 ]; then
        echo "   🔒 $RECENT_BLOCKS operations blocked recently"
        echo "      → Review security patterns or adjust permissions"
        ACTIONS_NEEDED=1
    fi
fi

# Check for patterns file
if [ -f "$PATTERNS_FILE" ] && [ -s "$PATTERNS_FILE" ]; then
    PATTERN_COUNT=$(grep -c "## Pattern Detected" "$PATTERNS_FILE" 2>/dev/null || echo "0")
    if [ "$PATTERN_COUNT" -gt 0 ]; then
        echo "   📋 $PATTERN_COUNT patterns detected and ready for action"
        echo "      → See: .claude/state/patterns-detected.md"
        ACTIONS_NEEDED=1
    fi
fi

if [ "$ACTIONS_NEEDED" -eq 0 ]; then
    echo "   ✅ No immediate actions needed"
fi

echo ""

exit 0
