#!/usr/bin/env bash
# plan-w-team-child-cleanup.sh
#
# Stops `claude --bg` children registered for a /plan-w-team run.
#
# Reads the per-run spawned-children manifest at
#   .claude/state/plan-w-team-spawned-children-<SLUG>.jsonl
# and calls `claude stop <session_id>` for every row. Fire-and-forget — a
# non-zero exit from `claude stop` typically means the child already finished
# and is recorded as `noop` rather than treated as an error.
#
# Emits a single compact JSON document to stdout describing the cleanup run.
# The retro stage (07-retro.md §8j-sexies) captures that JSON and merges it
# into the retro state file under quality_signals.spawned_children_cleanup.
#
# Usage:
#   plan-w-team-child-cleanup.sh <slug> [manifest_path]
#
# Environment:
#   PLAN_W_TEAM_DISABLE_CHILD_CLEANUP=1  # skip the cleanup loop entirely
#   CLAUDE_PROJECT_DIR                    # used to resolve default manifest path
#
# === FAIL-OPEN CONTRACT ===
# Internal errors NEVER block retro completion. Any unhandled failure → exit 0
# with a "skipped" cleanup JSON so the retro continues.
#
# Spec: docs/specs/plan-w-team-self-cleanup.md
# Caller: .claude/commands/plan-w-team/07-retro.md §8j-sexies
# Test:   .claude/scripts/plan-w-team-child-cleanup.test.sh

set -u

SLUG="${1:-}"
MANIFEST_OVERRIDE="${2:-}"

if [ -z "$SLUG" ]; then
    printf '{"skipped":true,"reason":"missing slug","attempts":[]}\n'
    exit 0
fi

# Resolve manifest path. Worktree-aware: prefer $PWD when it has its own
# .claude/ (matches register-spawn.sh + surface-status.sh resolution).
if [ -n "$MANIFEST_OVERRIDE" ]; then
    MANIFEST="$MANIFEST_OVERRIDE"
elif [ -d "$PWD/.claude/state" ]; then
    MANIFEST="$PWD/.claude/state/plan-w-team-spawned-children-${SLUG}.jsonl"
elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}/.claude/state" ]; then
    MANIFEST="$CLAUDE_PROJECT_DIR/.claude/state/plan-w-team-spawned-children-${SLUG}.jsonl"
else
    MANIFEST=".claude/state/plan-w-team-spawned-children-${SLUG}.jsonl"
fi

if [ "${PLAN_W_TEAM_DISABLE_CHILD_CLEANUP:-}" = "1" ]; then
    printf '{"skipped":true,"reason":"PLAN_W_TEAM_DISABLE_CHILD_CLEANUP=1","attempts":[]}\n'
    exit 0
fi

ATTEMPTS_JSON='[]'
TOTAL_REGISTERED=0
TOTAL_STOPPED=0
TOTAL_NOOP=0
TOTAL_MIRROR_PATCHED=0
TOTAL_MIRROR_SKIPPED=0
RECONCILED=0

PRIMARY_PRESENT=0
[ -f "$MANIFEST" ] && PRIMARY_PRESENT=1

# No primary manifest AND no lineage reconciliation requested → nothing to do.
# (Preserves the exact pre-C8 contract when PWT_CLEANUP_PARENT_SID is unset.)
if [ "$PRIMARY_PRESENT" = "0" ] && [ -z "${PWT_CLEANUP_PARENT_SID:-}" ]; then
    printf '{"skipped":true,"reason":"no registry","attempts":[]}\n'
    exit 0
fi

