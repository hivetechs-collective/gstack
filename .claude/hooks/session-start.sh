#!/bin/bash
# Claude-Pattern: Automatic session start context loading
# Runs when Claude Code session begins or after compaction
# Enhanced: Uncommitted work detection + CI failure check (2025-12-26)

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.claude/state"
STATE_FILE="$STATE_DIR/session-state.md"
SESSION_LOG="$STATE_DIR/session-log.txt"
COMPACT_LOG="$STATE_DIR/compact-log.txt"
HOOKS_DIR="$PROJECT_ROOT/.claude/hooks"
UTILS_DIR="$PROJECT_ROOT/.claude/hooks/utils"

# =================================================================
# CMUX: Auto-rename workspace tab to repo name (like tmux rename-window)
#
# CMUX is the Claude-pattern workspace manager. When a Claude Code
# session starts inside a CMUX-managed environment, $CMUX_SOCKET is
# set by the cmux daemon — its presence confirms we are inside a
# managed workspace pane.
#
# This block makes each Claude workspace tab display the repository
# name, giving the same "named tab" UX you get with tmux rename-window.
#
# Graceful-failure design:
#   - `command -v cmux` guards against machines that don't have cmux installed
#   - All git/cmux calls redirect stderr to /dev/null so hook never blocks
#     the session if the workspace manager or git is unavailable
# =================================================================
if [ -n "$CMUX_SOCKET" ] && command -v cmux &>/dev/null; then
    # Resolve the top-level git directory name (e.g. "claude-pattern")
    # Works from any subdirectory or worktree inside the repo
    REPO_NAME=$(basename "$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)

    # Only rename if we successfully resolved a repo name
    if [ -n "$REPO_NAME" ]; then
        cmux rename-workspace "$REPO_NAME" 2>/dev/null
    fi
fi

# Source JSON logger if available
if [ -f "$UTILS_DIR/json-logger.sh" ]; then
    source "$UTILS_DIR/json-logger.sh"
    LOGGING_ENABLED=true
else
    LOGGING_ENABLED=false
fi

# Log this session start
mkdir -p "$STATE_DIR"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "[$TIMESTAMP] SESSION_START" >> "$SESSION_LOG"

# JSON log session start
if [ "$LOGGING_ENABLED" = "true" ]; then
    log_session "start" "{\"agent_type\":\"${AGENT_TYPE:-main}\"}"
fi

# =================================================================
# AUTO-SYNC FROM CLAUDE-PATTERN (keeps all projects up to date)
# =================================================================
CLAUDE_PATTERN="/Users/veronelazio/Developer/Private/claude-pattern"
LOCAL_VERSION_FILE="$PROJECT_ROOT/.claude/.sync-version"
SOURCE_VERSION_FILE="$CLAUDE_PATTERN/.claude/.sync-version"
SYNC_SCRIPT="$CLAUDE_PATTERN/.claude/scripts/sync-to-project.sh"

auto_sync_from_pattern() {
    # Skip if we ARE claude-pattern
    if [ "$PROJECT_ROOT" = "$CLAUDE_PATTERN" ]; then
        return 0
    fi

    # Skip if sync script doesn't exist
    if [ ! -f "$SYNC_SCRIPT" ]; then
        return 0
    fi

    local needs_sync=false
    local reason=""

    # Check if .claude directory is missing entirely
    if [ ! -d "$PROJECT_ROOT/.claude" ]; then
        needs_sync=true
        reason="No .claude directory"
    # Check if version file is missing locally
    elif [ ! -f "$LOCAL_VERSION_FILE" ]; then
        needs_sync=true
        reason="No sync version (first sync)"
    # Check if source version is newer
    elif [ -f "$SOURCE_VERSION_FILE" ]; then
        SOURCE_DATE=$(cat "$SOURCE_VERSION_FILE" 2>/dev/null)
        LOCAL_DATE=$(cat "$LOCAL_VERSION_FILE" 2>/dev/null)
        if [ "$SOURCE_DATE" != "$LOCAL_DATE" ]; then
            needs_sync=true
            reason="claude-pattern updated ($SOURCE_DATE)"
        fi
    fi

    if [ "$needs_sync" = true ]; then
        echo ""
        echo "🔄 AUTO-SYNC: $reason"
        echo "   Syncing from claude-pattern..."

        # Run sync script silently, capture result
        if "$SYNC_SCRIPT" "$PROJECT_ROOT" >/dev/null 2>&1; then
            # Copy version marker to indicate sync completed
            if [ -f "$SOURCE_VERSION_FILE" ]; then
                cp "$SOURCE_VERSION_FILE" "$LOCAL_VERSION_FILE"
            fi
            echo "   ✅ Sync complete"
        else
            echo "   ⚠️  Sync failed - continuing with existing config"
        fi
        echo ""
    fi
}

# Run auto-sync check
auto_sync_from_pattern

# =================================================================
# AGENT TYPE DETECTION (Claude Code v2.1.2+)
# =================================================================
# The AGENT_TYPE environment variable is now provided by Claude Code
# when --agent flag is used. This allows agent-specific initialization.
if [ -n "$AGENT_TYPE" ]; then
    echo "[$TIMESTAMP] SESSION_START agent_type=$AGENT_TYPE" >> "$SESSION_LOG"
fi

echo "═══════════════════════════════════════════════════════════════"
if [ -n "$AGENT_TYPE" ]; then
    echo "  CLAUDE-PATTERN SESSION INITIALIZED [Agent: $AGENT_TYPE]"
else
    echo "  CLAUDE-PATTERN SESSION INITIALIZED"
fi
echo "═══════════════════════════════════════════════════════════════"

# =================================================================
# DATE AWARENESS (Critical for accurate searches and context)
# =================================================================
CURRENT_DATE=$(date +"%B %d, %Y")
CURRENT_YEAR=$(date +"%Y")
echo ""
echo "📅 TODAY: $CURRENT_DATE"
echo "   When searching: use $CURRENT_YEAR (not older years)"
echo "   AI knowledge may be outdated - always verify with current sources"

# Agent-specific initialization
if [ -n "$AGENT_TYPE" ]; then
    case "$AGENT_TYPE" in
        security-expert)
            echo ""
            echo "🔒 Security audit mode - read-only analysis enabled"
            ;;
        code-review-expert)
            echo ""
            echo "📝 Code review mode - analysis and recommendations"
            ;;
        system-architect)
            echo ""
            echo "🏗️  Architecture planning mode - design exploration"
            ;;
        orchestrator)
            echo ""
            echo "🎯 Orchestrator mode - multi-agent coordination active"
            ;;
    esac
