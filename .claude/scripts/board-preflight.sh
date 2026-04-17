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

# Runbook reference — printed on every failure path so Claude and humans
# can jump straight to the matching recovery procedure.
RUNBOOK="docs/operations/BOARD_TEMPLATE_RUNBOOK.md"

# PROJECT_ROOT = current git repo's top-level directory.
# Fails fast with a clear error if not run inside a git repo.
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "PREFLIGHT ERROR: Not inside a git repo. Run this from the repo you want to add a board to." >&2
  echo "  See: $RUNBOOK (§9 Runbook Procedures) for bootstrap steps." >&2
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
    echo "  See: $RUNBOOK (FM-11 Consumer repo out of date) for recovery." >&2
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
  echo "  See: $RUNBOOK (FM-1 gh not authenticated) for full recovery." >&2
  exit 1
fi

# Verify the 'project' scope is present — copyProjectV2 and createProjectV2
# both require it, and the default `gh auth login` does NOT grant it.
if ! gh auth status 2>&1 | grep -q "'project'"; then
  echo "PREFLIGHT WARNING: gh token may be missing 'project' scope." >&2
  echo "  If board.sh init fails, run: gh auth refresh -s project,read:org" >&2
  echo "  See: $RUNBOOK (FM-2 gh missing project scope) for details." >&2
fi

# Detect owner info from git remote
OWNER=$(gh repo view --json owner -q '.owner.login' 2>/dev/null || echo "")
OWNER_TYPE=$(gh repo view --json owner -q '.owner.__typename' 2>/dev/null || echo "User")
REPO_NAME=$(gh repo view --json name -q '.name' 2>/dev/null || basename "$PROJECT_ROOT")
# Sanitize REPO_NAME: strip anything that isn't alnum / dot / underscore / hyphen.
# basename on an odd cwd could yield characters that break sed/awk downstream or
# flow into the board title shell-expanded. Belt-and-suspenders: whitelist only.
REPO_NAME=$(printf '%s' "$REPO_NAME" | tr -cd 'A-Za-z0-9._-')

if [ -z "$OWNER" ]; then
  echo "PREFLIGHT ERROR: Could not detect repo owner. Is this a GitHub repo?" >&2
  echo "  See: $RUNBOOK (§9.4 Initialize a brand-new repo) for setup steps." >&2
  exit 1
fi

if [ -z "$REPO_NAME" ]; then
  echo "PREFLIGHT ERROR: Could not derive a usable repo name." >&2
  echo "  See: $RUNBOOK (§9.4 Initialize a brand-new repo) for setup steps." >&2
  exit 1
fi

# Convert repo name to title: "my-project" -> "My Project Development"
BOARD_TITLE=$(echo "$REPO_NAME" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')" Development"

echo "PREFLIGHT: Creating board '$BOARD_TITLE' for $OWNER ($OWNER_TYPE)..."
echo "PREFLIGHT: board.sh init will attempt to clone from a canonical org template."
echo "PREFLIGHT: If no template is found, it falls back to from-scratch creation."
echo "PREFLIGHT: (See $RUNBOOK §5 Discovery Chain for how template lookup works.)"

# Use @me for user-owned repos, org name for org-owned repos.
# board.sh init handles template discovery: for org targets it queries that org
# directly; for user targets it walks the user's org memberships looking for any
# org-owned template it can copy cross-owner. See RUNBOOK §5.
if [ "$OWNER_TYPE" = "Organization" ]; then
  if ! "$PROJECT_ROOT/scripts/board.sh" init --owner "$OWNER" --title "$BOARD_TITLE"; then
    echo "PREFLIGHT ERROR: board.sh init failed for org '$OWNER'." >&2
    echo "  Diagnose by section in $RUNBOOK:" >&2
    echo "    FM-2  — missing 'project' scope on gh token" >&2
    echo "    FM-3  — template lookup returned empty (discovery failed)" >&2
    echo "    FM-5  — copyProjectV2 mutation error" >&2
    echo "    FM-6  — clone succeeded but board.json write failed" >&2
    echo "  Retry with: scripts/board.sh init --owner $OWNER --title \"$BOARD_TITLE\" --no-template" >&2
    exit 1
  fi
else
  if ! "$PROJECT_ROOT/scripts/board.sh" init --owner "@me" --title "$BOARD_TITLE"; then
    echo "PREFLIGHT ERROR: board.sh init failed for user '@me'." >&2
    echo "  Diagnose by section in $RUNBOOK:" >&2
    echo "    FM-2  — missing 'project' scope on gh token" >&2
    echo "    FM-3  — no org template found via user/orgs walk" >&2
    echo "    FM-5  — copyProjectV2 cross-owner copy failed" >&2
    echo "    FM-6  — clone succeeded but board.json write failed" >&2
    echo "    FM-8  — wrong owner (you may need to create an org template first)" >&2
    echo "  Retry with: scripts/board.sh init --owner @me --title \"$BOARD_TITLE\" --no-template" >&2
    exit 1
  fi
fi

# Commit so other agents/sessions see it.
# Use `git commit -o <pathspec>` to scope the commit strictly to the board files.
# The -o (--only) flag ignores whatever is currently staged and commits ONLY the
# listed paths — this prevents sweeping unrelated staged work into the board-
# bootstrap commit (common hazard when preflight runs mid-session).
cd "$PROJECT_ROOT"
git commit -o scripts/board.sh .github/board.json -m "$(cat <<'MSG'
chore: initialize plan-w-team board

Creates GitHub Projects v2 board and checks in scripts/board.sh +
.github/board.json.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)" || echo "PREFLIGHT WARN: Failed to commit board files (may already be committed)" >&2

echo "PREFLIGHT: Board initialized and committed."
echo "PREFLIGHT: Verify views/workflows inherited correctly — see $RUNBOOK §7."
