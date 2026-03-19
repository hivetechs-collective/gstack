# Claude Code Agent Switcher - Quick Reference Guide

**Created**: 2025-10-23
**For**: Multi-project agent configuration management

## 🎯 What This Does

Easily switch between different Claude Code agent configurations for different projects without manually editing JSON files.

## 📋 Available Commands

### List All Agent Sets
```bash
agents-list
```
Shows all available agent sets (standard and custom) with token counts and descriptions.

### Show Detailed Info
```bash
agents-show <set-name>
```
Display detailed information about a specific agent set including all agents and notes.

**Examples**:
```bash
agents-show hive-core          # Hive Consensus agents
agents-show hivetechs-website  # Website agents
agents-show rust               # Rust development agents
```

### Switch Agent Sets
```bash
agents-switch <set-name>
```
Switch to a different agent set. Automatically:
- Backs up current settings
- Updates `~/.claude/settings.json`
- Shows what changed

**Examples**:
```bash
agents-switch hive-core          # Switch to Hive agents (12 agents, ~9k tokens)
agents-switch hivetechs-website  # Switch to website agents (12 agents, ~9k tokens)
agents-switch rust               # Switch to Rust agents (6 agents, ~4k tokens)
```

**⚠️ Important**: You must **restart Claude Code** after switching for changes to take effect.

### Check Current Configuration
```bash
agents-current
```
Shows currently enabled agents and total count.

### Quick Shortcuts
```bash
agents-hive     # Quick switch to hive-core
agents-website  # Quick switch to hivetechs-website
```

## 📁 Available Agent Sets

### Standard Sets (9)
Located at: `~/.claude/agents/../agent-sets/`

1. **core** (7 agents, ~4k tokens) - Essential agents for any project
2. **hive-core** (12 agents, ~9k tokens) - Hive Consensus (Electron + Rust + Release)
3. **rust** (6 agents, ~4k tokens) - Rust backend development
4. **electron** (8 agents, ~5k tokens) - Electron desktop apps
5. **web-fullstack** (10 agents, ~6k tokens) - Next.js/React web apps
6. **database** (5 agents, ~3k tokens) - Database design and optimization
7. **cloud** (6 agents, ~4k tokens) - Cloud infrastructure and DevOps
8. **observability** (4 agents, ~3k tokens) - Monitoring and logging
9. **release-pipeline** (5 agents, ~3.5k tokens) - macOS build and release

### Custom Sets (1)
Located at: `~/.claude/agents/../agent-sets/custom/`

1. **hivetechs-website** (12 agents, ~9k tokens) - Next.js + Cloudflare + D1 + Paddle

## 🔧 How It Works

### Architecture
```
Pattern Repository (Hub)
└── /Users/veronelazio/Developer/Private/claude-pattern
    ├── .claude/agents/ (174 agents - symlinked to ~/.claude/agents)
    ├── .claude/agent-sets/ (9 standard sets)
    ├── .claude/agent-sets/custom/ (custom sets)
    └── .claude/scripts/agent-switcher.sh (this tool)

Global Settings
└── ~/.claude/settings.json
    └── agentDescriptions.enabled: [] (updated by switcher)
```

### Workflow
1. Pattern repo contains ALL agents (single source of truth)
2. Agent sets define collections for specific use cases
3. Switcher updates global settings.json with selected set
4. Restart Claude Code to apply changes

## 🚀 Daily Usage Examples

### Working on Hive Desktop App
```bash
cd ~/Developer/Private/hive
agents-hive              # Switch to Hive agents
# Restart Claude Code
```

### Working on HiveTechs Website
```bash
cd ~/Developer/Private/hivetechs-website
agents-website           # Switch to website agents
# Restart Claude Code
```

### Quick Rust Project
```bash
cd ~/projects/my-rust-api
agents-switch rust       # Switch to Rust agents (only 6 agents, ~4k tokens)
# Restart Claude Code
```

### Check What's Currently Active
```bash
agents-current           # See current configuration
```

## 📊 Token Budget Management

Claude Code warns when agent descriptions exceed 15k tokens. Here are the token counts:

| Agent Set | Agents | Tokens | Use Case |
|-----------|--------|--------|----------|
| core | 7 | ~4k | Minimal, any project |
| rust | 6 | ~4k | Rust development |
| database | 5 | ~3k | Database work |
| observability | 4 | ~3k | Monitoring |
| release-pipeline | 5 | ~3.5k | macOS releases |
| cloud | 6 | ~4k | Cloud infrastructure |
| electron | 8 | ~5k | Electron apps |
| web-fullstack | 10 | ~6k | Web applications |
| **hive-core** | **12** | **~9k** | **Hive desktop app** |
| **hivetechs-website** | **12** | **~9k** | **Website development** |

**Recommendation**: Stay under 12 agents (~9k tokens) for optimal performance.

## 🛠️ Creating Custom Agent Sets

1. Create JSON file in custom directory:
   ```bash
   vi ~/Developer/Private/claude-pattern/.claude/agent-sets/custom/my-project.json
   ```

2. Use this template:
   ```json
   {
     "name": "my-project",
     "description": "Brief description of project type",
     "agents": [
       "agent-1",
       "agent-2",
       "agent-3"
     ],
     "estimatedTokens": 6000,
     "categories": {
       "coordination": [],
       "implementation": ["agent-1"],
       "research-planning": ["agent-2", "agent-3"]
     },
     "notes": "Detailed notes about when to use this set"
   }
   ```

3. Test it:
   ```bash
   agents-show my-project
   agents-switch my-project
   ```

## 🔄 Updating Agent Sets

Agent sets are just JSON files. You can edit them directly:
```bash
vi ~/Developer/Private/claude-pattern/.claude/agent-sets/custom/hivetechs-website.json
```

Changes take effect next time you run `agents-switch`.

## 🆘 Troubleshooting

### Commands Not Found
```bash
# Reload your shell configuration
source ~/.zshrc

# Or open a new terminal window
```

### Changes Not Applied
- Did you restart Claude Code after switching?
- Check current config: `agents-current`
- Verify settings file: `cat ~/.claude/settings.json | jq .agentDescriptions`

### Backup and Restore
Every switch creates a backup:
```bash
ls -la ~/.claude/settings.json.backup.*
```

To restore:
```bash
cp ~/.claude/settings.json.backup.20251023-204530 ~/.claude/settings.json
```

## 📚 Related Documentation

- **Complete System Guide**: `~/Developer/Private/claude-pattern/.claude/README_AGENT_SYSTEM.md`
- **Migration Guide**: `~/Developer/Private/claude-pattern/.claude/QUICK_START_AGENT_CONFIG.md`
- **Agent Descriptions**: `~/Developer/Private/claude-pattern/.claude/agents/`
- **Pattern Repo**: `~/Developer/Private/claude-pattern/`

---

**Pro Tip**: Add `agents-current` to your shell prompt to always see which agent set is active!
