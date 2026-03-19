# Repository Sync Strategy for claude-pattern

**Project Name**: Claude Pattern Template Repository
**Date**: 2025-10-08
**Coordinator**: Orchestrator
**Status**: Phase 2 - Architecture Design

---

## Executive Summary

This document provides a comprehensive strategy for **sharing and synchronizing** the claude-pattern repository (70+ agents, extensive documentation, status line configuration) with existing projects (hive, hivetechs-website) and future projects.

### Key Requirements Met

1. **Initial Setup**: Complete claude-pattern setup in < 5 minutes
2. **Ongoing Sync**: Pull updates with a single command
3. **No Manual Copying**: Automated file synchronization
4. **Status Line Guaranteed**: Works immediately after integration
5. **Full Agent Access**: All 70+ agents available from integrated projects
6. **Documentation Library**: All research and SDK docs accessible
7. **Conflict Handling**: Preserves project-specific customizations
8. **Rollback Strategy**: Safe reversion if sync fails

---

## Part 1: Current State Analysis

### 1.1 claude-pattern Repository Structure

**Location**: `/Users/veronelazio/Developer/Private/claude-pattern`

**Contents** (112 agent markdown files):
```
.claude/
├── agents/                          # 70+ specialist agents
│   ├── coordination/                # orchestrator, git-expert
│   ├── implementation/              # 18 implementation agents
│   │   ├── react-typescript-specialist.md
│   │   ├── rust-backend-specialist.md
│   │   ├── ios-specialist.md
│   │   ├── android-specialist.md
│   │   └── ... (14 more)
│   ├── research-planning/           # 50+ research agents
│   │   ├── aws-specialist.md
│   │   ├── kubernetes-specialist.md
│   │   ├── databricks-specialist.md
│   │   ├── claude-sdk-expert/      # SDK documentation
│   │   │   └── docs/               # 17 SDK reference files
│   │   ├── git-expert/
│   │   │   └── SDK_ENHANCEMENTS.md
│   │   └── system-architect/
│   │       └── SDK_ENHANCEMENTS.md
│   ├── research/                    # Latest technology updates
│   │   └── 2025_TECHNOLOGY_UPDATES.md
│   ├── COMPLETE_AGENT_REGISTRY.md   # 70 agent inventory
│   ├── AGENT_EXPANSION_PLAN.md      # Expansion roadmap
│   ├── COVERAGE_GAP_ANALYSIS.md     # Coverage analysis
│   ├── GENERATION_REPORT.md         # Generation metadata
│   └── EXECUTION_SUMMARY.md         # Implementation summary
├── commands/                        # Slash commands
│   ├── agent_prompts/              # Agent prompt templates
│   ├── design/                     # Design workflow commands
│   └── dev/                        # Development commands
├── docs/                            # Integration guides
│   └── MCP_USAGE_GUIDE.md
├── outputs/                         # Design/implementation outputs
├── statusline.sh                   # Status line script (15,483 bytes)
├── settings.json                   # Base settings (105 bytes)
├── settings.local.json            # Local settings (5,146 bytes)
└── .mcp.json                       # MCP server configuration
```

**Key Characteristics**:
- **70+ agents** with 94% technology coverage
- **SDK documentation** (17 files, 5,363 lines) offline reference
- **Status line** custom script with token tracking, cost monitoring, burn rate
- **MCP servers** (5 configured: memory, filesystem, sequential-thinking, git, ref)
- **Slash commands** for agent invocation and design workflows

### 1.2 Existing Project: hive

**Location**: `/Users/veronelazio/Developer/Private/hive`

