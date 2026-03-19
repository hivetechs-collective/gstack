#!/bin/bash
# Autonomous Pipeline: CI Gate Enforcement Hook
# Blocks development when unacknowledged CI failures exist
# Generic template - works with any project
#
# Usage: Called by pre-tool-use hooks before Write/Edit operations
#
# Failure Types:
#   - BILLING: Infrastructure issue (acknowledge to proceed)
#   - CODE: Code failure (must fix before proceeding)
#   - INFRA: Infrastructure failure (acknowledge to proceed)
#
# To acknowledge a known issue (allows development to proceed):
#   echo "[timestamp] ACKNOWLEDGED: <workflow> - <reason>" >> .claude/state/ci-failures.log

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.claude/state"
CI_LOG="$STATE_DIR/ci-failures.log"

# Exit codes
EXIT_OK=0
EXIT_BLOCKED=1

# Check if gh CLI is available
if ! command -v gh &> /dev/null; then
    # Can't check CI, allow to proceed
    exit $EXIT_OK
fi

# Get recent CI failures
FAILURES=$(gh run list --limit 10 --json conclusion,name,databaseId,createdAt \
    --jq '[.[] | select(.conclusion == "failure")] | length' 2>/dev/null || echo "0")

if [ "$FAILURES" = "0" ] || [ -z "$FAILURES" ]; then
    exit $EXIT_OK
fi

# Count unacknowledged failures
UNACKNOWLEDGED=0
BLOCKING_FAILURES=""

# Get failed workflow names
FAILED_WORKFLOWS=$(gh run list --limit 10 --json conclusion,name,databaseId \
    --jq '.[] | select(.conclusion == "failure") | .name' 2>/dev/null)

while IFS= read -r workflow; do
    [ -z "$workflow" ] && continue

    # Check if this workflow is acknowledged or resolved in the log
    if [ -f "$CI_LOG" ]; then
        # Check for RESOLVED or ACKNOWLEDGED entries for this workflow
        if grep -q "RESOLVED:.*$workflow" "$CI_LOG" 2>/dev/null; then
            continue
        fi
        if grep -q "ACKNOWLEDGED:.*$workflow" "$CI_LOG" 2>/dev/null; then
            continue
        fi
        if grep -q "KNOWN_ISSUE:.*$workflow" "$CI_LOG" 2>/dev/null; then
            continue
        fi
    fi

    # This failure is not acknowledged
    UNACKNOWLEDGED=$((UNACKNOWLEDGED + 1))
    BLOCKING_FAILURES="$BLOCKING_FAILURES\n   X $workflow"
done <<< "$FAILED_WORKFLOWS"

if [ "$UNACKNOWLEDGED" -gt 0 ]; then
    echo ""
    echo "+===============================================================+"
    echo "|  CI GATE: DEVELOPMENT BLOCKED                                 |"
    echo "+---------------------------------------------------------------+"
    echo "|  $UNACKNOWLEDGED unacknowledged CI failure(s) detected"
    echo "+===============================================================+"
    echo ""
    echo "Blocking failures:"
    echo -e "$BLOCKING_FAILURES"
    echo ""
    echo "+---------------------------------------------------------------+"
    echo "|  OPTIONS:                                                     |"
    echo "|                                                               |"
    echo "|  1. FIX the failure (preferred)                               |"
    echo "|     -> View logs: gh run view <id> --log-failed               |"
    echo "|     -> Fix code, commit, push                                 |"
    echo "|     -> Mark: RESOLVED: <workflow> - <commit>                  |"
    echo "|                                                               |"
    echo "|  2. ACKNOWLEDGE if infrastructure issue (billing, etc.)       |"
    echo "|     -> echo \"\$(date -u +%Y-%m-%dT%H:%M:%SZ) ACKNOWLEDGED:     |"
    echo "|       <workflow> - <reason>\" >> .claude/state/ci-failures.log |"
    echo "|                                                               |"
    echo "|  3. Mark as KNOWN_ISSUE if pre-existing                       |"
    echo "|     -> echo \"\$(date -u +%Y-%m-%dT%H:%M:%SZ) KNOWN_ISSUE:      |"
    echo "|       <workflow>\" >> .claude/state/ci-failures.log            |"
    echo "+---------------------------------------------------------------+"
    echo ""

    exit $EXIT_BLOCKED
fi

exit $EXIT_OK
