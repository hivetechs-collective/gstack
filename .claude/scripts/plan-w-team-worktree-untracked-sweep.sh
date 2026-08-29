#!/usr/bin/env bash
# plan-w-team-worktree-untracked-sweep.sh
#
# Clears provably-lossless UNTRACKED files from INSIDE worktrees under
# .claude/worktrees/. Dry-run by default; --execute to act.
#
# ─── WHY THIS EXISTS (recursive-followup row 17 / WT-5, 2026-06-08) ──────────
# Every other cleanup path in this subsystem works at WORKTREE granularity —
# `git worktree remove --force` destroys the whole tree. Nothing has ever cleared
# a file *inside* a worktree that SURVIVES. Two consequences:
#
#   1. A worktree the GC keeps — in-use, unmerged, ORPHAN-ASK, or held by any of
#      the fail-closed arms — accumulates untracked churn indefinitely.
#   2. preserve_then_reap filters backups with the NARROW preserve set, so every
#      untracked file under `.claude/`, `tests/skill/` and `docs/operations/` is
#      copied into the backup on EVERY reap. Synced noise then buries the
#      genuinely authored files the backup exists to save.
#
# ─── THE SAFETY ARGUMENT (read this before touching the predicate) ───────────
# This script DELETES, unattended, from inside a retro, with no human reading a
# diff. So it does not delete anything it merely believes is junk. It deletes two
# classes whose bytes are RECOVERABLE by construction (see the invariant below —
# "recoverable", deliberately, not the stronger "lossless" the first draft claimed):
#
#   STATE  — the path matches the BACKUP ignore set ($PWT_PRESERVE_IGNORE_DEFAULT).
#            That set is already this repo's declared answer to "what need NOT
#            survive a destructive reap": machine-written runtime state and
#            regenerable build trees. We are reusing an existing verdict, not
#            minting a new one. MINUS the durable-artifact keep-list below.
#
#   SYNCED — the path sits under a synced-tooling prefix AND the working file
#            hashes to the SAME blob the default branch stores for that same
#            path. The exact bytes are a reachable git object;
#            `git checkout <ref> -- <path>` restores it verbatim.
#
# Everything else is AUTHORED and is KEPT — a brand-new `.claude/` script, an
# edited copy of a synced file, `output/*.html`, and every path whose class could
# not be PROVEN. Unprovable always means keep.
#
# THE INVARIANT IS RECOVERABILITY, NOT DISJOINTNESS. The first draft of this
# script claimed something stronger and FALSE: "the sweep never removes anything
# preserve_then_reap would back up." The oracle test disproved it immediately —
# class SYNCED removes files the backup WOULD copy out, because `.claude/` is
# absent from the narrow backup set and a synced file therefore survives the
# preserve filter. Keeping that claim would have meant either deleting a true
# statement's test or, worse, gutting class SYNCED to satisfy a proxy property.
#
# The property that actually makes a removal safe is that the bytes can be got
# back, and the two classes earn it by different routes:
#
#   STATE  — nothing to get back; the repo already declared it regenerable or
#            machine-written. Proven by DISJOINTNESS from the backup set (it is
#            exactly the set preserve_then_reap declines to save).
#   SYNCED — the bytes are a reachable git object, which is STRICTLY STRONGER
#            than a backup copy — so overlapping the backup set is fine here; the
#            copy was redundant. Proven by RESTORING the file after removal and
#            byte-comparing (test [18b]), not by any naming convention.
#
# Both halves are asserted non-vacuously, so neither can pass by being empty.
#
# ─── WHAT IS DELIBERATELY OUT OF SCOPE ───────────────────────────────────────
# Enumeration uses `--exclude-standard`, so GITIGNORED trees (node_modules/,
# dist/, build/) are never even listed. That is a boundary, not an oversight:
# worktree-deps-share.sh may back those with a SHARED store, and deleting through
# a shared symlink would destroy it for every other worktree. The whole-worktree
# GC already sweeps them with --force. It is also the same enumeration idiom
# preserve_then_reap uses, which is what makes the two sets directly comparable in
# the class-STATE disjointness proof.
#
# ─── FAIL-CLOSED POSTURE ─────────────────────────────────────────────────────
# Run-wide gates (shared module, python3, liveness) abort the WHOLE pass; per-
# worktree vetoes (containment, in-use, newborn) skip one worktree; an unresolvable
# default ref degrades by disabling class SYNCED only. Every one of them errs
# toward removing LESS.
#
# Gate order is load-bearing: the repo's own lesson (worktree-lifecycle.md §VETO 0)
# is that a fail-closed gate positioned below a branch that can act on the evidence
# it validates is worth nothing. Only the containment check may precede the python3
# probe, because pure-shell realpath is the one test that does not depend on python3
# being alive.
#
# Tests: .claude/scripts/plan-w-team-worktree-untracked-sweep.test.sh
# Docs:  docs/operations/worktree-lifecycle.md §"Untracked sweep"
#
# EXIT CODES
#   0  completed (including every "swept nothing" fail-closed outcome — a skip is
#      never a run failure; §8j-septies is fail-open by contract)
#   2  usage error
#
# bash 3.2 (mac-mini /bin/bash): no `declare -A`, no `${v,,}`, no mapfile.

