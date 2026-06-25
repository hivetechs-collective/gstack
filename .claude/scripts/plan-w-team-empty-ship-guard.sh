#!/bin/bash
# plan-w-team-empty-ship-guard.sh — Step-6 empty-ship loop-breaker (1.48.0).
#
# WHY: observed once (worker 5088e5f4, 2026-06-25) a worker `git reset` to HEAD,
# discarding its own work, then LOOPED on Step 6 / push with an EMPTY worktree
# (0 commits to ship) and never terminated. Pushing zero commits is a no-op that
# would otherwise let the §6g post-push path mint a false-positive SHIP_PUSH_CONFIRMED
# PASS. This guard breaks that loop deterministically.
#
# CONTRACT (fail-safe by construction — NEVER blocks a real ship):
#   exit 3  (HALT)    iff it can POSITIVELY confirm there is nothing to ship:
#                       0 commits ahead of <base_ref>  AND  a clean tracked tree
#                       (git diff --quiet HEAD). A real ship ALWAYS has commits
#                       ahead of base, so this can never fire on a real ship.
#   exit 0  (PROCEED) on ANY commit(s) to ship, a dirty tracked tree, OR ANY
#                       ambiguity (no base ref, not a git repo, rev-list error).
#                       The fail-safe direction is always PROCEED.
#
# Untracked files are intentionally IGNORED in the cleanliness check: they are not
# part of `git push`, and the permanently-untracked goal-state file
# (.claude/state/plan-w-team-goal-*.json) must not suppress the guard.
#
# Usage: plan-w-team-empty-ship-guard.sh <base_ref> [slug]
#   <base_ref>  e.g. origin/main  (the ship base the §6 gates resolve)
#   [slug]      optional — records a per-slug empty-ship attempt counter for
#               diagnostics (so a recurring empty-ship loop is visible in state).
#
# bash 3.2 compatible. Read-only: never mutates the repo, never pushes.

set -u

BASE_REF="${1:-}"
SLUG="${2:-}"

# ── Fail-safe early exits (any ambiguity → PROCEED) ──────────────────────────
# No base ref to compare against → cannot judge "nothing to ship" → proceed.
[ -n "$BASE_REF" ] || exit 0
# Not a git repo → proceed.
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Commits ahead of base. If rev-list errors (e.g. unknown ref), proceed (fail-safe).
COMMITS="$(git rev-list --count "$BASE_REF..HEAD" 2>/dev/null)" || exit 0
[ -n "$COMMITS" ] || exit 0
case "$COMMITS" in
  ''|*[!0-9]*) exit 0 ;;   # non-numeric → ambiguous → proceed
esac

# Real commits to ship → PROCEED immediately (the common, healthy path).
[ "$COMMITS" -gt 0 ] && exit 0

# Zero commits ahead. Is there uncommitted TRACKED work (a ship-in-progress that
# §6f would commit)? If so, PROCEED — there IS work, just not committed yet.
if ! git diff --quiet HEAD 2>/dev/null; then
  exit 0
fi

# ── Positively-confirmed EMPTY ship: 0 commits ahead AND clean tracked tree ──
# Record an attempt counter for diagnostics (best-effort; never affects the verdict).
if [ -n "$SLUG" ]; then
  STATE_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}/.claude/state"
  COUNTER="$STATE_DIR/plan-w-team-empty-ship-attempts-${SLUG}.txt"
  if mkdir -p "$STATE_DIR" 2>/dev/null; then
    PREV=0
    [ -f "$COUNTER" ] && PREV="$(tr -dc '0-9' < "$COUNTER" 2>/dev/null)"
    [ -n "$PREV" ] || PREV=0
    printf '%s\n' "$((PREV + 1))" > "$COUNTER" 2>/dev/null || true
  fi
fi

echo "empty-ship: 0 commits ahead of '$BASE_REF' and a clean tracked tree — nothing to ship." >&2
echo "  halting Step 6 instead of looping push on an empty worktree (would mint a false PASS)." >&2
exit 3
