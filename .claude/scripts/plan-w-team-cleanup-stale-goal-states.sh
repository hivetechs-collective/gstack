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
# PASS 2 — provably-orphaned FULL per-run family GC (prong B 2026-06-10; the
#   FULL-family + headless extension is 2026-08-29, followups row 18 / SA-4).
#   The SUCCESS-only pass left non-terminal orphans — and their sibling run-state
#   family — on disk FOREVER. Prong B (2026-06-10) began reaping a provably-orphaned
#   `terminal_state=null` family, but only a FIVE-prefix subset (goal, manifest,
#   skill-version, spawned-children, stage-events), so every reap BEHEADED its own
#   family: it deleted the goal+manifest anchors while leaving the OTHER ~42 per-run
#   classes on disk with no discovery anchor ("headless"). SA-4's larger half (row 18)
#   closes this: PASS 2 now reaps the COMPLETE per-run family (the 47 `$SLUG`-keyed
#   `plan-w-team-*` registry classes + `supervisor-progress-<slug>.json`) and adds a
#   HEADLESS arm that reaps aged families whose control state (goal AND manifest AND
#   workflow-lock) is already gone — no live run can lack all three, so their absence
#   is structural proof of orphanhood.
#
#   Two safe reap classifications, BOTH keyed on the GOAL file (the manifest's
#   `terminal_state` is null in production — `pwt-manifest.sh` only sets it via an
#   env-passthrough no caller passes — so it is used ONLY for run_sid + age):
#     (i)  ANCHORED NULL-ORPHAN — a goal/manifest/workflow-lock exists, the goal's
#          terminal_state is null, the family is aged ≥ PWT_GOAL_STALE_HOURS (24),
#          and the owner SID is provably DEAD (fail-CLOSED on __QUERY_FAILED__ /
#          no-SID / live SID). This is prong B's predicate, reused verbatim.
#     (ii) HEADLESS — NO goal AND NO manifest AND NO `workflow-<slug>.lock` dir, and
#          the family is aged beyond the MUCH more conservative PWT_HEADLESS_STALE_HOURS
#          (default 168h / 7 days). No SID exists to query liveness, so this arm has no
#          per-run liveness check; the long age gate is its backstop. The absence of all
#          three control artifacts is STRONG (not absolute) evidence of orphanhood: a
#          live autonomous /goal or --launch run is always goal-anchored, and any run
#          past Step 3 is manifest-anchored — but an INTERACTIVE run paused in Steps 0-2
#          with PLAN_W_TEAM_DISABLE_GOAL=1 can transiently hold none (its workflow-lock
#          is released by the pre-flight EXIT trap, its manifest is not written until
#          Step 3). The 7-day gate closes that window: a family untouched for a week
#          cannot be a session doing active work (a live run touches its artifacts), and
#          the only members at risk are RECOVERABLE early-planning artifacts (scope-lock,
#          ac-snapshot), never committed work.
#
#   COLLISION SAFETY (delete blast radius). Reaping is file-driven with
#   longest-reap-prefix-wins attribution + an explicit GLOBAL denylist + a slug
#   charset guard, because the naive `<prefix><slug>.*` glob is NOT collision-proof:
#   reap prefixes nest (`plan-w-team-retro-` ⊂ `plan-w-team-retro-capture-`), so a
#   poison slug `capture-history` under `plan-w-team-retro-` would glob — and delete —
#   the durable global `plan-w-team-retro-capture-history.jsonl`. Longest-prefix-wins
#   attributes that file to its TRUE class (`retro-capture-`, slug `history`), and the
#   denylist subtracts it outright. Only slugs matching `^[A-Za-z0-9_-]+$` are reapable.
#
# PRESERVED states (signal worth keeping for inspection — NEVER reaped by either
# pass, regardless of age): any goal whose terminal_state is present, non-null and
# NOT SUCCESS — USER_ESCALATION_HALT, LOW_CONFIDENCE_STREAK, DEAD, API_HALT,
# EARLY_EXIT, and any UNKNOWN future value (preserve-by-default, a deliberate choice).
# REAPED:
#   - SUCCESS  (pass 1)          — retro completed, goal file should already be gone
#   - null     (pass 2, anchored)— ONLY when worker-dead AND aged (provable orphan)
#   - headless (pass 2)          — no goal/manifest/workflow-lock AND aged
#
# Usage:
#   plan-w-team-cleanup-stale-goal-states.sh                    # silent unless removals
#   plan-w-team-cleanup-stale-goal-states.sh --verbose          # log every action
#   plan-w-team-cleanup-stale-goal-states.sh --quiet            # suppress even the summary
#   plan-w-team-cleanup-stale-goal-states.sh --dry-run          # list, don't delete
#   plan-w-team-cleanup-stale-goal-states.sh --list-reap-prefixes    # print the per-slug reap prefixes (parity test)
#   plan-w-team-cleanup-stale-goal-states.sh --list-global-denylist  # print the never-reap globals (parity test)
#   STATE_DIR=/path/to/state plan-w-team-cleanup-stale-goal-states.sh   # override
#   PWT_GOAL_STALE_HOURS=<n>       anchored null-orphan age threshold (default 24)
#   PWT_HEADLESS_STALE_HOURS=<n>   headless-family age threshold (default 168 = 7 days)
#   PLAN_W_TEAM_DISABLE_ORPHAN_GC=1   skip pass 2 (SUCCESS-goal-only behavior)
#
# This is the SINGLE stale-goal-state janitor (reconciled 2026-06-08): both
# session-start (no args) and 07-retro.md (--quiet) call it. Pass 1 only ever
# removes terminal_state=SUCCESS goals; pass 2 only ever removes a provably-orphaned
# or headless family — so neither caller can delete a goal-state another LIVE run
# left for inspection.
#
# Exit code: always 0 (best-effort; never block session start)