if [ "$PRIMARY_PRESENT" = "1" ]; then
while IFS= read -r row; do
    [ -z "$row" ] && continue
    # jq exits non-zero on parse errors (e.g., malformed rows). `|| true` so the
    # outer loop keeps going; an empty $SID then triggers the skip below.
    SID=$(printf '%s' "$row" | jq -r '.session_id // empty' 2>/dev/null || true)
    PURPOSE=$(printf '%s' "$row" | jq -r '.purpose // "other"' 2>/dev/null || echo "other")
    ROW_TYPE=$(printf '%s' "$row" | jq -r '.type // ""' 2>/dev/null || echo "")
    [ -z "$SID" ] && continue
    TOTAL_REGISTERED=$((TOTAL_REGISTERED + 1))

    ATTEMPT_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if [ "$ROW_TYPE" = "supervisor_mirror" ]; then
        # Supervisor-mirror lifecycle: instead of stopping a session, jq-patch
        # the mirror goal-state file with terminal_state=SUCCESS so the origin
        # chat's goal-evaluator hook can stop waiting on this mirror.
        # See docs/specs/supervisor-mirror-lifecycle.md.
        MIRROR_PATH=$(printf '%s' "$row" | jq -r '.path // ""' 2>/dev/null || echo "")
        MIRROR_PATCHED=false
        MIRROR_REASON=""

        if [ -z "$MIRROR_PATH" ]; then
            MIRROR_REASON="missing path field"
            TOTAL_MIRROR_SKIPPED=$((TOTAL_MIRROR_SKIPPED + 1))
        elif [ ! -f "$MIRROR_PATH" ]; then
            MIRROR_REASON="mirror file not found"
            TOTAL_MIRROR_SKIPPED=$((TOTAL_MIRROR_SKIPPED + 1))
        else
            EXISTING=$(jq -r '.terminal_state // ""' "$MIRROR_PATH" 2>/dev/null || echo "")
            if [ -n "$EXISTING" ]; then
                # Idempotent: mirror already terminal, leave as-is.
                MIRROR_REASON="already terminal ($EXISTING)"
                TOTAL_MIRROR_SKIPPED=$((TOTAL_MIRROR_SKIPPED + 1))
            else
                if jq --arg t "SUCCESS" --arg r "auto-synced from worker retro" --arg ts "$ATTEMPT_TS" \
                    '.terminal_state = $t | .terminal_reason = $r | .terminated_at = $ts' \
                    "$MIRROR_PATH" > "$MIRROR_PATH.tmp" 2>/dev/null \
                    && mv "$MIRROR_PATH.tmp" "$MIRROR_PATH"; then
                    MIRROR_PATCHED=true
                    MIRROR_REASON="patched SUCCESS"
                    TOTAL_MIRROR_PATCHED=$((TOTAL_MIRROR_PATCHED + 1))
                else
                    rm -f "$MIRROR_PATH.tmp" 2>/dev/null || true
                    MIRROR_REASON="jq patch failed"
                    TOTAL_MIRROR_SKIPPED=$((TOTAL_MIRROR_SKIPPED + 1))
                fi
            fi
        fi

        ATTEMPTS_JSON=$(printf '%s' "$ATTEMPTS_JSON" | jq -c \
            --arg sid "$SID" \
            --arg purpose "$PURPOSE" \
            --arg ts "$ATTEMPT_TS" \
            --arg type "supervisor_mirror" \
            --arg path "$MIRROR_PATH" \
            --argjson patched "$MIRROR_PATCHED" \
            --arg reason "$MIRROR_REASON" \
            '. + [{session_id:$sid, purpose:$purpose, type:$type, attempted_at:$ts, mirror_path:$path, mirror_patched:$patched, mirror_reason:$reason}]' \
            2>/dev/null || printf '%s' "$ATTEMPTS_JSON")
        continue
    fi

    if claude stop "$SID" >/dev/null 2>&1; then
        EXIT_CODE=0
        TOTAL_STOPPED=$((TOTAL_STOPPED + 1))
    else
        EXIT_CODE=$?
        TOTAL_NOOP=$((TOTAL_NOOP + 1))
    fi

    # PWT-RAM2: drop the cross-repo fair-share claim for this sid, regardless
    # of whether `claude stop` succeeded. Idempotent — if the row was never
    # added (e.g. claim helper missing at spawn time) the remove is a no-op.
    CLAIM_HELPER_PATH="$(dirname "$0")/pwt-ram-claim.sh"
    if [ -x "$CLAIM_HELPER_PATH" ]; then
        "$CLAIM_HELPER_PATH" remove "$SID" >/dev/null 2>&1 || true
    fi

    ATTEMPTS_JSON=$(printf '%s' "$ATTEMPTS_JSON" | jq -c \
        --arg sid "$SID" \
        --arg purpose "$PURPOSE" \
        --arg ts "$ATTEMPT_TS" \
        --argjson exit_code "$EXIT_CODE" \
        '. + [{session_id:$sid, purpose:$purpose, attempted_at:$ts, exit_code:$exit_code}]' \
        2>/dev/null || printf '%s' "$ATTEMPTS_JSON")
done < "$MANIFEST"
fi  # end PRIMARY_PRESENT guard

