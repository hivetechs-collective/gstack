#!/bin/bash
# stop-failure-notify.sh — StopFailure hook: a turn ended on an API ERROR
# (auth wall / 401 after credential revocation, 5xx, network death), which is
# how an autonomous run halts SILENTLY. Distinct from Stop (normal end).
#
# Purpose: make silent halts loud. Fires a desktop notification, appends a
# durable breadcrumb to .claude/state/stop-failures.log, and — if an ntfy
# topic is configured — pushes to the phone so away-from-keyboard halts are
# noticed in minutes, not hours (2026-08-06: /login-wall runs sat halted for
# hours unnoticed; wake-from-sleep OAuth refresh race, fixed upstream in
# 2.1.221, but detection must not depend on the bug never recurring).
#
# Phone push (optional): export CLAUDE_HALT_NTFY_TOPIC=<topic> or write the
# topic as the sole line of ~/.config/claude/halt-ntfy-topic
#
# Contract: NEVER blocks, never exits non-zero, bash 3.2 safe.

INPUT=$(cat 2>/dev/null || true)
CWD_NOW=$(pwd)
TS=$(date "+%Y-%m-%d %H:%M:%S")
REPO=$(basename "${CLAUDE_PROJECT_DIR:-$CWD_NOW}")

# Best-effort error extraction from hook input (schema-defensive).
ERR=$(printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in ("error","errorMessage","message","reason","stopReason"):
    v=d.get(k)
    if isinstance(v,str) and v.strip():
        print(v[:180]); break
' 2>/dev/null)
[ -z "$ERR" ] && ERR="API error (details unavailable)"

MSG="Claude session HALTED in $REPO: $ERR"

# 1) Durable breadcrumb (works headless).
STATE_DIR="${CLAUDE_PROJECT_DIR:-$CWD_NOW}/.claude/state"
[ -d "$STATE_DIR" ] && printf '%s | %s | %s\n' "$TS" "$CWD_NOW" "$ERR" >> "$STATE_DIR/stop-failures.log" 2>/dev/null

# 2) Desktop notification (macOS; no-op elsewhere/headless).
if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$(printf '%s' "$MSG" | tr '"' "'")\" with title \"Claude Code halt\" sound name \"Basso\"" >/dev/null 2>&1 || true
fi

# 3) Phone push via ntfy (only if configured).
TOPIC="${CLAUDE_HALT_NTFY_TOPIC:-}"
[ -z "$TOPIC" ] && [ -f "$HOME/.config/claude/halt-ntfy-topic" ] && TOPIC=$(head -1 "$HOME/.config/claude/halt-ntfy-topic" 2>/dev/null)
if [ -n "$TOPIC" ] && command -v curl >/dev/null 2>&1; then
  curl -fsS -m 5 -H "Title: Claude Code halt" -H "Priority: high" -d "$MSG" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true
fi

exit 0
