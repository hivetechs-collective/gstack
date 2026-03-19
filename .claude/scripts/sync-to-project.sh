#!/bin/bash
# Ongoing sync script for existing projects with selective agent support
# Usage: ./sync-to-project.sh /path/to/project [--dry-run] [--profile <name>]
#
# Profiles:
#   --profile minimal    Core agents only (~10 agents)
#   --profile web        Web development (Next.js, React, APIs)
#   --profile backend    Backend development (Rust, Go, databases)
#   --profile full       All agents (default for claude-pattern only)
#
# Custom selection:
#   Create .claude/agent-manifest.txt in target project listing agent folders to include

set -e

SOURCE_DIR="/Users/veronelazio/Developer/Private/claude-pattern/.claude"
TARGET_DIR="$1/.claude"
DRY_RUN=""
PROFILE=""

usage() {
  echo "Usage: $0 /path/to/project [--dry-run] [--profile <minimal|web|backend|full>]"
  echo ""
  echo "Profiles:"
  echo "  minimal  - Core agents only (~10 agents, <5k tokens)"
  echo "  web      - Web development stack (~25 agents)"
  echo "  backend  - Backend/systems stack (~25 agents)"
  echo "  full     - All agents (150 agents, use for template repo only)"
  echo ""
  echo "Or create .claude/agent-manifest.txt in target project for custom selection."
  exit 1
}

if [ -z "$1" ]; then
  usage
fi

if [ ! -d "$1" ]; then
  echo "Error: Project directory $1 does not exist"
  exit 1
fi

# Parse arguments
shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN="--dry-run"
      echo "🔍 DRY RUN MODE - No changes will be made"
      shift
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Check if .claude directory exists - if not, run setup instead of sync
if [ ! -d "$TARGET_DIR" ]; then
  echo "📦 No .claude directory found in target project"
  echo "   Running initial setup instead of sync..."
  echo ""

  SETUP_SCRIPT="$(dirname "$0")/setup-new-project.sh"
  if [ -f "$SETUP_SCRIPT" ]; then
    if [ -n "$DRY_RUN" ]; then
      echo "DRY RUN: Would run setup-new-project.sh on $1"
      exit 0
    fi

    # Run setup script (it handles everything)
    "$SETUP_SCRIPT" "$(dirname "$TARGET_DIR")"

    # Also copy the init script
    PROJECT_ROOT="$(dirname "$TARGET_DIR")"
    mkdir -p "$PROJECT_ROOT/scripts"
    cp "$(dirname "$SOURCE_DIR")/scripts/init-project-context.ts" "$PROJECT_ROOT/scripts/" 2>/dev/null || true

    echo ""
    echo "✅ Initial setup complete! Future syncs will update existing files."
    exit 0
  else
    echo "Error: setup-new-project.sh not found at $SETUP_SCRIPT"
    exit 1
  fi
fi

# Define agent profiles
get_profile_agents() {
  case $1 in
    minimal)
      echo "coordination/orchestrator.md
mechanical/file-scanner.md
mechanical/log-parser.md
mechanical/build-runner.md
implementation/claude-code-docs-updater.md
team/builder.md
team/validator.md"
      ;;
    web)
      echo "coordination/orchestrator.md
coordination/release-orchestrator.md
mechanical/file-scanner.md
mechanical/log-parser.md
mechanical/build-runner.md
team/builder.md
team/validator.md
specialists/nextjs-expert.md
specialists/react-typescript-specialist.md
specialists/style-theme-expert.md
specialists/shadcn-expert.md
specialists/api-expert.md
specialists/nodejs-specialist.md
specialists/database-expert.md
research-planning/documentation-expert.md
research-planning/code-review-expert.md
research-planning/security-expert.md"
      ;;
    backend)
      echo "coordination/orchestrator.md
coordination/release-orchestrator.md
mechanical/file-scanner.md
mechanical/log-parser.md
mechanical/build-runner.md
team/builder.md
team/validator.md
specialists/rust-backend-specialist.md
specialists/go-specialist.md
specialists/database-expert.md
specialists/redis-specialist.md
specialists/kafka-specialist.md
specialists/kubernetes-specialist.md
specialists/docker-advanced-specialist.md
research-planning/documentation-expert.md
research-planning/code-review-expert.md
research-planning/security-expert.md"
      ;;
    full)
      echo "ALL"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Check for custom manifest in target project
MANIFEST_FILE="$TARGET_DIR/agent-manifest.txt"
SELECTED_AGENTS=""

if [ -f "$MANIFEST_FILE" ]; then
  echo "📋 Using custom agent manifest from $MANIFEST_FILE"
  SELECTED_AGENTS=$(cat "$MANIFEST_FILE")
elif [ -n "$PROFILE" ]; then
  echo "📋 Using profile: $PROFILE"
  SELECTED_AGENTS=$(get_profile_agents "$PROFILE")
  if [ -z "$SELECTED_AGENTS" ]; then
    echo "Error: Unknown profile '$PROFILE'"
    usage
  fi
else
  # Default to minimal for other projects
  echo "📋 Using default profile: minimal (use --profile for more agents)"
  SELECTED_AGENTS=$(get_profile_agents "minimal")
fi

echo "🔄 Syncing claude-pattern to $TARGET_DIR"

