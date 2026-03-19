#!/bin/bash
# Initial setup script for new projects
# Usage: ./setup-new-project.sh /path/to/new/project

set -e

SOURCE_DIR="/Users/veronelazio/Developer/Private/claude-pattern/.claude"
TARGET_DIR="$1/.claude"

if [ -z "$1" ]; then
  echo "Usage: $0 /path/to/new/project"
  exit 1
fi

if [ ! -d "$1" ]; then
  echo "Error: Project directory $1 does not exist"
  echo "Create it first with: mkdir -p $1"
  exit 1
fi

if [ -d "$TARGET_DIR" ]; then
  echo "⚠️  Warning: .claude directory already exists in $1"
  echo "Use sync-to-project.sh instead for existing projects"
  exit 1
fi

echo "🚀 Setting up claude-pattern in $1"
echo ""

# Create .claude directory
echo "📁 Creating .claude directory..."
mkdir -p "$TARGET_DIR"

# Copy all configuration with exclusions
echo "📦 Copying agents, configs, and documentation..."
rsync -av \
  --exclude='settings.local.json' \
  --exclude='statusline.log' \
  --exclude='agents.backup.*' \
  --exclude='outputs/*/*.md' \
  --exclude='*.pyc' \
  --exclude='__pycache__' \
  --exclude='secrets/' \
  --exclude='state/' \
  "$SOURCE_DIR/" "$TARGET_DIR/"

# Copy init script to project root
echo "📜 Copying project scripts..."
PROJECT_ROOT=$(dirname "$SOURCE_DIR")
mkdir -p "$1/scripts"
cp "$PROJECT_ROOT/scripts/init-project-context.ts" "$1/scripts/" 2>/dev/null && echo "  ✓ init-project-context.ts" || true

# Auto-initialize CLAUDE.md with project context
echo "🧠 Initializing project context..."
INIT_SCRIPT="$1/scripts/init-project-context.ts"
TARGET_CLAUDE_MD="$1/CLAUDE.md"

if [ -f "$INIT_SCRIPT" ] && command -v tsx &> /dev/null; then
  cd "$1"
  if tsx "$INIT_SCRIPT" --update 2>/dev/null; then
    echo "  ✓ CLAUDE.md created with project context"
  else
    echo "  ⚠ Could not auto-initialize CLAUDE.md (run /init manually after setup)"
  fi
  cd - > /dev/null
else
  echo "  ⚠ Skipped (tsx not available)"
fi

echo ""
echo "✅ Setup complete!"
echo ""
echo "Installed:"
echo "- agents/ directory (150 specialist agents)"
echo "- commands/ directory (custom slash commands)"
echo "- docs/ directory (documentation library)"
echo "- statusline.sh (status line configuration)"
echo "- settings.json (hooks and commands)"
echo "- .mcp.json (MCP server configuration)"
echo "- CLAUDE.md (auto-generated project context)"
echo ""
echo "Verify:"
echo "  cd $1"
echo "  find .claude/agents -name '*.md' | wc -l  # Should show 148+ files"
echo "  ls .claude/statusline.sh                    # Should exist"
echo "  cat CLAUDE.md                               # Should have project info"
echo ""
echo "Next steps:"
echo "1. Review and customize CLAUDE.md if needed"
echo "2. Customize .claude/settings.local.json for project-specific settings"
echo "3. Start using @agent-orchestrator from this project"
echo ""
echo "To sync updates later, use:"
echo "  $SOURCE_DIR/../scripts/sync-to-project.sh $1"
