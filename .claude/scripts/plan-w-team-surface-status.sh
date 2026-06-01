#!/bin/bash
# plan-w-team Surface Status — emits the standard ```status block for /goal evaluator
#
# Called by every lead-driven stage at end-of-stage, plus the retro at completion.
# The Haiku evaluator behind /goal (PWT-T5) cannot call tools; this helper is its
# primary sensor for judging pipeline progress.
#
# Spec: docs/specs/pwt-t5-goal-wrapper.md
# Schema: shared/goal-conditions.md §Status-Block Schema
# Kill switch: PLAN_W_TEAM_DISABLE_GOAL=1 (does NOT silence this helper; the helper
#              is observability, the kill switch only affects /goal invocation in
#              the skill md top-of-pipeline section)
#
# Usage: plan-w-team-surface-status.sh <slug> [stage_label]
# Exit:  0 = block emitted to stdout
#        1 = invocation error (missing slug)

set -u

usage() {
    cat >&2 <<EOF
Usage: $0 <slug> [stage_label]
Emits a fenced \`\`\`status block to stdout summarizing /plan-w-team run state
for the /goal evaluator. Reads workflow lock + supervisor-actions log + fleet log.
Graceful: any missing state surfaces as null / empty fields.
EOF
}

SLUG="${1:-}"
STAGE="${2:-unknown}"

if [ -z "$SLUG" ]; then
    usage
    exit 1
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
FALLBACK_STATE_DIR="$PROJECT_ROOT/.claude/state"
PWD_STATE_DIR="$PWD/.claude/state"

# Worktree-aware state lookup: prefer $PWD/.claude/state when /plan-w-team is
# running in a worktree distinct from the project root. Fall back to the
# canonical project root state dir otherwise. Picks whichever holds the active
# workflow lock for this SLUG; if neither does, defaults to $PWD path (where a
# new run will write its state). See 2026-05-20 holistic-check retro: state
# written in a worktree was invisible to status emitters and goal evaluator
# running in the main checkout.
if [ -d "$PWD_STATE_DIR/plan-w-team-workflow-${SLUG}.lock" ] && [ "$PWD_STATE_DIR" != "$FALLBACK_STATE_DIR" ]; then
    STATE_DIR="$PWD_STATE_DIR"
elif [ -d "$FALLBACK_STATE_DIR/plan-w-team-workflow-${SLUG}.lock" ]; then
    STATE_DIR="$FALLBACK_STATE_DIR"
elif [ -d "$PWD_STATE_DIR" ] && [ "$PWD_STATE_DIR" != "$FALLBACK_STATE_DIR" ]; then
    STATE_DIR="$PWD_STATE_DIR"
else
    STATE_DIR="$FALLBACK_STATE_DIR"
fi

LOCK_DIR="$STATE_DIR/plan-w-team-workflow-${SLUG}.lock"
SUP_LOG="$STATE_DIR/plan-w-team-supervisor-actions-${SLUG}.jsonl"
FLEET_LOG="$STATE_DIR/plan-w-team-fleet-${SLUG}.jsonl"
QUERY_SH="$PROJECT_ROOT/.claude/scripts/plan-w-team-fleet-query.sh"

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Mirror the stage into the canonical run manifest (main-checkout-relative), so a
# supervisor/human polling `pwt-status.sh` sees the live stage without reaching
# into the worktree. This is the deterministic per-stage chokepoint — every stage
# already calls this emitter, so the manifest stays current with no extra worker
# step. Best-effort: never let manifest bookkeeping affect the status block.
__MANIFEST_SH="$PROJECT_ROOT/.claude/scripts/pwt-manifest.sh"
if [ -x "$__MANIFEST_SH" ]; then
    __WT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    "$__MANIFEST_SH" set --slug "$SLUG" --stage "$STAGE" \
        ${__WT_ROOT:+--worktree "$__WT_ROOT"} >/dev/null 2>&1 || true
fi

# Workflow lock state
if [ -d "$LOCK_DIR" ]; then
    if [ "$STAGE" = "retro-complete" ]; then
        LOCK_STATE="done"
    else
        LOCK_STATE="active"
    fi
else
    LOCK_STATE="missing"
fi

# Ship-readiness gate — search supervisor log for a recent ship marker, otherwise n/a
SHIP_GATE="n/a"
if [ -f "$SUP_LOG" ]; then
    if grep -q '"call_site":"ship-readiness-gate"' "$SUP_LOG" 2>/dev/null; then
        SHIP_GATE=$(jq -r 'select(.event=="route_delegation" and .call_site=="ship-readiness-gate") | .router_choice' "$SUP_LOG" 2>/dev/null | tail -1 || echo "n/a")
        [ -z "$SHIP_GATE" ] && SHIP_GATE="n/a"
    elif [ "$STAGE" = "ship" ] || [ "$STAGE" = "post-ship" ] || [ "$STAGE" = "retro-complete" ]; then
        SHIP_GATE="pending"
    fi
fi

# Fleet summary
if [ -f "$FLEET_LOG" ] && [ -x "$QUERY_SH" ] && command -v jq >/dev/null 2>&1; then
    FLEET=$("$QUERY_SH" summary "$SLUG" 2>/dev/null || echo '{}')
    # Guard against empty/malformed
    echo "$FLEET" | jq -e . >/dev/null 2>&1 || FLEET='{}'
else
    FLEET='{}'
fi

# Pending escalations + low-confidence routes from supervisor-actions log
PENDING_ESC='[]'
LOW_CONF=0
if [ -f "$SUP_LOG" ] && command -v jq >/dev/null 2>&1; then
    PENDING_ESC=$(jq -s '[.[] | select(.event=="escalation") | .call_site] | unique' "$SUP_LOG" 2>/dev/null || echo '[]')
    LOW_CONF=$(jq -s '[.[] | select(.event=="route_delegation" and .router_confidence=="low")] | length' "$SUP_LOG" 2>/dev/null || echo 0)
fi

# Emit the fenced status block — JSON is built via jq so quoting is safe
STATUS_JSON=$(jq -n \
    --arg slug "$SLUG" \
    --arg stage "$STAGE" \
    --arg ts "$TS" \
    --arg lock "$LOCK_STATE" \
    --arg ship "$SHIP_GATE" \
    --argjson fleet "$FLEET" \
    --argjson esc "$PENDING_ESC" \
    --argjson low "$LOW_CONF" \
    '{slug:$slug, stage:$stage, ts:$ts, workflow_lock:$lock, ship_readiness_gate:$ship, fleet:$fleet, pending_escalations:$esc, low_confidence_routes:$low}' \
    2>/dev/null) || STATUS_JSON='{"slug":"'"$SLUG"'","stage":"'"$STAGE"'","ts":"'"$TS"'","error":"jq-failed"}'

printf '\n```status\n%s\n```\n' "$STATUS_JSON"

exit 0
