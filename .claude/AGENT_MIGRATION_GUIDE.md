# Agent Configuration Migration Guide

**Goal**: Eliminate 16k token warning while maintaining agent flexibility across projects.

**Duration**: 10 minutes

## Current Situation

- **Global config** (`~/.claude/settings.json`): 17 agents enabled (causing 16k token warning)
- **Hive project**: 177 agent files (many duplicates from pattern repo)
- **Pattern repo**: 174 agents (master library)
- **Problem**: Token bloat from loading all agents globally

## Target Architecture

```
Pattern Repo (Master Library)
    └── 174 agents in .claude/agents/

Global Config (Clean)
    └── 0 agents enabled, symlinked to pattern repo

Hive Project (Focused)
    └── 12 agents enabled via settings.local.json
```

**Result**: 16k → 9k tokens (43% reduction)

---

## Step-by-Step Migration

### Step 1: Backup Current Configs (30 seconds)

```bash
# Backup global config
cp ~/.claude/settings.json ~/.claude/settings.json.backup

# Backup Hive project config
cp ~/Developer/Private/hive/.claude/settings.local.json \
   ~/Developer/Private/hive/.claude/settings.local.json.backup

# Backup global agents (if not already symlinked)
if [ -d ~/.claude/agents ] && [ ! -L ~/.claude/agents ]; then
  mv ~/.claude/agents ~/.claude/agents.backup
fi
```

### Step 2: Create Symlink to Pattern Repo (30 seconds)

**This makes all 174 agents discoverable without duplication.**

```bash
# Remove existing agents directory (if it's not a symlink)
rm -rf ~/.claude/agents

# Symlink to pattern repository
ln -s /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents \
      ~/.claude/agents

# Verify
ls -la ~/.claude/agents
# Should show: agents -> /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents
```

### Step 3: Clean Global Config (1 minute)

**Remove all agents from global config to eliminate token bloat.**

