#!/usr/bin/env bash
# board-preflight.sh — Ensures GitHub Projects board is ready before /plan-w-team
# Idempotent: exits 0 immediately if board is already configured.
# Called by /plan-w-team pre-flight. Safe to run any number of times.
#
# IMPORTANT: This script operates on the CURRENT git repo (via git rev-parse),
# NOT the repo containing the script. It is shipped in claude-pattern's
# .claude/scripts/ and is synced into consumer repos. When run from a consumer
# repo, PROJECT_ROOT must resolve to THAT repo's root, not claude-pattern's.

set -euo pipefail

# PROJECT_ROOT = current git repo's top-level directory.
# Fails fast with a clear error if not run inside a git repo.
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "PREFLIGHT ERROR: Not inside a git repo. Run this from the repo you want to add a board to." >&2
  exit 1
}

# SOURCE_BOARD_SH = the template board.sh to copy from.
# Prefer the one in this repo's .claude/scripts/ (after sync), fall back to
# claude-pattern's global copy if invoked directly from there.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_BOARD_SH=""
if [ -f "$PROJECT_ROOT/.claude/scripts/board.sh" ]; then
  SOURCE_BOARD_SH="$PROJECT_ROOT/.claude/scripts/board.sh"
elif [ -f "$SCRIPT_DIR/board.sh" ]; then
  SOURCE_BOARD_SH="$SCRIPT_DIR/board.sh"
fi

# ─── Step 1: Ensure scripts/board.sh exists ──────────────────

if [ ! -f "$PROJECT_ROOT/scripts/board.sh" ]; then
  if [ -n "$SOURCE_BOARD_SH" ] && [ -f "$SOURCE_BOARD_SH" ]; then
    mkdir -p "$PROJECT_ROOT/scripts"
    cp "$SOURCE_BOARD_SH" "$PROJECT_ROOT/scripts/board.sh"
    chmod +x "$PROJECT_ROOT/scripts/board.sh"
    echo "PREFLIGHT: Copied board.sh to $PROJECT_ROOT/scripts/"
  else
    echo "PREFLIGHT ERROR: No source board.sh found." >&2
    echo "  Looked in: $PROJECT_ROOT/.claude/scripts/board.sh" >&2
    echo "  And:       $SCRIPT_DIR/board.sh" >&2
    exit 1
  fi
fi

# ─── Step 2: Ensure .github/board.json exists (board initialized) ─

if [ -f "$PROJECT_ROOT/.github/board.json" ]; then
  echo "PREFLIGHT: Board already configured (.github/board.json exists)"
  exit 0
fi

# Need to create a board — check gh auth first
if ! gh auth status &>/dev/null; then
  echo "PREFLIGHT ERROR: gh CLI not authenticated." >&2
  echo "Run: gh auth login" >&2
  exit 1
fi

# Detect owner info from git remote
OWNER=$(gh repo view --json owner -q '.owner.login' 2>/dev/null || echo "")
OWNER_TYPE=$(gh repo view --json owner -q '.owner.__typename' 2>/dev/null || echo "User")
REPO_NAME=$(gh repo view --json name -q '.name' 2>/dev/null || basename "$PROJECT_ROOT")

if [ -z "$OWNER" ]; then
  echo "PREFLIGHT ERROR: Could not detect repo owner. Is this a GitHub repo?" >&2
  exit 1
fi

# Convert repo name to title: "my-project" -> "My Project Development"
BOARD_TITLE=$(echo "$REPO_NAME" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')" Development"

echo "PREFLIGHT: Creating board '$BOARD_TITLE' for $OWNER ($OWNER_TYPE)..."

# Use @me for user-owned repos, org name for org-owned repos
if [ "$OWNER_TYPE" = "Organization" ]; then
  "$PROJECT_ROOT/scripts/board.sh" init --owner "$OWNER" --title "$BOARD_TITLE"
else
  "$PROJECT_ROOT/scripts/board.sh" init --owner "@me" --title "$BOARD_TITLE"
fi

# Commit so other agents/sessions see it
cd "$PROJECT_ROOT"
git add scripts/board.sh .github/board.json
git commit -m "chore: initialize GitHub Projects board for /plan-w-team

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"

echo "PREFLIGHT: Board initialized and committed."
