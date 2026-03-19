# Quick Start: Agent Configuration

**Problem**: Loading 17+ agents globally causes 16k token warning
**Solution**: Use hub-and-spoke architecture with agent sets
**Time**: 10 minutes to migrate

## 🚀 Quick Migration (5 Commands)

```bash
# 1. Backup current configs
cp ~/.claude/settings.json ~/.claude/settings.json.backup
cp ~/Developer/Private/hive/.claude/settings.local.json ~/Developer/Private/hive/.claude/settings.local.json.backup

# 2. Create symlink to pattern repo agents
rm -rf ~/.claude/agents
ln -s /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents ~/.claude/agents

# 3. Clear global config agents (edit manually)
# Set "agentDescriptions": { "enabled": [] } in ~/.claude/settings.json

# 4. Configure Hive project (copy from agent-sets/hive-core.json)
# See "Agent Set for Hive" section below

# 5. Restart Claude Code
# Close completely and reopen
```

**Result**: 16k token warning disappears, agents still work via symlink.

---

## 📋 Agent Set for Hive

**File**: `~/Developer/Private/hive/.claude/settings.local.json`

Add this section (merge with existing settings):

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
  }
}
```

**Token Impact**: 12 agents = ~9k tokens (was 16k with 17 agents globally)

---

## 🛠️ Using the Agent Manager

```bash
# From anywhere
~/Developer/Private/claude-pattern/.claude/scripts/agent-manager.sh

# Common commands
./scripts/agent-manager.sh list             # List all sets
./scripts/agent-manager.sh show hive-core   # Show hive-core details
./scripts/agent-manager.sh config rust      # Generate rust config
./scripts/agent-manager.sh check            # Check current config
./scripts/agent-manager.sh verify           # Verify symlink setup
```

**Or create a shell alias**:

```bash
# Add to ~/.zshrc or ~/.bashrc
alias agents='~/Developer/Private/claude-pattern/.claude/scripts/agent-manager.sh'

# Then use:
agents list
agents show hive-core
agents config rust
```

---

## 📦 Available Agent Sets

| Set | Agents | Tokens | Use Case |
|-----|--------|--------|----------|
| **core** | 7 | ~4k | Essential agents for any project |
| **hive-core** | 12 | ~9k | Hive Consensus (Electron + Rust + Release) |
| **electron** | 8 | ~5k | Electron desktop apps |
| **rust** | 6 | ~4k | Rust backend development |
| **release-pipeline** | 5 | ~3.5k | macOS release automation |
| **web-fullstack** | 10 | ~6k | Next.js/React web apps |
| **database** | 5 | ~3k | Database design and optimization |
| **cloud** | 6 | ~4k | AWS/GCP/Azure infrastructure |
| **observability** | 4 | ~3k | Monitoring and logging |

**View all sets**:
```bash
ls -1 ~/Developer/Private/claude-pattern/.claude/agent-sets/*.json
```

---

## 💡 Best Practices

### 1. Global Config: Keep Empty
**File**: `~/.claude/settings.json`
```json
{
  "agentDescriptions": {
    "enabled": []
  }
}
```

**Why**: Avoids loading agents in every project (token bloat)

### 2. Project Configs: Enable Only What You Need

**Hive** (Electron + Rust + Release):
```json
{
  "agentDescriptions": {
    "enabled": [
      "orchestrator",
      "electron-specialist",
      "rust-backend-specialist",
      "release-orchestrator",
      "macos-signing-expert",
      "homebrew-publisher"
      // ... 6 more
    ]
  }
}
```

**Rust Microservice** (Backend only):
```json
{
  "agentDescriptions": {
    "enabled": [
      "rust-backend-specialist",
      "database-expert",
      "security-expert",
      "code-review-expert"
    ]
  }
}
```

### 3. Token Budget: Stay Under 15k

| Agents | Tokens | Status |
|--------|--------|--------|
| 0-7    | 0-4k   | ✅ Optimal |
| 8-12   | 5-9k   | ✅ Good |
| 13-15  | 10-12k | ⚠️ High |
| 16+    | 13k+   | 🚫 Bloat |

### 4. Dynamic Loading: Add Agents for Specific Tasks

**Example**: Temporarily add homebrew-publisher for release work

```json
{
  "agentDescriptions": {
    "enabled": [
      "orchestrator",
      "git-expert",
      "homebrew-publisher"  // Temporary for release
    ]
  }
}
```

**After release**: Remove temporary agents to reduce tokens.

---

## 🔍 Verification

After migration, check:

```bash
# Verify symlink
ls -la ~/.claude/agents
# Should show: agents -> /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents

# Verify global config
cat ~/.claude/settings.json | jq '.agentDescriptions.enabled | length'
# Should show: 0

# Verify Hive config
cd ~/Developer/Private/hive
cat .claude/settings.local.json | jq '.agentDescriptions.enabled | length'
# Should show: 12

# Test agent autocomplete in Claude Code
# Type: @electron-specialist
# Should autocomplete correctly
```

---

## 🆘 Troubleshooting

### "Agent not found"

**Fix**: Ensure symlink exists
```bash
ln -s /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents ~/.claude/agents
```

### "Token warning still appears"

**Fix**: Restart Claude Code completely
- Quit from menu bar (Cmd+Q)
- Reopen project

### "Agents slow to load"

**Fix**: Not related to symlink (instant on macOS)
- Check network (Claude API)
- Check system resources

---

## 📚 Full Documentation

- **Migration Guide**: `/Users/veronelazio/Developer/Private/claude-pattern/.claude/AGENT_MIGRATION_GUIDE.md`
- **Architecture**: `/Users/veronelazio/Developer/Private/claude-pattern/.claude/AGENT_CONFIGURATION_ARCHITECTURE.md`
- **Agent Sets**: `/Users/veronelazio/Developer/Private/claude-pattern/.claude/agent-sets/README.md`

---

## ✅ Success Criteria

You'll know migration succeeded when:

1. ✅ No "16k token warning" in any project
2. ✅ Agents autocomplete with `@` in all projects
3. ✅ Hive has exactly 12 agents configured
4. ✅ Global config has 0 agents enabled
5. ✅ `~/.claude/agents` is a symlink to pattern repo
6. ✅ Projects can configure their own agent sets independently
