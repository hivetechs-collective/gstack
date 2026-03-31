#!/bin/bash
# Desktop Notification Hook (Stop, async)
# Sends macOS notification when Claude finishes responding

set -e

UTILS_DIR="$(cd "$(dirname "$0")/utils" && pwd)"
source "$UTILS_DIR/hook-profile.sh"
hook_gate "stop:desktop-notify" "standard,strict"

INPUT=$(cat)

# Send notification via osascript (macOS only, fail silently)
osascript -e 'display notification "Claude finished responding" with title "Claude Code" sound name "Tink"' 2>/dev/null || true

echo "$INPUT"
