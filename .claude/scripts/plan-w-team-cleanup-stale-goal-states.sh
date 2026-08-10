#!/usr/bin/env bash
# plan-w-team-cleanup-stale-goal-states.sh
#
# Two-pass GC for `.claude/state/plan-w-team-*` run-state.
#
# PASS 1 — SUCCESS goal-state removal (the original behavior, UNCHANGED).
#   Remove `plan-w-team-goal-<SLUG>.json` files whose `terminal_state` equals
#   `"SUCCESS"`. These SHOULD have been deleted by `07-retro.md` §8j-quater on
#   `RETRO_SUCCESS=1`, but pre-409e265 runs persist on disk as dead weight.
#
# PASS 2 — provably-orphaned NON-terminal family GC (prong B, 2026-06-10).
#   The SUCCESS-only pass left non-terminal orphans — and their sibling run-state
#   family (manifest, skill-version, spawned-children, stage-events) — on disk
#   FOREVER (open follow-up cleanup-eval SA-4). Worse, a non-terminal goal leftover
#   DID block the goal-evaluator (the earlier header claim that it "doesn't block …
#   naturally skips terminated ones" was FALSE for NON-terminal files — that is
#   exactly the prong-A evaluator bug). PASS 2 reaps a `terminal_state=null` family
#   ONLY when it is provably an orphan: worker DEAD (its worker_sid/run_sid is not
#   among live `claude` sessions, via pwt-live-session-sids.sh) AND aged beyond
#   PWT_GOAL_STALE_HOURS (default 24). Fail-CLOSED: if liveness can't be proven
#   (`__QUERY_FAILED__`) nothing is reaped. Kill switch
#   PLAN_W_TEAM_DISABLE_ORPHAN_GC=1 → PASS 2 is skipped (janitor stays SUCCESS-only).
#
# PRESERVED states (signal worth keeping for inspection — NEVER reaped by either
# pass, regardless of age):
#   - USER_ESCALATION_HALT       — hard-gate pause site needs user attention
#   - LOW_CONFIDENCE_STREAK      — supervisor escalation needs investigation
#   - DEAD                       — worker died unexpectedly (already recorded)
#   - API_HALT                   — transient API/socket halt (supervisor may resume)
# REAPED states:
#   - SUCCESS  (pass 1)          — retro completed, file should already be gone
#   - null     (pass 2)          — ONLY when worker-dead AND aged (provable orphan)
#
# Usage:
#   plan-w-team-cleanup-stale-goal-states.sh                    # silent unless removals
#   plan-w-team-cleanup-stale-goal-states.sh --verbose          # log every action
#   plan-w-team-cleanup-stale-goal-states.sh --quiet            # suppress even the summary
#   plan-w-team-cleanup-stale-goal-states.sh --dry-run          # list, don't delete
#   STATE_DIR=/path/to/state plan-w-team-cleanup-stale-goal-states.sh   # override
#   PWT_GOAL_STALE_HOURS=<n>     orphan age threshold (default 24)
#   PLAN_W_TEAM_DISABLE_ORPHAN_GC=1   skip pass 2 (SUCCESS-only behavior)
#
# This is the SINGLE stale-goal-state janitor (reconciled 2026-06-08): both
# session-start (no args) and 07-retro.md (--quiet) call it. Pass 1 only ever
# removes terminal_state=SUCCESS; pass 2 only ever removes a provably-orphaned
# non-terminal family — so neither caller can delete a goal-state another LIVE run
# left for inspection. (Replaces the second all-terminal cleaner
# plan-w-team-cleanup-stale-goals.sh, removed in the same 2026-06-08 change.)
#
# Exit code: always 0 (best-effort; never block session start)

set -u

STATE_DIR="${STATE_DIR:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}/.claude/state}"
VERBOSE=0
DRY_RUN=0
QUIET=0

