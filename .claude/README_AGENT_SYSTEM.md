# Agent Configuration System - Complete Guide

**Created**: 2025-10-23
**Status**: Production Ready
**Purpose**: Eliminate 16k token warnings while maintaining agent flexibility

---

## 🎯 Problem Solved

**Before**: Loading 17 agents globally caused ~16k token warning in every Claude Code session
**After**: Hub-and-spoke architecture with project-specific agent sets reduces tokens by 43-100%

**Impact**:
- Global: 17 agents (16k tokens) → 0 agents (0 tokens) = 100% reduction
- Hive: 17 agents (16k tokens) → 12 agents (9k tokens) = 43% reduction
- Other projects: Configure only what's needed (typically 3-10 agents)

---

## 📁 Documentation Structure

All documentation is in `/Users/veronelazio/Developer/Private/claude-pattern/.claude/`:

### Quick Start (Read This First)
**QUICK_START_AGENT_CONFIG.md** (180 lines)
- 5-command migration in 10 minutes
- Copy-paste config snippets
- Verification checklist

### Migration Guide (Detailed Steps)
**AGENT_MIGRATION_GUIDE.md** (380 lines)
- Step-by-step migration (6 phases)
- Troubleshooting section
- Rollback instructions
- Token budget guidelines

### Architecture Reference
**AGENT_CONFIGURATION_ARCHITECTURE.md** (280 lines)
- Hub-and-spoke design pattern
- Configuration hierarchy
- Best practices
- Future enhancements

### Implementation Summary
**AGENT_CONFIG_SUMMARY.md** (This file)
- What was created
- Quick reference
- Success metrics

---

## 🚀 Quick Migration (10 Minutes)

```bash
# Step 1: Backup current configs
cp ~/.claude/settings.json ~/.claude/settings.json.backup
cp ~/Developer/Private/hive/.claude/settings.local.json \
   ~/Developer/Private/hive/.claude/settings.local.json.backup

# Step 2: Create symlink to pattern repo
rm -rf ~/.claude/agents
ln -s /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents \
      ~/.claude/agents

# Step 3: Clear global agents (manual edit)
# Edit ~/.claude/settings.json
# Change: "agentDescriptions": { "enabled": [] }

# Step 4: Configure Hive project (manual edit)
# Edit ~/Developer/Private/hive/.claude/settings.local.json
# Add agent list from agent-sets/hive-core.json

# Step 5: Restart Claude Code
# Quit completely (Cmd+Q) and reopen
```

**See**: `QUICK_START_AGENT_CONFIG.md` for detailed config snippets

---

## 📦 Agent Sets (Pre-Defined Collections)

Located in `.claude/agent-sets/`:

### Core Development Sets

| File | Agents | Tokens | Use Case |
|------|--------|--------|----------|
| **core.json** | 7 | ~4k | Essential agents for any project |
| **electron.json** | 8 | ~5k | Electron desktop apps |
| **rust.json** | 6 | ~4k | Rust backend development |
| **web-fullstack.json** | 10 | ~6k | Next.js/React web apps |
| **database.json** | 5 | ~3k | Database optimization |

### Specialized Sets

| File | Agents | Tokens | Use Case |
|------|--------|--------|----------|
| **hive-core.json** | 12 | ~9k | Hive Consensus (Electron + Rust + Release) |
| **release-pipeline.json** | 5 | ~3.5k | macOS release automation |
| **cloud.json** | 6 | ~4k | AWS/GCP/Azure infrastructure |
| **observability.json** | 4 | ~3k | Monitoring and logging |

### Custom Sets
Create your own in `agent-sets/custom/` - see `custom/README.md`

---

## 🛠️ Agent Manager CLI

**Location**: `.claude/scripts/agent-manager.sh`

### Installation (Create Alias)

```bash
# Add to ~/.zshrc or ~/.bashrc
alias agents='/Users/veronelazio/Developer/Private/claude-pattern/.claude/scripts/agent-manager.sh'

# Reload shell
source ~/.zshrc
```

### Usage

```bash
# List all available agent sets
agents list

# Show details of a specific set
agents show hive-core

# Generate config snippet for a set
agents config rust

# Merge multiple sets (deduplicates)
agents merge electron rust

# Check current project configuration
agents check

# Verify global symlink setup
agents verify

# Create custom agent set
agents create my-workflow
```

### Example Output

```bash
$ agents list

═══════════════════════════════════════════════════════
  Claude Code Agent Configuration Manager
═══════════════════════════════════════════════════════

Available Agent Sets:

hive-core (12 agents, ~9000 tokens)
  Hive Consensus development (Electron + Rust + Release)

rust (6 agents, ~4000 tokens)
  Rust backend development and systems programming

# ... etc
```

---

## 📊 Architecture Overview

### Hub-and-Spoke Pattern

