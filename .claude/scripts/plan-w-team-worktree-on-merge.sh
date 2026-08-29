#!/usr/bin/env bash
# plan-w-team-worktree-on-merge.sh
#
# Per-merge worktree cleanup. Called by the Step 6 ship template AFTER a
# feature branch is merged to the default branch and the ship-readiness gate
# returns PASS. Removes the merged worktree + branch and unregisters it from
# the run's fleet JSONL.
#
# This is intentionally a THIN, EXPLICIT-PATH wrapper (not a repo-wide sweep):
# the supervisor invokes it with the exact worktree path + branch it just
# merged, so it has the right context and never touches anything else.
#
# Usage:
#   plan-w-team-worktree-on-merge.sh <worktree-path> <branch-name> [slug]
#
# Exit codes:
#   0  success — worktree removed, OR safely skipped (uncommitted/in-use/etc.)
#   2  usage error (missing args)
#
# Always exits 0 on a *safe skip* (it is not an error to preserve a worktree
# that fails a safety invariant) so the ship pipeline is never blocked.
#
# Environment:
#   PWT_WORKTREE_ON_MERGE_DISABLE=1     no-op (exit 0)
#   PWT_WORKTREE_GC_TEST_MODE=1         skip in-use check (tests)
#   PWT_WORKTREE_GC_TEST_LIVE_CWDS      inject live-cwd list (tests)
#   PWT_WORKTREE_GC_TEST_QUERY_FAILED=1 simulate a failed liveness probe (tests)
#   PWT_LIVE_SESSION_CWDS_SCRIPT        override the canonical liveness probe
#
# Safety invariants (same as plan-w-team-worktree-gc.sh):
#   1. NEVER touch a path outside .claude/worktrees/.
#   2. NEVER remove a worktree with uncommitted changes — evaluated with the
#      SHARED dirtiness contract (see below), not raw porcelain.
#   3. NEVER remove a worktree currently in-use by a live claude session — and
#      never remove one whose liveness could not be DETERMINED (fail-closed;
#      see the invariant-3 block below).
#   5. IDEMPOTENT: if the worktree is already gone, exit 0 with already-clean.
#
# ─── invariant 2 and the periodic GC agree (WT-2, 2026-08-15) ────────────────
# This script used to test RAW `git status --porcelain`: ANY dirt at all meant
# safe-skip. That is STRICTER than the periodic GC, which filters churn confined
# to the synced tooling layer (`.claude/`, `tests/skill/`, `docs/operations/`) and
# regenerable build trees. Since hooks rewrite `.claude/state/*` into every
# worktree, the ship-time reclaim therefore skipped almost every worktree the GC
# would have reaped — the leak was masked only because the periodic GC swept up
# afterwards.
#
# Both paths now share ONE policy module, so the fork cannot reappear. Note that
# the fix is NOT "apply the ignore filter": that is only the loosening half.
# Removing a worktree is a one-way door, so all three parts of the shared
# contract apply here, in this order:
#
#   a. TRACKED dirt (__pwt_tracked_dirty) → absolute veto, ignore set does NOT
#      apply. Pure shell, so it stays evaluable even when python3 is broken.
#   b. Guard unevaluable (no lib / no python3) → strict raw-porcelain skip.
#      An unevaluated filter emits nothing, which is indistinguishable from
#      "clean"; reading that as clean is the GC's VETO-0 data-loss class.
#   c. Ignore-filtered remainder → skip if anything real survives.
#   Then preserve_then_reap backs up authored work BEFORE the destructive
#   removal, and a failed backup aborts the removal.
#
# ─── invariant 3 and the periodic GC agree (WT-2 residual, 2.11.0) ───────────
# The dirtiness half above LOOSENS this script. That makes the in-use veto
# load-bearing where a dirtiness check used to stand in front of it — and on the
# 2.9.0 `.pwt-shipped` force path, where invariant 2 is relaxed by design,
# invariant 3 is the ONLY remaining protection. But invariant 3 had no
# fail-closed arm: it consulted a single SECONDARY probe and read an empty
# result as "nothing is live", so a missing helper or the known empty-but-exit-0
# `claude agents --json` flake skipped the check entirely.
#
# It now mirrors the GC's 2026-06-07 mid-flight-reap contract:
#   a. PRIMARY probe = pwt-live-session-cwds.sh; its `__QUERY_FAILED__` token or
#      a missing/non-executable helper sets LIVE_QUERY_FAILED.
#   b. claude-agents-extended.sh is SECONDARY and ADDITIVE ONLY — it may add
#      protected paths (per-subagent worktreePath) but never clears the flag.
#   c. LIVE_QUERY_FAILED ⇒ KEEP, ahead of preserve_then_reap and of the
#      shipped-force removal. The ship marker proves the WORK is durable; it
#      says nothing about whether a SESSION still owns the worktree.
# Absence of a matching path proves "not in use" only if the probe actually ran.
#
# Spec: docs/specs/resolve-recursive-followup-row-16-cleanup-eval-2026-06-08-wt-2-medium-deferred-p-1a44b2dd.md
#       docs/specs/worktree-lifecycle-cleanup.md
# Caller: .claude/commands/plan-w-team/05-ship.md (ship-readiness PASS path)
# Tests: .claude/scripts/plan-w-team-worktree-on-merge.test.sh