for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=1 ;;
        --quiet|-q) QUIET=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --help|-h)
            sed -nE 's/^# ?//; 1,/^$/p' "$0" | head -40
            exit 0
            ;;
        *) ;;  # ignore unknown args (best-effort caller)
    esac
done

[ -d "$STATE_DIR" ] || exit 0

# ── shared extractors (jq-preferred; grep+sed fallback on ANY empty jq result) ─
# NOT a jq-absence fallback — see the trigger breakdown at the pass-1 loop below.
__terminal_state_of() {  # $1=file → terminal_state string ("" for null/absent)
    local file="$1" st=""
    if command -v jq >/dev/null 2>&1; then
        st=$(jq -r '.terminal_state // empty' "$file" 2>/dev/null || echo "")
    fi
    if [ -z "$st" ]; then
        st=$(grep -oE '"terminal_state"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" 2>/dev/null \
            | head -1 \
            | sed -E 's/.*"terminal_state"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' \
            || echo "")
    fi
    printf '%s' "$st"
}
__json_str_field() {  # $1=file $2=key → string value ("" if absent)
    local file="$1" key="$2" v=""
    if command -v jq >/dev/null 2>&1; then
        v=$(jq -r ".${key} // empty" "$file" 2>/dev/null || echo "")
    fi
    if [ -z "$v" ]; then
        v=$(grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
            | head -1 \
            | sed -E "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/" || echo "")
    fi
    printf '%s' "$v"
}
__mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo ""; }

REMOVED=0