fi

# =================================================================
# UNCOMMITTED WORK DETECTION (100% reliable via hook)
# =================================================================
UNCOMMITTED=$(git -C "$PROJECT_ROOT" status --short 2>/dev/null)
if [ -n "$UNCOMMITTED" ]; then
    UNCOMMITTED_COUNT=$(echo "$UNCOMMITTED" | wc -l | tr -d ' ')
    echo ""
    echo "⚠️  UNCOMMITTED CHANGES DETECTED ($UNCOMMITTED_COUNT files)"
    echo "─────────────────────────────────────────────────────────────"
    echo "$UNCOMMITTED" | head -10
    if [ "$UNCOMMITTED_COUNT" -gt 10 ]; then
        echo "   ... and $((UNCOMMITTED_COUNT - 10)) more files"
    fi
    echo ""
    echo "📋 ACTIONS REQUIRED:"
    echo "   • Review changes: git diff"
    echo "   • If complete: git add . && git commit -m 'message'"
    echo "   • If incomplete: Continue work or git stash"
    echo "   • If invalid: git checkout . (WARNING: loses changes)"
    echo "─────────────────────────────────────────────────────────────"
fi

# =================================================================
# CI FAILURE DETECTION (100% reliable via hook)
# =================================================================
CI_FAILURES_LOG="$STATE_DIR/ci-failures.log"