set -u
set -o pipefail

emit() { printf '%s\n' "$1"; }

# ─── shared dirty-ignore policy ──────────────────────────────────────────────
# Sourced BEFORE the sourceable guard below so unit tests that `source` this file
# also resolve the shared symbols. Co-located with this script, so it ships and
# syncs alongside it.
ONMERGE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
PWT_DIRTY_IGNORE_LIB="${PWT_DIRTY_IGNORE_LIB:-$ONMERGE_SCRIPT_DIR/plan-w-team-dirty-ignore-lib.sh}"
if [ -r "$PWT_DIRTY_IGNORE_LIB" ]; then
    # shellcheck source=plan-w-team-dirty-ignore-lib.sh disable=SC1090
    . "$PWT_DIRTY_IGNORE_LIB"
    PWT_LIB_OK=1
else
    PWT_LIB_OK=0
fi

# ─── Fix A1: post-merge primary-checkout re-sync + remote-branch delete ──────
# After a server-side squash-merge, origin/<default> advances but the primary
# (non-worktree) checkout is never re-synced and the remote feature branch is
# never deleted — leaving the primary stale (parked behind origin, sometimes on
# a leftover feature label) and the remote branch list cluttered. This helper
# closes both gaps. It is fail-open (never blocks the merge bookkeeping) and
# safe (ff-only — never force-resets a primary with real local commits).
#
# Reads globals $MAIN_CHECKOUT and $BRANCH (set by the main flow below, or by a
# unit test that sources this script). Sets $RESYNC_REMOVED_REMOTE_BRANCH and
# $RESYNC_PRIMARY_HEAD for result_json observability.
RESYNC_REMOVED_REMOTE_BRANCH="false"
RESYNC_PRIMARY_HEAD="unknown"

