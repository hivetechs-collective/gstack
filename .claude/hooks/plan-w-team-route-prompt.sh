#!/usr/bin/env bash
# plan-w-team-route-prompt.sh
#
# UserPromptSubmit hook — defense-in-depth enforcement of the /plan-w-team
# routing rule. When the user's prompt OPENS with a "use /plan-w-team to ..."
# trigger phrase (natural-language autonomous-run pattern), this hook
# auto-launches pwt-goal.sh --launch in the background and blocks the original
# prompt so it never reaches the skill's pre-check. Closes the failure mode
# observed in cleanscale on 2026-05-20 where the agent misread the slash
# token as a "direct slash invocation" and ran the work in-session.
#
# === FAIL-OPEN CONTRACT ===
# This hook MUST NEVER block the user from working. On any internal error
# (missing jq, missing pwt-goal.sh, malformed input, launch failure, syntax
# error, anything), exit 0 silently so the prompt flows through unchanged.
# The "block" exit (2) is reserved for the ONE confirmed-launch path.
#
# === DISABLE MECHANISMS (any of these) ===
#   1. env: export PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1
#   2. sentinel: touch .claude/.pwt-route-disabled
#   3. settings: remove this hook entry from .claude/settings.json
#
# Do NOT disable by renaming this file — settings.json keeps the reference
# and Claude Code's hook runner exits 127, breaking every prompt. (This is
# the failure mode that made 1b4a64e dangerous.)
#
# === TRIGGER DETECTION (UNANCHORED — natural-language sacred) ===
# Trigger phrases fire anywhere in the prompt. Natural language is the
# user's product principle for /plan-w-team — they must be able to say
# "now lets test it, use /plan-w-team to ..." or "based on our analysis,
# use /plan-w-team to ..." and have it route. No position anchoring, no
# pleasantry-only prefix lists, no content-keyword exclusions. The trigger
# phrase list itself is specific enough ("use /plan-w-team to" etc.) to
# keep false positives low. The only OPT-OUT mechanisms are:
#   1. in-session phrases ("in this session", "run /plan-w-team here")
#   2. sentinel file (.claude/.pwt-route-disabled)
#   3. env var (PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1)
#   4. removing the entry from settings.json

set -u

# ─── Fail-open guard: any unexpected error → exit 0 (allow) ──────────────────
fail_open() { exit 0; }
trap fail_open ERR

# ─── Kill switches (env + sentinel file) ─────────────────────────────────────
[ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-}" = "1" ] && exit 0

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -z "$PROJECT_ROOT" ] && exit 0
[ -f "$PROJECT_ROOT/.claude/.pwt-route-disabled" ] && exit 0

# ─── Read stdin (hook contract) ──────────────────────────────────────────────
INPUT=$(cat 2>/dev/null || echo '{}')

# ─── Extract prompt: jq → python3 → grep+sed (graceful fallback chain) ───────
PROMPT=""
PARENT_SID_FROM_HOOK=""
if command -v jq >/dev/null 2>&1; then
    PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || echo "")
    PARENT_SID_FROM_HOOK=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
fi
if [ -z "$PROMPT" ] && command -v python3 >/dev/null 2>&1; then
    PROMPT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('prompt',''))" 2>/dev/null || echo "")
fi
if [ -z "$PARENT_SID_FROM_HOOK" ] && command -v python3 >/dev/null 2>&1; then
    PARENT_SID_FROM_HOOK=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
fi
if [ -z "$PROMPT" ]; then
    PROMPT=$(echo "$INPUT" | grep -oE '"prompt"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' \
        | head -1 | sed -E 's/^"prompt"[[:space:]]*:[[:space:]]*"//; s/"$//; s/\\"/"/g; s/\\n/ /g' \
        2>/dev/null || echo "")
fi

# Normalize parent sid to first 8 chars (matches pwt-launches.jsonl convention)
[ -n "$PARENT_SID_FROM_HOOK" ] && PARENT_SID_FROM_HOOK="${PARENT_SID_FROM_HOOK:0:8}"

# No prompt → allow
[ -z "$PROMPT" ] && exit 0

