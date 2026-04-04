#!/bin/bash
# Claude Code Damage Control Hook
# Implements three-tier protection: zeroAccess > readOnly > noDelete
# Plus dangerous command blocking with ask mode for risky operations
#
# Adapted from disler/claude-code-damage-control

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERNS_FILE="$SCRIPT_DIR/patterns.yaml"
UTILS_DIR="$(dirname "$SCRIPT_DIR")/utils"

# Source JSON logger if available
if [ -f "$UTILS_DIR/json-logger.sh" ]; then
    source "$UTILS_DIR/json-logger.sh"
    LOGGING_ENABLED=true
else
    LOGGING_ENABLED=false
fi

# Read input from Claude Code
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

# Helper: Output JSON response (v2.1.0+ additionalContext support)
respond() {
    local decision="$1"
    local reason="$2"
    local message="$3"
    local target="${4:-unknown}"

    # Log security event
    if [ "$LOGGING_ENABLED" = "true" ]; then
        log_security "damage_control" "$TOOL_NAME" "$reason" "$decision" "$target"
    fi

    # Build additionalContext for Claude to understand the block reason
    local context="DAMAGE CONTROL: $reason. Target: $target. This is a safety guardrail - consider alternative approaches."

    if [ "$decision" = "block" ]; then
        echo "{\"decision\": \"block\", \"reason\": \"$reason\", \"systemMessage\": \"$message\", \"additionalContext\": \"$context\"}"
        exit 2
    elif [ "$decision" = "ask" ]; then
        echo "{\"decision\": \"ask\", \"reason\": \"$reason\", \"systemMessage\": \"$message\", \"additionalContext\": \"$context\"}"
        exit 0
    else
        exit 0
    fi
}

# Helper: Check if path matches any pattern in a list
path_matches() {
    local path="$1"
    local patterns="$2"

    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        # Expand ~ to home directory
        local expanded_pattern="${pattern/#\~/$HOME}"

        # Check for glob match
        if [[ "$path" == $expanded_pattern ]] || [[ "$path" == *"$expanded_pattern"* ]]; then
            return 0
        fi
    done <<< "$patterns"
    return 1
}

# Extract file path from input (for Edit/Write tools)
get_file_path() {
    echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo ""
}

# Extract command from input (for Bash tool)
get_command() {
    echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo ""
}

# =============================================================================
# BASH COMMAND PROTECTION
# =============================================================================
check_bash_command() {
    local cmd="$1"

    # Safe targets for rm -rf — build caches and generated artifacts
    # These are always safe to delete and should never be blocked
    local safe_rm_targets=(
        '\.next'
        'node_modules'
        'dist'
        'target'
        'build'
        '__pycache__'
        '\.turbo'
        '\.parcel-cache'
        '\.cache'
        '\.tsbuildinfo'
    )

    # If this is an rm -rf command, check if it targets a safe directory
    if echo "$cmd" | grep -qE 'rm\s+(-[^\s]*)?-[rf]'; then
        for safe in "${safe_rm_targets[@]}"; do
            if echo "$cmd" | grep -qE "rm\s+(-[^\s]*)?-[rf]+\s+.*${safe}"; then
                # Safe build cache cleanup — allow without blocking
                return 0
            fi
        done
    fi

    # Dangerous patterns that should be blocked
    local block_patterns=(
        'rm\s+(-[^\s]*)?(-(rf|fr)|[^\s]*rf|[^\s]*fr)'
        'rmdir\s+--ignore-fail-on-non-empty'
        'chmod\s+777'
        'chown\s+(-R|--recursive)\s+root'
        'git\s+reset\s+--hard'
        'git\s+clean\s+-[fd]'
        'git\s+push.*--force([^-]|$)'
        'git\s+push.*\s-f([^o]|$)'
        'git\s+checkout\s+\.\s*$'
        'git\s+restore\s+\.\s*$'
        'git\s+stash\s+clear'
        'aws\s+ec2\s+terminate-instances'
        'aws\s+rds\s+delete-db'
        'aws\s+s3\s+rb.*--force'
        'terraform\s+destroy'
        'pulumi\s+destroy'
        'kubectl\s+delete\s+namespace'
        'kubectl\s+delete.*--all'
        'docker\s+rm\s+-f.*\$\(docker\s+ps'
        'npm\s+unpublish'
        'redis-cli.*FLUSHALL'
    )

    # Case-insensitive patterns (SQL)
    local block_patterns_ci=(
        'DROP\s+DATABASE'
        'DELETE\s+FROM\s+\w+\s*;?$'
    )

    # Patterns that should prompt for confirmation
    local ask_patterns=(
        'git\s+branch\s+-[dD]'
        'git\s+stash\s+drop'
        'git\s+push.*origin\s+(main|master)\b'
        'gcloud.*delete'
        'az\s+.*\s+delete'
        'docker\s+system\s+prune'
        'redis-cli.*FLUSHDB'
        'cargo\s+yank'
    )

    local ask_patterns_ci=(
        'DROP\s+TABLE'
        'TRUNCATE\s+TABLE'
        'DELETE\s+FROM.*WHERE'
    )

    # Check block patterns
    for pattern in "${block_patterns[@]}"; do
        if echo "$cmd" | grep -qE "$pattern"; then
            respond "block" "Dangerous command blocked" "⛔ BLOCKED: Command matches dangerous pattern: $pattern" "$cmd"
        fi
    done

    # Check case-insensitive block patterns
    for pattern in "${block_patterns_ci[@]}"; do
        if echo "$cmd" | grep -qiE "$pattern"; then
            respond "block" "Dangerous SQL blocked" "⛔ BLOCKED: SQL command is too dangerous: $pattern" "$cmd"
        fi
    done

    # Check ask patterns
    for pattern in "${ask_patterns[@]}"; do
        if echo "$cmd" | grep -qE "$pattern"; then
            respond "ask" "Risky command requires confirmation" "⚠️ CONFIRM: This command requires approval: $pattern" "$cmd"
        fi
    done

    # Check case-insensitive ask patterns
    for pattern in "${ask_patterns_ci[@]}"; do
        if echo "$cmd" | grep -qiE "$pattern"; then
            respond "ask" "Risky SQL requires confirmation" "⚠️ CONFIRM: This SQL requires approval: $pattern" "$cmd"
        fi
    done
}