```
Pattern Repository (Hub)
└── /Users/veronelazio/Developer/Private/claude-pattern
    └── .claude/agents/ (174 agents - single source of truth)

Global Config (Symlinked)
└── ~/.claude/
    ├── agents/ → symlink to pattern repo
    └── settings.json (0 agents enabled)

Projects (Spokes)
├── hive/
│   └── .claude/settings.local.json (12 agents from hive-core.json)
├── rust-project/
│   └── .claude/settings.local.json (6 agents from rust.json)
└── web-app/
    └── .claude/settings.local.json (10 agents from web-fullstack.json)
```

### Benefits

1. **Single Source of Truth**: Pattern repo is master, no duplication
2. **Zero Global Bloat**: Global config has 0 agents enabled
3. **Per-Project Optimization**: Each project loads only what it needs
4. **Easy Maintenance**: Update agents once in pattern repo
5. **Flexible Switching**: Change agent sets in seconds
6. **Token Efficiency**: 43-100% token reduction

---

## 📋 Configuration Examples

### Global Config (`~/.claude/settings.json`)

**Keep this minimal** (0 agents enabled):

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "alwaysThinkingEnabled": true,
  "memory": {
    "autoImport": ["~/.claude/CLAUDE.md"]
  },
  "agentDescriptions": {
    "enabled": []
  }
}
```

### Hive Project Config

**File**: `~/Developer/Private/hive/.claude/settings.local.json`

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

**Result**: 12 agents, ~9k tokens (optimized for Hive workflow)

### Rust Project Config

**For a Rust backend microservice**:

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

**Result**: 6 agents, ~4k tokens

### Web App Project Config

**For a Next.js/React application**:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "agentDescriptions": {
    "enabled": [
      "nextjs-expert",
      "react-typescript-specialist",
      "nodejs-specialist",
      "database-expert",
      "api-expert",
      "shadcn-expert",
      "observability-specialist",
      "security-expert",
      "git-expert"
    ]
  }
}
```

**Result**: 9 agents, ~6k tokens

---

## 🎯 Token Budget Guidelines

| Agents | Tokens | Status | Recommendation |
|--------|--------|--------|----------------|
| 0-7    | 0-4k   | ✅ Optimal | Small focused projects |
| 8-12   | 5-9k   | ✅ Good | Medium projects (Hive) |
| 13-15  | 10-12k | ⚠️ High | Large multi-tech projects |
| 16+    | 13k+   | 🚫 Bloat | Reduce agents (causes warning) |

**Rule**: Stay under 15k tokens (~12 agents max per project)

**Estimate**: ~750 tokens per agent (average)

---

## ✅ Verification Checklist

After migration, verify:

```bash
# 1. Check symlink exists
ls -la ~/.claude/agents
# Should show: agents -> /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents

# 2. Verify global config is clean
cat ~/.claude/settings.json | jq '.agentDescriptions.enabled | length'
# Should show: 0

# 3. Verify Hive config
cd ~/Developer/Private/hive
cat .claude/settings.local.json | jq '.agentDescriptions.enabled | length'
# Should show: 12

# 4. Test in Claude Code
# Open Hive project in Claude Code
# Type: @electron-specialist
# Should autocomplete correctly

# 5. Check for warnings
# No "16k token warning" should appear
```

---

## 🔧 Troubleshooting

### Issue: "Agent not found"

**Symptom**: `@agent-name` doesn't autocomplete

**Fix**:
```bash
# Check symlink
ls -la ~/.claude/agents

# If missing or broken:
rm -rf ~/.claude/agents
ln -s /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents ~/.claude/agents

# Restart Claude Code
```

### Issue: "Token warning still appears"

**Symptom**: Warning persists after config change

**Fix**:
1. Verify global config: `cat ~/.claude/settings.json | jq '.agentDescriptions.enabled'`
2. Should be empty array: `[]`
3. Completely quit Claude Code (Cmd+Q)
4. Reopen project

### Issue: "Agents seem slow"

**Symptom**: Agent invocations are slower

**Cause**: Not related to symlink (symlinks are instant on macOS)

**Check**:
- Network connection to Claude API
- System resources (CPU/memory)
- Claude Code version (update if needed)

### Issue: "Can't find specific agent"

**Fix**:
```bash
# Search for agent in pattern repo
find ~/Developer/Private/claude-pattern/.claude/agents -name "*agent-name*"

# If not found, agent may not exist or name is different
# Check AGENT_INTEGRATION_SUMMARY.md for complete list
```

---

## 🚀 Advanced Usage

### Dynamic Agent Loading

**Scenario**: Temporarily add agents for specific tasks

**Example**: Add `homebrew-publisher` only during release work

```json
{
  "agentDescriptions": {
    "enabled": [
      "orchestrator",
      "git-expert",
      "homebrew-publisher"  // ← Temporary
    ]
  }
}
```

