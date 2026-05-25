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
}))
' "$WORKTREE_PATH" "$BRANCH" "$SLUG" "$1" "$2" "$3" "$4"
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

# ─── invariant 2: uncommitted changes ─────────────────────────────────────
porcelain="$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null || echo "")"
if [ -n "$porcelain" ]; then
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
