#!/usr/bin/env bash
# subagent-stop-worktree-cleanup.sh
#
# SubagentStop hook handler. When an Agent-tool subagent terminates, sweep its
# per-agent worktree (.claude/worktrees/agent-<agent_id>/) and any companion
# process (pane-display.py spinner) tied to it.
#
# SubagentStop payload (stdin JSON):
#   { session_id, agent_id, agent_type, cwd, agent_transcript_path,
#     last_assistant_message, permission_mode, hook_event_name }
#
# This handler is FAIL-OPEN: any internal error exits 0 so subagent teardown is
# never blocked. It delegates the actual removal + safety invariants to
# plan-w-team-worktree-gc.sh (--scope subagent) and plan-w-team-companion-gc.sh,
# so the safety logic lives in exactly one place.
#
# Environment:
#   PWT_SUBAGENT_CLEANUP_DISABLE=1   no-op (exit 0)
#   CLAUDE_PROJECT_DIR               resolves script paths when not in a worktree
#
# Spec: docs/specs/worktree-lifecycle-cleanup.md
# Registered in: .claude/settings.json SubagentStop hooks array
# Tests: covered by plan-w-team-worktree-gc.test.sh (subagent-scope cases)

set -u

[ "${PWT_SUBAGENT_CLEANUP_DISABLE:-0}" = "1" ] && exit 0

INPUT="$(cat 2>/dev/null || echo '{}')"

AGENT_ID=""
if command -v jq >/dev/null 2>&1; then
    AGENT_ID="$(echo "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)"
else
    AGENT_ID="$(echo "$INPUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("agent_id",""))' 2>/dev/null || echo "")"
fi

# Normalize: agent_id may arrive with or without the "agent-" prefix.
AGENT_ID="${AGENT_ID#agent-}"
[ -z "$AGENT_ID" ] && exit 0

# Resolve script dir (this hook lives in .claude/hooks/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"
[ -d "$SCRIPTS" ] || SCRIPTS="${CLAUDE_PROJECT_DIR:-.}/.claude/scripts"

GC="$SCRIPTS/plan-w-team-worktree-gc.sh"
COMPANION="$SCRIPTS/plan-w-team-companion-gc.sh"

# 1. Sweep the subagent's worktree (scope=subagent guards everything else).
if [ -x "$GC" ]; then
    "$GC" --scope subagent --sid "$AGENT_ID" --execute >/dev/null 2>&1 || true
fi

# 2. Kill the companion spinner tied to this agent.
if [ -x "$COMPANION" ]; then
    "$COMPANION" --sid "$AGENT_ID" --execute >/dev/null 2>&1 || true
fi

exit 0
