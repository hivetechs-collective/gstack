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
if [ -n "${PWT_CLEANUP_PARENT_SID:-}" ] && [ "${#PWT_CLEANUP_PARENT_SID}" -lt 8 ]; then
    # Round-2 audit §3.2: a sub-8-char SELF_SID is too weak a lineage
    # discriminator (it would over-match a far larger set of parent ids), so
    # skip the cross-slug reconciliation rather than risk reaping a concurrent
    # run's worker. The primary-manifest pass above already ran.
    echo "[child-cleanup] PWT_CLEANUP_PARENT_SID too short (<8 chars) — skipping lineage reconciliation (over-reap guard, §3.2)" >&2
fi
if [ -n "${PWT_CLEANUP_PARENT_SID:-}" ] && [ "${#PWT_CLEANUP_PARENT_SID}" -ge 8 ]; then
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
            # Lineage match — EXACT, no trailing glob (round-2 audit §3.2). RP is
            # either the full session id (pwt-goal now records full; preferred) or
            # the legacy 8-char form. Match RP == full SELF_SID, OR RP == exactly
            # the 8-char prefix of SELF_SID (legacy registries). The dropped `*`
            # prevents a "starts-with" over-match reaping a concurrent run whose
            # parent id merely shares SELF_SID's first 8 chars. Anything else is
            # another run's child — never touch it.
            case "$RP" in "$SELF_SID"|"${SELF_SID:0:8}") : ;; *) continue ;; esac
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

# ─── §3.6: cross-checkout supervisor-mirror SUCCESS sync (PWT-WT1 regression) ──
# Under PWT-WT1 the worker runs in a worktree, so its primary manifest (the
# worktree state dir) lacks the supervisor_mirror row that pwt-goal
# --supervisor-goal wrote to the ORIGIN/main state dir. Without reaching it, the
# worker's retro never patches the mirror to SUCCESS → the origin goal-evaluator
# falsely writes LOW_CONFIDENCE_STREAK for a CLEANLY-shipped run (the round-2
# audit §3.6 regression; re-opens the 2026-05-22 mirror-stayed-null incident for
# the worktree worker). Resolve the main checkout's state dir and patch ONLY the
# mirror whose session_id is THIS worker (exact 8-char match — pwt-goal records
# the worker SID as the 8-char `backgrounded · <sid>`; no glob, so a concurrent
# run's mirror is never falsely SUCCESS'd). Only runs when actually in a worktree
# AND a parent-sid was passed; idempotent (skips an already-terminal mirror).
if [ -n "${PWT_CLEANUP_PARENT_SID:-}" ]; then
    # Resolve the MAIN checkout's state dir (test-only override takes precedence).
    MIRROR_MAIN_STATE="${PWT_CLEANUP_MAIN_STATE_OVERRIDE:-}"
    if [ -z "$MIRROR_MAIN_STATE" ]; then
        MIRROR_COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "")
        MIRROR_MAIN_ROOT=""
        case "$MIRROR_COMMON" in
            */.git) MIRROR_MAIN_ROOT="${MIRROR_COMMON%/.git}" ;;
            */.git/worktrees/*) MIRROR_MAIN_ROOT="${MIRROR_COMMON%/.git/worktrees/*}" ;;
        esac
        [ -n "$MIRROR_MAIN_ROOT" ] && MIRROR_MAIN_STATE="$MIRROR_MAIN_ROOT/.claude/state"
    fi
    if [ -n "$MIRROR_MAIN_STATE" ] && [ -d "$MIRROR_MAIN_STATE" ] && [ "$MIRROR_MAIN_STATE" != "$(dirname "$MANIFEST")" ]; then
        SELF8="${PWT_CLEANUP_PARENT_SID:0:8}"
        for oreg in "$MIRROR_MAIN_STATE"/plan-w-team-spawned-children-*.jsonl; do
            [ -f "$oreg" ] || continue
            while IFS= read -r row; do
                [ -z "$row" ] && continue
                [ "$(printf '%s' "$row" | jq -r '.type // ""' 2>/dev/null || echo "")" = "supervisor_mirror" ] || continue
                MSID=$(printf '%s' "$row" | jq -r '.session_id // ""' 2>/dev/null || echo "")
                # Exact match on this worker's sid (full or its 8-char form). No glob.
                [ "$MSID" = "$PWT_CLEANUP_PARENT_SID" ] || [ "$MSID" = "$SELF8" ] || continue
                MP=$(printf '%s' "$row" | jq -r '.path // ""' 2>/dev/null || echo "")
                [ -n "$MP" ] && [ -f "$MP" ] || { TOTAL_MIRROR_SKIPPED=$((TOTAL_MIRROR_SKIPPED + 1)); continue; }
                [ -n "$(jq -r '.terminal_state // ""' "$MP" 2>/dev/null || echo "")" ] && { TOTAL_MIRROR_SKIPPED=$((TOTAL_MIRROR_SKIPPED + 1)); continue; }
                if jq --arg t "SUCCESS" --arg r "auto-synced from worktree worker retro (§3.6 cross-checkout)" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    '.terminal_state = $t | .terminal_reason = $r | .terminated_at = $ts' "$MP" > "$MP.tmp" 2>/dev/null && mv "$MP.tmp" "$MP"; then
                    TOTAL_MIRROR_PATCHED=$((TOTAL_MIRROR_PATCHED + 1))
                    echo "[child-cleanup] §3.6 cross-checkout mirror patched SUCCESS: $MP (worker $MSID)" >&2
                else
                    rm -f "$MP.tmp" 2>/dev/null || true
                    TOTAL_MIRROR_SKIPPED=$((TOTAL_MIRROR_SKIPPED + 1))
                fi
            done < "$oreg"
        done
    fi
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
