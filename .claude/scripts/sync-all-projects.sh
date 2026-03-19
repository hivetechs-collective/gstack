#!/bin/bash
# Sync Claude Code configuration to all projects in a directory
# Usage: ./sync-all-projects.sh [base-directory] [--dry-run] [--commit]
#
# Defaults to /Users/veronelazio/Developer/Private if no directory specified
# Use --commit to automatically commit changes in each project

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-to-project.sh"
BASE_DIR="/Users/veronelazio/Developer/Private"
DRY_RUN=""
AUTO_COMMIT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN="--dry-run"
      shift
      ;;
    --commit)
      AUTO_COMMIT="true"
      shift
      ;;
    --*)
      echo "Unknown option: $1"
      shift
      ;;
    *)
      # Non-flag argument is the base directory
      BASE_DIR="$1"
      shift
      ;;
  esac
done

if [ ! -d "$BASE_DIR" ]; then
  echo "Error: Directory $BASE_DIR does not exist"
  exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  CLAUDE CODE SYNC - All Projects"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Base directory: $BASE_DIR"
echo "Dry run: ${DRY_RUN:-no}"
echo "Auto commit: ${AUTO_COMMIT:-no}"
echo ""

# Track results
SYNCED=0
SETUP=0
SKIPPED=0
FAILED=0

# Repos to exclude from sync (non-development repos)
EXCLUDED_REPOS=(
  "claude-pattern"           # Source repo
  "hive-consensus-support"   # GitHub support repo, no .claude needed
)

# Find all git repositories
for dir in "$BASE_DIR"/*/; do
  PROJECT_NAME=$(basename "$dir")

  # Skip excluded repos
  for excluded in "${EXCLUDED_REPOS[@]}"; do
    if [ "$PROJECT_NAME" = "$excluded" ]; then
      echo "⏭️  $PROJECT_NAME - Excluded from sync"
      ((SKIPPED++))
      continue 2
    fi
  done

  # Skip if not a git repo
  if [ ! -d "$dir/.git" ]; then
    echo "⏭️  $PROJECT_NAME - Not a git repo, skipping"
    ((SKIPPED++))
    continue
  fi

  echo "─────────────────────────────────────────────────────────────"
  echo "📁 $PROJECT_NAME"
  echo "─────────────────────────────────────────────────────────────"

  # Check if .claude exists to determine setup vs sync
  if [ -d "$dir/.claude" ]; then
    ACTION="Syncing"
  else
    ACTION="Setting up"
    ((SETUP++))
  fi

  echo "   $ACTION..."

  # Run sync (which auto-detects and runs setup if needed)
  if "$SYNC_SCRIPT" "$dir" $DRY_RUN 2>&1 | tail -5; then
    ((SYNCED++))

    # Auto-commit if requested
    if [ -n "$AUTO_COMMIT" ] && [ -z "$DRY_RUN" ]; then
      cd "$dir"
      if [ -n "$(git status --porcelain)" ]; then
        git add -A
        git commit -m "chore: sync Claude Code updates from claude-pattern

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>" 2>&1 | tail -1
        echo "   ✓ Committed"
      fi
      cd - > /dev/null
    fi
  else
    echo "   ✗ Failed"
    ((FAILED++))
  fi

  echo ""
done

echo "═══════════════════════════════════════════════════════════════"
echo "  SUMMARY"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Synced:  $SYNCED projects"
echo "  Setup:   $SETUP new projects"
echo "  Skipped: $SKIPPED (not git repos)"
echo "  Failed:  $FAILED"
echo ""

if [ -n "$DRY_RUN" ]; then
  echo "This was a dry run. Re-run without --dry-run to apply changes."
fi
