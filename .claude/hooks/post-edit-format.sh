#!/bin/bash
# CleanScale: Auto-format files after Edit/Write operations
# Claude Code v2.1.2+ PostToolUse hook

# Read JSON input from Claude Code
INPUT=$(cat 2>/dev/null || echo "{}")
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")

# Exit if no file path
[ -z "$FILE_PATH" ] && exit 0

# Only format supported file types
case "$FILE_PATH" in
    *.ts|*.tsx|*.js|*.jsx|*.json|*.md|*.css|*.scss)
        # Check if prettier is available
        if command -v npx &> /dev/null; then
            npx prettier --write "$FILE_PATH" 2>/dev/null || true
        fi
        ;;
    *.rs)
        # Rust formatting
        if command -v rustfmt &> /dev/null; then
            rustfmt "$FILE_PATH" 2>/dev/null || true
        fi
        ;;
esac

exit 0
