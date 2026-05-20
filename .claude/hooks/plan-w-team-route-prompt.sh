#!/usr/bin/env bash
# plan-w-team-route-prompt.sh
#
# UserPromptSubmit hook — defense-in-depth enforcement of the /plan-w-team
# routing rule. When the user's prompt contains a "use /plan-w-team to ..."
# trigger phrase (natural-language autonomous-run pattern), this hook
# auto-launches pwt-goal.sh --launch on their behalf and blocks the original
# prompt so it never reaches the skill's pre-check. Closes the failure mode
# observed in cleanscale on 2026-05-20 where the agent misread the slash
# token as a "direct slash invocation" and ran the work in-session.
#
# Disable temporarily: set PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1
# Kill switch (permanent): remove this hook entry from .claude/settings.json
#
# Exit codes:
#   0 — allow original prompt through unchanged
#   2 — block original prompt; emit guidance/launch confirmation

set -euo pipefail

[ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-}" = "1" ] && exit 0

INPUT=$(cat)

# Extract the user prompt — Claude Code passes JSON with a "prompt" field
PROMPT=$(echo "$INPUT" | grep -oE '"prompt"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' \
    | head -1 | sed -E 's/^"prompt"[[:space:]]*:[[:space:]]*"//; s/"$//; s/\\"/"/g; s/\\n/\n/g' \
    || echo "")

# No prompt → allow (shouldn't happen, but be defensive)
[ -z "$PROMPT" ] && { echo "$INPUT"; exit 0; }

# Case-insensitive trigger detection. Patterns mirror plan-w-team.md §Routing Pre-Check Step 1.
# Each pattern matches an autonomous-run intent expressed in natural language.
PROMPT_LC=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')

MATCHED_PATTERN=""
for pat in \
    "use /plan-w-team to " \
    "use our /plan-w-team to " \
    "using /plan-w-team " \
    "with /plan-w-team " \
    "kick off /plan-w-team " \
    "start a /plan-w-team run "; do
    if echo "$PROMPT_LC" | grep -qF "$pat"; then
        MATCHED_PATTERN="$pat"
        break
    fi
done

# Combined trigger: "definition of done" OR "done when" + "/plan-w-team"
if [ -z "$MATCHED_PATTERN" ]; then
    if echo "$PROMPT_LC" | grep -qF "/plan-w-team"; then
        if echo "$PROMPT_LC" | grep -qE "(definition of done|done when)"; then
            MATCHED_PATTERN="<dod>+/plan-w-team"
        fi
    fi
fi

# No trigger → allow original prompt through
[ -z "$MATCHED_PATTERN" ] && { echo "$INPUT"; exit 0; }

# Explicit in-session opt-in overrides the trigger (per skill Step 2)
for opt in "in this session" "right now in this session" "run /plan-w-team here" "invoke /plan-w-team in this session"; do
    if echo "$PROMPT_LC" | grep -qF "$opt"; then
        echo "$INPUT"
        exit 0
    fi
done

# Trigger matched and no in-session opt-in → AUTO-LAUNCH via pwt-goal.sh
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PWT_GOAL="$PROJECT_ROOT/.claude/scripts/pwt-goal.sh"

if [ ! -x "$PWT_GOAL" ]; then
    # Script not installed — emit guidance and allow the prompt through to the skill's
    # prose-level pre-check (still has a chance to catch it).
    echo "$INPUT"
    exit 0
fi

# Launch in background; capture output for the additionalContext message
LAUNCH_OUT=$("$PWT_GOAL" --launch "$PROMPT" 2>&1) || LAUNCH_RC=$?
LAUNCH_RC="${LAUNCH_RC:-0}"

if [ "$LAUNCH_RC" -ne 0 ]; then
    # Launch failed — let the prompt through with a warning so the skill can fall back
    cat <<EOF
{
  "decision": "allow",
  "additionalContext": "⚠ plan-w-team-route-prompt hook detected trigger pattern '$MATCHED_PATTERN' but pwt-goal.sh --launch failed:\n$LAUNCH_OUT\n\nFalling back to skill prose-level pre-check. Per plan-w-team.md §Routing Pre-Check, route this to pwt-goal.sh --launch when the in-skill pre-check runs."
}
EOF
    exit 0
fi

# Successful launch — block the original prompt so it doesn't double-execute the skill
cat <<EOF
{
  "decision": "block",
  "reason": "Detected /plan-w-team autonomous-run trigger pattern: '$MATCHED_PATTERN'. Auto-launched pwt-goal.sh --launch in background per skill routing rule. Watch progress with: claude agents",
  "systemMessage": "🚀 Routed /plan-w-team to autonomous mode.\n\n$LAUNCH_OUT\n\nUse 'claude agents' to monitor."
}
EOF
exit 2
