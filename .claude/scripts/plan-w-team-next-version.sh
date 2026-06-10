#!/usr/bin/env bash
# plan-w-team-next-version.sh — ship-time VERSION rebump against CURRENT main.
#
# WHY (PWT-VERSION-COLLISION, 2026-06-07): two /plan-w-team runs spawned off the
# same base both bumped VERSION to the same value (both grabbed 1.35.0 today) →
# VERSION + CHANGELOG merge conflict + a manual supervisor rebase. The root cause
# is that each run bumped from the VERSION it captured at SPAWN time, blind to a
# sibling run that landed a higher version first.
#
# THE FIX: at Step 6 ship, re-derive the new version from the version that is
# CURRENTLY on the merge target (origin/main or local main) — not the spawn-time
# snapshot. The script SELF-FETCHES the merge target first (best-effort
# `git fetch origin <base>`; offline / no-remote it silently falls back to the
# local refs) so the remote-tracking ref it reads is fresh without requiring a
# prior fetch/rebase step. So if run A shipped 1.37.0 while run B was working,
# run B's ship reads main=1.37.0 and ships 1.38.0 — no collision, no cross-run
# coordination needed.
#
# Usage:
#   plan-w-team-next-version.sh --bump <major|minor|patch> [--ref <git-ref>] \
#                               [--version-file <path>] [--write]
#
# Resolution of the AUTHORITATIVE current version (first that yields a semver),
# after a best-effort `git fetch --quiet origin <base>` refreshes the
# remote-tracking base (skipped for local --ref values; never fails the run):
#   1. --ref <ref>            → git show <ref>:<version-file>
#   2. (no --ref) origin/main → git show origin/main:<version-file>
#   3. (no --ref) main        → git show main:<version-file>
#   4. working-tree <version-file>
# Prints the computed NEXT version to stdout. With --write, also overwrites the
# working-tree <version-file> with it.
#
# Defaults: --version-file = .claude/commands/plan-w-team/VERSION, --bump patch.
# bash 3.2 compatible (mac-mini /bin/bash) — no associative arrays, no <<<.
# Exit: 0 success (next version on stdout); 1 on unresolvable/invalid version.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" 2>/dev/null || true

BUMP="patch"
REF=""
VERSION_FILE=".claude/commands/plan-w-team/VERSION"
WRITE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --bump)         BUMP="${2:-patch}"; shift 2 ;;
        --ref)          REF="${2:-}"; shift 2 ;;
        --version-file) VERSION_FILE="${2:-$VERSION_FILE}"; shift 2 ;;
        --write)        WRITE=1; shift ;;
        -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -40; exit 0 ;;
        *) shift ;;
    esac
done

case "$BUMP" in
    major|minor|patch) : ;;
    *) echo "✗ --bump must be major|minor|patch (got: $BUMP)" >&2; exit 1 ;;
esac

# Trim helper (whitespace + stray newlines a `git show` / file read can carry).
__trim() { printf '%s' "$1" | tr -d '[:space:]'; }

# Is $1 a clean MAJOR.MINOR.PATCH semver? (numeric components only.)
__is_semver() {
    case "$1" in
        *[!0-9.]*) return 1 ;;
    esac
    case "$1" in
        [0-9]*.[0-9]*.[0-9]*) : ;;
        *) return 1 ;;
    esac
    # exactly two dots
    local rest="${1#*.}"; rest="${rest#*.}"
    case "$rest" in *.*) return 1 ;; esac
    return 0
}

# Read a candidate version from a git ref's copy of the version file.
__read_ref() {
    local ref="$1"
    [ -z "$ref" ] && return 0
    git show "${ref}:${VERSION_FILE}" 2>/dev/null || true
}

# Best-effort freshness: refresh the remote-tracking base BEFORE reading it, so
# "current main" is actually current even when nothing in this session has
# fetched yet (§6d invokes this helper directly — no prior fetch is guaranteed).
# Must never break offline / hermetic-sandbox use (no remote): || true.
__fetch_base() {
    local base="main"
    case "$REF" in
        "")       : ;;                      # no --ref → default merge-target branch
        origin/*) base="${REF#origin/}" ;;  # remote-tracking ref → fetch its branch
        *)        return 0 ;;               # local ref/sha (HEAD, main, …): nothing to fetch
    esac
    git fetch --quiet origin "$base" >/dev/null 2>&1 || true
}
__fetch_base

CURRENT=""
if [ -n "$REF" ]; then
    CURRENT=$(__trim "$(__read_ref "$REF")")
else
    for r in origin/main main; do
        cand=$(__trim "$(__read_ref "$r")")
        if __is_semver "$cand"; then CURRENT="$cand"; break; fi
    done
fi
# Fall back to the working-tree file if no ref yielded a valid version.
if ! __is_semver "$CURRENT"; then
    [ -f "$VERSION_FILE" ] && CURRENT=$(__trim "$(cat "$VERSION_FILE" 2>/dev/null)")
fi

if ! __is_semver "$CURRENT"; then
    echo "✗ could not resolve a valid current version (file=$VERSION_FILE ref=${REF:-origin/main|main|worktree}); got: '${CURRENT}'" >&2
    exit 1
fi

# Split MAJOR.MINOR.PATCH (bash 3.2: cut, not read <<<).
MA=$(printf '%s' "$CURRENT" | cut -d. -f1)
MI=$(printf '%s' "$CURRENT" | cut -d. -f2)
PA=$(printf '%s' "$CURRENT" | cut -d. -f3)

case "$BUMP" in
    major) MA=$((MA + 1)); MI=0; PA=0 ;;
    minor) MI=$((MI + 1)); PA=0 ;;
    patch) PA=$((PA + 1)) ;;
esac
NEXT="${MA}.${MI}.${PA}"

if [ "$WRITE" -eq 1 ]; then
    printf '%s\n' "$NEXT" > "$VERSION_FILE" || {
        echo "✗ failed to write $VERSION_FILE" >&2; exit 1; }
fi

printf '%s\n' "$NEXT"
exit 0
