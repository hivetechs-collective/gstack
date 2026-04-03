#!/bin/bash
# PostToolUse Validator: ESLint check
# Runs ESLint after .js/.jsx/.ts/.tsx edits to catch linting errors
#
# Transient rules (no-unused-vars and variants) are treated as WARNINGS
# during multi-edit workflows, mirroring the TS6133 tolerance in
# typescript-check.sh. Real lint errors still block.

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

# Transient rules: expected during multi-edit workflows
# (e.g., adding import before usage site, removing usage before import)
TRANSIENT_RE="no-unused-vars|@typescript-eslint/no-unused-vars|unused-imports/no-unused-imports|unused-imports/no-unused-vars"

if [ -f "node_modules/.bin/eslint" ] || command -v npx &> /dev/null; then
    # Run ESLint on the specific file (errors only, not warnings)
    OUTPUT=$(npx eslint "$FILE_PATH" --quiet 2>&1) || {
        # ESLint stylish format error lines: "  2:10  error  message  rule-name"
        ALL_ERRORS=$(echo "$OUTPUT" | grep "  error  " || true)

        if [ -z "$ALL_ERRORS" ]; then
            # Can't parse output format — block with raw output (safe fallback)
            TRUNCATED=$(echo "$OUTPUT" | tail -20)
            echo "{\"decision\": \"block\", \"reason\": \"ESLint errors\", \"systemMessage\": \"ESLint found errors. Fix these issues:\\n$TRUNCATED\"}" >&2
            exit 2
        fi

        # Separate transient from real errors
        REAL_ERRORS=$(echo "$ALL_ERRORS" | grep -vE "($TRANSIENT_RE)[[:space:]]*$" || true)
        TRANSIENT=$(echo "$ALL_ERRORS" | grep -E "($TRANSIENT_RE)[[:space:]]*$" || true)

        if [ -n "$REAL_ERRORS" ]; then
            # Real ESLint errors — block and require fix
            TRUNCATED=$(echo "$OUTPUT" | tail -20)
            echo "{\"decision\": \"block\", \"reason\": \"ESLint errors\", \"systemMessage\": \"ESLint found errors. Fix these issues:\\n$TRUNCATED\"}" >&2
            exit 2
        elif [ -n "$TRANSIENT" ]; then
            # Only unused variable/import errors — warn but don't block
            COUNT=$(echo "$TRANSIENT" | wc -l | tr -d ' ')
            echo "{\"decision\": \"allow\", \"reason\": \"ESLint: $COUNT unused variable/import warning(s) — expected during multi-edit workflow, will resolve when usage/removal is completed\"}" >&2
            exit 0
        fi
    }
fi

exit 0
