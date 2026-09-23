#!/bin/bash
# Autonomous Pipeline: Auto-check CI status after git push
# PostToolUse hook - runs after every git push command
# Generic template - works with any project

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB_DIR="$PROJECT_ROOT/.claude/lib"

# Source configuration helper
if [ -f "$LIB_DIR/config.sh" ]; then
    source "$LIB_DIR/config.sh"
fi

PROJECT_NAME="${PROJECT_NAME:-$(get_project_name 2>/dev/null || echo 'Project')}"

# Post-push full-suite confirm (2.51.0, docs/operations/test-green-retest.md): a
# commit may have passed the gate on a targeted retest, so a push that leaves the
# default branch without a matching FULL green verdict gets one detached, niced
# full run of the pushed commit. Launch-and-return; it never blocks the push or
# this hook. Runs BEFORE the gh check below, which exits early without gh.
# Kill switch: PWT_DISABLE_POST_PUSH_CONFIRM=1.
PWT_POST_PUSH_CONFIRM="$PROJECT_ROOT/.claude/scripts/plan-w-team-post-push-confirm.sh"
if [ -x "$PWT_POST_PUSH_CONFIRM" ] && [ "${PWT_DISABLE_POST_PUSH_CONFIRM:-0}" != "1" ]; then
    PWT_PUSH_CMD=""
    if [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
        PWT_PUSH_CMD=$(jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
    fi
    "$PWT_POST_PUSH_CONFIRM" --launch --root "$PROJECT_ROOT" --command "$PWT_PUSH_CMD" 2>/dev/null || true
fi

echo ""
echo "==============================================================="
echo "  CI MONITORING (Auto-triggered after git push)"
echo "==============================================================="

# Check if gh CLI is available
if ! command -v gh &> /dev/null; then
    echo " GitHub CLI (gh) not found - cannot check CI status"
    echo "   Install: brew install gh"
    exit 0
fi

# Wait a moment for GitHub to register the push
sleep 2

echo ""
echo " Recent CI Runs:"
echo "---------------------------------------------------------------"

# Get the most recent run
LATEST_RUN=$(gh run list --limit 1 --json databaseId,status,conclusion,name,headBranch 2>/dev/null)

if [ -z "$LATEST_RUN" ] || [ "$LATEST_RUN" = "[]" ]; then
    echo "   No CI runs found. Workflow may not be triggered yet."
    echo "   Check again in 30 seconds: gh run list --limit 1"
else
    # Parse and display
    gh run list --limit 3 2>/dev/null || echo "   Unable to fetch run list"
fi

echo ""
echo "---------------------------------------------------------------"
echo " REQUIRED ACTIONS:"
echo "   - Monitor until completion: gh run view <run-id> --watch"
echo "   - If failure detected: gh run view <run-id> --log-failed"
echo "   - Do NOT start new features until CI passes"
echo "==============================================================="

# Check for immediate failures (within 5 seconds - fast checks)
FAILED=$(gh run list --limit 1 --json conclusion --jq '.[0].conclusion // empty' 2>/dev/null)
if [ "$FAILED" = "failure" ]; then
    echo ""
    echo " IMMEDIATE CI FAILURE DETECTED"
    echo "   Run: gh run view <run-id> --log-failed"
    echo "   Fix before continuing with development"
fi

exit 0
