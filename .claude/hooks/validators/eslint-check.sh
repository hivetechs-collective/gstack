#!/bin/bash
# PostToolUse Validator: ESLint check
# Runs ESLint after .js/.jsx/.ts/.tsx edits to catch linting errors

set -e

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

# Only check JavaScript/TypeScript files
if [[ ! "$FILE_PATH" =~ \.(js|jsx|ts|tsx)$ ]]; then
    exit 0
fi

# Skip node_modules and build directories
if [[ "$FILE_PATH" =~ node_modules|dist|\.next|build ]]; then
    exit 0
fi

# Find project root (where package.json or eslint config lives)
PROJECT_ROOT=$(dirname "$FILE_PATH")
while [ "$PROJECT_ROOT" != "/" ]; do
    if [ -f "$PROJECT_ROOT/package.json" ] || [ -f "$PROJECT_ROOT/.eslintrc.js" ] || [ -f "$PROJECT_ROOT/.eslintrc.json" ] || [ -f "$PROJECT_ROOT/eslint.config.js" ]; then
        break
    fi
    PROJECT_ROOT=$(dirname "$PROJECT_ROOT")
done

if [ ! -f "$PROJECT_ROOT/package.json" ]; then
    # No package.json found, skip validation
    exit 0
fi

# Check if eslint is available in project
cd "$PROJECT_ROOT"

if [ -f "node_modules/.bin/eslint" ] || command -v npx &> /dev/null; then
    # Run ESLint on the specific file (errors only, not warnings)
    OUTPUT=$(npx eslint "$FILE_PATH" --quiet 2>&1) || {
        # ESLint errors found - exit code 2 triggers self-correction
        TRUNCATED=$(echo "$OUTPUT" | tail -20)
        echo "{\"decision\": \"block\", \"reason\": \"ESLint errors\", \"systemMessage\": \"ESLint found errors. Fix these issues:\\n$TRUNCATED\"}" >&2
        exit 2
    }
fi

exit 0
