#!/bin/bash
# Bump the sync version to trigger auto-sync in all projects
# NOTE: This is now automatic via pre-commit hook - manual use rarely needed

VERSION_FILE="/Users/veronelazio/Developer/Private/claude-pattern/.claude/.sync-version"
NEW_VERSION=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "$NEW_VERSION" > "$VERSION_FILE"

echo "✅ Sync version bumped to: $NEW_VERSION"
echo ""
echo "All projects will auto-sync on their next session start."
echo ""
echo "To force immediate sync of all projects, run:"
echo "  .claude/scripts/sync-all-projects.sh --commit"