if command -v gh &> /dev/null; then
    # Check for recent CI failures
    FAILED_RUNS=$(gh run list --limit 5 --json conclusion,name,headBranch --jq '[.[] | select(.conclusion == "failure")] | length' 2>/dev/null || echo "0")
    IN_PROGRESS=$(gh run list --limit 3 --json status --jq '[.[] | select(.status == "in_progress")] | length' 2>/dev/null || echo "0")

    if [ "$FAILED_RUNS" != "0" ] && [ "$FAILED_RUNS" != "" ]; then
        echo ""
        echo "🔴 CI FAILURES DETECTED: $FAILED_RUNS failing run(s)"
        echo "─────────────────────────────────────────────────────────────"
        gh run list --limit 5 --json conclusion,name,headBranch --jq '.[] | select(.conclusion == "failure") | "   ❌ \(.name): \(.headBranch)"' 2>/dev/null || true
        echo ""
        echo "📋 ACTIONS REQUIRED:"
        echo "   • View details: gh run list --limit 5"
        echo "   • See logs: gh run view <run-id> --log-failed"
        echo "   • Fix failures before new development"
        echo "─────────────────────────────────────────────────────────────"
    fi

    if [ "$IN_PROGRESS" != "0" ] && [ "$IN_PROGRESS" != "" ]; then
        echo ""
        echo "🟡 CI IN PROGRESS: $IN_PROGRESS run(s) still running"
        echo "   Monitor with: gh run list --limit 3"
    fi
fi

# =================================================================
# UNRESOLVED ISSUES CHECK (Ownership enforcement)
# =================================================================
if [ -f "$CI_FAILURES_LOG" ]; then
    # Count unresolved failures (FAILURE entries without corresponding RESOLVED)
    UNRESOLVED=$(grep "FAILURE:" "$CI_FAILURES_LOG" 2>/dev/null | while read -r line; do
        WORKFLOW=$(echo "$line" | sed 's/.*FAILURE: \([^-]*\).*/\1/' | xargs)
        if ! grep -q "RESOLVED:.*$WORKFLOW" "$CI_FAILURES_LOG" 2>/dev/null; then
            echo "$line"
        fi
    done | wc -l | tr -d ' ')

    if [ "$UNRESOLVED" -gt 0 ] 2>/dev/null; then
        echo ""
        echo "🚨 UNRESOLVED CI FAILURES: $UNRESOLVED issue(s) logged but not fixed"
        echo "┌─────────────────────────────────────────────────────────────┐"
        echo "│  YOU OWN THESE. FIX THEM BEFORE NEW DEVELOPMENT.           │"
        echo "└─────────────────────────────────────────────────────────────┘"
        echo ""
        echo "📋 Unresolved issues:"
        grep "FAILURE:" "$CI_FAILURES_LOG" 2>/dev/null | while read -r line; do
            WORKFLOW=$(echo "$line" | sed 's/.*FAILURE: \([^-]*\).*/\1/' | xargs)
            if ! grep -q "RESOLVED:.*$WORKFLOW" "$CI_FAILURES_LOG" 2>/dev/null; then
                echo "   $line"
            fi
        done | head -5
        echo ""
        echo "   Log: .claude/state/ci-failures.log"
        echo "   When fixed, mark resolved with:"
        echo "   echo \"[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] RESOLVED: <workflow> - <commit>\" >> .claude/state/ci-failures.log"
        echo "─────────────────────────────────────────────────────────────"
    fi
fi

# Quick hook health verification
HOOK_ISSUES=0
for hook in session-start.sh pre-compact.sh check-blocked-request.sh block-protected-paths.sh session-end.sh; do
    if [ ! -x "$HOOKS_DIR/$hook" ] 2>/dev/null; then
        HOOK_ISSUES=$((HOOK_ISSUES + 1))
    fi
done

if [ "$HOOK_ISSUES" -gt 0 ]; then
    echo ""
    echo "⚠️  HOOK HEALTH WARNING: $HOOK_ISSUES hooks missing or not executable"
    echo "   Run: .claude/hooks/health-check.sh"
    echo ""
fi