**Current .claude/ Structure** (108 agent markdown files):
```
.claude/
├── AGENT_INTEGRATION_SUMMARY.md    # Last sync: 2025-10-08 12:20 PST
├── agents/                          # 31 agents (v1.1.0)
│   ├── coordination/
│   ├── implementation/
│   └── research-planning/
│       ├── claude-sdk-expert/      # SDK docs present
│       ├── git-expert/             # Enhanced with SDK
│       └── system-architect/       # Enhanced with SDK
├── agents.backup.20251008/         # Backup of previous version
├── agents.backup.20251008_121925/  # Another backup
├── statusline.sh                   # Status line script
├── settings.local.json            # Local settings (1,677 bytes)
├── statusline.log                  # Status line logs (267,319 bytes)
└── .mcp.json                       # MCP servers configured
```

**Integration Status**:
- ✅ Has 31 agents (v1.1.0) from previous manual sync
- ✅ Status line working (statusline.sh present)
- ✅ MCP servers configured (.mcp.json)
- ❌ Missing 39 new agents (70 total in claude-pattern vs 31 in hive)
- ❌ Missing research/ directory (2025 technology updates)
- ❌ Missing COVERAGE_GAP_ANALYSIS.md
- ❌ Missing EXECUTION_SUMMARY.md
- ❌ Missing some SDK enhancement files

### 1.3 Existing Project: hivetechs-website

**Location**: `/Users/veronelazio/Developer/Private/hivetechs-website`

**Current .claude/ Structure**:
```
.claude/
├── AGENT_INTEGRATION_SUMMARY.md    # Last sync: 2025-10-08 12:23 PST
├── agents/                          # 31 agents (v1.1.0)
├── agents.backup.20251008/
├── agents.backup.20251008_121925/
├── statusline.sh
├── settings.local.json            # Local settings
├── statusline.log                  # 267,319 bytes
└── .mcp.json
```

**Integration Status**:
- ✅ Same as hive (31 agents, status line, MCP)
- ❌ Missing same 39 agents as hive
- ❌ Missing research/ and other new files

### 1.4 Diff Analysis

**Files in claude-pattern NOT in hive/hivetechs-website**:

1. **New Agents** (39 agents):
   - Phase 2 additions: django-specialist, kafka-specialist, elasticsearch-specialist, argocd-specialist, gitlab-cicd-specialist, vector-database-specialist, performance-testing-specialist

2. **Research Documentation**:
   - `agents/research/2025_TECHNOLOGY_UPDATES.md`

3. **Analysis Files**:
   - `agents/COVERAGE_GAP_ANALYSIS.md`
   - `agents/EXECUTION_SUMMARY.md`
   - `agents/EXPANSION_IMPLEMENTATION_COMPLETE.md`

4. **Utility Scripts**:
   - `agents/generate_agents.py`
   - `agents/verify_sdk_compliance.py`

5. **Enhanced Documentation**:
   - `agents/research-planning/system-architect/` (subdirectory with SDK enhancements)

**Files that DIFFER**:
- `agents/GENERATION_REPORT.md` (updated in claude-pattern)
- `settings.local.json` (project-specific, should NOT sync)
- `statusline.log` (project-specific, should NOT sync)

**Files ONLY in hive/hivetechs-website**:
- `agents.backup.*/` (project-specific backups)
- `statusline.log` (runtime logs)

---

## Part 2: Sync Architecture Design

### 2.1 Recommended Strategy: rsync with Selective Sync

**Why rsync?**
- ✅ Fast, incremental file synchronization
- ✅ Preserves timestamps and permissions
- ✅ Supports exclusion patterns (protect project-specific files)
- ✅ Dry-run mode for testing
- ✅ Simple, no git complexity
- ✅ Works across any directory structure

**Why NOT git submodules/subtrees?**
- ❌ Requires git repository in claude-pattern
- ❌ Complex merge conflicts
- ❌ Harder to understand for non-git users
- ❌ Bidirectional sync complexity
- ❌ Commit history pollution

**Why NOT symlinks?**
- ❌ Doesn't work across different projects
- ❌ Breaks if source moves
- ❌ No per-project customization