set -u

STATE_DIR="${STATE_DIR:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}/.claude/state}"
VERBOSE=0
DRY_RUN=0
QUIET=0
LIST_MODE=""

for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=1 ;;
        --quiet|-q) QUIET=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --list-reap-prefixes) LIST_MODE="reap-prefixes" ;;
        --list-global-denylist) LIST_MODE="global-denylist" ;;
        --help|-h)
            sed -nE 's/^# ?//; 1,/^$/p' "$0" | head -40
            exit 0
            ;;
        *) ;;  # ignore unknown args (best-effort caller)
    esac
done

# ── PER-SLUG reap prefixes ────────────────────────────────────────────────────
# The complete per-run artifact family. The `plan-w-team-*` members are EXACTLY the
# 47 `$SLUG`-keyed classes in `shared/state-artifacts.md` (pinned by
# plan-w-team-cleanup-registry-parity.test.sh — drift in either direction fails).
# `supervisor-progress-` is the ONE sanctioned non-`plan-w-team-` extra (slug-keyed
# per-run anti-park snapshot, written by supervisor-progress-check.sh). Kept as an
# EXPLICIT list (never derived from the registry at runtime) so a doc file can never
# become a delete-capability input; the test guards parity instead.
PER_SLUG_REAP_PREFIXES="\
plan-w-team-goal- \
plan-w-team-manifest- \
plan-w-team-skill-version- \
plan-w-team-spawned-children- \
plan-w-team-stage-events- \
plan-w-team-untracked-baseline- \
plan-w-team-ac-snapshot- \
plan-w-team-scope-lock- \
plan-w-team-scope-unlock- \
plan-w-team-retro- \
plan-w-team-retro-capture- \
plan-w-team-autofix- \
plan-w-team-review-findings- \
plan-w-team-ack- \
plan-w-team-secret-scan-allow- \
plan-w-team-workflow- \
plan-w-team-postship- \
plan-w-team-coupling- \
plan-w-team-coupling-ack- \
plan-w-team-path-existence- \
plan-w-team-path-existence-ack- \
plan-w-team-fleet- \
plan-w-team-fleet-intent- \
plan-w-team-supervisor-actions- \
plan-w-team-orchestrator-decisions- \
plan-w-team-spec-fanout- \
plan-w-team-project-version- \
plan-w-team-project-version-baseline- \
plan-w-team-test-baseline- \
plan-w-team-regression-waiver- \
plan-w-team-sync-confirm- \
plan-w-team-deep-audit- \
plan-w-team-completion- \
plan-w-team-empty-ship-attempts- \
plan-w-team-fable-ledger- \
plan-w-team-ship-verdict- \
plan-w-team-landed- \
plan-w-team-test-green- \
plan-w-team-content-signal-suspects- \
plan-w-team-bypass- \
plan-w-team-pass1-synthesis- \
plan-w-team-test-output- \
plan-w-team-docs-waived- \
plan-w-team-credwall- \
plan-w-team-abstraction-claims- \
plan-w-team-lane-release- \
plan-w-team-stall- \
plan-w-team-stall-events- \
plan-w-team-host-distress- \
plan-w-team-liveness- \
supervisor-progress-"