set -uo pipefail

SWEEP_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── kill switch ─────────────────────────────────────────────────────────────
if [ "${PWT_UNTRACKED_SWEEP_DISABLE:-0}" = "1" ]; then
    printf '{"schema":"plan-w-team-worktree-untracked-sweep/v1","skipped":true,"reason":"PWT_UNTRACKED_SWEEP_DISABLE=1","totals":{"removed":0,"kept":0,"remove_failed":0},"worktrees":[]}\n'
    exit 0
fi

# ─── args ────────────────────────────────────────────────────────────────────
EXECUTE=0
JSON=0
PRINT_CLASSIFIED=0
ONE_WORKTREE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --execute)   EXECUTE=1 ;;
        --json)      JSON=1 ;;
        --worktree)  shift; ONE_WORKTREE="${1:-}" ;;
        --print-classified)
            # Test/audit seam: emit one `CLASS<TAB>repo-relative-path` line per
            # enumerated file to stderr, so the exact SET a run would remove is
            # observable — not just its cardinality. Both halves of the AC4
            # recoverability proof need the set, not the count: the class-STATE
            # disjointness check and the class-SYNCED restore-and-compare. On
            # stderr so it composes with --json without corrupting stdout.
            PRINT_CLASSIFIED=1 ;;
        -h|--help)
            # Print the whole leading comment block: every line from the shebang to
            # the first blank line that is not a comment. A hardcoded line range
            # silently truncates the moment the header grows (it already had).
            sed -n '2,/^[^#]/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//' >&2
            exit 0 ;;
        *)
            echo "unknown argument: $1" >&2
            echo "usage: plan-w-team-worktree-untracked-sweep.sh [--execute] [--json] [--print-classified] [--worktree <path>]" >&2
            exit 2 ;;
    esac
    shift
done

# ─── resolve MAIN checkout (correct even from inside a worktree) ─────────────
if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    MAIN_CHECKOUT="$PWT_PROJECT_ROOT_OVERRIDE"
else
    COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
    if [ -n "$COMMON_DIR" ]; then
        MAIN_CHECKOUT="$(dirname "$(realpath "$COMMON_DIR" 2>/dev/null || echo "$COMMON_DIR")")"
    else
        MAIN_CHECKOUT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
    fi
fi
WORKTREES_DIR="$MAIN_CHECKOUT/.claude/worktrees"
REAL_WORKTREES_DIR="$(realpath "$WORKTREES_DIR" 2>/dev/null || echo "$WORKTREES_DIR")"

# ─── accumulators ────────────────────────────────────────────────────────────
TOTAL_REMOVED=0
TOTAL_KEPT=0
TOTAL_REMOVE_FAILED=0
TOTAL_SCANNED=0
# One row per worktree, newline-separated, fields joined by US (\x1f).
#
# NOT tab-separated, and that is a correctness point rather than taste: TAB is
# an IFS *whitespace* character, so `IFS=$'\t' read` collapses runs of tabs into
# one delimiter and drops empty fields — every column after an empty `reason`
# would silently shift left. US is not IFS-whitespace, so empty fields survive.
# Today no field is ever empty, which means the tab version was correct only by
# luck; this makes it correct by construction.
ROWS=""
PWT_US=$(printf '\037')
GLOBAL_SKIP=""     # non-empty => whole run swept nothing

