#!/bin/bash
# Pre-Commit Quality Gate Hook
# PreToolUse hook (matcher: Bash) that quality-checks before git commit.
#
# Checks staged files for:
#   - debugger statements (blocks commit)
#   - Secret patterns: AWS keys, GitHub tokens, OpenAI keys, api_key assignments (blocks commit)
#   - console.log statements outside comments (warns)
#   - Conventional commit message format (warns)
#
# Exit codes:
#   0 - allow (clean or warnings only)
#   2 - block (errors found: debugger, secrets)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UTILS_DIR="$SCRIPT_DIR/utils"

source "$UTILS_DIR/hook-profile.sh"
hook_gate "pre:bash:pre-commit-quality" "standard,strict"

# Source JSON logger if available
if [ -f "$UTILS_DIR/json-logger.sh" ]; then
    source "$UTILS_DIR/json-logger.sh"
    LOGGING_ENABLED=true
else
    LOGGING_ENABLED=false
fi

# Read input from Claude Code
INPUT=$(cat)

# Extract the command from tool_input
COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

# Only activate on git commit (not --amend)
if ! echo "$COMMAND" | grep -q 'git commit'; then
    echo "$INPUT"
    exit 0
fi

# Skip if this is an amend
if echo "$COMMAND" | grep -q '\-\-amend'; then
    echo "$INPUT"
    exit 0
fi

# Get staged files (Added, Copied, Modified, Renamed)
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || echo "")

if [ -z "$STAGED_FILES" ]; then
    echo "$INPUT"
    exit 0
fi

ERRORS=()
WARNINGS=()

# Secret patterns
SECRET_PATTERNS=(
    'AKIA[A-Z0-9]{16}'
    'ghp_[a-zA-Z0-9]{36}'
    'sk-[a-zA-Z0-9]{20,}'
    'api_key[[:space:]]*[:=][[:space:]]*['"'"'"][^'"'"'"]+['"'"'"]'
)

# Check each staged file
while IFS= read -r file; do
    [ -z "$file" ] && continue

    # Only check relevant file extensions
    case "$file" in
        *.js|*.jsx|*.ts|*.tsx|*.py|*.go|*.rs) ;;
        *) continue ;;
    esac

    # Get the staged content of the file
    STAGED_CONTENT=$(git show ":$file" 2>/dev/null || continue)

    # Check for debugger statements
    if echo "$STAGED_CONTENT" | grep -nE '^\s*debugger\s*;?\s*$' > /dev/null 2>&1; then
        ERRORS+=("$file: contains 'debugger' statement")
    fi

    # Check for secret patterns
    for pattern in "${SECRET_PATTERNS[@]}"; do
        if echo "$STAGED_CONTENT" | grep -nE "$pattern" > /dev/null 2>&1; then
            ERRORS+=("$file: contains potential secret matching pattern '$pattern'")
        fi
    done

    # Check for console.log (warn only, skip comments)
    # Filter out single-line comments (//) and hash comments (#)
    UNCOMMENTED=$(echo "$STAGED_CONTENT" | sed 's|//.*||' | sed 's|#.*||')
    if echo "$UNCOMMENTED" | grep -nE 'console\.log\(' > /dev/null 2>&1; then
        WARNINGS+=("$file: contains 'console.log' (consider removing before commit)")
    fi

done <<< "$STAGED_FILES"

# Check conventional commit message format if -m flag is present
COMMIT_MSG=""
if echo "$COMMAND" | grep -qE '\-m\s'; then
    # Extract the message after -m flag — handle both -m "msg" and -m 'msg'
    COMMIT_MSG=$(echo "$COMMAND" | sed -n "s/.*-m[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    if [ -z "$COMMIT_MSG" ]; then
        # Try without quotes (heredoc style won't be captured but that's OK)
        COMMIT_MSG=$(echo "$COMMAND" | sed -n 's/.*-m[[:space:]]*\([^[:space:]]*\).*/\1/p')
    fi

    if [ -n "$COMMIT_MSG" ]; then
        # Check conventional commit format
        if ! echo "$COMMIT_MSG" | grep -qE '^(feat|fix|docs|style|refactor|test|chore|build|ci|perf|revert)(\(.+\))?: .+'; then
            WARNINGS+=("Commit message does not follow conventional commit format (feat|fix|docs|...): <description>")
        fi
    fi
fi

# Log findings
if [ "$LOGGING_ENABLED" = "true" ]; then
    err_count=${#ERRORS[@]}
    warn_count=${#WARNINGS[@]}
    log_hook "pre_commit_quality" "Bash" "checked" "errors=$err_count warnings=$warn_count"
fi

# Report findings
if [ ${#ERRORS[@]} -gt 0 ]; then
    # Build error message for additionalContext
    ERROR_MSG="PRE-COMMIT QUALITY GATE FAILED:\\n"
    for err in "${ERRORS[@]}"; do
        ERROR_MSG+="  ERROR: $err\\n"
        echo "[pre-commit-quality] ERROR: $err" >&2
    done
    for warn in "${WARNINGS[@]}"; do
        ERROR_MSG+="  WARNING: $warn\\n"
        echo "[pre-commit-quality] WARNING: $warn" >&2
    done
    ERROR_MSG+="Fix errors before committing. Remove debugger statements and secrets from staged files."

    echo "{\"decision\": \"block\", \"reason\": \"Pre-commit quality check failed\", \"systemMessage\": \"$ERROR_MSG\"}"
    exit 2
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
    for warn in "${WARNINGS[@]}"; do
        echo "[pre-commit-quality] WARNING: $warn" >&2
    done
fi

# Allow — echo input back unchanged
echo "$INPUT"
exit 0
