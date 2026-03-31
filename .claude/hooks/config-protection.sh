#!/bin/bash
# Config Protection Hook (PreToolUse: Write|Edit)
# Blocks modifications to linter/formatter config files.
# Agents frequently weaken configs instead of fixing code.
#
# Exit codes:
#   0 = allow (not a config file)
#   2 = block (config file modification attempted)

set -e

UTILS_DIR="$(cd "$(dirname "$0")/utils" && pwd)"
source "$UTILS_DIR/hook-profile.sh"
hook_gate "pre:edit:config-protection" "standard,strict"

INPUT=$(cat)

# Extract file_path from JSON
FILE_PATH=$(echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

if [ -z "$FILE_PATH" ]; then
    echo "$INPUT"
    exit 0
fi

BASENAME=$(basename "$FILE_PATH")

# Protected linter/formatter config files (ESLint, Prettier, Biome, Ruff, shellcheck, stylelint, markdownlint)
case "$BASENAME" in
    .eslintrc|.eslintrc.js|.eslintrc.cjs|.eslintrc.json|.eslintrc.yml|.eslintrc.yaml|eslint.config.js|eslint.config.mjs|eslint.config.cjs|eslint.config.ts|eslint.config.mts|.prettierrc|.prettierrc.js|.prettierrc.cjs|.prettierrc.json|.prettierrc.yml|.prettierrc.yaml|prettier.config.js|prettier.config.cjs|prettier.config.mjs|biome.json|biome.jsonc|.ruff.toml|ruff.toml|.shellcheckrc|.stylelintrc|.stylelintrc.json|.stylelintrc.yml|.markdownlint.json|.markdownlint.yaml|.markdownlintrc)
        echo "BLOCKED: Modifying $BASENAME is not allowed. Fix the source code to satisfy linter/formatter rules instead of weakening the config. If this is a legitimate config change, set CLAUDE_DISABLED_HOOKS=pre:edit:config-protection" >&2
        exit 2
        ;;
    *)
        echo "$INPUT"
        exit 0
        ;;
esac