emit_json() {
    # Deliberately printf-based, not python3: the outcome that MOST needs
    # reporting is "python3 is unavailable", which python3 cannot report. Same
    # reasoning as plan-w-team-worktree-on-merge.sh's result_json fallback.
    _j() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
    printf '{"schema":"plan-w-team-worktree-untracked-sweep/v1"'
    printf ',"executed":%s' "$([ "$EXECUTE" = "1" ] && echo true || echo false)"
    printf ',"skipped":%s' "$([ -n "$GLOBAL_SKIP" ] && echo true || echo false)"
    printf ',"reason":"%s"' "$(_j "${GLOBAL_SKIP:-ok}")"
    printf ',"totals":{"scanned":%s,"removed":%s,"kept":%s,"remove_failed":%s}' \
        "$TOTAL_SCANNED" "$TOTAL_REMOVED" "$TOTAL_KEPT" "$TOTAL_REMOVE_FAILED"
    printf ',"worktrees":['
    _first=1
    if [ -n "$ROWS" ]; then
        while IFS="$PWT_US" read -r wt st rs nrm nkp; do
            [ -z "$wt" ] && continue
            [ "$_first" = "1" ] || printf ','
            _first=0
            printf '{"path":"%s","status":"%s","reason":"%s","removed":%s,"kept":%s}' \
                "$(_j "$wt")" "$(_j "$st")" "$(_j "$rs")" "${nrm:-0}" "${nkp:-0}"
        done <<EOF
$ROWS
EOF
    fi
    printf ']}\n'
}

emit_human() {
    if [ -n "$GLOBAL_SKIP" ]; then
        echo "untracked-sweep: SWEPT NOTHING — $GLOBAL_SKIP"
        return 0
    fi
    printf 'untracked-sweep (%s): scanned=%s removed=%s kept=%s failed=%s\n' \
        "$([ "$EXECUTE" = "1" ] && echo execute || echo dry-run)" \
        "$TOTAL_SCANNED" "$TOTAL_REMOVED" "$TOTAL_KEPT" "$TOTAL_REMOVE_FAILED"
    if [ -n "$ROWS" ]; then
        while IFS="$PWT_US" read -r wt st rs nrm nkp; do
            [ -z "$wt" ] && continue
            printf '  %-14s %s (removed=%s kept=%s) %s\n' "$st" "$(basename "$wt")" "${nrm:-0}" "${nkp:-0}" "$rs"
        done <<EOF
$ROWS
EOF
    fi
}

finish() {
    if [ "$JSON" = "1" ]; then emit_json; else emit_human; fi
    exit 0
}

add_row() {
    # $1=path $2=status $3=reason $4=removed $5=kept  (US-joined; see $PWT_US)
    ROWS="${ROWS:+$ROWS
}$(printf '%s%s%s%s%s%s%s%s%s' "$1" "$PWT_US" "$2" "$PWT_US" "$3" "$PWT_US" "$4" "$PWT_US" "$5")"
}

# ─── GATE 1: shared dirty-ignore module ──────────────────────────────────────
# Positioned above everything that could classify, because the ignore-token
# semantics live there and a private re-implementation is the defect this whole
# module exists to prevent.
PWT_DIRTY_IGNORE_LIB="${PWT_DIRTY_IGNORE_LIB:-$SWEEP_SCRIPT_DIR/plan-w-team-dirty-ignore-lib.sh}"
if [ -r "$PWT_DIRTY_IGNORE_LIB" ]; then
    # shellcheck source=plan-w-team-dirty-ignore-lib.sh disable=SC1090
    . "$PWT_DIRTY_IGNORE_LIB"
else
    GLOBAL_SKIP="dirty-ignore lib unavailable — cannot classify, swept nothing"
    finish
fi

# ─── GATE 2: python3 ─────────────────────────────────────────────────────────
# The matcher runs in python3 and a broken interpreter emits nothing. For the
# DISCARD direction "nothing" happens to be the safe answer, but a caller that
# reported success for a pass that never ran would still be lying about coverage.
if ! __pwt_python_ok; then
    GLOBAL_SKIP="python3 unavailable — classification cannot be evaluated, swept nothing"
    finish
fi

