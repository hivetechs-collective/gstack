#!/bin/bash
# Auto-Tmux Dev Server Hook (PreToolUse: Bash)
# Redirects dev server commands to background tmux sessions instead of
# blocking Claude's main process. Prevents the common issue where running
# `npm run dev` blocks Claude until the server is manually killed.
#
# Intercepted commands:
#   npm run dev, npm start, pnpm dev, yarn dev, bun dev,
#   next dev, vite, cargo run, python -m flask run, uvicorn, etc.
#
# Exit codes:
#   0 = allow (not a dev server command, or tmux not available)
#   2 = block + redirect to tmux

set -e

UTILS_DIR="$(cd "$(dirname "$0")/utils" && pwd)"
source "$UTILS_DIR/hook-profile.sh"
hook_gate "pre:bash:auto-tmux" "standard,strict"

INPUT=$(cat)

# Check if tmux is available
if ! command -v tmux &>/dev/null; then
    echo "$INPUT"
    exit 0
fi

# Extract command from tool_input
COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

[ -z "$COMMAND" ] && { echo "$INPUT"; exit 0; }

# Detect dev server commands (long-running processes that block stdin)
IS_DEV_SERVER=false
DEV_SESSION_NAME=""

case "$COMMAND" in
    *"npm run dev"*|*"npm run start"*|*"npm start"*)
        IS_DEV_SERVER=true
        DEV_SESSION_NAME="dev-npm"
        ;;
    *"pnpm dev"*|*"pnpm run dev"*|*"pnpm start"*)
        IS_DEV_SERVER=true
        DEV_SESSION_NAME="dev-pnpm"
        ;;
    *"yarn dev"*|*"yarn start"*)
        IS_DEV_SERVER=true
        DEV_SESSION_NAME="dev-yarn"
        ;;
    *"bun dev"*|*"bun run dev"*)
        IS_DEV_SERVER=true
        DEV_SESSION_NAME="dev-bun"
        ;;
    *"next dev"*)
        IS_DEV_SERVER=true
        DEV_SESSION_NAME="dev-next"
        ;;
    *"vite"*)
        # Avoid matching vite.config.ts reads etc
        if echo "$COMMAND" | grep -qE '^\s*(npx\s+)?vite\s*$'; then
            IS_DEV_SERVER=true
            DEV_SESSION_NAME="dev-vite"
        fi
        ;;
    *"cargo run"*)
        IS_DEV_SERVER=true
        DEV_SESSION_NAME="dev-cargo"
        ;;
    *"python -m flask run"*|*"flask run"*)
        IS_DEV_SERVER=true
        DEV_SESSION_NAME="dev-flask"
        ;;
    *"uvicorn"*)
        IS_DEV_SERVER=true
        DEV_SESSION_NAME="dev-uvicorn"
        ;;
    *"python manage.py runserver"*)
        IS_DEV_SERVER=true
        DEV_SESSION_NAME="dev-django"
        ;;
esac

if [ "$IS_DEV_SERVER" = false ]; then
    echo "$INPUT"
    exit 0
fi

# Kill existing session if running (clean restart)
tmux kill-session -t "$DEV_SESSION_NAME" 2>/dev/null || true

# Start new tmux session with the dev command
tmux new-session -d -s "$DEV_SESSION_NAME" "$COMMAND"

# Give the server a moment to start
sleep 2

echo "[auto-tmux] Redirected to tmux session '$DEV_SESSION_NAME'. Attach with: tmux attach -t $DEV_SESSION_NAME" >&2
echo "{\"decision\": \"block\", \"reason\": \"Dev server redirected to tmux session '$DEV_SESSION_NAME'. The server is running in the background. Use 'tmux attach -t $DEV_SESSION_NAME' to view output.\"}"
exit 2