# Check if resuming from compaction
if [ -f "$STATE_FILE" ]; then
    echo ""
    echo "📂 RESTORED FROM COMPACTION - Previous state found"
    echo "   See: .claude/state/session-state.md for full details"

    # Show timestamp and trigger type from saved file
    SAVED_TIME=$(grep "Auto-saved:" "$STATE_FILE" | head -1 | sed 's/.*Auto-saved:\*\* //' || echo "unknown")
    TRIGGER=$(grep "Trigger:" "$STATE_FILE" | head -1 | sed 's/.*Trigger:\*\* //' || echo "unknown")
    echo "   Saved at: $SAVED_TIME"
    echo "   Trigger: $TRIGGER"

    # Verify PreCompact hook is working
    if echo "$TRIGGER" | grep -q "auto"; then
        echo "   ✅ PreCompact auto-trigger verified working"
    elif echo "$TRIGGER" | grep -q "manual"; then
        echo "   ✅ PreCompact manual-trigger verified working"
    elif echo "$TRIGGER" | grep -q "unknown"; then
        echo "   ⚠️  PreCompact hook may not be configured correctly"
    fi
    echo ""
    echo "   ⚠️  Review .claude/state/session-state.md for full context"
    echo ""
fi

# =================================================================
# DEATH SPIRAL DETECTION & RECOVERY
# =================================================================
if [ -f "$COMPACT_LOG" ]; then
    AUTO_COUNT=$(grep -c "triggered: auto" "$COMPACT_LOG" 2>/dev/null || true)
    [ -z "$AUTO_COUNT" ] && AUTO_COUNT=0

    # Check for compacts in the last hour (death spiral indicator)
    CURRENT_HOUR=$(date -u +"%Y-%m-%dT%H")
    COMPACTS_THIS_HOUR=$(grep -c "$CURRENT_HOUR" "$COMPACT_LOG" 2>/dev/null || echo "0")
    COMPACTS_THIS_HOUR=$(echo "$COMPACTS_THIS_HOUR" | tr -d '[:space:]')
    [ -z "$COMPACTS_THIS_HOUR" ] && COMPACTS_THIS_HOUR=0

    if [ "$COMPACTS_THIS_HOUR" -gt 2 ] 2>/dev/null; then
        echo ""
        echo "┌─────────────────────────────────────────────────────────────┐"
        echo "│  ⛔ DEATH SPIRAL DETECTED: $COMPACTS_THIS_HOUR COMPACTS THIS HOUR         │"
        echo "└─────────────────────────────────────────────────────────────┘"
        echo ""
        echo "🚨 YOU ARE IN A CONTEXT LOOP. STOP AND READ:"
        echo ""
        echo "   The last operation likely filled your context too fast."
        echo "   DO NOT repeat it. Instead:"
        echo ""
        echo "   ❌ DON'T: Repeat the same large operation"
        echo "   ❌ DON'T: Run multiple heavy tasks back-to-back"
        echo ""
        echo "   ✅ DO: Work on small, focused tasks"
        echo "   ✅ DO: Commit after every 1-2 files"
        echo "   ✅ DO: Check git log - task may already be done"
        echo "   ✅ NOTE: v2.1.2 saves large outputs to disk (not truncated)"
        echo ""
        echo "   📖 See: .claude/state/session-state.md for task state"
        echo "   📖 See: .claude/state/avoid-operations.txt for safe patterns"
        echo ""
        echo "─────────────────────────────────────────────────────────────"
    fi

    if [ "$AUTO_COUNT" -gt 0 ]; then
        echo "📊 Compaction Stats: $AUTO_COUNT auto-triggers verified"
    fi
fi

# =================================================================
# AUTO-CONTEXT INITIALIZATION (Memory Bank)
# =================================================================
# Automatically ensures CLAUDE.md is populated with project context.
# Runs /init --update if context is stale or missing.

CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"
INIT_SCRIPT="$PROJECT_ROOT/scripts/init-project-context.ts"
CONTEXT_STATE="$STATE_DIR/context-state.json"