# ─── GATE 3: liveness, fail-closed ───────────────────────────────────────────
# Third consumer of the contract the periodic GC and the per-merge ship path
# already share: canonical probe FIRST, claude-agents-extended.sh ADDITIVE-ONLY.
#
# One deliberate DIVERGENCE from those two, and it is a tightening: an EMPTY
# probe result with no failure token is treated here as a failure. `claude agents
# --json` is known empty-but-exit-0 under load, and the canonical probe's
# inclusion predicate additionally drops a `background` row with `state:blocked`
# and no `status` — the most common stuck-worker shape in this system. The GC can
# afford to read "no rows" as "nothing live" because it has three further vetoes
# AND writes a backup before destroying anything. This sweep has neither, so the
# only safe reading of "I saw no rows" is "I could not see".
LIVE_CWDS=""
LIVE_QUERY_FAILED=0
if [ "${PWT_WORKTREE_GC_TEST_QUERY_FAILED:-0}" = "1" ]; then
    LIVE_QUERY_FAILED=1
elif [ -n "${PWT_WORKTREE_GC_TEST_LIVE_CWDS:-}" ]; then
    LIVE_CWDS="$PWT_WORKTREE_GC_TEST_LIVE_CWDS"
elif [ "${PWT_WORKTREE_GC_TEST_MODE:-0}" != "1" ]; then
    LIVE_HELPER="${PWT_LIVE_SESSION_CWDS_SCRIPT:-}"
    if [ -z "$LIVE_HELPER" ]; then
        if [ -x "$SWEEP_SCRIPT_DIR/pwt-live-session-cwds.sh" ]; then
            LIVE_HELPER="$SWEEP_SCRIPT_DIR/pwt-live-session-cwds.sh"
        else
            LIVE_HELPER="$MAIN_CHECKOUT/.claude/scripts/pwt-live-session-cwds.sh"
        fi
    fi
    if [ -x "$LIVE_HELPER" ]; then
        _live_out="$("$LIVE_HELPER" 2>/dev/null || printf '__QUERY_FAILED__\n')"
        if printf '%s\n' "$_live_out" | grep -qx '__QUERY_FAILED__'; then
            LIVE_QUERY_FAILED=1
        else
            LIVE_CWDS="$_live_out"
        fi
    else
        LIVE_QUERY_FAILED=1
    fi
    # SECONDARY, ADDITIVE ONLY — may add protected paths, may never clear the flag.
    #
    # REQUIRED here (2.14.1), unlike in the GC. GATE 3's empty⇒blind rule only
    # catches the ALL-empty case. The canonical probe's predicate is an INCLUSION
    # match that DROPS a `background` row with `state:blocked` and no `status` —
    # the most common stuck-worker shape in this system — so a probe that returns
    # three OTHER live sessions while blind to the blocked worker passes GATE 3
    # and the per-worktree in-use veto, and that worker's worktree is swept.
    # worktree-lifecycle.md:194 records that the extended helper is what makes the
    # union COMPLETE. The GC can tolerate its absence because it has three further
    # vetoes and writes a backup first; this sweep has neither, so a missing or
    # non-executable helper means we cannot enumerate liveness ⇒ sweep nothing.
    AGENTS_EXTENDED="${PWT_WORKTREE_GC_AGENTS_EXTENDED:-$MAIN_CHECKOUT/.claude/scripts/claude-agents-extended.sh}"
    if [ ! -x "$AGENTS_EXTENDED" ]; then
        LIVE_QUERY_FAILED=1
    fi
    if [ -x "$AGENTS_EXTENDED" ]; then
        _ext_cwds="$("$AGENTS_EXTENDED" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for entry in (data if isinstance(data, list) else []):
    for key in ("cwd", "worktreePath"):
        v = entry.get(key) or ""
        if v:
            print(v)
' 2>/dev/null || true)"
        if [ -n "$_ext_cwds" ]; then
            LIVE_CWDS="${LIVE_CWDS:+$LIVE_CWDS
}$_ext_cwds"
        fi
    fi
    # The tightening described above: no rows AND no explicit failure ⇒ blind.
    if [ "$LIVE_QUERY_FAILED" = "0" ] && [ -z "$LIVE_CWDS" ]; then
        LIVE_QUERY_FAILED=1
    fi
fi
if [ "$LIVE_QUERY_FAILED" = "1" ]; then
    GLOBAL_SKIP="live-session probe unavailable or blind — cannot prove no worktree is in use, swept nothing"
    finish
fi

