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
#     (i)  ANCHORED NULL-ORPHAN — a goal/manifest/HELD workflow-lock exists, the goal's
#          terminal_state is null, the family is aged ≥ PWT_GOAL_STALE_HOURS (24),
#          and the owner SID is provably DEAD (fail-CLOSED on __QUERY_FAILED__ /
#          no-SID / live SID). This is prong B's predicate, reused verbatim. The owner
#          SIDs are the goal's worker_sid and the manifest's run_sid; ANY live one keeps
#          the family. Row 191: a HELD lock whose `owner` process is confirmed ALIVE
#          (pid present, start= matching or unreadable) keeps the family before any
#          oracle is asked — a legacy `pid`-only lock never does (that pid is the
#          pre-flight call's own transient shell) — and
#          a held lock's `owner` session= only ADDS keep evidence — it joins a SID set
#          that already has a worker_sid/run_sid, and never makes an otherwise
#          SID-less family (fail-closed keep) reapable on one oracle answer.
#     (ii) HEADLESS — NO goal AND NO manifest AND NO HELD `workflow-<slug>.lock`, and
#          the family is aged beyond the MUCH more conservative PWT_HEADLESS_STALE_HOURS
#          (default 168h / 7 days). No SID exists to query liveness, so this arm has no
#          per-run liveness check; the long age gate is its backstop. The absence of all
#          three control artifacts is STRONG (not absolute) evidence of orphanhood: a
#          live autonomous /goal or --launch run is always goal-anchored, and any run
#          past Step 3 is manifest-anchored — but an INTERACTIVE run paused in Steps 0-2
#          with PLAN_W_TEAM_DISABLE_GOAL=1 can hold none (its manifest is not written
#          until Step 3, and its workflow lock counts only while HELD — see below. A
#          `kind=parent` owner is normally the lead process itself (the Bash tool
#          shell's parent) and holds while the lead lives; only one recorded from a
#          nested shell under an unrecognised lead names that call's shell, which exits
#          with the call). "Held" (row 191): the pre-flight keeps the lock dir for the
#          whole run and retro-complete leaves it behind as `state=released`, so a lock
#          DIR is no longer control state by itself. A released lock, or one whose owner
#          process is confirmed gone (pid absent, or reused — its start time no longer
#          matches `owner` start=), is treated as ABSENT, and the finished family ages
#          out here exactly as it did when the old EXIT trap removed the dir.
#          The 7-day gate closes that window: a family untouched for a week
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
#   - headless (pass 2)          — no goal/manifest/HELD workflow-lock AND aged
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
plan-w-team-killswitch-ledger- \
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

# ── workflow-lock hold state (recursive-followup row 191) ─────────────────────
# Sets __LK_HELD (1 = the lock is control state), __LK_ALIVE (1 = HELD and its owner
# process is confirmed ALIVE) and __LK_SID (the owner's session=, "" when absent or
# not a plain id). Global-return form: no `$(…)` fork at the call.
# HELD = the dir exists, `state` is not `released`, and the owner process is not
# confirmed gone. The owner pid is `owner` pid=, else (a pre-row-191 lock with no
# `owner`) the legacy `pid` file. A usable pid is a decimal above 1, as the pre-flight
# reads it (`kill -0 0` / `kill -0 -1` succeed, pid 1 is launchd). No usable pid → cannot
# prove gone → HELD (fail-closed) but NOT alive. Gone = kill -0 fails AND ps lists no such
# pid, or `owner` start= is recorded and the live pid's start time differs (the pid was
# reused). The start stamp is formatted exactly as the pre-flight writes it (UTC, C
# locale, single-spaced).
# ALIVE = HELD by an `owner` record (the lead's claude pid or the pre-flight's parent
# pid) whose pid is usable and not gone: its start matches, or no start was recorded,
# or the live start is unreadable — each of those is "cannot prove the owner gone", so
# the caller keeps the family (fail-closed). A legacy `pid`-only lock is never ALIVE:
# that file holds the pre-flight call's own `$$`, a shell that exits with the call, so
# a live pid there (e.g. a recycled one) is not evidence that a run is live — it can
# make the lock HELD (control state) but never keeps the family outright.
__LK_HELD=0
__LK_ALIVE=0
__LK_SID=""
__lock_hold_v() {  # $1=lock dir
    local d="$1" st="" pid="" start="" cur="" own=0
    __LK_HELD=0; __LK_ALIVE=0; __LK_SID=""
    [ -d "$d" ] || return 0
    st="$(head -n 1 "$d/state" 2>/dev/null | tr -d '[:space:]')"
    [ "$st" = "released" ] && return 0
    if [ -f "$d/owner" ]; then
        own=1
        pid="$(sed -n 's/^pid=//p' "$d/owner" 2>/dev/null | head -n 1)"
        start="$(sed -n 's/^start=//p' "$d/owner" 2>/dev/null | head -n 1)"
        __LK_SID="$(sed -n 's/^session=//p' "$d/owner" 2>/dev/null | head -n 1)"
        case "$__LK_SID" in *[!A-Za-z0-9-]*) __LK_SID="" ;; esac
    else
        pid="$(head -n 1 "$d/pid" 2>/dev/null | tr -d '[:space:]')"
    fi
    __LK_HELD=1
    case "$pid" in ""|0*|1|*[!0-9]*) return 0 ;; esac
    if ! kill -0 "$pid" 2>/dev/null && [ -z "$(ps -o pid= -p "$pid" 2>/dev/null)" ]; then
        __LK_HELD=0; __LK_SID=""; return 0
    fi
    if [ -n "$start" ]; then
        cur="$(TZ=UTC LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')"
        if [ -n "$cur" ] && [ "$cur" != "$start" ]; then __LK_HELD=0; __LK_SID=""; return 0; fi
    fi
    [ "$own" = "1" ] && __LK_ALIVE=1
    return 0
}