### 2.2 Sync Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    claude-pattern (Source)                       │
│  /Users/veronelazio/Developer/Private/claude-pattern/.claude/   │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐│
│  │ agents/ (70+ agents, SDK docs, research)                   ││
│  │ commands/ (slash commands)                                 ││
│  │ docs/ (integration guides)                                 ││
│  │ statusline.sh (status line script)                         ││
│  │ settings.json (base settings)                              ││
│  │ .mcp.json (MCP configuration)                              ││
│  └────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ rsync (selective)
                              ├────────────────────────┐
                              ▼                        ▼
┌──────────────────────────────────┐ ┌───────────────────────────────┐
│      hive (Target 1)              │ │  hivetechs-website (Target 2) │
│  .claude/                         │ │  .claude/                      │
│  ├── agents/ (sync from source)  │ │  ├── agents/ (sync from source)│
│  ├── commands/ (sync from source)│ │  ├── commands/ (sync)          │
│  ├── docs/ (sync from source)    │ │  ├── docs/ (sync)              │
│  ├── statusline.sh (sync)         │ │  ├── statusline.sh (sync)      │
│  ├── settings.json (sync)         │ │  ├── settings.json (sync)      │
│  ├── .mcp.json (sync)             │ │  ├── .mcp.json (sync)          │
│  ├── settings.local.json (KEEP)  │ │  ├── settings.local.json (KEEP)│
│  ├── statusline.log (KEEP)        │ │  ├── statusline.log (KEEP)     │
│  └── agents.backup.*/ (KEEP)     │ │  └── agents.backup.*/ (KEEP)   │
└──────────────────────────────────┘ └───────────────────────────────┘
```

### 2.3 Sync Rules

**ALWAYS Sync** (from claude-pattern to target projects):
1. `agents/` directory (all subdirectories and files)
2. `commands/` directory
3. `docs/` directory
4. `statusline.sh` script
5. `settings.json` base settings
6. `.mcp.json` MCP configuration
7. `outputs/` directory structure (empty, for consistency)

**NEVER Sync** (protect project-specific files):
1. `settings.local.json` (project-specific permissions, paths)
2. `statusline.log` (runtime logs)
3. `agents.backup.*/` directories (project-specific backups)
4. `outputs/*/` filled content (project-specific outputs)
5. `.env*` files (if present)

**MERGE Strategy** (if conflicts):
- Default: **Source wins** (claude-pattern overwrites target)
- Exception: User manually edited files (requires `--interactive` flag)

### 2.4 Bidirectional Sync Considerations

**Use Case**: User improves an agent in `hive`, wants to push back to `claude-pattern`

**Strategy**: Manual review process
1. User identifies improved agent file in `hive/.claude/agents/`
2. User copies file to `claude-pattern/.claude/agents/`
3. User reviews diff in claude-pattern
4. User commits to claude-pattern if valuable
5. Next sync propagates improvement to all projects

**Why Manual?**
- ✅ Prevents accidental overwrites
- ✅ Allows quality review before propagating
- ✅ Avoids merge conflicts
- ✅ Simple, explicit process

**Automation Possibility** (future):
- Script to detect modified agents in target projects
- Prompt user: "Agent X modified in hive. Sync back to claude-pattern?"
- Copy file and show diff
- User approves or rejects

---

## Part 3: Implementation

### 3.1 Initial Setup Script

**File**: `/Users/veronelazio/Developer/Private/claude-pattern/.claude/scripts/setup-new-project.sh`

```bash
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
  exit 1
fi

echo "🚀 Setting up claude-pattern in $1"

# Create .claude directory
mkdir -p "$TARGET_DIR"

# Sync all syncable files
rsync -av --exclude='settings.local.json' \
          --exclude='statusline.log' \
          --exclude='agents.backup.*' \
          --exclude='outputs/*/*.md' \
          "$SOURCE_DIR/" "$TARGET_DIR/"

echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "1. Create $TARGET_DIR/settings.local.json with project-specific settings"
echo "2. Test status line: cd $1 && .claude/statusline.sh"
echo "3. Verify agents: ls $TARGET_DIR/agents/"
echo "4. Start using agents in Claude Code"
