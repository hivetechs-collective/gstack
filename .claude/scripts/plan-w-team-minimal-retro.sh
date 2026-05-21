#!/usr/bin/env bash
# plan-w-team-minimal-retro.sh
#
# Writes a minimal `.claude/state/plan-w-team-retro-$SLUG.json` so the
# pwt-watch.sh completion-summary surface and /goal evaluator always have
# *something* to read — even on early-exit paths (hard-gate halts, escalations,
# ship-gate exit-1, supervisor crashes).
#
# Invocation pattern (from inside a stage shell block):
#
#   trap '.claude/scripts/plan-w-team-minimal-retro.sh "$SLUG" "$PWT_CURRENT_STAGE" "$PWT_EARLY_EXIT_REASON"' EXIT
#
# Chain with existing traps using the `trap -p EXIT | sed` pattern in 05-ship.md.
#
# Usage:
#   plan-w-team-minimal-retro.sh <slug> [stage] [reason]
#
# Behavior:
#   - Writes only when no complete retro exists yet for the slug (won't clobber).
#   - Exits 0 silently on any error (fail-open).
#   - The minimal retro is keyed by `"minimal": true` so downstream readers
#     can distinguish it from a full retro.
#
# Spec: docs/specs/plan-w-team-self-cleanup.md AC5

set -u

fail_open() { exit 0; }
trap fail_open ERR

SLUG="${1:-}"
STAGE="${2:-unknown}"
REASON="${3:-early-exit-no-reason}"

[ -z "$SLUG" ] && exit 0

# Worktree-aware state dir resolution (mirrors surface-status.sh §worktree-aware).
# When /plan-w-team runs in a worktree, state files belong in $PWD/.claude/state/
# not the main checkout. CLAUDE_PROJECT_DIR points at the main checkout under
# `claude --bg`, so PWD detection is the only signal we have.
PWD_STATE_DIR="$PWD/.claude/state"
FALLBACK_PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
FALLBACK_STATE_DIR="${FALLBACK_PROJECT_ROOT}/.claude/state"

if [ -d "$PWD/.claude" ]; then
    STATE_DIR="$PWD_STATE_DIR"
elif [ -n "$FALLBACK_PROJECT_ROOT" ]; then
    STATE_DIR="$FALLBACK_STATE_DIR"
else
    exit 0
fi

RETRO="$STATE_DIR/plan-w-team-retro-${SLUG}.json"

# Don't clobber a complete retro. The complete retro is what we WANT — the
# minimal-retro fallback exists for cases where the complete one never gets
# written.
if [ -f "$RETRO" ]; then
    # If the existing file is marked minimal, that means a prior early-exit
    # wrote it but the run is continuing. Leave it; a downstream complete
    # retro will overwrite as a normal jq -n redirect.
    exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if command -v jq >/dev/null 2>&1; then
    jq -n \
        --arg slug "$SLUG" \
        --arg stage "$STAGE" \
        --arg ts "$TS" \
        --arg reason "$REASON" \
        '{
            slug:$slug,
            stage:$stage,
            terminal_state:"EARLY_EXIT",
            ts:$ts,
            early_exit_reason:$reason,
            minimal:true,
            metrics:{
                commits:null,
                ac_passing:null,
                ac_count:null,
                tasks_completed:null,
                files_changed:null
            },
            self_assessment:{
                score:null,
                rationale:"early-exit before retro — stage halted with reason: \($reason)"
            },
            quality_signals:{}
        }' > "$RETRO" 2>/dev/null || true
else
    # Last-resort static template. JSON validity is more important than dynamic
    # field interpolation when jq is missing.
    cat > "$RETRO" 2>/dev/null <<EOF || true
{"slug":"$SLUG","stage":"$STAGE","terminal_state":"EARLY_EXIT","ts":"$TS","early_exit_reason":"$REASON","minimal":true,"metrics":{"commits":null,"ac_passing":null,"ac_count":null,"tasks_completed":null,"files_changed":null},"self_assessment":{"score":null,"rationale":"early-exit before retro"},"quality_signals":{}}
EOF
fi

# Stop any `claude --bg` children registered for this run. Fire-and-forget —
# the helper is fail-open (never exits non-zero). Without this call, early-exit
# paths (hard-gate halts, ship-gate exit-1, supervisor crashes) leave bg
# children orphaned because the full retro stage's §8j-sexies block never runs.
# The helper itself honors PLAN_W_TEAM_DISABLE_CHILD_CLEANUP=1.
CLEANUP_SH="$(dirname "$0")/plan-w-team-child-cleanup.sh"
if [ -x "$CLEANUP_SH" ]; then
    "$CLEANUP_SH" "$SLUG" >/dev/null 2>&1 || true
fi

exit 0