# Backup existing configuration (only if not dry-run)
if [ -z "$DRY_RUN" ]; then
  if [ -d "$TARGET_DIR/agents" ]; then
    BACKUP_DIR="$TARGET_DIR/agents.backup.$(date +%Y%m%d_%H%M%S)"
    echo "📦 Creating backup at $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    cp -r "$TARGET_DIR/agents" "$BACKUP_DIR/" 2>/dev/null || true
  fi
fi

# Sync non-agent files first
echo "📁 Syncing configuration files..."
rsync -av $DRY_RUN \
  --exclude='agents/' \
  --exclude='settings.local.json' \
  --exclude='statusline.log' \
  --exclude='agents.backup.*' \
  --exclude='outputs/*/*.md' \
  --exclude='*.pyc' \
  --exclude='__pycache__' \
  --exclude='state/' \
  --exclude='scripts/' \
  --exclude='secrets/' \
  "$SOURCE_DIR/" "$TARGET_DIR/"

# Sync agents based on selection
echo "🤖 Syncing agents..."

if [ "$SELECTED_AGENTS" = "ALL" ]; then
  # Full sync of all agents
  rsync -av $DRY_RUN \
    "$SOURCE_DIR/agents/" "$TARGET_DIR/agents/"
  AGENT_COUNT=$(find "$SOURCE_DIR/agents" -name "*.md" | wc -l | tr -d ' ')
else
  # Selective sync
  if [ -z "$DRY_RUN" ]; then
    mkdir -p "$TARGET_DIR/agents/coordination"
    mkdir -p "$TARGET_DIR/agents/mechanical"
    mkdir -p "$TARGET_DIR/agents/specialists"
    mkdir -p "$TARGET_DIR/agents/research-planning"
    mkdir -p "$TARGET_DIR/agents/implementation"
    mkdir -p "$TARGET_DIR/agents/team"
  fi

  AGENT_COUNT=0
  while IFS= read -r agent; do
    [ -z "$agent" ] && continue
    [[ "$agent" == \#* ]] && continue  # Skip comments

    if [ -f "$SOURCE_DIR/agents/$agent" ]; then
      if [ -z "$DRY_RUN" ]; then
        cp "$SOURCE_DIR/agents/$agent" "$TARGET_DIR/agents/$agent"
      fi
      echo "  ✓ $agent"
      AGENT_COUNT=$((AGENT_COUNT + 1))
    else
      echo "  ⚠ $agent (not found)"
    fi
  done <<< "$SELECTED_AGENTS"
fi

# Sync root scripts folder (init-project-context.ts)
PROJECT_ROOT=$(dirname "$SOURCE_DIR")
TARGET_ROOT=$(dirname "$TARGET_DIR")
echo "📜 Syncing project scripts..."
mkdir -p "$TARGET_ROOT/scripts"
if [ -z "$DRY_RUN" ]; then
  cp "$PROJECT_ROOT/scripts/init-project-context.ts" "$TARGET_ROOT/scripts/" 2>/dev/null && echo "  ✓ init-project-context.ts" || true
else
  echo "  Would copy: scripts/init-project-context.ts"
fi

# Copy sync version marker (enables auto-sync detection)
echo "🔖 Updating sync version..."
if [ -z "$DRY_RUN" ]; then
  if [ -f "$SOURCE_DIR/.sync-version" ]; then
    cp "$SOURCE_DIR/.sync-version" "$TARGET_DIR/.sync-version"
    echo "  ✓ .sync-version marker updated"
  fi
else
  echo "  Would copy: .sync-version"
fi

# Auto-initialize CLAUDE.md with project context
echo "🧠 Initializing project context..."
if [ -z "$DRY_RUN" ]; then
  INIT_SCRIPT="$TARGET_ROOT/scripts/init-project-context.ts"
  TARGET_CLAUDE_MD="$TARGET_ROOT/CLAUDE.md"

  if [ -f "$INIT_SCRIPT" ] && command -v tsx &> /dev/null; then
    # Check if CLAUDE.md needs initialization
    if [ ! -f "$TARGET_CLAUDE_MD" ] || ! grep -q "AUTO-GENERATED by /init" "$TARGET_CLAUDE_MD" 2>/dev/null; then
      cd "$TARGET_ROOT"
      if tsx "$INIT_SCRIPT" --update 2>/dev/null; then
        echo "  ✓ CLAUDE.md initialized with project context"
      else
        echo "  ⚠ Could not auto-initialize CLAUDE.md (run /init manually)"
      fi
      cd - > /dev/null
    else
      echo "  ✓ CLAUDE.md already has project context"
    fi
  else
    echo "  ⚠ Skipped (tsx not available or init script missing)"
  fi
else
  echo "  Would run: tsx scripts/init-project-context.ts --update"
fi

if [ -z "$DRY_RUN" ]; then
  echo ""
  echo "✅ Sync complete!"
  echo ""
  echo "Summary:"
  echo "  - $AGENT_COUNT agents synced"
  echo "  - Configuration files updated"
  echo "  - statusline.sh updated"
  echo "  - scripts/init-project-context.ts synced"
  echo ""
  echo "Preserved:"
  echo "  - settings.local.json (project-specific)"
  echo "  - agent-manifest.txt (if exists)"
  if [ -n "$BACKUP_DIR" ]; then
    echo "  - Previous backup at $BACKUP_DIR"
  fi
  echo ""
  echo "To customize agents, create: $TARGET_DIR/agent-manifest.txt"
else
  echo ""
  echo "This was a dry run. Re-run without --dry-run to apply changes."
fi
