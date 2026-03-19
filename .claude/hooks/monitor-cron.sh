#!/bin/bash
# Autonomous Pipeline: External monitoring script for cron
# Run this via cron to monitor hook health between sessions
# Generic template - works with any project
#
# Installation:
#   crontab -e
#   # Add: 0 */6 * * * /path/to/project/.claude/hooks/monitor-cron.sh
#
# This checks hook health every 6 hours and alerts if issues detected

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.claude/state"
SESSION_LOG="$STATE_DIR/session-log.txt"
COMPACT_LOG="$STATE_DIR/compact-log.txt"
MONITOR_LOG="$STATE_DIR/monitor-log.txt"
ALERT_FILE="$STATE_DIR/alerts.txt"
LIB_DIR="$PROJECT_ROOT/.claude/lib"

# Source configuration helper
if [ -f "$LIB_DIR/config.sh" ]; then
    source "$LIB_DIR/config.sh"
fi

PROJECT_NAME="${PROJECT_NAME:-$(get_project_name 2>/dev/null || echo 'Project')}"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Create state directory if needed
mkdir -p "$STATE_DIR"

echo "[$TIMESTAMP] MONITOR_RUN started for $PROJECT_NAME" >> "$MONITOR_LOG"

ALERTS=""

# Check 1: Hook files exist and are executable
HOOKS_DIR="$PROJECT_ROOT/.claude/hooks"
for hook in session-start.sh session-end.sh pre-compact.sh check-blocked-request.sh block-protected-paths.sh; do
    if [ ! -x "$HOOKS_DIR/$hook" ]; then
        ALERTS="${ALERTS}MISSING_HOOK: $hook\n"
    fi
done

# Check 2: settings.json is valid
SETTINGS_FILE="$PROJECT_ROOT/.claude/settings.json"
if [ -f "$SETTINGS_FILE" ]; then
    if ! python3 -c "import json; json.load(open('$SETTINGS_FILE'))" 2>/dev/null; then
        ALERTS="${ALERTS}INVALID_SETTINGS_JSON\n"
    fi
else
    ALERTS="${ALERTS}MISSING_SETTINGS_JSON\n"
fi

# Check 3: project.json exists and is valid
CONFIG_FILE="$PROJECT_ROOT/.claude/project.json"
if [ -f "$CONFIG_FILE" ]; then
    if ! python3 -c "import json; json.load(open('$CONFIG_FILE'))" 2>/dev/null; then
        ALERTS="${ALERTS}INVALID_PROJECT_JSON\n"
    fi
else
    ALERTS="${ALERTS}MISSING_PROJECT_JSON (optional)\n"
fi

# Check 4: Verify sessions are being logged
if [ -f "$SESSION_LOG" ]; then
    LAST_MODIFIED=$(stat -f %m "$SESSION_LOG" 2>/dev/null || stat -c %Y "$SESSION_LOG" 2>/dev/null)
    CURRENT_TIME=$(date +%s)
    TIME_DIFF=$((CURRENT_TIME - LAST_MODIFIED))

    # Alert if no sessions logged in 7 days (604800 seconds)
    if [ "$TIME_DIFF" -gt 604800 ]; then
        ALERTS="${ALERTS}NO_RECENT_SESSIONS: Last session ${TIME_DIFF}s ago\n"
    fi
fi

# Check 5: Verify PreCompact is triggering
if [ -f "$COMPACT_LOG" ]; then
    AUTO_COUNT=$(grep -c "triggered: auto" "$COMPACT_LOG" 2>/dev/null || true)
    MANUAL_COUNT=$(grep -c "triggered: manual" "$COMPACT_LOG" 2>/dev/null || true)
    UNKNOWN_COUNT=$(grep -c "triggered: unknown" "$COMPACT_LOG" 2>/dev/null || true)

    # Ensure counts are valid integers
    [ -z "$AUTO_COUNT" ] && AUTO_COUNT=0
    [ -z "$MANUAL_COUNT" ] && MANUAL_COUNT=0
    [ -z "$UNKNOWN_COUNT" ] && UNKNOWN_COUNT=0

    # Convert to integers (remove any newlines)
    AUTO_COUNT=$(echo "$AUTO_COUNT" | tr -d '\n')
    MANUAL_COUNT=$(echo "$MANUAL_COUNT" | tr -d '\n')
    UNKNOWN_COUNT=$(echo "$UNKNOWN_COUNT" | tr -d '\n')

    # Alert if all compactions show "unknown" (hook not triggering properly)
    TOTAL=$((AUTO_COUNT + MANUAL_COUNT + UNKNOWN_COUNT))
    if [ "$TOTAL" -gt 0 ] && [ "$UNKNOWN_COUNT" -eq "$TOTAL" ]; then
        ALERTS="${ALERTS}PRECOMPACT_HOOK_NOT_TRIGGERING: All $TOTAL compactions show 'unknown' trigger\n"
    fi

    echo "  Compact stats: auto=$AUTO_COUNT manual=$MANUAL_COUNT unknown=$UNKNOWN_COUNT" >> "$MONITOR_LOG"
fi

# Write alerts if any
if [ -n "$ALERTS" ]; then
    echo "[$TIMESTAMP] ALERTS DETECTED:" >> "$MONITOR_LOG"
    echo -e "$ALERTS" >> "$MONITOR_LOG"

    # Write to alerts file for easy checking
    echo "[$TIMESTAMP] Project: $PROJECT_NAME" > "$ALERT_FILE"
    echo -e "$ALERTS" >> "$ALERT_FILE"

    echo "[$TIMESTAMP] MONITOR_RUN completed with alerts" >> "$MONITOR_LOG"

    # Optional: Send notification (uncomment and configure)
    # curl -X POST "$WEBHOOK_URL" -d "{\"text\": \"Hooks Alert ($PROJECT_NAME): $ALERTS\"}"
    # mail -s "Hooks Alert - $PROJECT_NAME" "admin@example.com" <<< "$ALERTS"

    exit 1
else
    # Clear alerts file if no issues
    rm -f "$ALERT_FILE"
    echo "[$TIMESTAMP] MONITOR_RUN completed OK" >> "$MONITOR_LOG"
    exit 0
fi
