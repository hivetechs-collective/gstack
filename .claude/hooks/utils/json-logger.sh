#!/bin/bash
# JSON Logger Utility for Claude Code Hooks
# Provides structured logging for all hook events with analytics support
#
# Logs: ${CLAUDE_LOG_DIR:-$HOME/.claude/logs}/{hooks,sessions,security}.jsonl
#
# This file is SOURCED by hooks, so it defines functions only and assigns no
# globals. It used to set LOG_DIR / HOOKS_LOG / SESSION_LOG / SECURITY_LOG at
# source time, which overwrote session-end.sh's and session-start.sh's own
# SESSION_LOG (.claude/state/session-log.txt): their text blocks went into
# sessions.jsonl and session-log.txt stopped updating after 2026-01-24. Paths are
# now resolved inside each function, at call time. Pinned by json-logger.test.sh.

# Print the path of one log file, creating the log dir if needed. Returns 1 when
# the dir cannot be created; logging is best-effort and must never fail a hook.
_json_log_path() {
    local dir="${CLAUDE_LOG_DIR:-$HOME/.claude/logs}"
    mkdir -p "$dir" 2>/dev/null || return 1
    echo "$dir/$1"
}

# Append one line to one log file (best-effort, silent on failure).
_json_log_append() {
    local path
    path=$(_json_log_path "$1") || return 0
    echo "$2" >> "$path" 2>/dev/null || true
}

# Get ISO timestamp
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Get session ID (use Claude's or generate one)
get_session_id() {
    echo "${CLAUDE_SESSION_ID:-$(date +%s)}"
}

# Log a hook event
# Usage: log_hook <hook_type> <tool_name> <decision> <reason> [extra_json]
log_hook() {
    local hook_type="$1"
    local tool_name="$2"
    local decision="$3"
    local reason="$4"
    # Not "${5:-{}}": that parses as "${5:-{}" plus a literal "}" (stray brace).
    local extra="$5"
    [ -n "$extra" ] || extra='{}'

    local timestamp=$(get_timestamp)
    local session_id=$(get_session_id)
    local project_dir="${PWD##*/}"

    # Build JSON log entry
    local log_entry=$(cat <<EOF
{"timestamp":"$timestamp","session_id":"$session_id","hook":"$hook_type","tool":"$tool_name","decision":"$decision","reason":"$reason","project":"$project_dir","extra":$extra}
EOF
)

    _json_log_append "hooks.jsonl" "$log_entry"
}

# Log a security event (blocked or asked)
# Usage: log_security <event_type> <tool> <pattern> <action> <path_or_command>
log_security() {
    local event_type="$1"
    local tool="$2"
    local pattern="$3"
    local action="$4"
    local target="$5"

    local timestamp=$(get_timestamp)
    local session_id=$(get_session_id)
    local project_dir="${PWD##*/}"

    local log_entry=$(cat <<EOF
{"timestamp":"$timestamp","session_id":"$session_id","event":"$event_type","tool":"$tool","pattern":"$pattern","action":"$action","target":"$target","project":"$project_dir"}
EOF
)

    _json_log_append "security.jsonl" "$log_entry"
}

# Log session lifecycle
# Usage: log_session <event> [extra_json]
log_session() {
    local event="$1"
    local extra="$2"
    [ -n "$extra" ] || extra='{}'

    local timestamp=$(get_timestamp)
    local session_id=$(get_session_id)
    local project_dir="${PWD##*/}"

    local log_entry=$(cat <<EOF
{"timestamp":"$timestamp","session_id":"$session_id","event":"$event","project":"$project_dir","extra":$extra}
EOF
)

    _json_log_append "sessions.jsonl" "$log_entry"
}

# Get hook statistics
# Usage: get_hook_stats [hours_back]
get_hook_stats() {
    local hours="${1:-24}"
    local HOOKS_LOG="${CLAUDE_LOG_DIR:-$HOME/.claude/logs}/hooks.jsonl"
    local cutoff=$(date -u -v-${hours}H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "$hours hours ago" +"%Y-%m-%dT%H:%M:%SZ")

    if [ -f "$HOOKS_LOG" ]; then
        echo "=== Hook Statistics (last ${hours}h) ==="
        echo ""
        echo "By Hook Type:"
        grep -E "\"timestamp\":\"[^\"]+\"" "$HOOKS_LOG" | \
            jq -r '.hook' 2>/dev/null | sort | uniq -c | sort -rn
        echo ""
        echo "By Decision:"
        grep -E "\"timestamp\":\"[^\"]+\"" "$HOOKS_LOG" | \
            jq -r '.decision' 2>/dev/null | sort | uniq -c | sort -rn
        echo ""
        echo "By Tool:"
        grep -E "\"timestamp\":\"[^\"]+\"" "$HOOKS_LOG" | \
            jq -r '.tool' 2>/dev/null | sort | uniq -c | sort -rn
    else
        echo "No hook logs found"
    fi
}

# Get security statistics
get_security_stats() {
    local SECURITY_LOG="${CLAUDE_LOG_DIR:-$HOME/.claude/logs}/security.jsonl"
    if [ -f "$SECURITY_LOG" ]; then
        echo "=== Security Events ==="
        echo ""
        echo "By Action:"
        jq -r '.action' "$SECURITY_LOG" 2>/dev/null | sort | uniq -c | sort -rn
        echo ""
        echo "Recent Blocks:"
        tail -5 "$SECURITY_LOG" | jq -r '"[\(.timestamp)] \(.action): \(.target)"' 2>/dev/null
    else
        echo "No security events logged"
    fi
}

# Export functions for sourcing
export -f _json_log_path _json_log_append log_hook log_security log_session get_hook_stats get_security_stats get_timestamp get_session_id