# =============================================================================
# FILE PATH PROTECTION
# =============================================================================
check_file_path() {
    local path="$1"
    local operation="$2"  # read, write, edit, delete

    # Allow .example template files (they contain dummy values, not real secrets)
    if [[ "$path" == *.example ]]; then
        return 0
    fi

    # Zero Access Paths - Block everything (except .example templates handled above)
    local zero_access=(
        "/.env"
        ".env.local"
        ".env.production"
        ".env.development"
        ".env.staging"
        "*.env"
        ".ssh/"
        "*.pem"
        "*.key"
        "id_rsa"
        "id_ed25519"
        ".gnupg/"
        ".aws/"
        ".config/gcloud/"
        ".azure/"
        ".kube/config"
        "*.tfstate"
        ".npmrc"
        ".pypirc"
        ".netrc"
        "*.p12"
        "*.pfx"
        "*secret*.json"
        "*credential*.json"
        "*token*.json"
    )

    for pattern in "${zero_access[@]}"; do
        if [[ "$path" == *"$pattern"* ]] || [[ "$path" == $pattern ]]; then
            respond "block" "Zero-access path" "⛔ BLOCKED: This path contains secrets/credentials and cannot be accessed: $path" "$path"
        fi
    done

    # Read-Only Paths - Block write/edit/delete
    if [ "$operation" != "read" ]; then
        local read_only=(
            "/etc/"
            "/usr/"
            "/System/"
            "node_modules/"
            "target/"
            "dist/"
            ".next/"
            "__pycache__/"
            "package-lock.json"
            "yarn.lock"
            "pnpm-lock.yaml"
            "Cargo.lock"
        )

        for pattern in "${read_only[@]}"; do
            if [[ "$path" == *"$pattern"* ]]; then
                respond "block" "Read-only path" "⛔ BLOCKED: This path is read-only and cannot be modified: $path" "$path"
            fi
        done
    fi

    # No-Delete Paths - Block only deletion
    if [ "$operation" = "delete" ]; then
        local no_delete=(
            "README.md"
            "LICENSE"
            "CHANGELOG.md"
            ".git/"
            ".gitignore"
            "Dockerfile"
            "docker-compose.yml"
            "Makefile"
            "Cargo.toml"
            "package.json"
            "tsconfig.json"
            ".claude/"
            "CLAUDE.md"
        )

        for pattern in "${no_delete[@]}"; do
            if [[ "$path" == *"$pattern"* ]]; then
                respond "block" "No-delete path" "⛔ BLOCKED: This critical file cannot be deleted: $path" "$path"
            fi
        done
    fi
}

# =============================================================================
# MAIN LOGIC
# =============================================================================

case "$TOOL_NAME" in
    Bash)
        cmd=$(get_command)
        if [ -n "$cmd" ]; then
            check_bash_command "$cmd"
        fi
        ;;

    Write|Edit)
        path=$(get_file_path)
        if [ -n "$path" ]; then
            check_file_path "$path" "write"
        fi
        ;;

    Read)
        path=$(get_file_path)
        if [ -n "$path" ]; then
            check_file_path "$path" "read"
        fi
        ;;
esac

# If we get here, allow the operation
exit 0
