#!/bin/bash
# plan-w-team Lane Context — SessionStart + UserPromptSubmit hook
#
# PWT-LANE3 (2026-08-09, cleanscale incident): after a compaction, what
# survives into the new context is the OBJECTIVE ("apps working"); what dies is
# the ROLE ("you are supervising worker X — do not implement"). A summary keeps
# what reads like task content and drops what reads like procedural
# scaffolding. The drifted session then optimizes the objective directly —
# doing the lane's work itself — and every Stop-hook nudge rewards it.
#
# This hook re-injects the binding role contract from DISK, where compaction
# cannot touch it:
#   - at every SessionStart (startup, resume, and post-compaction), and
#   - on a throttled cadence at UserPromptSubmit (default every 30 min),
# for any session that is the WORKER or a BOUND SUPERVISOR of a live
# /plan-w-team lane. Unbound sessions get nothing (the lane-guard still
# protects the lane's worktree and artifacts from them).
#
# Delivery: emits {"additionalContext": ..., "systemMessage": ...} on stdout —
# the completion-surface idiom. systemMessage is the field the harness has
# been measured to actually deliver (tests/skill/CONVENTIONS.md contract
# table); additionalContext rides along for harness versions that honor it.
#
# FAIL-OPEN CONTRACT: this hook must never block a prompt. Any internal error
# → exit 0 silently.
#
# Kill switch: PLAN_W_TEAM_DISABLE_LANE_CONTEXT=1
# Throttle:    PWT_LANE_CONTEXT_INTERVAL_S (default 1800; SessionStart ignores it)
# Spec: docs/operations/lane-enforcement.md

set -u

[ "${PLAN_W_TEAM_DISABLE_LANE_CONTEXT:-}" = "1" ] && exit 0

INPUT=$(cat 2>/dev/null || echo '{}')
command -v jq >/dev/null 2>&1 || exit 0

SELF_SID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
SELF8="${SELF_SID:0:8}"
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$CWD" ] || CWD="$PWD"