# ── collision-proof attribution + reaping helpers (row 18) ────────────────────
# The `_v` forms return through a GLOBAL (__BEST / __SLUG) instead of stdout so the
# one-scan index below can attribute a file WITHOUT a `$(…)` subshell. That is a cost
# fix, not a style one: the 2026-09-21 cleanscale regression was this script forking
# ≥3 times per file per family (~350K forks over a 1,356-entry state dir = 397 s, to
# reap nothing), synchronously, on every post-compaction SessionStart. The printf
# wrappers stay so the classification has ONE body and cannot drift from itself.
__BEST=""
__SLUG=""
__longest_reap_prefix_v() {  # $1=basename → __BEST = the LONGEST reap prefix it starts with ("")
    local base="$1" p
    __BEST=""
    for p in $PER_SLUG_REAP_PREFIXES; do
        case "$base" in
            "$p"*) [ "${#p}" -gt "${#__BEST}" ] && __BEST="$p" ;;
        esac
    done
    return 0
}
__longest_reap_prefix() { __longest_reap_prefix_v "$1"; printf '%s' "$__BEST"; }

# __slug_of_file: the slug a state file belongs to, or "" if it is a global /
# unmanaged / charset-invalid file. Longest-prefix-wins + denylist + charset guard —
# the single attribution point shared by discovery, age, and reap so they cannot
# disagree.
__slug_of_file_v() {  # $1=basename → __SLUG ("" = not a reapable per-slug file)
    local base="$1" rest slug
    __SLUG=""
    __in_global_denylist "$base" && return 0
    __longest_reap_prefix_v "$base"
    [ -z "$__BEST" ] && return 0
    rest="${base#"$__BEST"}"
    slug="$rest"
    case "$rest" in *.*) slug="${rest%.*}" ;; esac   # strip one trailing extension
    case "$slug" in
        ""|*[!A-Za-z0-9_-]*) return 0 ;;             # charset guard (no dots/metachars)
    esac
    __SLUG="$slug"
    return 0
}
__slug_of_file() { __slug_of_file_v "$1"; printf '%s' "$__SLUG"; }

# ── ONE-SCAN family index ─────────────────────────────────────────────────────
# PASS 2 used to rescan ALL of $STATE_DIR once per candidate family (newest-mtime)
# and again per reaped family — O(families × entries). The index walks the directory
# ONCE, attributes each entry in-shell, and takes every mtime from ONE batched stat:
#   FAMILY_INDEX   "slug<TAB>path" per attributed entry        (temp file, outside STATE_DIR)
#   FAMILY_INDEX_MT "mtime path" per indexed path               (temp file, same private dir)
#   FAMILY_NEWEST  "slug newest-mtime" per family, sorted      (-1 = some member unreadable)
# Every uncertainty stays a KEEP, exactly as before: a member whose mtime cannot be
# read marks its family -1 (the old `echo -1`), and a member whose NAME carries a tab
# or newline — which a line-based index cannot represent faithfully — marks its family
# unindexable and the family is kept whole. An index that cannot be built at all
# (no mktemp, control characters in $STATE_DIR itself) skips PASS 2 entirely.
#
# Both temp files live in ONE `mktemp -d` directory (0700, atomically created): the
# mtime file decides whether a HEADLESS family counts as aged, and that arm has no second
# liveness check — so it must never be a guessable name opened with a plain `>` in a
# shared $TMPDIR, where a pre-planted symlink/file could feed it spoofed mtimes
# (Step-5 security review, 2.47.0).
FAMILY_INDEX_DIR=""
FAMILY_INDEX=""
FAMILY_INDEX_MT=""
FAMILY_NEWEST=""
UNINDEXABLE_SLUGS=" "
__TAB="$(printf '\t')"
__NL='
'
__cleanup_family_index() {
    [ -n "$FAMILY_INDEX_DIR" ] || return 0
    rm -f "$FAMILY_INDEX" "$FAMILY_INDEX_MT" 2>/dev/null
    rmdir "$FAMILY_INDEX_DIR" 2>/dev/null
    return 0
}

