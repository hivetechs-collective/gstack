# Agent Configuration Architecture

**Last Updated**: 2025-10-23
**Version**: 1.0.0

## Overview

This document defines the hub-and-spoke architecture for organizing 174+ Claude Code agents across multiple projects while avoiding token bloat.

## Architecture Philosophy

1. **Pattern Repository = Single Source of Truth**: All agent definitions live in `/Developer/Private/claude-pattern/.claude/agents/`
2. **Agent Sets = Curated Collections**: Pre-defined groups of agents for common workflows
3. **Project Configs = Lightweight References**: Projects enable only what they need via agent sets
4. **Global Config = Minimal**: No agents enabled globally to avoid token bloat

## Directory Structure

```
claude-pattern/
├── .claude/
│   ├── agents/                          # 174 agent definitions (source of truth)
│   │   ├── coordination/                # 18 agents
│   │   ├── implementation/              # 20 agents
│   │   ├── research-planning/           # 131 agents
│   │   └── hive/                        # 4 agents
│   ├── agent-sets/                      # NEW: Curated collections
│   │   ├── README.md                    # Documentation
│   │   ├── core.json                    # Essential 5-7 agents
│   │   ├── electron.json                # Electron development (8 agents)
│   │   ├── rust.json                    # Rust development (6 agents)
│   │   ├── release-pipeline.json        # Release automation (5 agents)
│   │   ├── hive-core.json               # Hive-specific (12 agents)
│   │   ├── web-fullstack.json           # Web development (10 agents)
│   │   ├── database.json                # Database work (5 agents)
│   │   └── custom/                      # User-defined sets
│   └── settings.json                    # Minimal global config
│
~/.claude/
└── settings.json                         # NO agents enabled (references pattern repo)
│
project-name/
└── .claude/
    └── settings.local.json               # Imports agent sets by reference
```

## Agent Set Design

### Core Sets (High Usage)

**core.json** (~5-7 agents, ~3-4k tokens):
- orchestrator
- system-architect
- security-expert
- code-review-expert
- documentation-expert
- git-expert
- mcp-expert

**electron.json** (~8 agents, ~5k tokens):
- electron-specialist
- nodejs-specialist
- react-typescript-specialist
- database-expert
- security-expert
- api-expert
- documentation-expert
- git-expert

**rust.json** (~6 agents, ~4k tokens):
- rust-backend-specialist
- system-architect
- performance-testing-specialist
- database-expert
- security-expert
- code-review-expert

**release-pipeline.json** (~5 agents, ~3-4k tokens):
- release-orchestrator
- macos-signing-expert
- homebrew-publisher
- git-expert
- documentation-expert

**hive-core.json** (~12 agents, ~8-9k tokens):
- orchestrator
- electron-specialist
- rust-backend-specialist
- release-orchestrator
- macos-signing-expert
- homebrew-publisher
- nodejs-specialist
- database-expert
- git-expert
- security-expert
- api-expert
- documentation-expert

### Specialized Sets (On-Demand)

**web-fullstack.json**:
- nextjs-expert
- react-typescript-specialist
- nodejs-specialist
- database-expert
- api-expert
- docker-advanced-specialist
- observability-specialist

**database.json**:
- database-expert
- mongodb-specialist
- redis-specialist
- vector-database-specialist
- snowflake-specialist

**cloud.json**:
- aws-specialist
- gcp-specialist
- azure-specialist
- cloudflare-expert
- terraform-specialist

## Configuration Hierarchy

### 1. Global Config (`~/.claude/settings.json`)

**Purpose**: Minimal settings, NO agents enabled
**Token Impact**: ~0 tokens from agents

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "alwaysThinkingEnabled": true,
  "memory": {
    "autoImport": [
      "~/.claude/CLAUDE.md"
    ]
  },
  "agentDescriptions": {
    "enabled": []
  }
}
```

### 2. Pattern Repository Settings (`claude-pattern/.claude/settings.json`)

**Purpose**: Status line, global behaviors, NO agents
**Token Impact**: ~0 tokens from agents

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "statusLine": {
    "type": "command",
    "command": ".claude/statusline.sh",
    "padding": 0
  },
  "agentDescriptions": {
    "enabled": []
  }
}
```

### 3. Project Settings (`project/.claude/settings.local.json`)

**Purpose**: Enable project-specific agent sets
**Token Impact**: 3-12k tokens depending on set