Edit `~/.claude/settings.json`:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "alwaysThinkingEnabled": true,
  "memory": {
    "autoImport": [
      "~/.claude/CLAUDE.md"
    ]
  },
  "customCommands": {
    "pm-status": "bash ~/.claude/commands/pm-status.sh",
    "pm-recover": "bash ~/.claude/commands/pm-recover.sh",
    "pm-assign": "bash ~/.claude/commands/pm-assign.sh '${TASK}'",
    "verify-commit": "bash ~/.claude/commands/verify-and-commit.sh",
    "show-progress": "bash ~/.claude/commands/show-progress.sh",
    "plan-incremental": "bash ~/.claude/commands/incremental-plan.sh '${TASK}'",
    "save-context": "bash ~/.claude/commands/context-save.sh",
    "reload-config": "bash ~/.claude/commands/reload-config.sh",
    "parallel-fix": "bash ~/.claude/commands/parallel-fix.sh",
    "qa-all": "cargo build --release && cargo test --all-features && cargo clippy -- -D warnings && cargo fmt --check"
  },
  "behavior": {
    "parallelAgentsWithPM": true,
    "incrementalDevelopment": true,
    "continuousVerification": true,
    "conflictPrevention": true
  },
  "tools": {
    "bashCommands": {
      "allowList": [
        "cargo",
        "rustc",
        "rustup",
        "rust-analyzer",
        "clippy",
        "rustfmt",
        "wrangler",
        "npm",
        "node",
        "git",
        "gh",
        "curl",
        "wget",
        "rg",
        "ripgrep",
        "fd",
        "bat",
        "exa",
        "tokei",
        "hyperfine",
        "just",
        "make",
        "sqlite3",
        "sqlx",
        "taplo"
      ]
    }
  },
  "feedbackSurveyState": {
    "lastShownTime": 1754055402751
  },
  "agentDescriptions": {
    "enabled": []
  }
}
```

**Key change**: `"enabled": []` (was 17 agents, now 0)

### Step 4: Configure Hive Project (2 minutes)

**Enable only the 12 agents needed for Hive development.**

Edit `/Users/veronelazio/Developer/Private/hive/.claude/settings.local.json`:

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
  "permissions": {
    "allow": [
      "Bash(export SIGN_ID=\"Developer ID Application: HiveTechs Collective LLC (FWBLB27H52)\")",
      "Bash(if [ -f \".version-lock-1.8.547\" ])",
      "Bash(then echo \"✅ Release pipeline is running (version locked)\")",
      "Bash(else echo \"❌ No version lock found - pipeline may not have started\")",
      "Bash(else echo \"❌ No version lock found - pipeline may have completed or failed\")",
      "Bash(git secrets:*)",
      "Bash(npm run lint)",
      "Bash(npx tsc:*)",
      "Bash(chmod:*)",
      "Bash(cat:*)",
      "Bash(git add:*)",
      "Bash(./scripts/release.sh:*)",
      "Bash(export NOTARY_PROFILE=\"HiveNotaryProfile\")",
      "Bash(export SIGN_ID='Developer ID Application: HiveTechs Collective LLC (FWBLB27H52)')",
      "Bash(export NOTARY_PROFILE='HiveNotaryProfile')",
      "Bash(SIGN_ID='Developer ID Application: HiveTechs Collective LLC (FWBLB27H52)' NOTARY_PROFILE='HiveNotaryProfile' ./scripts/release.sh)",
      "Bash(npm run typecheck:*)",
      "Bash(npm run build:*)",
      "Bash(git commit:*)",
      "Bash(git push:*)",
      "Bash(security find-identity:*)",
      "Bash(xcrun notarytool:*)",
      "Bash(security find-generic-password:*)",
      "Read(//Users/veronelazio/**)",
      "Bash(brew upgrade:*)",
      "Bash(open:*)",
      "Bash(log show:*)",
      "Bash(/Applications/Hive Consensus.app/Contents/MacOS/Hive Consensus)",
      "Bash(node:*)",
      "Bash(git revert:*)",
      "Bash(git stash:*)",
      "Bash(git checkout:*)",
      "Bash(git reset:*)",
      "WebSearch",
      "WebFetch(domain:skywork.ai)",
      "WebFetch(domain:www.anthropic.com)",
      "Bash(echo:*)",
      "Bash(awk:*)",
      "WebFetch(domain:support.claude.com)",
      "WebFetch(domain:github.com)"
    ],
    "deny": [],
    "ask": [],
    "additionalDirectories": [
      "/tmp",
      "/Users/veronelazio/.hive-consensus/logs",
      "/Users/veronelazio/Developer/Private",
      "/Users/veronelazio/Library/Application Support/Hive Consensus/logs",
      "/Users/veronelazio/Library"
    ]
  },
  "statusLine": {
    "type": "command",
    "command": ".claude/statusline.sh",
    "padding": 0
  }
}
```

**Key changes**:
- Added `"agentDescriptions"` section with 12 Hive-specific agents
- Preserved all existing permissions and settings
- Agents come from `hive-core.json` agent set

### Step 5: Clean Up Hive Agent Duplicates (3 minutes)

**Remove duplicate agents from Hive project** (now served from pattern repo via symlink).

```bash
cd ~/Developer/Private/hive

# Count current agents
find .claude/agents -name "*.md" | wc -l
# Shows: 177 agents

# Move to backup (don't delete yet, just in case)
mv .claude/agents .claude/agents.backup

# Verify agents still work via symlink
ls ~/.claude/agents/hive/
# Should show: electron-debug-expert.md, homebrew-publisher.md, macos-signing-expert.md, release-orchestrator.md
```

**Result**: Hive project no longer has duplicate agents, uses global symlink to pattern repo.

### Step 6: Restart Claude Code and Verify (2 minutes)

```bash
# Quit Claude Code completely
# Reopen in Hive project
cd ~/Developer/Private/hive
code .
```

**Check**:
1. No more "16k token warning"
2. Agents still autocomplete with `@`
3. Try: `@electron-specialist` (should work)
4. Try: `@rust-backend-specialist` (should work)
5. Try: `@release-orchestrator` (should work)

---

## Verification Checklist

After migration, verify:

- [ ] Global config has `"enabled": []`
- [ ] `~/.claude/agents` is a symlink to pattern repo
- [ ] Hive project has 12 agents in `settings.local.json`
- [ ] No "16k token warning" appears
- [ ] All agents autocomplete with `@` in Hive project
- [ ] Agents work correctly when invoked
- [ ] Hive `.claude/agents` directory removed (or renamed to `.backup`)

