#!/bin/bash
# PostToolUse Validator: JSON syntax validation
# Validates JSON files after edits to catch syntax errors immediately

set -e

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

# Only check JSON files
if [[ ! "$FILE_PATH" =~ \.json$ ]]; then
    exit 0
fi

# Skip node_modules
if [[ "$FILE_PATH" =~ node_modules ]]; then
    exit 0
fi

# Check if file exists
if [ ! -f "$FILE_PATH" ]; then
    exit 0
fi

# Validate JSON using Python (available on most systems)
if command -v python3 &> /dev/null; then
    OUTPUT=$(python3 -c "import json; json.load(open('$FILE_PATH'))" 2>&1) || {
        echo "{\"decision\": \"block\", \"reason\": \"Invalid JSON\", \"systemMessage\": \"JSON syntax error in $FILE_PATH:\\n$OUTPUT\"}" >&2
        exit 2
    }
elif command -v jq &> /dev/null; then
    OUTPUT=$(jq empty "$FILE_PATH" 2>&1) || {
        echo "{\"decision\": \"block\", \"reason\": \"Invalid JSON\", \"systemMessage\": \"JSON syntax error in $FILE_PATH:\\n$OUTPUT\"}" >&2
        exit 2
    }
fi

exit 0
