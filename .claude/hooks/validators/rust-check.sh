#!/bin/bash
# PostToolUse Validator: Rust compilation check
# Runs cargo check after .rs file edits to catch errors immediately

set -e

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

# Only check Rust files
if [[ ! "$FILE_PATH" =~ \.rs$ ]]; then
    exit 0
fi

# Skip target directory
if [[ "$FILE_PATH" =~ /target/ ]]; then
    exit 0
fi

# Find project root (where Cargo.toml lives)
PROJECT_ROOT=$(dirname "$FILE_PATH")
while [ "$PROJECT_ROOT" != "/" ]; do
    if [ -f "$PROJECT_ROOT/Cargo.toml" ]; then
        break
    fi
    PROJECT_ROOT=$(dirname "$PROJECT_ROOT")
done

if [ ! -f "$PROJECT_ROOT/Cargo.toml" ]; then
    # No Cargo.toml found, skip validation
    exit 0
fi

# Run cargo check
cd "$PROJECT_ROOT"

if command -v cargo &> /dev/null; then
    OUTPUT=$(cargo check --message-format=short 2>&1) || {
        # Compilation errors found - exit code 2 triggers self-correction
        # Truncate output if too long
        TRUNCATED=$(echo "$OUTPUT" | tail -30)
        echo "{\"decision\": \"block\", \"reason\": \"Rust compilation errors\", \"systemMessage\": \"cargo check failed. Fix these errors:\\n$TRUNCATED\"}" >&2
        exit 2
    }
fi

exit 0
