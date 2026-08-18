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
#   PWT_WORKTREE_ON_MERGE_DISABLE=1   no-op (exit 0)
#   PWT_WORKTREE_GC_TEST_MODE=1       skip in-use check (tests)
#   PWT_WORKTREE_GC_TEST_LIVE_CWDS    inject live-cwd list (tests)
#
# Safety invariants (same as plan-w-team-worktree-gc.sh):
#   1. NEVER touch a path outside .claude/worktrees/.
#   2. NEVER remove a worktree with uncommitted changes.
#   3. NEVER remove a worktree currently in-use by a live claude session.
#   5. IDEMPOTENT: if the worktree is already gone, exit 0 with already-clean.
#
# Spec: docs/specs/worktree-lifecycle-cleanup.md
# Caller: .claude/commands/plan-w-team/05-ship.md (ship-readiness PASS path)
# Tests: .claude/scripts/plan-w-team-worktree-on-merge.test.sh

set -u
set -o pipefail

emit() { printf '%s\n' "$1"; }

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
    if [ -z "$(git -C "$mc" status --porcelain 2>/dev/null)" ]; then
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

# ─── invariant 2: uncommitted changes (RELAXED for shipped — Part C) ───────
porcelain="$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null || echo "")"
if [ -n "$porcelain" ] && ! __wt_on_merge_shipped_ok "$WORKTREE_PATH"; then
    result_json 0 0 1 "safe-skip: uncommitted changes in worktree (invariant 2)"
    exit 0
fi

# ─── invariant 3: in-use by live session ──────────────────────────────────
LIVE_CWDS=""
if [ -n "${PWT_WORKTREE_GC_TEST_LIVE_CWDS:-}" ]; then
    LIVE_CWDS="$PWT_WORKTREE_GC_TEST_LIVE_CWDS"
elif [ "${PWT_WORKTREE_GC_TEST_MODE:-0}" != "1" ]; then
    AGENTS_EXTENDED="${PWT_WORKTREE_GC_AGENTS_EXTENDED:-$MAIN_CHECKOUT/.claude/scripts/claude-agents-extended.sh}"
    if [ -x "$AGENTS_EXTENDED" ]; then
        LIVE_CWDS="$("$AGENTS_EXTENDED" 2>/dev/null | python3 -c '
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
