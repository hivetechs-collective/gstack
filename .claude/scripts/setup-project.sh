#!/bin/bash
# Autonomous Pipeline - Project Setup Script
# Sets up a new project with the autonomous development pipeline
#
# Usage:
#   .claude/scripts/setup-project.sh [project-name]
#
# This script:
# 1. Initializes .claude/project.json with your project name
# 2. Ensures all hooks are executable
# 3. Creates required directories
# 4. Copies template files if needed

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo "==============================================================="
echo "  Autonomous Pipeline - Project Setup"
echo "==============================================================="
echo ""

# Get project name
PROJECT_NAME="${1:-}"
if [ -z "$PROJECT_NAME" ]; then
    # Try to detect from directory name
    PROJECT_NAME=$(basename "$PROJECT_ROOT")
    echo -e "${YELLOW}No project name provided, using directory name: $PROJECT_NAME${NC}"
fi

echo -e "${CYAN}Setting up: $PROJECT_NAME${NC}"
echo ""

# 1. Create directories
echo "Creating directories..."
mkdir -p .claude/state
mkdir -p .claude/state/checkpoints
mkdir -p .claude/lib
mkdir -p docs/governance
echo -e "${GREEN}✓ Directories created${NC}"

# 2. Update project.json
if [ -f ".claude/project.json" ]; then
    echo "Updating .claude/project.json..."
    if command -v jq &> /dev/null; then
        # Update project name using jq
        jq ".project.name = \"$PROJECT_NAME\"" .claude/project.json > .claude/project.json.tmp
        mv .claude/project.json.tmp .claude/project.json
        echo -e "${GREEN}✓ project.json updated${NC}"
    else
        echo -e "${YELLOW}⚠ jq not installed, please update .claude/project.json manually${NC}"
    fi
else
    echo -e "${YELLOW}⚠ .claude/project.json not found - run sync-to-project.sh first${NC}"
fi

# 3. Make hooks executable
echo "Making hooks executable..."
if [ -d ".claude/hooks" ]; then
    chmod +x .claude/hooks/*.sh 2>/dev/null || true
    echo -e "${GREEN}✓ Hooks are executable${NC}"
else
    echo -e "${YELLOW}⚠ .claude/hooks not found${NC}"
fi

# 4. Make scripts executable
echo "Making scripts executable..."
if [ -d ".claude/scripts" ]; then
    chmod +x .claude/scripts/*.sh 2>/dev/null || true
    echo -e "${GREEN}✓ Scripts are executable${NC}"
fi

# 5. Copy templates if not exists
echo "Checking template files..."
if [ -f "PROMPT.md.template" ] && [ ! -f "PROMPT.md" ]; then
    cp PROMPT.md.template PROMPT.md
    # Replace placeholder with project name
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" PROMPT.md 2>/dev/null || true
    else
        sed -i "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" PROMPT.md 2>/dev/null || true
    fi
    echo -e "${GREEN}✓ Created PROMPT.md from template${NC}"
fi

if [ -f "@AGENT.md.template" ] && [ ! -f "@AGENT.md" ]; then
    cp @AGENT.md.template @AGENT.md
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" @AGENT.md 2>/dev/null || true
    else
        sed -i "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" @AGENT.md 2>/dev/null || true
    fi
    echo -e "${GREEN}✓ Created @AGENT.md from template${NC}"
fi

if [ -f "fix_plan.md.template" ] && [ ! -f "fix_plan.md" ]; then
    cp fix_plan.md.template fix_plan.md
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" fix_plan.md 2>/dev/null || true
    else
        sed -i "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" fix_plan.md 2>/dev/null || true
    fi
    echo -e "${GREEN}✓ Created fix_plan.md from template${NC}"
fi

# 6. Run health check
echo ""
echo "Running health check..."
if [ -x ".claude/hooks/health-check.sh" ]; then
    .claude/hooks/health-check.sh || echo -e "${YELLOW}⚠ Some checks failed, review above${NC}"
else
    echo -e "${YELLOW}⚠ Health check not available${NC}"
fi

echo ""
echo "==============================================================="
echo "  Setup Complete!"
echo "==============================================================="
echo ""
echo "Next steps:"
echo "  1. Edit .claude/project.json to configure your features"
echo "  2. Create docs/TODO.md with your tasks (optional)"
echo "  3. Run: claude  # Start Claude Code session"
echo "  4. Use: /develop  # Start autonomous development"
echo ""
echo "Available commands:"
echo "  /develop    - Autonomous development workflow"
echo "  /context    - Load project context"
echo "  /governance - Run governance checks"
echo "  /blocked    - Show blocked features"
echo ""