# ─── C8: lineage reconciliation (concurrent-run-safe) ───────────────────────
# The primary manifest is keyed by the feature SLUG, but pwt-goal registers a
# spawned worker under SLUG_GUESS=__pwt_safe_slug(ORIGINAL_REQUEST), which can
# differ — so a child registered under a different slug would never be reaped
# (the orphan-bg accumulation the registry+cleanup pair exists to prevent, audit
# C8). When the caller passes the reaping session's own id via
# PWT_CLEANUP_PARENT_SID, ALSO scan sibling registries and reap rows whose
# parent_session_id matches THIS session. Concurrent-safe: another run's children
# carry a different parent_session_id and are left untouched. Additive — with the
# env unset this block is skipped, so behavior is byte-identical to pre-C8.
if [ -n "${PWT_CLEANUP_PARENT_SID:-}" ]; then
    SELF_SID="$PWT_CLEANUP_PARENT_SID"
    STATE_DIR_RESOLVED=$(dirname "$MANIFEST")
    for sib in "$STATE_DIR_RESOLVED"/plan-w-team-spawned-children-*.jsonl; do
        [ -f "$sib" ] || continue          # literal glob when no match → skip
        [ "$sib" = "$MANIFEST" ] && continue
        while IFS= read -r row; do
            [ -z "$row" ] && continue
            RT=$(printf '%s' "$row" | jq -r '.type // ""' 2>/dev/null || echo "")
            [ "$RT" = "supervisor_mirror" ] && continue   # mirror rows: handled by their own run's primary pass
            RSID=$(printf '%s' "$row" | jq -r '.session_id // empty' 2>/dev/null || true)
            RP=$(printf '%s' "$row" | jq -r '.parent_session_id // empty' 2>/dev/null || true)
            [ -z "$RSID" ] && continue
            # Lineage match only (tolerate short/long sid forms). Anything not
            # spawned BY this session is another run's child — never touch it.
            case "$RP" in "$SELF_SID"|"${SELF_SID:0:8}"*) : ;; *) continue ;; esac
            # Dedup against rows already attempted in the primary pass.
            printf '%s' "$ATTEMPTS_JSON" | jq -e --arg s "$RSID" 'any(.[]; .session_id==$s)' >/dev/null 2>&1 && continue
            ATTEMPT_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            if claude stop "$RSID" >/dev/null 2>&1; then EC=0; TOTAL_STOPPED=$((TOTAL_STOPPED + 1)); else EC=$?; TOTAL_NOOP=$((TOTAL_NOOP + 1)); fi
            CLAIM_HELPER_PATH="$(dirname "$0")/pwt-ram-claim.sh"
            [ -x "$CLAIM_HELPER_PATH" ] && "$CLAIM_HELPER_PATH" remove "$RSID" >/dev/null 2>&1 || true
            TOTAL_REGISTERED=$((TOTAL_REGISTERED + 1)); RECONCILED=$((RECONCILED + 1))
            ATTEMPTS_JSON=$(printf '%s' "$ATTEMPTS_JSON" | jq -c --arg sid "$RSID" --arg ts "$ATTEMPT_TS" --argjson ec "$EC" \
                '. + [{session_id:$sid, purpose:"reconciled-by-lineage", attempted_at:$ts, exit_code:$ec}]' 2>/dev/null || printf '%s' "$ATTEMPTS_JSON")
        done < "$sib"
    done
fi

jq -nc \
    --argjson attempts "$ATTEMPTS_JSON" \
    --argjson registered "$TOTAL_REGISTERED" \
    --argjson stopped "$TOTAL_STOPPED" \
    --argjson noop "$TOTAL_NOOP" \
    --argjson reconciled "$RECONCILED" \
    --argjson mirror_patched "$TOTAL_MIRROR_PATCHED" \
    --argjson mirror_skipped "$TOTAL_MIRROR_SKIPPED" \
    '{skipped:false, registered:$registered, stopped:$stopped, noop:$noop, reconciled:$reconciled, mirror_patched:$mirror_patched, mirror_skipped:$mirror_skipped, attempts:$attempts}' \
    2>/dev/null || printf '{"skipped":false,"registered":%d,"stopped":%d,"noop":%d,"reconciled":%d,"mirror_patched":%d,"mirror_skipped":%d,"attempts":[]}\n' \
        "$TOTAL_REGISTERED" "$TOTAL_STOPPED" "$TOTAL_NOOP" "$RECONCILED" "$TOTAL_MIRROR_PATCHED" "$TOTAL_MIRROR_SKIPPED"