# ─── ignore sets ─────────────────────────────────────────────────────────────
# The BACKUP set, never the classify set. See __pwt_path_discard_filter's header
# for why passing the classify set here would be a data-loss bug.
#
# OWN KNOB, deliberately (2.14.1). Reading PWT_WORKTREE_GC_PRESERVE_IGNORE
# directly would give one env var two OPPOSITE safety directions: for
# preserve_then_reap, widening it means "back up less" (annoying); for this
# sweep it would mean "DELETE MORE" (destructive). An operator trimming backup
# volume would silently widen the fleet's delete set — the WT-2 drift class in
# env-var form. So the sweep takes PWT_SWEEP_DISCARD_IGNORE, defaulting to the
# preserve set so the shipped behaviour is identical, and the two meanings can
# never be changed by one edit again.
SWEEP_IGNORE_SET="${PWT_SWEEP_DISCARD_IGNORE-${PWT_WORKTREE_GC_PRESERVE_IGNORE-$PWT_PRESERVE_IGNORE_DEFAULT}}"

# Synced-tooling prefixes eligible for class SYNCED. These are the three trees a
# consumer receives by sync rather than developing (worktree-lifecycle.md
# §Ignore-path dirty check). A path outside them is never class SYNCED even if it
# happens to match the default branch.
SWEEP_SYNCED_PREFIXES="${PWT_SWEEP_SYNCED_PREFIXES-.claude/:tests/skill/:docs/operations/}"

# ─── durable-artifact keep-list (class STATE exclusion) ──────────────────────
# `.claude/state/` is in the BACKUP ignore set because, when a worktree is being
# DESTROYED anyway, its per-run state is worthless. This sweep runs on worktrees
# that SURVIVE, and a handful of `.claude/state/` artifacts are declared
# cross-run DURABLE by shared/state-artifacts.md — including the recursive-
# followups ledger this very feature was queued from. Deleting one would destroy
# durable data that no reap would ever have touched.
#
# Basename globs, matched before class STATE. The list is kept honest by the test
# corpus, which RE-DERIVES the durable set from shared/state-artifacts.md and
# fails if a registry row is not covered here — so a future durable artifact
# cannot silently become sweepable.
SWEEP_DURABLE_KEEP="${PWT_SWEEP_DURABLE_KEEP-plan-w-team-directive-*:plan-w-team-retro-capture-history.jsonl:plan-w-team-recursive-followups.jsonl:plan-w-team-run-state-audit.jsonl:plan-w-team-lane-guard-audit.jsonl:plan-w-team-ds1-audit.jsonl:plan-w-team-land-audit.jsonl:*-audit.jsonl:*-history.jsonl}"

__is_durable_keep() {
    # $1 = repo-relative path. Returns 0 when the BASENAME matches a keep glob.
    local base rest tok
    base="$(basename "$1")"
    rest="$SWEEP_DURABLE_KEEP"
    while [ -n "$rest" ]; do
        tok="${rest%%:*}"
        if [ "$tok" = "$rest" ]; then rest=""; else rest="${rest#*:}"; fi
        [ -n "$tok" ] || continue
        # shellcheck disable=SC2254  # glob match is intended
        case "$base" in $tok) return 0 ;; esac
    done
    return 1
}

# ─── default-ref resolution for class SYNCED ─────────────────────────────────
# Ordered and fail-closed: unresolvable ⇒ class SYNCED is DISABLED for the whole
# run (class STATE keeps working). The worktree's own branch is never the ref —
# a file on it would be TRACKED, so the comparison would be vacuous.
resolve_synced_ref() {
    local r
    if [ -n "${PWT_SWEEP_SYNCED_REF:-}" ]; then
        git -C "$MAIN_CHECKOUT" rev-parse -q --verify "${PWT_SWEEP_SYNCED_REF}^{commit}" >/dev/null 2>&1 \
            && { printf '%s' "$PWT_SWEEP_SYNCED_REF"; return 0; }
        return 1
    fi
    r="$(git -C "$MAIN_CHECKOUT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo "")"
    if [ -n "$r" ] && git -C "$MAIN_CHECKOUT" rev-parse -q --verify "${r}^{commit}" >/dev/null 2>&1; then
        printf '%s' "$r"; return 0
    fi
    for r in main master; do
        if git -C "$MAIN_CHECKOUT" rev-parse -q --verify "${r}^{commit}" >/dev/null 2>&1; then
            printf '%s' "$r"; return 0
        fi
    done
    return 1
}
SYNCED_REF="$(resolve_synced_ref || echo "")"