**Example for Hive Project**:
```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "agentDescriptions": {
    "enabled": [
      "orchestrator",
      "electron-specialist",
      "rust-backend-specialist",
      "release-orchestrator",
      "macos-signing-expert",
      "homebrew-publisher",
      "nodejs-specialist",
      "database-expert",
      "git-expert",
      "security-expert",
      "api-expert",
      "documentation-expert"
    ]
  },
  "statusLine": {
    "type": "command",
    "command": ".claude/statusline.sh",
    "padding": 0
  }
}
```

**Example for Rust-Only Project**:
```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "agentDescriptions": {
    "enabled": [
      "rust-backend-specialist",
      "system-architect",
      "performance-testing-specialist",
      "database-expert",
      "security-expert",
      "code-review-expert"
    ]
  }
}
```

## Agent Discovery Workflow

Claude Code loads agents in this order:

1. **Checks project config** (`.claude/settings.local.json`)
   - If `agentDescriptions.enabled` exists, load those agents
2. **Falls back to global config** (`~/.claude/settings.json`)
   - If `agentDescriptions.enabled` exists, load those agents
3. **Searches for agent files** in both:
   - Project `.claude/agents/` directory
   - Global `~/.claude/agents/` directory

**Important**: Agent files must exist at one of these paths:
- `/Users/veronelazio/.claude/agents/{category}/{agent-name}.md`
- `/Users/veronelazio/Developer/Private/{project}/.claude/agents/{category}/{agent-name}.md`

## Migration Strategy

### Phase 1: Clean Up Global Config (Immediate)

Remove all agents from `~/.claude/settings.json`:

```json
{
  "agentDescriptions": {
    "enabled": []
  }
}
```

**Result**: 16k token warning disappears immediately

### Phase 2: Symlink Pattern Agents to Global (Recommended)

Create symlink so agents are discoverable:

```bash
# Backup existing agents
mv ~/.claude/agents ~/.claude/agents.backup

# Symlink to pattern repository
ln -s /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents ~/.claude/agents

# Verify
ls -la ~/.claude/agents
```

**Benefits**:
- Single source of truth (pattern repo)
- No duplication
- Easy updates (edit in pattern repo, available everywhere)
- Projects can reference agents by name

### Phase 3: Configure Projects (Per-Project)

For each project, create `.claude/settings.local.json` with only needed agents:

**Hive Project** (12 agents, ~9k tokens):
```json
{
  "agentDescriptions": {
    "enabled": [
      "orchestrator",
      "electron-specialist",
      "rust-backend-specialist",
      "release-orchestrator",
      "macos-signing-expert",
      "homebrew-publisher",
      "nodejs-specialist",
      "database-expert",
      "git-expert",
      "security-expert",
      "api-expert",
      "documentation-expert"
    ]
  }
}
```

**Rust Microservice Project** (6 agents, ~4k tokens):
```json
{
  "agentDescriptions": {
    "enabled": [
      "rust-backend-specialist",
      "system-architect",
      "database-expert",
      "security-expert",
      "code-review-expert",
      "git-expert"
    ]
  }
}
```

### Phase 4: Create Agent Sets (Optional Enhancement)

Create `claude-pattern/.claude/agent-sets/` with JSON files for quick reference:

**agent-sets/hive-core.json**:
```json
{
  "name": "hive-core",
  "description": "Hive Consensus development (Electron + Rust + Release)",
  "agents": [
    "orchestrator",
    "electron-specialist",
    "rust-backend-specialist",
    "release-orchestrator",
    "macos-signing-expert",
    "homebrew-publisher",
    "nodejs-specialist",
    "database-expert",
    "git-expert",
    "security-expert",
    "api-expert",
    "documentation-expert"
  ],
  "estimatedTokens": 9000
}
```

Then reference in project:
```bash
# Copy agent list from set to project config
cat claude-pattern/.claude/agent-sets/hive-core.json | jq '.agents'
```

## Token Budget Guidelines

| Agent Count | Estimated Tokens | Use Case |
|-------------|------------------|----------|
| 0 agents    | 0                | Pattern repo, minimal projects |
| 5-7 agents  | 3-4k             | Small focused projects |
| 8-10 agents | 5-7k             | Medium projects |
| 12-15 agents| 9-12k            | Large multi-tech projects (Hive) |
| 17+ agents  | 13-16k           | ⚠️ Token bloat territory |

**Rule of Thumb**: Stay under 15k tokens (~12 agents max per project)

## Best Practices

### 1. Agent Selection Strategy