**After release**: Remove temporary agent to reduce tokens

### Merging Agent Sets

**Scenario**: Combine Electron + Rust for hybrid project

```bash
# Generate merged config
agents merge electron rust

# Copy output to project's settings.local.json
```

**Result**: Deduplicated list of all agents from both sets

### Creating Custom Sets

**Scenario**: Define your own workflow

```bash
# Create custom set
agents create my-rust-cloudflare

# Edit the generated JSON
vim ~/.claude/agent-sets/custom/my-rust-cloudflare.json
```

**Example**:
```json
{
  "name": "my-rust-cloudflare",
  "description": "Rust backend with Cloudflare Workers",
  "agents": [
    "rust-backend-specialist",
    "cloudflare-expert",
    "database-expert",
    "security-expert",
    "performance-testing-specialist"
  ],
  "estimatedTokens": 3500
}
```

---

## 📚 Complete File Reference

### Documentation
- **README_AGENT_SYSTEM.md** (this file) - Complete guide
- **QUICK_START_AGENT_CONFIG.md** - 10-minute quick start
- **AGENT_MIGRATION_GUIDE.md** - Detailed migration steps
- **AGENT_CONFIGURATION_ARCHITECTURE.md** - System design
- **AGENT_CONFIG_SUMMARY.md** - Implementation summary

### Agent Sets
- **agent-sets/README.md** - Agent set documentation
- **agent-sets/*.json** - 9 pre-defined sets
- **agent-sets/custom/README.md** - Custom set guide

### Tools
- **scripts/agent-manager.sh** - CLI management tool

### Integration
- **AGENT_INTEGRATION_SUMMARY.md** - Complete list of 174 agents

---

## 🎓 Best Practices

### 1. Keep Global Config Clean
- **Never** enable agents in `~/.claude/settings.json`
- **Always** use project-specific `settings.local.json`
- **Reason**: Prevents token bloat across all projects

### 2. Enable Only What You Need
- Review weekly: which agents did you actually use?
- Remove unused agents immediately
- Add specialists only when working on that tech

### 3. Use Agent Sets as Templates
- Start with a pre-defined set (e.g., `hive-core.json`)
- Customize based on actual usage
- Create custom sets for recurring workflows

### 4. Monitor Token Usage
- Stay under 12 agents per project (~9k tokens)
- Use `agents check` to see current configuration
- Adjust if approaching 15k token limit

### 5. Maintain the Pattern Repo
- Pattern repo is single source of truth
- Update agents there, not in project directories
- Symlink ensures all projects get updates

---

## 📊 Success Metrics

After migration, you should see:

- ✅ **No token warnings**: No "16k token warning" in any project
- ✅ **Clean global config**: 0 agents enabled globally
- ✅ **Optimized projects**: 3-12 agents per project
- ✅ **Working agents**: All agents autocomplete with `@`
- ✅ **Single source**: Pattern repo is master
- ✅ **Easy updates**: Edit agents once, available everywhere
- ✅ **Flexible switching**: Change sets in seconds

**Token Reduction**:
- Global: 100% (16k → 0k)
- Hive: 43% (16k → 9k)
- Other projects: Configurable (typically 3-7k)

---

## 🔄 Maintenance

### Weekly Review
1. Check which agents you actually used
2. Remove unused agents from project configs
3. Update custom sets based on patterns

### Monthly Update
1. Pull latest agent updates from pattern repo
2. Review new agents added to library
3. Consider new agent sets for workflows

### Quarterly Audit
1. Review all project configurations
2. Consolidate similar agent sets
3. Share useful custom sets to main library

---

## 🚀 Next Steps

1. **Quick Start** (10 min): Read `QUICK_START_AGENT_CONFIG.md`
2. **Migrate** (10 min): Follow 5-command migration
3. **Verify** (5 min): Test in Hive project
4. **Optimize** (ongoing): Adjust agents based on usage
5. **Create** (optional): Define custom sets for your workflows

---

## 📞 Support

**Documentation Issues**:
- Check troubleshooting sections
- Review `AGENT_MIGRATION_GUIDE.md` for detailed steps
- Verify symlink setup with `agents verify`

**Agent Issues**:
- See `AGENT_INTEGRATION_SUMMARY.md` for complete agent list
- Check agent exists in pattern repo
- Verify agent name spelling

**Configuration Help**:
- Use `agents check` to see current config
- Use `agents show <set-name>` for set details
- Compare your config with examples in this guide

---

**Ready to migrate?** Start with `QUICK_START_AGENT_CONFIG.md`

**Questions?** Review `AGENT_MIGRATION_GUIDE.md` troubleshooting section

**Success!** Enjoy your optimized agent configuration with 43-100% token reduction
