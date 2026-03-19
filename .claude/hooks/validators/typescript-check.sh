#!/bin/bash
# PostToolUse Validator: TypeScript type checking
# Runs tsc after .ts/.tsx file edits to catch type errors immediately

set -e

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

# Only check TypeScript files
if [[ ! "$FILE_PATH" =~ \.(ts|tsx)$ ]]; then
    exit 0
fi

# Skip node_modules and build directories
if [[ "$FILE_PATH" =~ node_modules|dist|\.next|build ]]; then
    exit 0
fi

# Find project root (where tsconfig.json lives)
PROJECT_ROOT=$(dirname "$FILE_PATH")
while [ "$PROJECT_ROOT" != "/" ]; do
    if [ -f "$PROJECT_ROOT/tsconfig.json" ]; then
        break
    fi
    PROJECT_ROOT=$(dirname "$PROJECT_ROOT")
done

if [ ! -f "$PROJECT_ROOT/tsconfig.json" ]; then
    # No tsconfig found, skip validation
    exit 0
fi

# Run TypeScript check
cd "$PROJECT_ROOT"

# Check if tsc is available
if command -v npx &> /dev/null; then
    # Run tsc with noEmit to just check types
    OUTPUT=$(npx tsc --noEmit 2>&1) || {
        # Type errors found - exit code 2 triggers self-correction
        echo "{\"decision\": \"block\", \"reason\": \"TypeScript errors\", \"systemMessage\": \"TypeScript compilation failed. Fix these errors:\\n$OUTPUT\"}" >&2
        exit 2
    }
fi

exit 0