# ─── Slash-command guard (RECURSION-CRITICAL) ────────────────────────────────
# If the prompt starts with a slash, it is an explicit skill/command
# invocation, NOT natural-language routing. NEVER re-route slash commands.
#
# Critical recursion case: pwt-goal.sh --launch spawns `claude --bg` with
# bootstrap text "/goal Use /plan-w-team to <REQUEST>". That child session's
# UserPromptSubmit hook fires on this very text. Without this guard, the
# child detects "use /plan-w-team to" and launches ANOTHER claude --bg with
# the request re-wrapped — an infinite cascade observed in production on
# 2026-05-20 (19 background agents accumulated before discovery).
#
# Allowing leading whitespace before "/" handles indented bootstraps.
TRIMMED=$(printf '%s' "$PROMPT" | sed -E 's/^[[:space:]]+//')
case "$TRIMMED" in
    /*) exit 0 ;;
esac

# ─── Unanchored trigger detection ────────────────────────────────────────────
# Trigger phrases match anywhere in the prompt. Natural language for any
# effort is the product principle. Trust the specificity of the trigger
# phrase list ("use /plan-w-team to" etc.) to keep false positives low,
# and trust opt-out mechanisms for the edge cases.
PROMPT_LC=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]')

MATCHED_PATTERN=""
for pat in \
    "use /plan-w-team to " \
    "use our /plan-w-team to " \
    "using /plan-w-team " \
    "with /plan-w-team " \
    "kick off /plan-w-team " \
    "kick off a /plan-w-team " \
    "start a /plan-w-team run " \
    "start /plan-w-team " \
    "run /plan-w-team to "; do
    if printf '%s' "$PROMPT_LC" | grep -qF "$pat"; then
        MATCHED_PATTERN="$pat"
        break
    fi
done

# No trigger → allow
[ -z "$MATCHED_PATTERN" ] && exit 0

# ─── In-session opt-in: explicit override ────────────────────────────────────
for opt in \
    "in this session" \
    "right now in this session" \
    "run /plan-w-team here" \
    "invoke /plan-w-team in this session" \
    "/plan-w-team here in this session"; do
    if printf '%s' "$PROMPT_LC" | grep -qF "$opt"; then
        exit 0
    fi
done

# ─── Locate launcher; fail open if missing ───────────────────────────────────
PWT_GOAL="$PROJECT_ROOT/.claude/scripts/pwt-goal.sh"
[ -x "$PWT_GOAL" ] || exit 0

# ─── Background launch ───────────────────────────────────────────────────────
# nohup + & ensures the user's prompt is never blocked by claude --bg
# startup latency. Log file lets the user inspect what happened.
LOG_DIR="$PROJECT_ROOT/.claude/state/pwt-launch-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
TS=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/launch-$TS-$$.log"

# Spawn in background, detached from the hook's stdin/stdout.
# PWT_PARENT_SID is read by pwt-goal.sh when CLAUDE_JOB_DIR is unset (which it
# is here — the hook runs in the interactive session's process tree without
# CLAUDE_JOB_DIR). This is what lets the statusline classify the spawned bg
# session as "🛠 supervisor" instead of falling through to "👥 other".
PWT_PARENT_SID="$PARENT_SID_FROM_HOOK" \
    nohup "$PWT_GOAL" --launch "$PROMPT" >"$LOG_FILE" 2>&1 </dev/null &
LAUNCH_PID=$!
disown "$LAUNCH_PID" 2>/dev/null || true

# ─── Poll launch log briefly for session ID ──────────────────────────────────
# pwt-goal.sh emits "backgrounded · XXXXXXXX" once claude --bg returns.
# Real use: poll up to 3s. Test mode (PLAN_W_TEAM_HOOK_TEST_MODE=1): 0.3s
# (keeps the test suite fast — shim writes immediately or not at all).
if [ "${PLAN_W_TEAM_HOOK_TEST_MODE:-}" = "1" ]; then
    POLL_TICKS=10
else
    POLL_TICKS=30
fi
SESSION_ID=""
for _ in $(seq 1 "$POLL_TICKS"); do
    if [ -f "$LOG_FILE" ]; then
        # Strip ANSI color codes before grepping
        SESSION_ID=$(sed -E 's/\x1b\[[0-9;]*m//g' "$LOG_FILE" 2>/dev/null \
            | grep -oE 'backgrounded · [a-f0-9]{8}' \
            | head -1 | awk '{print $NF}' || echo "")
        [ -n "$SESSION_ID" ] && break
    fi
    sleep 0.1
done

# ─── Spawn completion watcher (macOS desktop notification on finish) ─────────
# Skipped in test mode — the watcher polls real jobs dirs which won't exist
# for fake session IDs and would either hang or pollute /tmp.
WATCHER="$PROJECT_ROOT/.claude/scripts/pwt-watch.sh"
if [ -n "$SESSION_ID" ] \
   && [ -x "$WATCHER" ] \
   && [ "${PLAN_W_TEAM_HOOK_TEST_MODE:-}" != "1" ]; then
    nohup "$WATCHER" "$SESSION_ID" >/dev/null 2>&1 </dev/null &
    disown $! 2>/dev/null || true
fi

# ─── Register spawn for retro-time cleanup ───────────────────────────────────
# Best-effort: writes to .claude/state/plan-w-team-spawned-children-$SLUG.jsonl
# so 07-retro.md §8j-sexies can claude-stop orphaned children. Slug derived
# from the prompt; on miss we use "_unsourced" so the row still exists.
REGISTER_HELPER="$PROJECT_ROOT/.claude/scripts/plan-w-team-register-spawn.sh"
if [ -n "$SESSION_ID" ] && [ -x "$REGISTER_HELPER" ]; then
    SLUG_GUESS=$(printf '%s' "$PROMPT" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-64 \
        2>/dev/null || echo "")
    [ -z "$SLUG_GUESS" ] && SLUG_GUESS="_unsourced"
    "$REGISTER_HELPER" "$SESSION_ID" "pwt-goal-launch" "$SLUG_GUESS" "" "plan-w-team-route-prompt.sh" \
        >/dev/null 2>&1 || true
fi

# Emit block decision with confirmation message.
PWT_MATCHED="$MATCHED_PATTERN" \
PWT_PID="$LAUNCH_PID" \
PWT_LOG="$LOG_FILE" \
PWT_SID="$SESSION_ID" \
python3 - <<'PYEOF' 2>/dev/null || exit 0
import json, os
matched = os.environ.get("PWT_MATCHED", "?")
pid     = os.environ.get("PWT_PID", "?")
log     = os.environ.get("PWT_LOG", "?")
sid     = os.environ.get("PWT_SID", "").strip()

if sid:
    sysmsg = (
        f"🚀 Routed /plan-w-team to autonomous mode.\n"
        f"   session: {sid}\n"
        f"   pid:     {pid} (launcher)\n"
        f"   log:     {log}\n\n"
        f"Monitor commands (copy-paste):\n"
        f"   claude agents          # list all running sessions\n"
        f"   claude logs {sid}    # tail this session's output\n"
        f"   claude attach {sid}  # open in current terminal\n"
        f"   claude stop {sid}    # halt if needed\n\n"
        f"You'll get a macOS notification when this session finishes."
    )
else:
    sysmsg = (
        f"🚀 Routed /plan-w-team to autonomous mode.\n"
        f"   pid={pid} (launcher)\n"
        f"   log={log}\n\n"
        f"Session ID not yet visible (claude --bg still initializing).\n"
        f"Find it with:\n"
        f"   grep backgrounded {log}\n"
        f"Then monitor with: claude logs <session-id>\n"
        f"Or list everything: claude agents"
    )

msg = {
    "decision": "block",
    "reason": (
        f"Detected /plan-w-team autonomous-run trigger pattern: '{matched.strip()}'. "
        f"Auto-launched pwt-goal.sh --launch (pid={pid}, session={sid or '?'}) "
        f"per skill routing rule."
    ),
    "systemMessage": sysmsg,
}
print(json.dumps(msg))
PYEOF
exit 2
