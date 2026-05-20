#!/bin/bash
# plan-w-team Supervisor Wrapper
#
# Gates whether 03-execute.md Pattern C spawns the persistent supervisor agent.
# Default: ON for parallel-builder runs. Use PLAN_W_TEAM_DISABLE_SUPERVISOR=1
# kill switch to revert to legacy lead-fanout during incidents.
#
# Spec: docs/specs/pwt-t4-supervisor.md
# Agent: .claude/agents/team/supervisor.md
# Protocol: .claude/commands/plan-w-team/shared/supervisor-protocol.md
#
# Usage: plan-w-team-supervisor-route.sh <slug>
# Exit:  0 = supervisor enabled + supervisor_start row written; caller should spawn agent
#        1 = invocation error (missing slug, missing state dir)
#        2 = supervisor disabled by kill switch; caller falls through
#             to Pattern A/B in 03-execute.md

set -u

usage() {
    cat >&2 <<EOF
Usage: $0 <slug>
Env:
  PLAN_W_TEAM_DISABLE_SUPERVISOR=1  kill switch — falls through to legacy fanout
Exit codes:
  0  supervisor enabled (default); caller should spawn .claude/agents/team/supervisor.md
  1  invocation error
  2  supervisor disabled by kill switch (fall through to Pattern A/B)
EOF
}

SLUG="${1:-}"

if [ -z "$SLUG" ]; then
    usage
    exit 1
fi

if [ "${PLAN_W_TEAM_DISABLE_SUPERVISOR:-}" = "1" ]; then
    echo "[supervisor-route] kill switch set (PLAN_W_TEAM_DISABLE_SUPERVISOR=1)" >&2
    exit 2
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
STATE_DIR="$PROJECT_ROOT/.claude/state"

if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    echo "[supervisor-route] ERROR: cannot create $STATE_DIR" >&2
    exit 1
fi

ACTIONS_LOG="$STATE_DIR/plan-w-team-supervisor-actions-${SLUG}.jsonl"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# The actual supervisor agent_id is assigned by Claude Code when Agent() is called;
# this row records the wrapper-side intent so retro can detect orphaned starts
# (wrapper succeeded but Agent never fired).
printf '{"ts":"%s","event":"supervisor_start","slug":"%s","supervisor_agent_id":"pending-agent-spawn"}\n' \
    "$TS" "$SLUG" >> "$ACTIONS_LOG" 2>/dev/null || {
        echo "[supervisor-route] WARN: action log append failed; continuing" >&2
    }

echo "[supervisor-route] enabled for slug=$SLUG; caller should spawn supervisor agent" >&2
exit 0