__resync_primary_checkout() {
    local mc="${MAIN_CHECKOUT:-}" br="${BRANCH:-}"
    [ -n "$mc" ] && { [ -d "$mc/.git" ] || [ -e "$mc/.git" ]; } || { echo "resync: no MAIN_CHECKOUT" >&2; return 0; }

    # Resolve the default branch (main/master/…) from the remote — never hardcode.
    local def
    def=$(git -C "$mc" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
    [ -n "$def" ] || def=$(git -C "$mc" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')
    [ -n "$def" ] || def=main

    git -C "$mc" fetch --quiet origin "$def" 2>/dev/null || { echo "resync: fetch failed" >&2; return 0; }

    local head
    head=$(git -C "$mc" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "DETACHED")

    # Only auto-switch when the tree is clean (no staged/unstaged changes).
    if [ -z "$(git -C "$mc" -c core.quotePath=false status --porcelain 2>/dev/null)" ]; then
        if [ "$head" != "$def" ]; then
            git -C "$mc" switch "$def" 2>/dev/null \
                || echo "resync: could not switch to $def (head=$head) — left as-is" >&2
            head=$(git -C "$mc" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "DETACHED")
        fi
        if [ "$head" = "$def" ]; then
            # Fast-forward ONLY — never create a merge commit in the primary checkout.
            git -C "$mc" merge --ff-only "origin/$def" 2>/dev/null \
                || echo "resync: ff-only to origin/$def declined (diverged) — manual review" >&2
        fi
    else
        echo "resync: primary checkout dirty — skipped switch/ff (head=$head)" >&2
    fi

    # Delete the REMOTE feature branch (idempotent; ignore 'remote ref does not exist').
    if [ -n "$br" ] && [ "$br" != "$def" ]; then
        if git -C "$mc" push origin --delete "$br" 2>/dev/null; then
            RESYNC_REMOVED_REMOTE_BRANCH="true"
        else
            echo "resync: remote branch $br already gone or protected" >&2
        fi
    fi
    RESYNC_PRIMARY_HEAD="$(git -C "$mc" symbolic-ref --quiet --short HEAD 2>/dev/null || echo DETACHED)"
}

# ─── Part C: shipped-worktree force-remove (disk-hygiene as-it-goes) ─────────
# A valid `.pwt-shipped` marker (Part A, written at ship) whose tag resolves on
# the default branch is the merge-path-independent proof the worktree's output
# landed — so its uncommitted content is stale post-ship generated artifacts, not
# work, and invariant 2 (uncommitted → safe-skip) is RELAXED to a force-remove.
# Positive proof only (mirrors plan-w-team-worktree-gc.sh:shipped_marker_valid);
# invariant 3 (in-use) stays absolute below. Reads global MAIN_CHECKOUT (set by the
# main flow before invariant 2). Kill switch: PWT_WORKTREE_ON_MERGE_NO_SHIPPED_FORCE=1.
__wt_on_merge_shipped_ok() {
    local wt="$1" marker tag tagcommit sha shacommit def
    [ "${PWT_WORKTREE_ON_MERGE_NO_SHIPPED_FORCE:-0}" = "1" ] && return 1
    marker="$wt/.pwt-shipped"
    [ -f "$marker" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    def="${PWT_WORKTREE_GC_DEFAULT_BRANCH:-}"
    [ -n "$def" ] || def=$(git -C "$MAIN_CHECKOUT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
    [ -n "$def" ] || def=main
    # Trust the marker if EITHER its ship sha OR its version tag resolves on the
    # default branch (local OR origin) — the universal proof (sha) plus the
    # tag-cutting-repo bonus. A forged/stale marker (neither resolves on default)
    # falls through to today's uncommitted safe-skip.
    sha="$(jq -r '.sha // ""' "$marker" 2>/dev/null)"
    if [ -n "$sha" ]; then
        shacommit="$(git -C "$MAIN_CHECKOUT" rev-parse -q --verify "${sha}^{commit}" 2>/dev/null)"
        if [ -n "$shacommit" ]; then
            git -C "$MAIN_CHECKOUT" merge-base --is-ancestor "$shacommit" "$def" 2>/dev/null && return 0
            git -C "$MAIN_CHECKOUT" merge-base --is-ancestor "$shacommit" "origin/$def" 2>/dev/null && return 0
        fi
    fi
    tag="$(jq -r '.tag // ""' "$marker" 2>/dev/null)"
    if [ -n "$tag" ]; then
        tagcommit="$(git -C "$MAIN_CHECKOUT" rev-parse -q --verify "refs/tags/${tag}^{commit}" 2>/dev/null)"
        if [ -n "$tagcommit" ]; then
            git -C "$MAIN_CHECKOUT" merge-base --is-ancestor "$tagcommit" "$def" 2>/dev/null && return 0
            git -C "$MAIN_CHECKOUT" merge-base --is-ancestor "$tagcommit" "origin/$def" 2>/dev/null && return 0
        fi
    fi
    return 1
}

# Sourceable guard: when this file is sourced (unit tests), define the helpers
# above and return before the arg-required main flow — so a test can call
# __resync_primary_checkout directly. When executed, fall through to the flow.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0 2>/dev/null || true
fi
# ─── end Fix A1 helper ───────────────────────────────────────────────────────

if [ "${PWT_WORKTREE_ON_MERGE_DISABLE:-0}" = "1" ]; then
    emit '{"skipped":true,"reason":"PWT_WORKTREE_ON_MERGE_DISABLE=1"}'
    exit 0
fi

WORKTREE_PATH="${1:-}"
BRANCH="${2:-}"
SLUG="${3:-}"

if [ -z "$WORKTREE_PATH" ] || [ -z "$BRANCH" ]; then
    echo "usage: plan-w-team-worktree-on-merge.sh <worktree-path> <branch-name> [slug]" >&2
    exit 2
fi

# ─── resolve main checkout ────────────────────────────────────────────────
COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
if [ -n "$COMMON_DIR" ]; then
    MAIN_CHECKOUT="$(dirname "$(realpath "$COMMON_DIR" 2>/dev/null || echo "$COMMON_DIR")")"
else
    MAIN_CHECKOUT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
fi
WORKTREES_DIR="$MAIN_CHECKOUT/.claude/worktrees"
real_worktrees_dir="$(realpath "$WORKTREES_DIR" 2>/dev/null || echo "$WORKTREES_DIR")"

result_json() {
    # $1=removed_worktree $2=removed_branch $3=skipped $4=reason
    #
    # python3 is the normal serializer, but the one case that MOST needs to be
    # reportable — "python3 is unavailable, so the dirty filter could not be
    # evaluated and we kept the worktree" — is exactly the case in which python3
    # cannot serialize. Without a fallback that skip is silent in the ship log.
    # The shell path emits the same keys; values here are script-controlled
    # (paths under .claude/worktrees/, a branch name, a fixed reason string), and
    # any embedded double-quote or backslash is escaped before interpolation.
    # Short-circuit order matters: when the lib is absent __pwt_python_ok does not
    # exist, so the lib check must be evaluated first.
    if [ "${PWT_LIB_OK:-0}" != "1" ] || ! __pwt_python_ok; then
        _j() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
        printf '{"schema": "plan-w-team-worktree-on-merge/v1", "worktree_path": "%s", "branch": "%s", "slug": "%s", "removed_worktree": %s, "removed_branch": %s, "skipped": %s, "reason": "%s", "removed_remote_branch": %s, "primary_checkout_head": "%s"}\n' \
            "$(_j "$WORKTREE_PATH")" "$(_j "$BRANCH")" "$(_j "$SLUG")" \
            "$([ "$1" = "1" ] && echo true || echo false)" \
            "$([ "$2" = "1" ] && echo true || echo false)" \
            "$([ "$3" = "1" ] && echo true || echo false)" \
            "$(_j "$4")" \
            "$([ "$RESYNC_REMOVED_REMOTE_BRANCH" = "true" ] && echo true || echo false)" \
            "$(_j "$RESYNC_PRIMARY_HEAD")"
        return 0
    fi
    python3 -c '
import json, sys
print(json.dumps({
    "schema": "plan-w-team-worktree-on-merge/v1",
    "worktree_path": sys.argv[1],
    "branch": sys.argv[2],
    "slug": sys.argv[3],
    "removed_worktree": sys.argv[4] == "1",
    "removed_branch": sys.argv[5] == "1",
    "skipped": sys.argv[6] == "1",
    "reason": sys.argv[7],
    "removed_remote_branch": sys.argv[8] == "true",
    "primary_checkout_head": sys.argv[9],
}))
' "$WORKTREE_PATH" "$BRANCH" "$SLUG" "$1" "$2" "$3" "$4" \
        "$RESYNC_REMOVED_REMOTE_BRANCH" "$RESYNC_PRIMARY_HEAD"
}

# ─── invariant 1: containment ─────────────────────────────────────────────
real_wt="$(realpath "$WORKTREE_PATH" 2>/dev/null || echo "$WORKTREE_PATH")"
case "$real_wt" in
    "$real_worktrees_dir"/*) : ;;
    *)
        result_json 0 0 1 "refused: path outside .claude/worktrees/ (invariant 1)"
        exit 0
        ;;
esac

# ─── invariant 5: idempotency — already gone ──────────────────────────────
if [ ! -d "$WORKTREE_PATH" ]; then
    # Worktree dir already removed. Prune registry + drop branch if it lingers.
    git -C "$MAIN_CHECKOUT" worktree prune 2>/dev/null || true
    removed_branch=0
    if git -C "$MAIN_CHECKOUT" show-ref --quiet --verify "refs/heads/$BRANCH"; then
        if git -C "$MAIN_CHECKOUT" branch -D "$BRANCH" >/dev/null 2>&1; then removed_branch=1; fi
    fi
    result_json 0 "$removed_branch" 0 "already-clean: worktree dir absent"
    exit 0
fi

# ─── VETO 0: the guards themselves must be evaluable ──────────────────────
# Mirrors the periodic GC's VETO 0, and sits ABOVE every remaining invariant on
# purpose. Nearly all of them are implemented in python3 — the dirty filter, and
# also invariant 3's live-cwd extraction below — and each returns empty/non-zero
# when the interpreter is broken. Empty reads as "no real dirt" and "no live
# session", so BOTH vetoes report themselves satisfied without ever having been
# evaluated, and a merged-but-live worktree gets removed.
#
# This must precede the porcelain check rather than live inside it: a CLEAN
# worktree skips the dirt branch entirely, which is exactly the path on which the
# in-use veto would then be silently inert. A missing module is folded in for the
# same reason plus one more — without it there is no preserve_then_reap either,
# so nothing could be backed up before the removal.
#
# It also stays above the shipped-marker override below: that override skips the
# DIRTINESS question, not the in-use question, and invariant 3 is python3-backed.
if [ "${PWT_LIB_OK:-0}" != "1" ]; then
    result_json 0 0 1 "safe-skip: dirty-ignore lib unavailable — guards unevaluable, nothing reapable (VETO 0)"
    exit 0
fi
if ! __pwt_python_ok; then
    result_json 0 0 1 "safe-skip: python3 unavailable — guards unevaluable, nothing reapable (VETO 0)"
    exit 0
fi

# ─── invariant 2: uncommitted changes ─────────────────────────────────────
# TWO changes land on this test and COMPOSE rather than compete:
#
#   * WT-2 replaced the RAW porcelain test with the periodic GC's shared
#     three-part dirtiness contract (filter LOOSENS, tracked-dirt veto TIGHTENS,
#     preserve-then-reap BACKSTOPS), so ship-time reclaim stops leaking exactly
#     the worktrees the GC would reap.
#   * 2.9.0 Part C added the shipped-marker override: a valid `.pwt-shipped`
#     whose tag/sha resolves on the default branch is POSITIVE PROOF the output
#     already landed, so leftover content is post-ship residue, not authored work.
#
# The override therefore sits ABOVE the contract, and the contract governs every
# worktree for which no such proof exists — which is the case the 2026-07-30
# data-loss class actually covers. Ordering is the safety property: each arm is a
# KEEP, and the worktree is reapable only once every arm has been positively
# cleared. Spec: docs/specs/resolve-recursive-followup-row-16-cleanup-eval-2026-06-08-wt-2-medium-deferred-p-1a44b2dd.md
porcelain="$(git -C "$WORKTREE_PATH" -c core.quotePath=false status --porcelain 2>/dev/null || echo "")"
PWT_SHIPPED_FORCE=0
if [ -n "$porcelain" ]; then
    if __wt_on_merge_shipped_ok "$WORKTREE_PATH"; then
        # Proven shipped → force-remove. Also suppresses the pre-reap backup
        # below: the ship tag IS the durable copy, so a backup here is waste,
        # and a FAILED backup would abort a reclaim 2.9.0 guarantees.
        PWT_SHIPPED_FORCE=1
    else

        # (a) TRACKED dirt — absolute veto, in ANY path, ignore prefixes included.
        if printf '%s\n' "$porcelain" | __pwt_tracked_dirty; then
            result_json 0 0 1 "safe-skip: uncommitted TRACKED changes in worktree (invariant 2 / VETO 2)"
            exit 0
        fi

        # (b) Untracked remainder — reapable only if nothing survives the ignore set.
        #     `-` (not `:-`) so an explicitly-empty override disables ignoring and
        #     restores strict any-dirty=keep, identically to the periodic GC.
        ignore_prefixes="${PWT_WORKTREE_GC_DIRTY_IGNORE-$PWT_DIRTY_IGNORE_DEFAULT}"
        if [ -z "$ignore_prefixes" ]; then
            result_json 0 0 1 "safe-skip: uncommitted changes in worktree (invariant 2)"
            exit 0
        fi
        real_dirty="$(printf '%s\n' "$porcelain" | __pwt_dirty_ignore_filter "$ignore_prefixes")"
        if [ -n "$real_dirty" ]; then
            result_json 0 0 1 "safe-skip: uncommitted changes in worktree (invariant 2)"
            exit 0
        fi
    fi
fi

# ─── invariant 3: in-use by live session ──────────────────────────────────
# WT-2 residual, closed in 2.11.0. This check used to consult ONLY
# claude-agents-extended.sh and read an EMPTY result as "no live sessions".
# Three ways that silently disarmed the veto on a one-way door:
#   * the helper missing / non-executable → LIVE_CWDS empty → the whole
#     `if [ -n "$LIVE_CWDS" ]` block skipped → removal proceeds unchecked;
#   * `claude agents --json` returning empty-but-exit-0 under load — a KNOWN
#     flake, which is precisely why claude-agents-extended.sh carries a retry
#     wrapper — indistinguishable from "nothing is live";
#   * the CANONICAL probe (pwt-live-session-cwds.sh, with its __QUERY_FAILED__
#     token) was never consulted at all, though the periodic GC treats it as
#     PRIMARY and agents-extended as a secondary ADDITIVE source.
#
# Two things make that load-bearing now rather than merely untidy. Invariant 2
# is deliberately LOOSER since 2.8.0, so this veto no longer has a dirtiness
# check standing in front of it; and on the 2.9.0 `.pwt-shipped` force path
# invariant 2 is relaxed by design, leaving invariant 3 as the SOLE protection.
# So it now mirrors the GC's 2026-06-07 mid-flight-reap contract exactly:
# absence of a matching path only proves "not in use" IF the probe actually ran.
LIVE_CWDS=""
LIVE_QUERY_FAILED=0
if [ "${PWT_WORKTREE_GC_TEST_QUERY_FAILED:-0}" = "1" ]; then
    # Test seam: simulate a failed probe without a fake claude binary (same
    # variable the GC suite uses, so both suites speak one dialect).
    LIVE_QUERY_FAILED=1
elif [ -n "${PWT_WORKTREE_GC_TEST_LIVE_CWDS:-}" ]; then
    LIVE_CWDS="$PWT_WORKTREE_GC_TEST_LIVE_CWDS"
elif [ "${PWT_WORKTREE_GC_TEST_MODE:-0}" != "1" ]; then
    # ── PRIMARY (canonical) source, identical to the periodic GC's ──────────
    LIVE_HELPER="${PWT_LIVE_SESSION_CWDS_SCRIPT:-}"
    if [ -z "$LIVE_HELPER" ]; then
        # Prefer the sibling next to THIS script; fall back to MAIN_CHECKOUT's.
        if [ -n "$ONMERGE_SCRIPT_DIR" ] && [ -x "$ONMERGE_SCRIPT_DIR/pwt-live-session-cwds.sh" ]; then
            LIVE_HELPER="$ONMERGE_SCRIPT_DIR/pwt-live-session-cwds.sh"
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
        # Canonical helper missing → cannot confirm liveness → fail closed.
        LIVE_QUERY_FAILED=1
    fi
    # ── SECONDARY source, ADDITIVE ONLY ────────────────────────────────────
    # It may ADD protected paths; it can NEVER clear LIVE_QUERY_FAILED. If the
    # canonical probe failed but this one returns data we keep the fail-closed
    # posture (conservative) while still protecting the extra paths it found.
    #
    # This source is load-bearing for COVERAGE, not merely a tidy extra. Measured
    # against real `claude agents --json` (2026-08-19, 8 live rows): the canonical
    # probe filters on `kind` + `status`, but the schema is MIXED — `interactive`
    # rows carry `status` (idle/busy) while `background` rows carry `state`
    # (working/blocked/done) and only SOMETIMES a `status`. A background row with
    # `state:blocked` and no `status` — i.e. a worker stuck at its Stop hook, the
    # single most common stuck-worker shape in this system — is dropped by the
    # primary and returned by this one, which applies no status filter at all.
    # So the union is what makes enumeration complete, and a successful-but-blind
    # primary must never be able to authorize a reap this source would veto.
    # (The primary's inclusion-match on an observed-once enum is the same defect
    # class as the 2.10.0 double-spawn Tier-B bug; narrowing it changes the
    # PERIODIC GC's reap behavior fleet-wide and collides with zombie-prune's
    # opposite reading of `blocked`, so it is queued as its own scoped decision
    # rather than widened into this run.)
    AGENTS_EXTENDED="${PWT_WORKTREE_GC_AGENTS_EXTENDED:-$MAIN_CHECKOUT/.claude/scripts/claude-agents-extended.sh}"
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
fi

if [ -n "$LIVE_CWDS" ]; then
    while IFS= read -r cwd; do
        [ -z "$cwd" ] && continue
        real_cwd="$(realpath "$cwd" 2>/dev/null || echo "$cwd")"
        case "$real_cwd" in
            "$real_wt"|"$real_wt"/*)
                result_json 0 0 1 "safe-skip: worktree in-use by live claude session (invariant 3)"
                exit 0
                ;;
        esac
    done <<< "$LIVE_CWDS"
fi

# FAIL-CLOSED arm. Ordered AFTER the positive-match loop on purpose: a confirmed
# hit is the more precise reason to report, and reporting it does not depend on
# the canonical probe having succeeded. Ordered BEFORE preserve_then_reap and the
# removal — including the PWT_SHIPPED_FORCE path, because the shipped marker
# proves the WORK is durable, never that the SESSION owning the worktree is gone.
if [ "$LIVE_QUERY_FAILED" = "1" ]; then
    result_json 0 0 1 "safe-skip: live-session probe failed — cannot prove worktree is unused (invariant 3, fail-closed)"
    exit 0
fi

# ─── preserve authored work BEFORE the destructive removal ────────────────
# Invariant 2 now (correctly) lets a worktree through whose only dirt is
# untracked churn under the classify-ignore prefixes. But `.claude/`,
# `tests/skill/` and `docs/operations/` are exactly where a /plan-w-team tooling
# lane does its work, so "ignorable for the reap decision" is NOT the same as
# "worthless". preserve_then_reap re-checks with the NARROWER backup set and
# copies out anything authored. Fail-safe: a failed backup skips the removal
# rather than proceeding — same contract as the periodic GC's remove_one.
# (Unconditional: VETO 0 above already proved the module is loaded.)
# Skipped on the proven-shipped path (2.9.0): the ship tag is the durable
# copy, so backing up post-ship residue is waste — and a failed backup must
# not abort a reclaim the shipped marker guarantees (its test S6 asserts no
# backup is written). On every other path the backstop is unconditional.
if [ "$PWT_SHIPPED_FORCE" != "1" ]; then
    if ! preserve_then_reap "$WORKTREE_PATH"; then
        result_json 0 0 1 "safe-skip: preserve-then-reap backup failed — worktree kept (invariant 2)"
        exit 0
    fi
fi

# ─── all invariants pass → remove ─────────────────────────────────────────
removed_wt=0
removed_branch=0
if git -C "$MAIN_CHECKOUT" worktree remove --force "$WORKTREE_PATH" 2>/dev/null; then
    removed_wt=1
else
    git -C "$MAIN_CHECKOUT" worktree prune 2>/dev/null || true
    if [ -d "$WORKTREE_PATH" ]; then
        case "$real_wt" in
            "$real_worktrees_dir"/*) rm -rf "$WORKTREE_PATH"; removed_wt=1 ;;
        esac
    else
        removed_wt=1
    fi
fi

if git -C "$MAIN_CHECKOUT" show-ref --quiet --verify "refs/heads/$BRANCH"; then
    if git -C "$MAIN_CHECKOUT" branch -D "$BRANCH" >/dev/null 2>&1; then
        removed_branch=1
    fi
fi

# ─── Fix A1: re-sync the primary checkout + delete the remote feature branch ──
# Runs only on the success path (all invariants passed, local branch swept).
# Fail-open: never blocks the merge result on hygiene.
__resync_primary_checkout

# ─── unregister from fleet JSONL ──────────────────────────────────────────
if [ -d "$MAIN_CHECKOUT/.claude/state" ]; then
    for manifest in "$MAIN_CHECKOUT/.claude/state/"plan-w-team-spawned-children-*.jsonl; do
        [ -f "$manifest" ] || continue
        tmp="$(mktemp)"
        WT_PATH="$WORKTREE_PATH" WT_BRANCH="$BRANCH" python3 -c '
import json, os, sys
target_path = os.environ.get("WT_PATH","")
target_branch = os.environ.get("WT_BRANCH","")
rp_target = os.path.realpath(target_path) if target_path else ""
keep = []
with open(sys.argv[1]) as f:
    for line in f:
        s=line.strip()
        if not s:
            continue
        try:
            d=json.loads(s)
        except Exception:
            keep.append(s); continue
        wp = d.get("worktree_path") or d.get("cwd") or ""
        br = d.get("branch") or ""
        if rp_target and wp and os.path.realpath(wp) == rp_target:
            continue
        if target_branch and br == target_branch:
            continue
        keep.append(s)
for s in keep:
    print(s)
' "$manifest" > "$tmp" 2>/dev/null
        if [ -s "$tmp" ] || [ ! -s "$manifest" ]; then
            if ! cmp -s "$tmp" "$manifest"; then mv "$tmp" "$manifest"; else rm -f "$tmp"; fi
        else
            # tmp empty but manifest had content → all rows removed; write empty file
            if ! cmp -s "$tmp" "$manifest"; then mv "$tmp" "$manifest"; else rm -f "$tmp"; fi
        fi
    done
fi

git -C "$MAIN_CHECKOUT" worktree prune 2>/dev/null || true

if [ "$removed_wt" = "1" ]; then
    result_json "$removed_wt" "$removed_branch" 0 "removed: merged worktree + branch swept"
else
    result_json "$removed_wt" "$removed_branch" 1 "remove-failed: git worktree remove did not complete"
fi
exit 0