# ── GLOBAL denylist ───────────────────────────────────────────────────────────
# Durable / cross-run / differently-keyed `.claude/state/plan-w-team-*` files that
# MUST NEVER be reaped. Most do not begin with any reap prefix and are auto-skipped
# by __longest_reap_prefix; `plan-w-team-retro-capture-history.jsonl` is the ONE that
# shares a reap-prefix stem (`plan-w-team-retro-capture-`), so denylisting it is the
# load-bearing safety entry. The keyed globals (friction-ack / hook-spawn / directive /
# status) are matched by pattern. plan-w-team-cleanup-registry-parity.test.sh asserts
# every registry global that begins with a reap prefix is covered here.
GLOBAL_DENYLIST_LITERALS="\
plan-w-team-retro-capture-history.jsonl \
plan-w-team-recursive-followups.jsonl \
plan-w-team-friction-log.jsonl \
plan-w-team-friction-log.lock \
plan-w-team-push.lock \
plan-w-team-land-audit.jsonl \
plan-w-team-run-state-audit.jsonl \
plan-w-team-lane-guard-audit.jsonl \
plan-w-team-ds1-audit.jsonl \
plan-w-team-test-green.lock"

__in_global_denylist() {  # $1=basename → 0 if a never-reap global
    local base="$1" g
    for g in $GLOBAL_DENYLIST_LITERALS; do
        [ "$base" = "$g" ] && return 0
    done
    case "$base" in
        plan-w-team-friction-ack-*|plan-w-team-hook-spawn-*|plan-w-team-directive-*|plan-w-team-status-*) return 0 ;;
    esac
    return 1
}

# Debug subcommands (static — safe without a state dir; consumed by the parity test).
if [ "$LIST_MODE" = "reap-prefixes" ]; then
    for p in $PER_SLUG_REAP_PREFIXES; do printf '%s\n' "$p"; done
    exit 0
fi
if [ "$LIST_MODE" = "global-denylist" ]; then
    for g in $GLOBAL_DENYLIST_LITERALS; do printf '%s\n' "$g"; done
    printf '%s\n' "plan-w-team-friction-ack-*" "plan-w-team-hook-spawn-*" "plan-w-team-directive-*" "plan-w-team-status-*"
    exit 0
fi

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

# ── collision-proof attribution + reaping helpers (row 18) ────────────────────
__longest_reap_prefix() {  # $1=basename → the LONGEST reap prefix it starts with ("")
    local base="$1" best="" p
    for p in $PER_SLUG_REAP_PREFIXES; do
        case "$base" in
            "$p"*) [ "${#p}" -gt "${#best}" ] && best="$p" ;;
        esac
    done
    printf '%s' "$best"
}

