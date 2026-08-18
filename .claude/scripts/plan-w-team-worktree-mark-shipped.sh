#!/usr/bin/env bash
# plan-w-team-worktree-mark-shipped.sh — write a `.pwt-shipped` marker into a
# run's worktree at ship time (Part A of the disk-hygiene "reclaim as it ships"
# upgrade; spec: docs/specs/plan-w-team-disk-hygiene-as-it-goes.md).
#
# WHY: a `/plan-w-team` worktree is dead weight once its output is on the default
# branch, but "shipped" is otherwise INVISIBLE to the cleanup machinery — a
# squash-merge defeats `git branch --merged`, a local admin-squash-merge repo has
# no gh PR to consult, and the post-ship worktree's uncommitted generated
# artifacts then pin it UNSAFE-KEEP forever (parts held 25 such worktrees, 15 GB).
# This marker is the merge-path-INDEPENDENT proof: written once at ship (after the
# tag is cut and the merge lands), it lets `plan-w-team-worktree-gc.sh`
# (SAFE-PRUNE-SHIPPED) and `plan-w-team-worktree-on-merge.sh` (force-remove)
# reclaim the worktree despite uncommitted content — verified against the tag
# resolving on the default branch, so a forged/stale marker cannot authorize a reap.
#
# Usage:
#   plan-w-team-worktree-mark-shipped.sh --tag <tag> --sha <sha> --slug <slug> [--worktree <path>]
#     --worktree defaults to $PWD when $PWD is under .claude/worktrees/ (the worker
#     ships from inside its own worktree). A lead-implements-directly run in the
#     main checkout has no worktree to mark → clean no-op.
#
# Contract: FAIL-OPEN — any problem (not in a worktree, missing args, unwritable)
# exits 0 without writing; it must NEVER block a ship. Idempotent (last write wins).
# Kill switch: PWT_DISABLE_SHIPPED_MARKER=1.
#
# Marker file: <worktree>/.pwt-shipped
#   {"schema":"plan-w-team-shipped/v1","slug":..,"tag":..,"sha":..,"at":..}
set -u

[ "${PWT_DISABLE_SHIPPED_MARKER:-0}" = "1" ] && exit 0

TAG=""; SHA=""; SLUG=""; WT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tag)      TAG="${2:-}"; shift 2 || break ;;
        --sha)      SHA="${2:-}"; shift 2 || break ;;
        --slug)     SLUG="${2:-}"; shift 2 || break ;;
        --worktree) WT="${2:-}"; shift 2 || break ;;
        *) shift ;;
    esac
done

# Resolve the worktree: explicit --worktree, else $PWD if it is one.
[ -n "$WT" ] || WT="$PWD"
case "$WT" in
    */.claude/worktrees/*) : ;;
    *) exit 0 ;;   # not a run worktree (e.g. lead-direct in main) → nothing to mark
esac
[ -d "$WT" ] || exit 0

# The GC verifies the tag OR the sha resolves on the default branch; refuse to
# write a marker with NEITHER — it could never authorize a reap (a no-op, not a
# lie). The sha (the default-branch ship commit) is the universal proof; the tag
# is a bonus for repos that cut one.
[ -n "$TAG" ] || [ -n "$SHA" ] || exit 0

AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
MARKER="$WT/.pwt-shipped"
TMP="$MARKER.tmp.$$"
if command -v jq >/dev/null 2>&1; then
    jq -n --arg slug "$SLUG" --arg tag "$TAG" --arg sha "$SHA" --arg at "$AT" \
        '{schema:"plan-w-team-shipped/v1", slug:$slug, tag:$tag, sha:$sha, at:$at}' \
        > "$TMP" 2>/dev/null && mv "$TMP" "$MARKER" 2>/dev/null || rm -f "$TMP"
else
    printf '{"schema":"plan-w-team-shipped/v1","slug":"%s","tag":"%s","sha":"%s","at":"%s"}\n' \
        "$SLUG" "$TAG" "$SHA" "$AT" > "$TMP" 2>/dev/null && mv "$TMP" "$MARKER" 2>/dev/null || rm -f "$TMP"
fi
[ -f "$MARKER" ] && echo "  ✓ .pwt-shipped marked: tag=$TAG slug=$SLUG ($WT)" >&2
exit 0