## Token Impact

**Before**:
- Global: 17 agents = ~13-16k tokens
- Loaded in EVERY project (wasteful)

**After**:
- Global: 0 agents = 0 tokens
- Hive project: 12 agents = ~9k tokens
- Other projects: Configure as needed (3-10 agents typically)

**Savings**: 43% reduction in Hive, 100% reduction in non-Hive projects

---

## Troubleshooting

### "Agent not found" error

**Symptom**: `@agent-name` doesn't autocomplete

**Fix**: Ensure symlink exists
```bash
ls -la ~/.claude/agents
# Should show symlink to pattern repo
```

If broken:
```bash
rm -rf ~/.claude/agents
ln -s /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents ~/.claude/agents
```

### "Token warning still appears"

**Symptom**: Warning persists after config change

**Fix**: Completely quit and restart Claude Code
- Close all Claude Code windows
- Quit from menu bar (Cmd+Q)
- Reopen project

### "Can't find specific agent"

**Symptom**: Specific agent missing from autocomplete

**Fix**: Check agent exists in pattern repo
```bash
find ~/Developer/Private/claude-pattern/.claude/agents -name "*agent-name*"
```

If missing, agent may need to be created or name may be different.

### "Agents work but seem slow"

**Symptom**: Agent invocations are slower

**Cause**: Not related to symlink (symlinks are instant on macOS)
**Check**: Network issues with Claude API, not local config

---

## Using Agent Sets

Now that you have the architecture set up, you can easily change agent configurations:

### Switch to Rust-Only Set (6 agents, ~4k tokens)

Edit Hive's `settings.local.json`:
```bash
cat ~/Developer/Private/claude-pattern/.claude/agent-sets/rust.json | jq '.agents'
```

Copy agent list:
```json
{
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

### Switch to Release-Only Set (5 agents, ~3.5k tokens)

```bash
cat ~/Developer/Private/claude-pattern/.claude/agent-sets/release-pipeline.json | jq '.agents'
```

### Combine Multiple Sets

```bash
# Electron + Rust (deduplicated)
jq -s '.[0].agents + .[1].agents | unique' \
  ~/Developer/Private/claude-pattern/.claude/agent-sets/electron.json \
  ~/Developer/Private/claude-pattern/.claude/agent-sets/rust.json
```

---

## Next Steps

After successful migration:

1. **Test in other projects**: Apply same pattern to other repositories
2. **Create custom sets**: Define sets for your specific workflows in `agent-sets/custom/`
3. **Monitor usage**: Track which agents you actually use over a week
4. **Optimize further**: Remove unused agents from project configs
5. **Share**: Commit useful agent sets to pattern repo

## Rollback (If Needed)

If something goes wrong, restore backups:

```bash
# Restore global config
cp ~/.claude/settings.json.backup ~/.claude/settings.json

# Restore Hive config
cp ~/Developer/Private/hive/.claude/settings.local.json.backup \
   ~/Developer/Private/hive/.claude/settings.local.json

# Restore Hive agents
mv ~/Developer/Private/hive/.claude/agents.backup \
   ~/Developer/Private/hive/.claude/agents

# Restore global agents (if you had a non-symlinked version)
rm ~/.claude/agents
mv ~/.claude/agents.backup ~/.claude/agents
```

---

## Benefits Achieved

- **Token Efficiency**: 43% reduction in Hive (16k → 9k tokens)
- **Global Cleanliness**: No token bloat in non-Hive projects
- **Single Source of Truth**: Pattern repo is master, no duplication
- **Flexibility**: Easy to add/remove agents per-project
- **Maintainability**: Update agents in one place (pattern repo)
- **Discoverability**: All 174 agents available via autocomplete
- **Fast Switching**: Change agent sets by editing one JSON array

## Success Criteria

You'll know migration succeeded when:

1. ✅ No "16k token warning" in any project
2. ✅ Agents autocomplete with `@` in all projects
3. ✅ Hive has exactly 12 agents configured
4. ✅ Other projects can configure their own agent sets
5. ✅ Pattern repo is single source for all agent definitions
6. ✅ Global config is clean and minimal
