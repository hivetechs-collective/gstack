#!/bin/bash
# Hook Runtime Profile Gating Utility
# Allows hooks to be enabled/disabled based on profile level and explicit overrides

# Profile: minimal, standard (default), strict
CLAUDE_HOOK_PROFILE="${CLAUDE_HOOK_PROFILE:-standard}"

# Comma-separated hook IDs to force-disable (e.g., "post:edit:typecheck,pre:bash:tmux")
CLAUDE_DISABLED_HOOKS="${CLAUDE_DISABLED_HOOKS:-}"

# Check if a hook is enabled under current profile and not explicitly disabled
# Usage: hook_enabled "pre:bash:config-protection" "standard,strict"
# Returns: 0 (enabled) or 1 (disabled)
hook_enabled() {
    local hook_id="$1"
    local allowed_profiles="$2"

    # Check explicit disable list first
    if [[ -n "$CLAUDE_DISABLED_HOOKS" ]]; then
        local IFS=','
        for disabled in $CLAUDE_DISABLED_HOOKS; do
            [[ "$disabled" == "$hook_id" ]] && return 1
        done
    fi

    # Check if current profile is in the allowed list
    local IFS=','
    for profile in $allowed_profiles; do
        [[ "$profile" == "$CLAUDE_HOOK_PROFILE" ]] && return 0
    done

    return 1
}

# Gate a hook script: check profile, exit 0 with stdin passthrough if disabled
# Usage (at top of hook): hook_gate "pre:edit:config-protection" "standard,strict"
hook_gate() {
    if ! hook_enabled "$1" "$2"; then
        cat  # passthrough stdin
        exit 0
    fi
}

# Export functions for sourcing
export -f hook_enabled hook_gate