__under_synced_prefix() {
    # $1 = repo-relative path
    local rest tok
    rest="$SWEEP_SYNCED_PREFIXES"
    while [ -n "$rest" ]; do
        tok="${rest%%:*}"
        if [ "$tok" = "$rest" ]; then rest=""; else rest="${rest#*:}"; fi
        [ -n "$tok" ] || continue
        case "$1" in "$tok"*) return 0 ;; esac
    done
    return 1
}

# ─── per-worktree sweep ──────────────────────────────────────────────────────
sweep_one() {
    local wt="$1"
    local real_wt removed=0 kept=0

    # GATE 0 (pure shell — the only check trustable ahead of python3): containment.
    real_wt="$(realpath "$wt" 2>/dev/null || echo "$wt")"
    case "$real_wt" in
        "$REAL_WORKTREES_DIR"/*) : ;;
        *) add_row "$wt" "refused" "outside .claude/worktrees/ (containment)" 0 0; return 0 ;;
    esac
    [ -d "$wt" ] || { add_row "$wt" "skipped" "not a directory" 0 0; return 0; }

    # VETO: in-use by a live session.
    if [ -n "$LIVE_CWDS" ]; then
        local cwd real_cwd
        while IFS= read -r cwd; do
            [ -z "$cwd" ] && continue
            real_cwd="$(realpath "$cwd" 2>/dev/null || echo "$cwd")"
            case "$real_cwd" in
                "$real_wt"|"$real_wt"/*)
                    add_row "$wt" "skipped" "in-use by live session" 0 0; return 0 ;;
            esac
        done <<EOF
$LIVE_CWDS
EOF
    fi

    # VETO: git LOCK (GC veto 3, ported 2.14.1 — the newborn race closer).
    #
    # Omitting this was a real data-loss window, not a theoretical one.
    # `git worktree add` writes the lock (with `pid N`) at SPAWN, whereas the bg
    # session becomes visible to `claude agents --json` only once it REGISTERS.
    # worktree-lifecycle.md:222 measures that gap at ~43 MINUTES on a real lane
    # (lock 11:27:02, goal-state started_at 12:10:22) and states at :238 that
    # "Veto 3's pid arm is what closes the newborn race, because the pid is
    # available strictly earlier than the agents-list probe". With only liveness
    # + a 30-minute newborn grace, a worktree at minute 31-43 was past the grace,
    # absent from the live-cwd set, and sweepable while its owner was very much
    # alive. A live pid is positive proof of an owner; an unparseable lock reason
    # is unprovable and therefore also a keep.
    local lock_reason lock_pid
    lock_reason="$(git -C "$MAIN_CHECKOUT" worktree list --porcelain 2>/dev/null \
        | awk -v t="$real_wt" '
            /^worktree /{ p=substr($0,10); next }
            /^locked/   { if (p==t) { print substr($0,7); exit } }
        ')"
    if [ -n "$lock_reason" ] || git -C "$MAIN_CHECKOUT" worktree list --porcelain 2>/dev/null \
         | awk -v t="$real_wt" '/^worktree /{p=substr($0,10)} /^locked/{if(p==t){found=1}} END{exit !found}'; then
        lock_pid="$(printf '%s' "$lock_reason" | sed -n 's/.*[(, ]pid[= ]\{1,\}\([0-9]\{1,\}\).*/\1/p' | head -1)"
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            add_row "$wt" "skipped" "locked by LIVE pid $lock_pid (veto 3 — earlier signal than the agents probe)" 0 0
            return 0
        fi
        if [ -z "$lock_pid" ]; then
            add_row "$wt" "skipped" "locked with no parseable pid — cannot prove abandoned (veto 3, fail-closed)" 0 0
            return 0
        fi
        # Locked with a DEAD pid: provably abandoned, fall through (GC parity).
    fi

    # VETO: newborn grace. Mirrors the GC's veto 4, including its fail-closed arm
    # for an unreadable birth time.
    #
    # Default raised 30 -> 60 (2.14.1): the measured spawn-to-registration gap is
    # ~43 minutes, so a 30-minute window left a 13-minute hole even with the lock
    # veto above as the primary closer. Belt and braces on a one-way door.
    local min_age age_min birth now
    min_age="${PWT_WORKTREE_MIN_AGE_MINUTES:-60}"
    if [ "$min_age" != "0" ]; then
        birth="$(stat -f %B "$wt" 2>/dev/null || stat -c %W "$wt" 2>/dev/null || echo "")"
        if [ -z "$birth" ] || [ "$birth" = "0" ] || [ "$birth" = "-" ]; then
            add_row "$wt" "skipped" "newborn grace: birth time unreadable (fail-closed)" 0 0; return 0
        fi
        now="$(date +%s)"
        age_min=$(( (now - birth) / 60 ))
        if [ "$age_min" -lt "$min_age" ]; then
            add_row "$wt" "skipped" "newborn grace: ${age_min}m < ${min_age}m" 0 0; return 0
        fi
    fi

    # Enumerate untracked, non-ignored files. -z because git QUOTES a path holding
    # a control character even under core.quotePath=false, and a quoted string
    # names no file on disk. core.quotePath=false additionally keeps non-ASCII
    # paths unescaped (the 2.8.0 lesson).
    #
    # The list goes to a TEMP FILE, never to a variable. Command substitution
    # cannot carry NUL: bash strips NUL bytes from `$(...)`, so `paths="$(git …
    # -z)"` silently concatenates every path into one unsplittable string and the
    # `read -d ''` loop below then finds no delimiter, hits EOF, and processes
    # ZERO records while every guard still reports success — a sweep that scans
    # nothing and calls itself clean. A temp file preserves the NULs AND the
    # enumeration exit code, and keeps the read loop in the CURRENT shell so the
    # counters it increments survive (a pipe would subshell them away).
    local enum_rc=0 listfile
    listfile="$(mktemp -t pwt-sweep-list.XXXXXX)" || {
        add_row "$wt" "skipped" "could not create temp list file" 0 0; return 0; }
    git -C "$wt" -c core.quotePath=false ls-files --others --exclude-standard -z \
        > "$listfile" 2>/dev/null || enum_rc=1
    if [ "$enum_rc" != "0" ]; then
        rm -f "$listfile"
        add_row "$wt" "skipped" "enumeration failed (not a git worktree?)" 0 0; return 0
    fi
    if [ ! -s "$listfile" ]; then
        rm -f "$listfile"
        add_row "$wt" "clean" "no untracked files" 0 0; return 0
    fi

    local dirs_touched=""
    local p abs cls blob whash
    while IFS= read -r -d '' p; do
        [ -n "$p" ] || continue
        TOTAL_SCANNED=$((TOTAL_SCANNED + 1))

        # A newline cannot be passed through the newline-oriented shared matcher,
        # and a TAB would corrupt the TAB-delimited row accumulator. Neither class
        # can then be PROVEN, and unprovable always means keep.
        case $p in
            *$'\n'*|*$'\t'*)
                kept=$((kept + 1))
                [ "$PRINT_CLASSIFIED" = "1" ] && printf 'UNSAFE-NAME\t%s\n' "$(printf '%q' "$p")" >&2
                continue ;;
        esac

        abs="$wt/$p"
        # Only ever act on a regular file or a symlink, never a directory, and
        # never through a path whose real parent escaped the worktree. `git
        # ls-files --others` does not descend into a SYMLINKED directory (it
        # reports the link itself as one entry), so a symlinked path component
        # cannot appear here — this re-check is the belt to that suspenders.
        if [ -d "$abs" ] && [ ! -L "$abs" ]; then kept=$((kept + 1)); continue; fi
        local real_parent
        real_parent="$(realpath "$(dirname "$abs")" 2>/dev/null || echo "")"
        case "$real_parent" in
            "$real_wt"|"$real_wt"/*) : ;;
            *) kept=$((kept + 1)); continue ;;
        esac

        cls="AUTHORED"

        # class STATE — matches the BACKUP ignore set, minus the durable keep-list.
        if printf '%s\n' "$p" | __pwt_path_discard_filter "$SWEEP_IGNORE_SET" | grep -qxF "$p"; then
            if __is_durable_keep "$p"; then
                cls="AUTHORED"          # durable cross-run artifact — never sweepable
            else
                cls="STATE"
            fi
        fi

        # class SYNCED — byte-identical to the default ref's blob for this path.
        # Symlinks are excluded outright: `git hash-object` on a symlink hashes the
        # TARGET's content while the stored blob holds the target PATH string, so
        # the two sides would be comparing different things (verified empirically).
        if [ "$cls" = "AUTHORED" ] && [ -n "$SYNCED_REF" ] && [ ! -L "$abs" ] && [ -f "$abs" ]; then
            if __under_synced_prefix "$p"; then
                # -q --verify is REQUIRED: bare `git rev-parse <ref>:<path>` echoes
                # its own argument back on failure, which would then be compared
                # against a hash. Empty + non-zero is the only safe failure shape.
                blob="$(git -C "$wt" rev-parse -q --verify "${SYNCED_REF}:${p}" 2>/dev/null || echo "")"
                if [ -n "$blob" ]; then
                    whash="$(git -C "$wt" hash-object -- "$p" 2>/dev/null || echo "")"
                    # MODE must match too (2.14.1). `git hash-object` hashes CONTENT
                    # and is blind to the executable bit, so a worktree copy that was
                    # chmod +x'd is byte-identical to the ref yet NOT reproducible by
                    # `git checkout <ref> -- <path>` — that restores the ref's mode and
                    # silently drops the mode change, which is a real authored edit.
                    # Comparing modes keeps "recoverable" honest: what we delete must
                    # come back exactly, bits AND bits-of-metadata.
                    local refmode wtmode
                    refmode="$(git -C "$wt" ls-tree "$SYNCED_REF" -- "$p" 2>/dev/null | awk '{print $1}')"
                    if [ -x "$abs" ]; then wtmode="100755"; else wtmode="100644"; fi
                    if [ -n "$whash" ] && [ "$blob" = "$whash" ] \
                       && [ -n "$refmode" ] && [ "$refmode" = "$wtmode" ]; then
                        cls="SYNCED"
                    fi
                fi
            fi
        fi

        [ "$PRINT_CLASSIFIED" = "1" ] && printf '%s\t%s\n' "$cls" "$p" >&2

        if [ "$cls" = "AUTHORED" ]; then
            kept=$((kept + 1))
            continue
        fi

        if [ "$EXECUTE" != "1" ]; then
            removed=$((removed + 1))     # dry-run: what WOULD be removed
            continue
        fi
        if rm -f -- "$abs" 2>/dev/null; then
            removed=$((removed + 1))
            dirs_touched="${dirs_touched:+$dirs_touched
}$(dirname "$p")"
        else
            TOTAL_REMOVE_FAILED=$((TOTAL_REMOVE_FAILED + 1))
        fi
    done < "$listfile"
    rm -f "$listfile"

    # Prune directories that the removals emptied — bottom-up, with rmdir (which
    # refuses a non-empty dir), never rm -r, and never past the worktree root.
    if [ "$EXECUTE" = "1" ] && [ -n "$dirs_touched" ]; then
        local d cur
        while IFS= read -r d; do
            [ -n "$d" ] && [ "$d" != "." ] || continue
            cur="$wt/$d"
            while [ "$cur" != "$wt" ] && [ -d "$cur" ]; do
                rmdir "$cur" 2>/dev/null || break
                cur="$(dirname "$cur")"
            done
        done <<EOF
$(printf '%s\n' "$dirs_touched" | sort -ru)
EOF
    fi

    TOTAL_REMOVED=$((TOTAL_REMOVED + removed))
    TOTAL_KEPT=$((TOTAL_KEPT + kept))
    add_row "$wt" "$([ "$EXECUTE" = "1" ] && echo swept || echo dry-run)" \
        "$([ -n "$SYNCED_REF" ] && echo "ref=$SYNCED_REF" || echo "class SYNCED disabled: default ref unresolved")" \
        "$removed" "$kept"
}

# ─── main ────────────────────────────────────────────────────────────────────
if [ -n "$ONE_WORKTREE" ]; then
    sweep_one "$ONE_WORKTREE"
else
    if [ ! -d "$WORKTREES_DIR" ]; then
        finish
    fi
    for _wt in "$WORKTREES_DIR"/*; do
        [ -e "$_wt" ] || continue
        [ -d "$_wt" ] || continue
        sweep_one "$_wt"
    done
fi

finish