**Ask**: "What technologies am I actively working with?"
- Electron app? → electron-specialist, nodejs-specialist
- Rust backend? → rust-backend-specialist, system-architect
- Release pipeline? → release-orchestrator, macos-signing-expert
- Database work? → database-expert

**Don't enable**:
- Agents for technologies you're not using (e.g., kubernetes-specialist for desktop app)
- Redundant specialists (e.g., both nextjs-expert and react-typescript-specialist unless needed)
- Research agents unless actively researching (e.g., openrouter-expert)

### 2. Dynamic Agent Loading

**When working on specific features**, temporarily add agents:

```json
{
  "agentDescriptions": {
    "enabled": [
      // Core agents always enabled
      "orchestrator",
      "git-expert",

      // Temporarily for Homebrew work
      "homebrew-publisher",

      // Temporarily for signing debugging
      "macos-signing-expert"
    ]
  }
}
```

**After feature complete**, remove temporary agents:

```json
{
  "agentDescriptions": {
    "enabled": [
      "orchestrator",
      "git-expert"
    ]
  }
}
```

### 3. Symlink vs Copy

**Recommended: Symlink**
- `ln -s /path/to/pattern/.claude/agents ~/.claude/agents`
- Single source of truth
- Automatic updates

**When to Copy**:
- Project-specific agent customizations
- Testing agent modifications
- Offline/disconnected environments

### 4. Agent Set Curation

Create sets for YOUR workflows:

```bash
claude-pattern/.claude/agent-sets/
├── my-rust-workflow.json       # Your custom Rust setup
├── my-electron-workflow.json   # Your custom Electron setup
└── my-release-workflow.json    # Your custom release process
```

## Troubleshooting

### "Agent not found" Error

**Symptom**: `@agent-name` doesn't autocomplete or work

**Fix**: Ensure agent exists at:
- `~/.claude/agents/{category}/{agent-name}.md`, OR
- `{project}/.claude/agents/{category}/{agent-name}.md`

**Verify**:
```bash
# Check global agents
ls ~/.claude/agents/*/*.md | grep agent-name

# Check project agents
ls ./.claude/agents/*/*.md | grep agent-name
```

### "Token warning still appears"

**Symptom**: Warning after reducing agents

**Fix**: Restart Claude Code session
- Close current session
- Reopen project
- Config changes apply on new session start

### "Agents not loading from pattern repo"

**Symptom**: Pattern repo agents not discovered

**Fix**: Create symlink
```bash
ln -s /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents ~/.claude/agents
```

## Advanced: Multi-Project Workflow

### Scenario: Working on 3 projects simultaneously

**Project A** (Hive - Electron):
```json
{
  "agentDescriptions": {
    "enabled": ["orchestrator", "electron-specialist", "rust-backend-specialist"]
  }
}
```

**Project B** (Rust Microservice):
```json
{
  "agentDescriptions": {
    "enabled": ["rust-backend-specialist", "database-expert", "security-expert"]
  }
}
```

**Project C** (Next.js App):
```json
{
  "agentDescriptions": {
    "enabled": ["nextjs-expert", "react-typescript-specialist", "api-expert"]
  }
}
```

**Result**: Each project loads only 3-5 agents (~2-4k tokens), no global bloat

## Maintenance

### Monthly Review

1. **Check agent usage**: Which agents did you actually use?
2. **Update sets**: Add frequently used agents, remove unused
3. **Sync pattern repo**: Pull latest agent updates
4. **Audit token usage**: Ensure projects stay under 15k tokens

### Agent Updates

When pattern repo agents are updated:

```bash
cd /Users/veronelazio/Developer/Private/claude-pattern
git pull origin main

# Symlinked agents auto-update
# Copied agents need manual refresh
```

## Future Enhancements

**Potential improvements** (not yet implemented):

1. **Agent set JSON files**: Pre-defined collections in `agent-sets/`
2. **CLI tool**: `claude-agent-manager` to manage sets
3. **Auto-detection**: Detect project tech and suggest agent sets
4. **Token calculator**: Estimate token usage before enabling
5. **Agent analytics**: Track which agents provide most value

## References

- **Pattern Repository**: `/Users/veronelazio/Developer/Private/claude-pattern`
- **Global Config**: `~/.claude/settings.json`
- **Project Config Example**: `/Users/veronelazio/Developer/Private/hive/.claude/settings.local.json`
- **Agent Integration Summary**: `claude-pattern/.claude/AGENT_INTEGRATION_SUMMARY.md`