# bash 3.2 + nullglob-safe iteration
for f in "$STATE_DIR"/plan-w-team-goal-*.json; do
    [ -f "$f" ] || continue

    # Extract terminal_state. jq is PREFERRED, but read the fallback's trigger
    # carefully: __terminal_state_of falls back to grep+sed whenever the jq result is
    # EMPTY — not whenever jq is missing. That is three distinct situations:
    #   1. jq absent            → the portability case the fallback was added for;
    #   2. jq present, file UNPARSEABLE → jq errors, $st is empty, grep+sed runs anyway;
    #   3. jq present, terminal_state legitimately null/absent → grep+sed also finds
    #      nothing (it only matches a QUOTED value), so same answer, no harm.
    #
    # Case 2 is the one with teeth, and it is NOT hypothetical: on a jq-equipped host a
    # CORRUPT goal file whose raw text still contains "terminal_state": "SUCCESS" is
    # classified by grep+sed and REAPED by pass 1 below. The goal-evaluator hook meeting
    # that same file does the opposite — its `jq -e .` guard fails, it logs
    # `WARN: corrupt goal state … skipping` and `continue`s without classifying it
    # (.claude/hooks/plan-w-team-goal-evaluator.sh:441-445). Same file, opposite
    # disposition.
    #
    # That divergence is deliberate, not an oversight. This is a best-effort
    # session-start GC: pass 1 only ever deletes on a literal SUCCESS string, and a
    # corrupt SUCCESS leftover is precisely the dead weight it exists to reap — while
    # going jq-only here would break jq-less hosts for no safety gain. The evaluator is
    # jq-only-or-bail in BOTH directions (no jq at all → warn + `exit 0`, same file
    # :201-205) and does NOT share this fallback.
    #
    # Both behaviors above are pinned by the "corrupt JSON carrying a quoted SUCCESS"
    # and "valid null preserved" cases in plan-w-team-cleanup-stale-goal-states.test.sh;
    # change the extraction and those fail. Shared as a helper so pass 2 reuses the
    # exact extraction (__json_str_field has the identical empty-result fallback shape).
    STATE="$(__terminal_state_of "$f")"

    if [ "$STATE" = "SUCCESS" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "[dry-run] would remove $f (terminal_state=SUCCESS)"
        else
            rm -f "$f" 2>/dev/null && REMOVED=$((REMOVED + 1))
            [ "$VERBOSE" = "1" ] && echo "removed $f (terminal_state=SUCCESS)"
        fi
    elif [ "$VERBOSE" = "1" ]; then
        echo "kept $f (terminal_state=${STATE:-null})"
    fi
done

# ── PASS 2: provably-orphaned non-terminal family GC (prong B) ───────────────
# Reap a `terminal_state=null` goal/family ONLY when its worker is provably DEAD
# (owner SID not among live claude sessions) AND it is aged beyond
# PWT_GOAL_STALE_HOURS. Escalation/DEAD/API_HALT are preserved by the null-only
# gate. Fail-CLOSED on a failed liveness query. Skipped entirely under
# PLAN_W_TEAM_DISABLE_ORPHAN_GC=1.
ORPHANS_REAPED=0
# All five canonical per-run families (shared/state-artifacts.md). goal+manifest
# drive slug discovery; all five are reaped together once a slug is judged orphan.
FAMILY_PREFIXES="plan-w-team-goal- plan-w-team-manifest- plan-w-team-skill-version- plan-w-team-spawned-children- plan-w-team-stage-events-"

if [ "${PLAN_W_TEAM_DISABLE_ORPHAN_GC:-}" != "1" ]; then
    # 1) Discover candidate slugs from goal-*.json and manifest-*.json (so a
    #    goal-less orphan family — e.g. a <1.29.0 worker-only run — is still caught).
    CAND_SLUGS=""
    for f in "$STATE_DIR"/plan-w-team-goal-*.json "$STATE_DIR"/plan-w-team-manifest-*.json; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"; slug="$base"
        slug="${slug#plan-w-team-goal-}"; slug="${slug#plan-w-team-manifest-}"
        slug="${slug%.json}"
        CAND_SLUGS="$CAND_SLUGS
$slug"
    done
    CAND_SLUGS="$(printf '%s\n' "$CAND_SLUGS" | grep -v '^$' | sort -u)"

    # 2) Pre-filter to NON-terminal + AGED candidates (query liveness only if any
    #    survive — zero cost on a clean state dir). Emit "slug<SPACE>sid,sid".
    MAX_AGE=$(( ${PWT_GOAL_STALE_HOURS:-24} * 3600 ))
    NOW=$(date -u +%s)
    REAP_CANDIDATES=""
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        gf="$STATE_DIR/plan-w-team-goal-${slug}.json"
        mf="$STATE_DIR/plan-w-team-manifest-${slug}.json"
        st=""
        [ -f "$gf" ] && st="$(__terminal_state_of "$gf")"
        [ -z "$st" ] && [ -f "$mf" ] && st="$(__terminal_state_of "$mf")"
        [ -n "$st" ] && continue   # any terminal_state (SUCCESS/escalation/DEAD/API_HALT) → keep
        # Age = NEWEST mtime across the family (a recently-touched member = maybe alive).
        newest=0
        for pref in $FAMILY_PREFIXES; do
            for ext in json jsonl; do
                ff="$STATE_DIR/${pref}${slug}.${ext}"
                [ -f "$ff" ] || continue
                m="$(__mtime_of "$ff")"
                [ -n "$m" ] || { newest=-1; break; }
                [ "$m" -gt "$newest" ] 2>/dev/null && newest="$m"
            done
            [ "$newest" -lt 0 ] && break
        done
        [ "$newest" -le 0 ] 2>/dev/null && continue   # unreadable / no files → keep (fail-safe)
        age=$(( NOW - newest ))
        [ "$age" -lt "$MAX_AGE" ] 2>/dev/null && continue   # recent → keep
        # Owner SIDs: worker_sid (goal) + run_sid (manifest).
        sids=""
        [ -f "$gf" ] && { w="$(__json_str_field "$gf" worker_sid)"; [ -n "$w" ] && sids="$sids $w"; }
        [ -f "$mf" ] && { r="$(__json_str_field "$mf" run_sid)"; [ -n "$r" ] && sids="$sids $r"; }
        sids="$(printf '%s' "$sids" | tr ' ' '\n' | grep -v '^$' | paste -sd, - 2>/dev/null || true)"
        REAP_CANDIDATES="$REAP_CANDIDATES
${slug} ${sids}"
    done <<EOF
$CAND_SLUGS
EOF
    REAP_CANDIDATES="$(printf '%s\n' "$REAP_CANDIDATES" | grep -v '^[[:space:]]*$')"

    # 3) Query live SIDs ONCE (fail-CLOSED), then reap dead+aged orphans.
    if [ -n "$REAP_CANDIDATES" ]; then
        SIDS_HELPER="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/pwt-live-session-sids.sh"
        QUERY_OK=1
        LIVE_SIDS=""
        if [ -x "$SIDS_HELPER" ]; then
            LIVE_SIDS="$("$SIDS_HELPER" 2>/dev/null)"
        else
            QUERY_OK=0   # helper missing → cannot prove dead → fail-CLOSED
        fi
        printf '%s\n' "$LIVE_SIDS" | grep -qFx '__QUERY_FAILED__' && QUERY_OK=0
        LIVE8="$(printf '%s\n' "$LIVE_SIDS" | grep -v '^$' | grep -vFx '__QUERY_FAILED__' | cut -c1-8 | sort -u)"

        if [ "$QUERY_OK" = "1" ]; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                slug="${line%% *}"; sids="${line#* }"
                [ "$sids" = "$line" ] && sids=""   # no SID present
                # No owner SID at all → the worker is UNIDENTIFIABLE, so we cannot
                # prove it is dead. Fail-CLOSED (keep): a long-running in-session
                # /plan-w-team writes a goal with no worker_sid, and reaping it would
                # delete a possibly-live run's state. "provably dead" REQUIRES a SID.
                if [ -z "$sids" ]; then
                    [ "$VERBOSE" = "1" ] && echo "kept family $slug (no owner SID → cannot prove dead, fail-closed)"
                    continue
                fi
                alive=0
                OLD_IFS="$IFS"; IFS=','
                for s in $sids; do
                    [ -z "$s" ] && continue
                    s8="$(printf '%s' "$s" | cut -c1-8)"
                    if printf '%s\n' "$LIVE8" | grep -qFx "$s8"; then alive=1; break; fi
                done
                IFS="$OLD_IFS"
                if [ "$alive" = "1" ]; then
                    [ "$VERBOSE" = "1" ] && echo "kept family $slug (worker live)"
                    continue
                fi
                # Provable orphan: null + aged + worker dead → reap the whole family.
                for pref in $FAMILY_PREFIXES; do
                    for ext in json jsonl; do
                        ff="$STATE_DIR/${pref}${slug}.${ext}"
                        [ -f "$ff" ] || continue
                        if [ "$DRY_RUN" = "1" ]; then
                            echo "[dry-run] would remove $ff (orphaned non-terminal family: worker dead + aged ≥ ${PWT_GOAL_STALE_HOURS:-24}h)"
                        else
                            rm -f "$ff" 2>/dev/null && ORPHANS_REAPED=$((ORPHANS_REAPED + 1))
                            [ "$VERBOSE" = "1" ] && echo "removed $ff (orphan family $slug)"
                        fi
                    done
                done
            done <<EOF
$REAP_CANDIDATES
EOF
        elif [ "$VERBOSE" = "1" ]; then
            echo "orphan-GC: liveness query failed/absent → fail-CLOSED, reaped nothing"
        fi
    fi
fi

if [ "$DRY_RUN" != "1" ] && [ "$QUIET" != "1" ]; then
    [ "$REMOVED" -gt 0 ] && echo "🧹 cleaned $REMOVED stale SUCCESS goal-state file(s)"
    [ "$ORPHANS_REAPED" -gt 0 ] && echo "🧹 reaped $ORPHANS_REAPED orphaned non-terminal run-state file(s)"
fi

exit 0
