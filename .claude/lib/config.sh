#!/bin/bash
# Claude Pattern - Configuration Helper
# Sources project configuration from .claude/project.json
# Usage: source .claude/lib/config.sh

# Find project root (where .claude directory lives)
find_project_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.claude" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    echo ""
    return 1
}

# Get the project root
if [ -z "$PROJECT_ROOT" ]; then
    PROJECT_ROOT="$(find_project_root "$(pwd)")"
    if [ -z "$PROJECT_ROOT" ]; then
        PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    fi
fi

CONFIG_FILE="$PROJECT_ROOT/.claude/project.json"

# Read a value from project.json using jq or fallback to grep/sed
get_config() {
    local key="$1"
    local default="$2"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "$default"
        return
    fi

    # Try jq first (more reliable)
    if command -v jq &> /dev/null; then
        local value
        value=$(jq -r "$key // empty" "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$value" ] && [ "$value" != "null" ]; then
            echo "$value"
            return
        fi
    fi

    # Fallback for simple keys without jq
    echo "$default"
}

# Get nested config values
get_project_name() {
    get_config '.project.name' 'My Project'
}

get_project_description() {
    get_config '.project.description' 'Project description'
}

get_phase_current() {
    get_config '.phase.current' '1'
}

get_phase_name() {
    get_config '.phase.name' 'Development'
}

get_phase_target() {
    get_config '.phase.target' 'TBD'
}

get_ralph_calls() {
    get_config '.ralph.callsPerHour' '50'
}

get_ralph_timeout() {
    get_config '.ralph.timeoutMinutes' '45'
}

get_build_command() {
    get_config '.commands.build' 'npm run build'
}

get_test_command() {
    get_config '.commands.test' 'npm test'
}

# Get features as formatted list
get_features_list() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "   - No features configured"
        return
    fi

    if command -v jq &> /dev/null; then
        jq -r '.features[] | "   \u2022 \(.name) (\(.id)) \(if .status == "unblocked" then "\u2705" else "\u26a0\ufe0f" end)"' "$CONFIG_FILE" 2>/dev/null || echo "   - No features configured"
    else
        echo "   - See .claude/project.json for features"
    fi
}

# Get unblocked features count
get_unblocked_count() {
    if [ ! -f "$CONFIG_FILE" ] || ! command -v jq &> /dev/null; then
        echo "all"
        return
    fi
    jq '[.features[] | select(.status == "unblocked")] | length' "$CONFIG_FILE" 2>/dev/null || echo "all"
}

# Check if project is configured
is_configured() {
    [ -f "$CONFIG_FILE" ] && [ "$(get_project_name)" != "My Project" ]
}

# Export for subshells
export PROJECT_ROOT
export CONFIG_FILE