# ── MAIN-checkout resolution (same idiom as the lane-guard / evaluator) ──────
__main_root_of() {
    local from="$1" cdir
    cdir=$(git -C "$from" rev-parse --git-common-dir 2>/dev/null || echo "")
    case "$cdir" in
        "") echo "" ;;
        /*) (cd "$(dirname "$cdir")" 2>/dev/null && pwd) || echo "" ;;
        *)  (cd "$from/$(dirname "$cdir")" 2>/dev/null && pwd) || echo "" ;;
    esac
}
MAIN_ROOT=""
if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    MAIN_ROOT="$PWT_PROJECT_ROOT_OVERRIDE"
else
    MAIN_ROOT=$(__main_root_of "$CWD")
    [ -z "$MAIN_ROOT" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && MAIN_ROOT=$(__main_root_of "$CLAUDE_PROJECT_DIR")
fi
[ -n "$MAIN_ROOT" ] && [ -d "$MAIN_ROOT/.claude/state" ] || exit 0
STATE_DIR="$MAIN_ROOT/.claude/state"

# ── Throttle (UserPromptSubmit only — SessionStart always re-binds) ──────────
if [ "$EVENT" = "UserPromptSubmit" ]; then
    MARKER="${TMPDIR:-/tmp}/pwt-lane-context-${SELF8:-nosid}"
    NOW=$(date -u +%s)
    LAST=$(cat "$MARKER" 2>/dev/null || echo 0)
    printf '%s' "${LAST:-}" | grep -qE '^[0-9]+$' || LAST=0
    INTERVAL="${PWT_LANE_CONTEXT_INTERVAL_S:-1800}"
    [ $(( NOW - LAST )) -lt "$INTERVAL" ] 2>/dev/null && exit 0
fi

# ── Compose role sections for every live lane this session is party to ───────
SECTIONS=""
shopt -s nullglob
for GF in "$STATE_DIR"/plan-w-team-goal-*.json; do
    jq -e . "$GF" >/dev/null 2>&1 || continue
    [ -n "$(jq -r '.terminal_state // ""' "$GF" 2>/dev/null)" ] && continue
    MTIME=$(stat -f %m "$GF" 2>/dev/null || stat -c %Y "$GF" 2>/dev/null || echo "")
    if [ -n "$MTIME" ] && [ "$MTIME" -gt 0 ] 2>/dev/null; then
        AGE=$(( $(date -u +%s) - MTIME ))
        [ "$AGE" -ge $(( ${PWT_GOAL_STALE_HOURS:-24} * 3600 )) ] 2>/dev/null && continue
    fi
    SLUG=$(jq -r '.slug // ""' "$GF" 2>/dev/null)
    [ -n "$SLUG" ] || continue
    [ -f "$STATE_DIR/plan-w-team-lane-release-${SLUG}.json" ] && continue
    WSID=$(jq -r '.worker_sid // ""' "$GF" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$WSID" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
        *) continue ;;
    esac
    W8="${WSID:0:8}"
    WT=$(jq -r '.worktree_path // ""' "$STATE_DIR/plan-w-team-manifest-${SLUG}.json" 2>/dev/null)
    STAGE=$(jq -r '.current_stage // ""' "$STATE_DIR/plan-w-team-manifest-${SLUG}.json" 2>/dev/null)

    if [ -n "$SELF8" ] && [ "$SELF8" = "$W8" ]; then
        SECTIONS="${SECTIONS}${SECTIONS:+

}🔧 LANE CONTEXT (re-bound from disk — compaction-proof): you are the WORKER of /plan-w-team lane '$SLUG'${STAGE:+ (manifest stage: $STAGE)}.
- Continue THIS slug's pipeline stages verbatim — never mint a new slug.
- Terminal exits only: retro-complete (stage=retro-complete + workflow_lock=done) or a hard-gate escalation. The Stop evaluator enforces this.
- Goal-state: $GF"
        continue
    fi

    BOUND=0
    [ "${PLAN_W_TEAM_SUPERVISOR_SESSION:-0}" = "1" ] && BOUND=1
    if [ "$BOUND" = "0" ] && [ -n "$SELF8" ]; then
        SSID=$(jq -r '.supervisor_sid // ""' "$GF" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        [ -n "$SSID" ] && [ "${SSID:0:8}" = "$SELF8" ] && BOUND=1
    fi
    if [ "$BOUND" = "0" ] && [ -n "$SELF8" ] && [ -f "$STATE_DIR/pwt-launches.jsonl" ]; then
        if jq -r --arg w "$W8" 'select(((.sid // "") | ascii_downcase | startswith($w))) | (.parent_sid // "")' \
             "$STATE_DIR/pwt-launches.jsonl" 2>/dev/null \
             | tr '[:upper:]' '[:lower:]' | cut -c1-8 | grep -qFx "$SELF8"; then
            BOUND=1
        fi
    fi
    [ "$BOUND" = "1" ] || continue

    SECTIONS="${SECTIONS}${SECTIONS:+

}🔒 LANE CONTEXT (re-bound from disk — compaction-proof): you are the SUPERVISOR of live /plan-w-team lane '$SLUG' (worker ${W8}${WT:+, worktree $WT}${STAGE:+, stage $STAGE}).
- NEVER implement, build, test, or commit this lane's work yourself — the PreToolUse lane-guard denies it, and a supervisor doing the work forks the run.
- Observe: .claude/scripts/pwt-status.sh / plan-w-team-fleet-query.sh. Steer: stop the worker and resume it by session UUID from inside its worktree with revised instructions. Queue follow-ups as briefs under .claude/state/.
- Completion is decided by the Stop evaluator from the WORKER's artifacts (PASS ship-verdict / its own retro) — anchors emitted in YOUR transcript cannot finish the goal (PWT-LANE2).
- Lane wedged? Escalate to the user. Only the USER releases a lane (plan-w-team-lane-release-${SLUG}.json, written outside this session)."
done
shopt -u nullglob

[ -n "$SECTIONS" ] || exit 0

# Stamp the throttle marker only on successful emission.
if [ "$EVENT" = "UserPromptSubmit" ]; then
    printf '%s' "$(date -u +%s)" > "${TMPDIR:-/tmp}/pwt-lane-context-${SELF8:-nosid}" 2>/dev/null || true
fi

SECTIONS="$SECTIONS" jq -n --arg s "$SECTIONS" \
    '{additionalContext: $s, systemMessage: $s}' 2>/dev/null || exit 0

exit 0
