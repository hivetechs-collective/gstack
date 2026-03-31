#!/bin/bash
# MCP Health Check Hook
# Dual-role: PreToolUse (warn on unhealthy) + PostToolUseFailure (track failures)
# Health state: ~/.claude/mcp-health-cache.json | Backoff: min(2^failures * 30, 600)s
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UTILS_DIR="$SCRIPT_DIR/utils"
CACHE_FILE="$HOME/.claude/mcp-health-cache.json"

if [ -f "$UTILS_DIR/json-logger.sh" ]; then
    source "$UTILS_DIR/json-logger.sh"; LOGGING_ENABLED=true
else LOGGING_ENABLED=false; fi

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

# Only process MCP tools (mcp__<server>__<action>)
if [[ "$TOOL_NAME" != mcp__* ]]; then echo "$INPUT"; exit 0; fi

# Extract server name using __ as delimiter (server names may contain single _)
SERVER_NAME=$(echo "$TOOL_NAME" | awk -F'__' '{print $2}')
if [ -z "$SERVER_NAME" ]; then echo "$INPUT"; exit 0; fi

# Ensure cache file exists
mkdir -p "$(dirname "$CACHE_FILE")"
if [ ! -f "$CACHE_FILE" ] || [ ! -s "$CACHE_FILE" ]; then
    echo '{"servers":{}}' > "$CACHE_FILE"
fi

now_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

to_epoch() {
    local ts="$1"
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null && return
    date -d "$ts" +%s 2>/dev/null || echo 0
}

calc_backoff() {
    local b=$(( (1 << $1) * 30 ))
    [ "$b" -gt 600 ] && b=600
    echo "$b"
}

EVENT="${CLAUDE_HOOK_EVENT_NAME:-PreToolUse}"

if [ "$EVENT" = "PreToolUse" ]; then
    BACKOFF_UNTIL=$(jq -r ".servers[\"$SERVER_NAME\"].backoff_until // empty" "$CACHE_FILE" 2>/dev/null || echo "")
    FAILURES=$(jq -r ".servers[\"$SERVER_NAME\"].failures // 0" "$CACHE_FILE" 2>/dev/null || echo "0")

    if [ -n "$BACKOFF_UNTIL" ] && [ "$BACKOFF_UNTIL" != "null" ]; then
        BACKOFF_EPOCH=$(to_epoch "$BACKOFF_UNTIL")
        NOW_EPOCH=$(now_epoch)
        if [ "$BACKOFF_EPOCH" -gt "$NOW_EPOCH" ] 2>/dev/null; then
            echo "[MCP Health] Server '$SERVER_NAME' is unhealthy (${FAILURES} failures). Backing off until ${BACKOFF_UNTIL}. Consider using alternative tools." >&2
            [ "$LOGGING_ENABLED" = "true" ] && log_hook "mcp_health" "$TOOL_NAME" "warn" "Server $SERVER_NAME unhealthy, in backoff"
        else
            # Past backoff — recover server
            UPDATED=$(jq ".servers[\"$SERVER_NAME\"] = {\"healthy\": true, \"failures\": 0, \"last_failure\": null, \"backoff_until\": null}" "$CACHE_FILE")
            echo "$UPDATED" > "$CACHE_FILE"
            [ "$LOGGING_ENABLED" = "true" ] && log_hook "mcp_health" "$TOOL_NAME" "recover" "Server $SERVER_NAME recovered after backoff"
        fi
    fi
    echo "$INPUT"; exit 0

elif [ "$EVENT" = "PostToolUseFailure" ]; then
    NOW=$(now_ts)
    FAILURES=$(jq -r ".servers[\"$SERVER_NAME\"].failures // 0" "$CACHE_FILE" 2>/dev/null || echo "0")
    FAILURES=$(( FAILURES + 1 ))
    BACKOFF_SECS=$(calc_backoff "$FAILURES")
    HEALTHY="true"
    [ "$FAILURES" -ge 3 ] && HEALTHY="false"

    # Calculate backoff_until (macOS + Linux)
    if date -v+${BACKOFF_SECS}S +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
        BACKOFF_UNTIL=$(date -u -v+${BACKOFF_SECS}S +"%Y-%m-%dT%H:%M:%SZ")
    else
        BACKOFF_UNTIL=$(date -u -d "+${BACKOFF_SECS} seconds" +"%Y-%m-%dT%H:%M:%SZ")
    fi

    UPDATED=$(jq ".servers[\"$SERVER_NAME\"] = {\"healthy\": $HEALTHY, \"failures\": $FAILURES, \"last_failure\": \"$NOW\", \"backoff_until\": \"$BACKOFF_UNTIL\"}" "$CACHE_FILE")
    echo "$UPDATED" > "$CACHE_FILE"

    echo "[MCP Health] Server '$SERVER_NAME' failure #${FAILURES}. Backing off for ${BACKOFF_SECS}s." >&2
    [ "$LOGGING_ENABLED" = "true" ] && log_hook "mcp_health" "$TOOL_NAME" "failure" "Server $SERVER_NAME failure #$FAILURES, backoff ${BACKOFF_SECS}s"
    echo "$INPUT"; exit 0
fi

echo "$INPUT"; exit 0
