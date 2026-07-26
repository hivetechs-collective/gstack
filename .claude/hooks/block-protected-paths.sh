#!/bin/bash
# Autonomous Pipeline: Path protection hook
# Blocks writes to protected paths based on .claude/project.json configuration
# Generic template - reads from .claude/project.json
#
# ---------------------------------------------------------------------------
# HOOK ENFORCEMENT CONTRACT (fixed 2026-07-26 — this hook did not enforce)
# ---------------------------------------------------------------------------
# Registered PreToolUse (Write|Edit|MultiEdit). The contract is:
#   exit 0  → allow. stdout IS parsed for JSON control.
#   exit 2  → BLOCK. stderr is shown to Claude. stdout is NOT parsed.
#   other   → non-blocking error; the tool call PROCEEDS.
# (.claude/docs/CLAUDE_CODE_CLI_REFERENCE.md:471-477;
#  agents/research-planning/claude-sdk-expert/docs/hooks.md:126-138)
#
# Every block site here previously printed {"decision":"block"} to STDOUT and
# then `exit 1`. That failed twice over: exit 1 is a non-blocking error so the
# write proceeded, and the JSON was never parsed because stdout is only read on
# exit 0. The guard reported blocking while allowing — the exact "ENFORCING but
# doesn't enforce" theater that block-gh-actions-build.sh:5-8 was written to
# eliminate. Blocks now write the reason to STDERR and exit 2.
#
# Under `bypassPermissions` (the standing posture) there is no permission
# backstop, so this hook layer is 100% of the policy — see
# .claude/docs/SKILL_PERMISSION_CONVENTION.md "Safety is in the hooks".

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/.claude/project.json"
LIB_DIR="$PROJECT_ROOT/.claude/lib"

# Source configuration helper
if [ -f "$LIB_DIR/config.sh" ]; then
    source "$LIB_DIR/config.sh"
fi

# Read tool input from stdin
INPUT=$(cat 2>/dev/null || echo "{}")

# Extract file path from input
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; data=json.load(sys.stdin); print(data.get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")

if [ -z "$FILE_PATH" ]; then
    # No file path in input, allow operation
    exit 0
fi

# ---------------------------------------------------------------------------
# PWT-C4 — secret-scan-allow is a user-only hard-gate; a bg worker must never
# self-author the allow-file to suppress the fail-closed secret scanner.
# ---------------------------------------------------------------------------
# 05-ship.md §6a-ter enforces the secret gate by file PRESENCE:
# `plan-w-team-secret-scan-allow-<slug>` → scanner runs with --allow. Nothing
# stopped a bg worker's own LLM from Writing that file and silently clearing a
# real secret finding with no human review (the gate is classified `user` in
# PWT-T2, but that is procedural-only). Inside a bg /plan-w-team worker — marked
# by PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1, which pwt-goal.sh sets for every
# spawned session — refuse the write and tell the worker to surface a
# pending_escalation instead. Interactive sessions (no in-worker marker) are
# unaffected: a human approving an allowlist addition is the legitimate path.
# See audit C4 (docs/operations/pwt-principles-enforcement-audit-2026-06-02.md).
if [ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-}" = "1" ] && \
   printf '%s' "$FILE_PATH" | grep -qE 'plan-w-team-secret-scan-allow-'; then
    cat >&2 << MSGEOF
⛔ BLOCKED (PWT-C4): writing the secret-scan allow-file ($FILE_PATH) from inside a bg /plan-w-team worker would suppress the fail-closed secret scanner with no human review. secret-scan-allow is a user-only hard-gate. Surface a pending_escalation (secret-scan-allow) to the human instead of writing the allow-file; an interactive operator can approve it.
MSGEOF
    exit 2
fi

# Check if file is in a protected path
if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
    PROTECTED_PATHS=$(jq -r '.governance.protectedPaths[]?' "$CONFIG_FILE" 2>/dev/null)

    while IFS= read -r protected; do
        if [ -n "$protected" ]; then
            # Convert glob pattern to regex
            pattern=$(echo "$protected" | sed 's/\*/.*/g')
            if echo "$FILE_PATH" | grep -qE "$pattern"; then
                # Reason goes to STDERR + exit 2 — the documented PreToolUse
                # blocking path. See HOOK ENFORCEMENT CONTRACT at the top.
                cat >&2 << MSGEOF
⛔ BLOCKED: $FILE_PATH is in protected path ($protected). Check .claude/project.json governance.protectedPaths to modify permissions.
MSGEOF
                exit 2
            fi
        fi
    done <<< "$PROTECTED_PATHS"

    # Check blocked features' paths
    BLOCKED_PATHS=$(jq -r '.features[] | select(.status == "blocked") | .path' "$CONFIG_FILE" 2>/dev/null)

    while IFS= read -r blocked; do
        if [ -n "$blocked" ]; then
            pattern=$(echo "$blocked" | sed 's/\*/.*/g')
            if echo "$FILE_PATH" | grep -qE "$pattern"; then
                FEATURE_NAME=$(jq -r ".features[] | select(.path == \"$blocked\") | .name" "$CONFIG_FILE" 2>/dev/null)
                cat >&2 << MSGEOF
⛔ BLOCKED: Feature '$FEATURE_NAME' requires approval. Path $FILE_PATH is blocked until feature is unblocked in .claude/project.json.
MSGEOF
                exit 2
            fi
        fi
    done <<< "$BLOCKED_PATHS"
fi

# Allow operation
exit 0
