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

# === Evaluator Outcome Extraction ===
# Step 4b writes evaluator outcomes to a state file (shell hooks can't access TaskList).
# Read that file, append structured entries to learnings.jsonl, then trigger instincts.
EVAL_OUTCOMES_FILE="$STATE_DIR/evaluator-outcomes.jsonl"

if [ -f "$EVAL_OUTCOMES_FILE" ] && [ -s "$EVAL_OUTCOMES_FILE" ]; then
    EVAL_LINE_COUNT=$(wc -l < "$EVAL_OUTCOMES_FILE" | tr -d ' ')

    if [ "$EVAL_LINE_COUNT" -gt 0 ]; then
        # Append each evaluator outcome to learnings.jsonl
        while IFS= read -r line; do
            # Validate it's JSON with the expected type field
            if echo "$line" | grep -q '"type":"evaluator_outcome"'; then
                echo "$line" >> "$LEARNINGS_FILE"
            fi
        done < "$EVAL_OUTCOMES_FILE"

        # Extract failure categories from ALL evaluator outcomes across sessions
        # (not just this session's outcomes file — cross-session accumulation)
        EVAL_FAILURES=""
        if command -v jq &> /dev/null; then
            EVAL_FAILURES=$(jq -r 'select(.type == "evaluator_outcome" and (.failure_categories | length > 0)) | .failure_categories[]' "$LEARNINGS_FILE" 2>/dev/null | sort | uniq -c | sort -rn || echo "")
        else
            # Fallback: grep-based extraction from accumulated learnings
            EVAL_FAILURES=$(grep '"type":"evaluator_outcome"' "$LEARNINGS_FILE" 2>/dev/null \
                | grep -o '"failure_categories":\[[^]]*\]' \
                | sed 's/"failure_categories":\[//;s/\]//;s/"//g' \
                | tr ',' '\n' | sed 's/^ *//' | grep -v '^$' \
                | sort | uniq -c | sort -rn || echo "")
        fi

        # Clear processed outcomes
        rm -f "$EVAL_OUTCOMES_FILE"
    fi
fi

# === Instinct Extraction ===
# After capturing session summary, extract instincts from commit patterns
INSTINCT_MANAGER="$(dirname "$0")/instinct-manager.sh"
PROJECT_NAME=$(basename "$PROJECT_ROOT")

if [ -x "$INSTINCT_MANAGER" ]; then
    # For each commit type detected, create or strengthen a project-scoped instinct
    if [ "$FEAT_COUNT" -gt 0 ]; then
        TRIGGER="when adding new features in $LEARNING_TYPE context"
        EXISTING_ID=$("$INSTINCT_MANAGER" find-by-trigger "$TRIGGER" 2>/dev/null || echo "")
        if [ -n "$EXISTING_ID" ]; then
            "$INSTINCT_MANAGER" strengthen "$EXISTING_ID" 2>/dev/null || true
        else
            "$INSTINCT_MANAGER" create "$TRIGGER" \
                "Follow established feature patterns: commit with feat: prefix, include tests" \
                "0.5" "workflow" "project" "$PROJECT_NAME" 2>/dev/null || true
        fi
    fi

    if [ "$FIX_COUNT" -gt 0 ]; then
        TRIGGER="when fixing bugs in $LEARNING_TYPE context"
        EXISTING_ID=$("$INSTINCT_MANAGER" find-by-trigger "$TRIGGER" 2>/dev/null || echo "")
        if [ -n "$EXISTING_ID" ]; then
            "$INSTINCT_MANAGER" strengthen "$EXISTING_ID" 2>/dev/null || true
        else
            "$INSTINCT_MANAGER" create "$TRIGGER" \
                "Follow fix workflow: diagnose root cause, commit with fix: prefix, verify resolution" \
                "0.5" "workflow" "project" "$PROJECT_NAME" 2>/dev/null || true
        fi
    fi

    if [ "$REFACTOR_COUNT" -gt 0 ]; then
        TRIGGER="when refactoring in $LEARNING_TYPE context"
        EXISTING_ID=$("$INSTINCT_MANAGER" find-by-trigger "$TRIGGER" 2>/dev/null || echo "")
        if [ -n "$EXISTING_ID" ]; then
            "$INSTINCT_MANAGER" strengthen "$EXISTING_ID" 2>/dev/null || true
        else
            "$INSTINCT_MANAGER" create "$TRIGGER" \
                "Follow refactor discipline: commit with refactor: prefix, no behavior changes" \
                "0.5" "code-style" "project" "$PROJECT_NAME" 2>/dev/null || true
        fi
    fi

    # === Evaluator Failure Instincts ===
    # Evaluator failures are high-signal evidence — start at 0.6 confidence
    # (vs 0.5 for commit-pattern instincts) per spec design decision.
    if [ -n "$EVAL_FAILURES" ]; then
        echo "$EVAL_FAILURES" | while read -r count category; do
            [ -z "$category" ] && continue
            # Map failure category to instinct domain
            EVAL_DOMAIN="testing"
            case "$category" in
                error_handling|error-handling)   EVAL_DOMAIN="code-style" ;;
                test_coverage|test-coverage)     EVAL_DOMAIN="testing" ;;
                security|auth*)                  EVAL_DOMAIN="security" ;;
                backward_compat*|breaking*)      EVAL_DOMAIN="code-style" ;;
                *)                               EVAL_DOMAIN="workflow" ;;
            esac

            TRIGGER="evaluator fails on $category in $PROJECT_NAME"
            ACTION="Add $category quality rubric to acceptance criteria — evaluator has failed on this ${count} times"
            EXISTING_ID=$("$INSTINCT_MANAGER" find-by-trigger "$TRIGGER" 2>/dev/null || echo "")
            if [ -n "$EXISTING_ID" ]; then
                "$INSTINCT_MANAGER" strengthen "$EXISTING_ID" 2>/dev/null || true
            elif [ "$count" -ge 2 ]; then
                # Create instinct only when 2+ occurrences of same category
                "$INSTINCT_MANAGER" create "$TRIGGER" "$ACTION" \
                    "0.6" "$EVAL_DOMAIN" "project" "$PROJECT_NAME" 2>/dev/null || true
            fi
        done
    fi
fi

exit 0