auto_init_context() {
    local needs_init=false
    local reason=""

    # Check if CLAUDE.md exists
    if [ ! -f "$CLAUDE_MD" ]; then
        needs_init=true
        reason="CLAUDE.md missing"
    # Check if auto-generated section exists
    elif ! grep -q "AUTO-GENERATED by /init" "$CLAUDE_MD" 2>/dev/null; then
        needs_init=true
        reason="No auto-generated context"
    # Check if context is stale (older than 24 hours)
    elif [ -f "$CONTEXT_STATE" ]; then
        LAST_SCAN=$(cat "$CONTEXT_STATE" 2>/dev/null | grep -o '"timestamp":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$LAST_SCAN" ]; then
            # Convert to epoch and compare
            LAST_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_SCAN%.*}" +%s 2>/dev/null || echo "0")
            NOW_EPOCH=$(date +%s)
            AGE_HOURS=$(( (NOW_EPOCH - LAST_EPOCH) / 3600 ))
            if [ "$AGE_HOURS" -gt 24 ]; then
                needs_init=true
                reason="Context stale (${AGE_HOURS}h old)"
            fi
        fi
    fi

    # Run init if needed
    if [ "$needs_init" = true ] && [ -f "$INIT_SCRIPT" ]; then
        echo ""
        echo "🧠 AUTO-CONTEXT: $reason"
        echo "   Running /init --update..."

        # Run init script and capture JSON output
        if command -v tsx &> /dev/null; then
            INIT_OUTPUT=$(tsx "$INIT_SCRIPT" --json 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$INIT_OUTPUT" ]; then
                # Save context state
                echo "$INIT_OUTPUT" > "$CONTEXT_STATE"

                # Extract key info for display using Python (more reliable than grep)
                PROJECT_NAME=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
                PROJECT_TYPE=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))" 2>/dev/null)
                AGENT_COUNT=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('claudeIntegration',{}).get('agentCount',0))" 2>/dev/null)
                HAS_RALPH=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(str(json.load(sys.stdin).get('claudeIntegration',{}).get('hasRalph',False)).lower())" 2>/dev/null)

                echo "   ✅ Context loaded: $PROJECT_NAME ($PROJECT_TYPE)"
                echo "   📦 $AGENT_COUNT agents | 🤖 Ralph: $HAS_RALPH"

                # Update CLAUDE.md with auto-generated sections
                tsx "$INIT_SCRIPT" --update >/dev/null 2>&1
            else
                echo "   ⚠️  Init script failed - using existing context"
            fi
        else
            echo "   ⚠️  tsx not available - skipping auto-init"
        fi
    fi
}

# Run auto-context (silent if already current)
auto_init_context

# =================================================================
# PROJECT CONTEXT SUMMARY
# =================================================================
# Display key project info from context state

if [ -f "$CONTEXT_STATE" ]; then
    PROJECT_NAME=$(cat "$CONTEXT_STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','Unknown'))" 2>/dev/null)
    PROJECT_TYPE=$(cat "$CONTEXT_STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type','unknown'))" 2>/dev/null)
    AGENT_COUNT=$(cat "$CONTEXT_STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('claudeIntegration',{}).get('agentCount',0))" 2>/dev/null)
    COMMAND_COUNT=$(cat "$CONTEXT_STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('claudeIntegration',{}).get('commandCount',0))" 2>/dev/null)
    HAS_RALPH=$(cat "$CONTEXT_STATE" | python3 -c "import sys,json; print(str(json.load(sys.stdin).get('claudeIntegration',{}).get('hasRalph',False)).lower())" 2>/dev/null)

    echo ""
    echo "📋 Project: $PROJECT_NAME"
    echo "📂 Type: $PROJECT_TYPE | 📦 $AGENT_COUNT agents | 🔧 $COMMAND_COUNT commands"
    if [ "$HAS_RALPH" = "true" ]; then
        echo "🤖 Ralph: Ready for autonomous development"
    fi
else
    # Fallback when no context state exists
    echo ""
    echo "📋 Project: $(basename "$PROJECT_ROOT")"
    echo "   Run /init to generate project context"
fi

echo ""
echo "📖 Commands: /init /context /blocked /safe /governance"
echo "═══════════════════════════════════════════════════════════════"

# =================================================================
# COMPOUND: Surface learnings and auto-act on patterns
# =================================================================
COMPOUND_DIR="$PROJECT_ROOT/.claude/hooks/compound"

if [ -x "$COMPOUND_DIR/surface-learnings.sh" ]; then
    "$COMPOUND_DIR/surface-learnings.sh"
fi

if [ -x "$COMPOUND_DIR/auto-act.sh" ]; then
    "$COMPOUND_DIR/auto-act.sh"
fi

echo ""

exit 0
