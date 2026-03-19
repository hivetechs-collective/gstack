#!/bin/bash
# Autonomous Pipeline: Hooks Health Check
# Run this to verify all hooks are properly configured and working
# Generic template - works with any project

# Note: Don't use set -e as we test exit codes

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/.claude/hooks"
SETTINGS_FILE="$PROJECT_ROOT/.claude/settings.json"
STATE_DIR="$PROJECT_ROOT/.claude/state"
CONFIG_FILE="$PROJECT_ROOT/.claude/project.json"
LIB_DIR="$PROJECT_ROOT/.claude/lib"

# Source configuration helper
if [ -f "$LIB_DIR/config.sh" ]; then
    source "$LIB_DIR/config.sh"
fi

PROJECT_NAME="${PROJECT_NAME:-$(get_project_name 2>/dev/null || echo 'Project')}"

echo "==============================================================="
echo "  ${PROJECT_NAME^^} HOOKS HEALTH CHECK"
echo "==============================================================="
echo ""

PASSED=0
FAILED=0

# Helper function for test results
check() {
    local name="$1"
    local result="$2"
    if [ "$result" -eq 0 ]; then
        echo "  [OK] $name"
        PASSED=$((PASSED + 1))
    else
        echo "  [FAIL] $name"
        FAILED=$((FAILED + 1))
    fi
}

# 1. Check hook files exist
echo " Hook Files:"
for hook in session-start.sh pre-compact.sh check-blocked-request.sh block-protected-paths.sh post-git-push.sh context-checkpoint.sh; do
    if [ -f "$HOOKS_DIR/$hook" ]; then
        check "$hook exists" 0
    else
        check "$hook exists" 1
    fi
done
echo ""

# 2. Check hook files are executable
echo " Executable Permissions:"
for hook in session-start.sh pre-compact.sh check-blocked-request.sh block-protected-paths.sh post-git-push.sh context-checkpoint.sh; do
    if [ -x "$HOOKS_DIR/$hook" ]; then
        check "$hook is executable" 0
    else
        check "$hook is executable" 1
    fi
done
echo ""

# 3. Check settings.json exists and is valid JSON
echo " Settings Configuration:"
if [ -f "$SETTINGS_FILE" ]; then
    check "settings.json exists" 0
    if python3 -c "import json; json.load(open('$SETTINGS_FILE'))" 2>/dev/null; then
        check "settings.json is valid JSON" 0
    else
        check "settings.json is valid JSON" 1
    fi
else
    check "settings.json exists" 1
fi
echo ""

# 4. Check hooks are configured in settings.json
echo " Hook Configuration:"
if [ -f "$SETTINGS_FILE" ]; then
    # Required hooks
    for event in SessionStart PreCompact PreToolUse PostToolUse; do
        if grep -q "\"$event\"" "$SETTINGS_FILE"; then
            check "$event hook configured" 0
        else
            check "$event hook configured" 1
        fi
    done
fi
echo ""

# 5. Check project configuration
echo " Project Configuration:"
if [ -f "$CONFIG_FILE" ]; then
    check "project.json exists" 0
    if python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
        check "project.json is valid JSON" 0
    else
        check "project.json is valid JSON" 1
    fi
else
    check "project.json exists" 1
    echo "     [!] Create .claude/project.json for project-specific config"
fi
echo ""

# 6. Check config helper
echo " Configuration Helper:"
if [ -f "$LIB_DIR/config.sh" ]; then
    check "config.sh exists" 0
    if [ -x "$LIB_DIR/config.sh" ] || source "$LIB_DIR/config.sh" 2>/dev/null; then
        check "config.sh is sourceable" 0
    else
        check "config.sh is sourceable" 1
    fi
else
    check "config.sh exists" 1
fi
echo ""

# 7. Check state directory is writable
echo " State Directory:"
mkdir -p "$STATE_DIR"
if [ -d "$STATE_DIR" ]; then
    check "state directory exists" 0
    if touch "$STATE_DIR/.write-test" 2>/dev/null; then
        rm -f "$STATE_DIR/.write-test"
        check "state directory is writable" 0
    else
        check "state directory is writable" 1
    fi
else
    check "state directory exists" 1
fi
echo ""

# 8. Test hook functionality
echo " Functional Tests:"

# Test session-start (should exit 0)
"$HOOKS_DIR/session-start.sh" > /dev/null 2>&1
check "session-start.sh runs successfully" $?

# Test pre-compact (should exit 0 and create state file)
echo '{"trigger":"test","session_id":"health-check"}' | "$HOOKS_DIR/pre-compact.sh" > /dev/null 2>&1
check "pre-compact.sh runs successfully" $?

if [ -f "$STATE_DIR/session-state.md" ]; then
    check "pre-compact.sh creates state file" 0
else
    check "pre-compact.sh creates state file" 1
fi

# Test check-blocked-request (should exit 0)
echo "create a test component" | "$HOOKS_DIR/check-blocked-request.sh" > /dev/null 2>&1
check "check-blocked-request.sh runs successfully" $?

# Test block-protected-paths (should exit 0 for non-protected path)
echo '{"tool_input":{"file_path":"src/test.ts"}}' | "$HOOKS_DIR/block-protected-paths.sh" > /dev/null 2>&1
check "block-protected-paths.sh runs successfully" $?

# Test post-git-push (should exit 0)
"$HOOKS_DIR/post-git-push.sh" > /dev/null 2>&1
check "post-git-push.sh runs successfully" $?

# Test context-checkpoint (should exit 0 and create checkpoint)
"$HOOKS_DIR/context-checkpoint.sh" > /dev/null 2>&1
check "context-checkpoint.sh runs successfully" $?

if ls "$STATE_DIR/checkpoints"/checkpoint-*.json 1> /dev/null 2>&1; then
    check "context-checkpoint.sh creates checkpoint file" 0
else
    check "context-checkpoint.sh creates checkpoint file" 1
fi

echo ""

# 9. Check compact log for automatic triggers
echo " Compaction Log Analysis:"
COMPACT_LOG="$STATE_DIR/compact-log.txt"
if [ -f "$COMPACT_LOG" ]; then
    check "compact-log.txt exists" 0

    TOTAL_ENTRIES=$(wc -l < "$COMPACT_LOG" | tr -d ' ')
    AUTO_COUNT=$(grep -c "triggered: auto" "$COMPACT_LOG" 2>/dev/null || true)
    MANUAL_COUNT=$(grep -c "triggered: manual" "$COMPACT_LOG" 2>/dev/null || true)

    [ -z "$AUTO_COUNT" ] && AUTO_COUNT=0
    [ -z "$MANUAL_COUNT" ] && MANUAL_COUNT=0

    echo "     Total entries: $TOTAL_ENTRIES"
    echo "     Auto triggers: $AUTO_COUNT"
    echo "     Manual triggers: $MANUAL_COUNT"

    if [ "$AUTO_COUNT" -gt 0 ] 2>/dev/null; then
        check "PreCompact auto-trigger verified" 0
    else
        echo "     [!] No auto triggers yet (need to experience auto-compaction)"
    fi
else
    echo "     [!] No compact log yet (no compactions recorded)"
fi
echo ""

# Summary
echo "==============================================================="
echo "  SUMMARY"
echo "==============================================================="
echo ""
echo "  Passed: $PASSED"
echo "  Failed: $FAILED"
echo ""

if [ "$FAILED" -eq 0 ]; then
    echo "  [OK] All checks passed!"
    echo ""
    exit 0
else
    echo "  [FAIL] Some checks failed - review above"
    echo ""
    exit 1
fi