# __slug_of_file: echo the slug a state file belongs to, or "" if it is a global /
# unmanaged / charset-invalid file. Longest-prefix-wins + denylist + charset guard —
# the single attribution point shared by discovery, age, and reap so they cannot
# disagree.
__slug_of_file() {  # $1=basename → slug ("" = not a reapable per-slug file)
    local base="$1" p rest slug
    __in_global_denylist "$base" && { printf ''; return; }
    p="$(__longest_reap_prefix "$base")"
    [ -z "$p" ] && { printf ''; return; }
    rest="${base#"$p"}"
    slug="$rest"
    case "$rest" in *.*) slug="${rest%.*}" ;; esac   # strip one trailing extension
    case "$slug" in
        ""|*[!A-Za-z0-9_-]*) printf ''; return ;;    # charset guard (no dots/metachars)
    esac
    printf '%s' "$slug"
}

__family_newest_mtime() {  # $1=slug → newest mtime across its family (-1 unreadable, 0 none)
    local slug="$1" f base newest=0 m
    for f in "$STATE_DIR"/*; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        [ "$(__slug_of_file "$base")" = "$slug" ] || continue
        m="$(__mtime_of "$f")"
        [ -n "$m" ] || { echo "-1"; return; }
        [ "$m" -gt "$newest" ] 2>/dev/null && newest="$m"
    done
    echo "$newest"
}

REAPED_FILES=0
REAPED_FAMILIES=0
__reap_family() {  # $1=slug (already charset-validated + confirmed reapable)
    local slug="$1" f base
    for f in "$STATE_DIR"/*; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        [ "$(__slug_of_file "$base")" = "$slug" ] || continue
        if [ "$DRY_RUN" = "1" ]; then
            echo "[dry-run] would remove $f (orphan/headless family $slug)"
        else
            if [ -d "$f" ]; then rm -rf "$f" 2>/dev/null; else rm -f "$f" 2>/dev/null; fi
            REAPED_FILES=$((REAPED_FILES + 1))
            [ "$VERBOSE" = "1" ] && echo "removed $f (family $slug)"
        fi
    done
    [ "$DRY_RUN" = "1" ] || REAPED_FAMILIES=$((REAPED_FAMILIES + 1))
}

REMOVED=0

# ── PASS 1: SUCCESS goal-state removal (UNCHANGED) ────────────────────────────
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

# ── PASS 2: provably-orphaned / headless FULL-family GC (row 18) ──────────────
# Skipped entirely under PLAN_W_TEAM_DISABLE_ORPHAN_GC=1 (janitor stays SUCCESS-only).
if [ "${PLAN_W_TEAM_DISABLE_ORPHAN_GC:-}" != "1" ]; then
    MAX_AGE=$(( ${PWT_GOAL_STALE_HOURS:-24} * 3600 ))
    # Headless families carry NO SID to prove death, so they get a far more conservative
    # age gate than anchored orphans (Q4, security review 2026-08-29).
    HEADLESS_MAX_AGE=$(( ${PWT_HEADLESS_STALE_HOURS:-168} * 3600 ))
    NOW=$(date -u +%s)

    # 1) Discover candidate slugs (longest-prefix-wins attribution, denylist + charset).
    CAND_SLUGS=""
    for f in "$STATE_DIR"/*; do
        [ -e "$f" ] || continue
        slug="$(__slug_of_file "$(basename "$f")")"
        [ -n "$slug" ] || continue
        CAND_SLUGS="$CAND_SLUGS
$slug"
    done
    CAND_SLUGS="$(printf '%s\n' "$CAND_SLUGS" | grep -v '^$' | sort -u)"

    # 2) Classify each candidate → PRESERVE / HEADLESS (age-only) / NULL (liveness).
    HEADLESS_CAND=""
    NULL_CAND=""      # "slug<SPACE>sid,sid" lines
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        newest="$(__family_newest_mtime "$slug")"
        [ "$newest" -le 0 ] 2>/dev/null && continue          # unreadable / none → keep
        age=$(( NOW - newest ))
        [ "$age" -lt "$MAX_AGE" ] 2>/dev/null && continue    # fresh → keep (protects live + just-finished)

        gf="$STATE_DIR/plan-w-team-goal-${slug}.json"
        mf="$STATE_DIR/plan-w-team-manifest-${slug}.json"
        wl="$STATE_DIR/plan-w-team-workflow-${slug}.lock"

        if [ -f "$gf" ]; then
            term="$(__terminal_state_of "$gf")"
            if [ -n "$term" ] && [ "$term" != "SUCCESS" ]; then
                [ "$VERBOSE" = "1" ] && echo "kept family $slug (preserved terminal_state=$term)"
                continue                                     # escalation/DEAD/API_HALT/EARLY_EXIT/unknown
            fi
            # null (or SUCCESS, which PASS 1 already removed) → anchored null-orphan path.
            sids=""
            w="$(__json_str_field "$gf" worker_sid)"; [ -n "$w" ] && sids="$sids $w"
            [ -f "$mf" ] && { r="$(__json_str_field "$mf" run_sid)"; [ -n "$r" ] && sids="$sids $r"; }
        elif [ -f "$mf" ] || [ -d "$wl" ]; then
            # No goal, but control state (manifest/workflow-lock) exists → null-orphan via run_sid.
            sids=""
            [ -f "$mf" ] && { r="$(__json_str_field "$mf" run_sid)"; [ -n "$r" ] && sids="$sids $r"; }
        else
            # HEADLESS: no goal, no manifest, no workflow-lock dir. No SID to prove death,
            # so require the much longer HEADLESS_MAX_AGE — a family untouched for 7 days
            # cannot be a live session doing work (Q4 fix; see the header).
            if [ "$age" -lt "$HEADLESS_MAX_AGE" ] 2>/dev/null; then
                [ "$VERBOSE" = "1" ] && echo "kept family $slug (headless but younger than PWT_HEADLESS_STALE_HOURS)"
                continue
            fi
            HEADLESS_CAND="$HEADLESS_CAND
$slug"
            continue
        fi

        sids="$(printf '%s' "$sids" | tr ' ' '\n' | grep -v '^$' | paste -sd, - 2>/dev/null || true)"
        if [ -z "$sids" ]; then
            # No owner SID → cannot prove dead → fail-CLOSED keep (protects a live
            # in-session run that wrote a goal with no worker_sid).
            [ "$VERBOSE" = "1" ] && echo "kept family $slug (no owner SID → fail-closed)"
            continue
        fi
        NULL_CAND="$NULL_CAND
${slug} ${sids}"
    done <<EOF
$CAND_SLUGS
EOF

    # 3) Reap HEADLESS families — aged is sufficient (no live run lacks all control state).
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        [ "$VERBOSE" = "1" ] && echo "reaping HEADLESS family $slug (no goal/manifest/workflow-lock, aged)"
        __reap_family "$slug"
    done <<EOF
$(printf '%s\n' "$HEADLESS_CAND" | grep -v '^[[:space:]]*$')
EOF

    # 4) Reap ANCHORED NULL-ORPHANS — query live SIDs ONCE (fail-CLOSED), reap dead ones.
    NULL_CAND="$(printf '%s\n' "$NULL_CAND" | grep -v '^[[:space:]]*$')"
    if [ -n "$NULL_CAND" ]; then
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
                [ "$sids" = "$line" ] && sids=""
                [ -z "$sids" ] && continue
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
                [ "$VERBOSE" = "1" ] && echo "reaping ANCHORED null-orphan family $slug (worker dead + aged)"
                __reap_family "$slug"
            done <<EOF
$NULL_CAND
EOF
        elif [ "$VERBOSE" = "1" ]; then
            echo "orphan-GC: liveness query failed/absent → fail-CLOSED, reaped nothing from null path"
        fi
    fi
fi

if [ "$DRY_RUN" != "1" ] && [ "$QUIET" != "1" ]; then
    [ "$REMOVED" -gt 0 ] && echo "🧹 cleaned $REMOVED stale SUCCESS goal-state file(s)"
    [ "$REAPED_FILES" -gt 0 ] && echo "🧹 reaped $REAPED_FILES file(s) across $REAPED_FAMILIES orphaned/headless run-state family(ies)"
fi

exit 0
