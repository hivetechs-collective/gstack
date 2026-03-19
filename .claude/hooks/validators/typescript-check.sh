#!/bin/bash
# PostToolUse Validator: TypeScript type checking
# Runs tsc after .ts/.tsx file edits to catch type errors immediately
#
# TS6133 (unused imports/variables) are treated as WARNINGS, not blockers.
# These are transient during multi-edit workflows where an import is added
# before its usage site is edited. Real type errors still block.

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
        # Separate TS6133 (unused variable/import) from real type errors.
        # TS6133 is transient during multi-edit workflows — an import added
        # before its usage site is edited will trigger this. These resolve
        # naturally as the builder continues editing.
        REAL_ERRORS=$(echo "$OUTPUT" | grep -v 'TS6133' || true)
        TS6133_WARNINGS=$(echo "$OUTPUT" | grep 'TS6133' || true)

        if [ -n "$REAL_ERRORS" ]; then
            # Real type errors — block and require fix
            echo "{\"decision\": \"block\", \"reason\": \"TypeScript errors\", \"systemMessage\": \"TypeScript compilation failed. Fix these errors:\\n$OUTPUT\"}" >&2
            exit 2
        elif [ -n "$TS6133_WARNINGS" ]; then
            # Only unused imports/variables — warn but don't block
            # These are expected during multi-edit workflows
            COUNT=$(echo "$TS6133_WARNINGS" | wc -l | tr -d ' ')
            echo "{\"decision\": \"allow\", \"reason\": \"TS6133 warnings only ($COUNT unused imports/variables) — expected during multi-edit workflow, will resolve when usage is added\"}" >&2
            exit 0
        fi
    }
fi

exit 0