__build_family_index() {  # → 0 when FAMILY_INDEX/FAMILY_NEWEST are usable, 1 = fail-CLOSED (skip pass 2)
    local f base joined
    case "$STATE_DIR" in *"$__TAB"*|*"$__NL"*) return 1 ;; esac
    FAMILY_INDEX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwt-janitor-index.XXXXXX" 2>/dev/null)" || { FAMILY_INDEX_DIR=""; return 1; }
    # A real directory we own, not a symlink to one: only then are the names inside it ours.
    [ -n "$FAMILY_INDEX_DIR" ] && [ -d "$FAMILY_INDEX_DIR" ] && [ ! -L "$FAMILY_INDEX_DIR" ] || { FAMILY_INDEX_DIR=""; return 1; }
    trap __cleanup_family_index EXIT
    FAMILY_INDEX="$FAMILY_INDEX_DIR/index"
    FAMILY_INDEX_MT="$FAMILY_INDEX_DIR/mtimes"

    for f in "$STATE_DIR"/*; do
        [ -e "$f" ] || continue
        base="${f##*/}"
        __slug_of_file_v "$base"
        [ -n "$__SLUG" ] || continue
        case "$base" in
            *"$__TAB"*|*"$__NL"*) UNINDEXABLE_SLUGS="$UNINDEXABLE_SLUGS$__SLUG " ; continue ;;
        esac
        printf '%s\t%s\n' "$__SLUG" "$f"
    done > "$FAMILY_INDEX" || return 1
    [ -s "$FAMILY_INDEX" ] || return 0        # nothing attributable → nothing to classify

    # One batched stat for every indexed path (BSD `-f '%m %N'`, GNU `-c '%Y %n'`).
    if stat -f %m / >/dev/null 2>&1; then
        cut -f2- "$FAMILY_INDEX" | tr '\n' '\0' | xargs -0 stat -f '%m %N' > "$FAMILY_INDEX_MT" 2>/dev/null
    else
        cut -f2- "$FAMILY_INDEX" | tr '\n' '\0' | xargs -0 stat -c '%Y %n' > "$FAMILY_INDEX_MT" 2>/dev/null
    fi

    # xargs exits non-zero when ANY stat fails (a member vanished mid-run): that is a
    # per-family -1 below, not a reason to drop the pass. A missing mtime FILE is.
    [ -f "$FAMILY_INDEX_MT" ] || return 1

    # Join: a member with no readable numeric mtime poisons its family to -1 (KEEP).
    # awk's status is checked on its own — piped straight into sort, sort's 0 would mask it.
    joined="$(awk '
        NR == FNR { sp = index($0, " "); if (sp > 1) mt[substr($0, sp + 1)] = substr($0, 1, sp - 1); next }
        {
            tb = index($0, "\t"); if (tb < 2) next
            slug = substr($0, 1, tb - 1); path = substr($0, tb + 1); seen[slug] = 1
            if (!(path in mt) || mt[path] !~ /^[0-9]+$/) bad[slug] = 1
            else if (mt[path] + 0 > newest[slug] + 0) newest[slug] = mt[path]
        }
        END { for (s in seen) print s, ((s in bad) ? -1 : newest[s] + 0) }
    ' "$FAMILY_INDEX_MT" "$FAMILY_INDEX" 2>/dev/null)" || return 1
    [ -n "$joined" ] || return 1
    FAMILY_NEWEST="$(printf '%s\n' "$joined" | sort)"
    return 0
}

REAPED_FILES=0
REAPED_FAMILIES=0
__reap_family() {  # $1=slug (already charset-validated + confirmed reapable)
    local slug="$1" f
    [ -n "$FAMILY_INDEX" ] && [ -f "$FAMILY_INDEX" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -e "$f" ] || continue
        # Re-attribute at the moment of deletion: the index is a work list, never an
        # authority. Must still sit DIRECTLY in $STATE_DIR and still classify to $slug.
        [ "${f%/*}" = "$STATE_DIR" ] || continue
        __slug_of_file_v "${f##*/}"
        [ "$__SLUG" = "$slug" ] || continue
        if [ "$DRY_RUN" = "1" ]; then
            echo "[dry-run] would remove $f (orphan/headless family $slug)"
        else
            if [ -d "$f" ]; then rm -rf "$f" 2>/dev/null; else rm -f "$f" 2>/dev/null; fi
            REAPED_FILES=$((REAPED_FILES + 1))
            [ "$VERBOSE" = "1" ] && echo "removed $f (family $slug)"
        fi
    done <<EOF
$(awk -v s="$slug" '{ tb = index($0, "\t"); if (tb > 1 && substr($0, 1, tb - 1) == s) print substr($0, tb + 1) }' "$FAMILY_INDEX" 2>/dev/null)
EOF
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

    # 1) Discover candidate slugs + each family's newest mtime in ONE directory scan
    #    (longest-prefix-wins attribution, denylist + charset). An index that cannot be
    #    built is fail-CLOSED: FAMILY_NEWEST stays empty and nothing below reaps.
    if ! __build_family_index; then
        FAMILY_NEWEST=""
        [ "$VERBOSE" = "1" ] && echo "orphan-GC: family index unavailable → fail-CLOSED, reaped nothing"
    fi

    # 2) Classify each candidate → PRESERVE / HEADLESS (age-only) / NULL (liveness).
    HEADLESS_CAND=""
    NULL_CAND=""      # "slug<SPACE>sid,sid" lines
    while IFS=' ' read -r slug newest; do
        [ -z "$slug" ] && continue
        case "$UNINDEXABLE_SLUGS" in
            *" $slug "*)
                [ "$VERBOSE" = "1" ] && echo "kept family $slug (member name not indexable → fail-closed)"
                continue ;;
        esac
        case "$newest" in ""|*[!0-9-]*) continue ;; esac     # malformed index row → keep
        [ "$newest" -le 0 ] 2>/dev/null && continue          # unreadable / none → keep
        age=$(( NOW - newest ))
        [ "$age" -lt "$MAX_AGE" ] 2>/dev/null && continue    # fresh → keep (protects live + just-finished)

        gf="$STATE_DIR/plan-w-team-goal-${slug}.json"
        mf="$STATE_DIR/plan-w-team-manifest-${slug}.json"
        wl="$STATE_DIR/plan-w-team-workflow-${slug}.lock"
        # Row 191: only a HELD lock is control state. A held lock whose owner process
        # is confirmed ALIVE keeps the family outright — the lead is running, whatever
        # one oracle answer says about its session (the oracle omits `waiting`
        # sessions). Otherwise the lock's session= only ADDS keep evidence: it joins
        # an owner-SID set that already has a goal worker_sid or a manifest run_sid,
        # and it never turns an empty set (fail-closed keep) into a reapable one.
        __lock_hold_v "$wl"
        if [ "$__LK_HELD" = "1" ] && [ "$__LK_ALIVE" = "1" ]; then
            [ "$VERBOSE" = "1" ] && echo "kept family $slug (workflow lock held by a live owner process)"
            continue
        fi

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
            # Keep evidence only: never the sole SID (see __lock_hold_v above).
            [ -n "$sids" ] && [ -n "$__LK_SID" ] && sids="$sids $__LK_SID"
        elif [ -f "$mf" ] || [ "$__LK_HELD" = "1" ]; then
            # No goal, but control state (a manifest or a HELD workflow lock whose
            # owner is not confirmed alive) exists → null-orphan via the manifest
            # run_sid; the lock owner's session only adds keep evidence to it.
            sids=""
            [ -f "$mf" ] && { r="$(__json_str_field "$mf" run_sid)"; [ -n "$r" ] && sids="$sids $r"; }
            [ -n "$sids" ] && [ -n "$__LK_SID" ] && sids="$sids $__LK_SID"
        else
            # HEADLESS: no goal, no manifest, no HELD workflow lock (absent, released at
            # retro-complete, or its owner process is gone). No SID to prove death,
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
$FAMILY_NEWEST
EOF

    # 3) Reap HEADLESS families — aged is sufficient (no live run lacks all control state).
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        [ "$VERBOSE" = "1" ] && echo "reaping HEADLESS family $slug (no goal/manifest/held workflow-lock, aged)"
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
