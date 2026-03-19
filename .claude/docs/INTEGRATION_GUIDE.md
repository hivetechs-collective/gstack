# Claude Pattern Integration Guide

**Quick Start**: Get the complete claude-pattern setup (70+ agents, status line, documentation) in your project in < 5 minutes.

---

## For New Projects

### Step 1: Initial Setup

```bash
# From claude-pattern repository
cd /Users/veronelazio/Developer/Private/claude-pattern/.claude/scripts

# Run setup script
./setup-new-project.sh /path/to/your/project
```

**What This Does**:
- Creates `.claude/` directory in your project
- Copies all 70+ agents
- Copies status line script and configuration
- Copies slash commands and documentation
- **Preserves** any existing project-specific files

### Step 2: Create Project-Specific Settings

```bash
cd /path/to/your/project/.claude

# Create settings.local.json
cat > settings.local.json << 'EOF'
{
  "permissions": {
    "allow": [
      "Read(//path/to/your/project/**)",
      "Bash(git:*)",
      "Bash(npm:*)"
    ],
    "deny": [],
    "ask": []
  },
  "statusLine": {
    "type": "command",
    "command": ".claude/statusline.sh",
    "padding": 0
  }
}
EOF
```

### Step 3: Verify Setup

```bash
# Check agents
ls .claude/agents/

# Test status line
.claude/statusline.sh

# Count agents
find .claude/agents -name "*.md" -type f | wc -l
# Should show: 112
```

### Step 4: Start Using Agents

In Claude Code:
```
"Use the orchestrator to coordinate implementing authentication"
"Use the rust-backend-specialist to optimize this Tokio code"
"Use the system-architect to design the microservices architecture"
```

---

## For Existing Projects (hive, hivetechs-website)

### Step 1: Backup Current Setup

```bash
cd /path/to/existing/project/.claude

# Your existing backups are automatically preserved
# They will NOT be overwritten
```

### Step 2: Dry Run (Recommended First)

```bash
cd /Users/veronelazio/Developer/Private/claude-pattern/.claude/scripts

# See what would change without actually changing it
./sync-to-project.sh /path/to/existing/project --dry-run
```

Review the output carefully. It will show:
- Files to be added
- Files to be updated
- Files to be deleted
- Files to be preserved

### Step 3: Sync

```bash
# Apply the sync
./sync-to-project.sh /path/to/existing/project
```

**What This Does**:
- Creates automatic backup (`.claude/agents.backup.YYYYMMDD_HHMMSS/`)
- Syncs all agents (31 → 70 agents)
- Updates status line script
- Updates MCP configuration
- **Preserves** `settings.local.json`, `statusline.log`, existing backups

### Step 4: Verify

```bash
cd /path/to/existing/project

# Count agents (should now be 112 markdown files)
find .claude/agents -name "*.md" -type f | wc -l

# Check new agents
ls .claude/agents/implementation/
ls .claude/agents/research-planning/

# Verify your settings preserved
cat .claude/settings.local.json
```

---

## Ongoing Sync Workflow

When claude-pattern is updated with new agents or improvements:

### Option 1: Manual Sync

```bash
cd /Users/veronelazio/Developer/Private/claude-pattern/.claude/scripts

# Sync to all projects
./sync-to-project.sh /Users/veronelazio/Developer/Private/hive
./sync-to-project.sh /Users/veronelazio/Developer/Private/hivetechs-website
./sync-to-project.sh /path/to/new/project
```

### Option 2: Automated Sync (Future)

```bash
# Create a sync-all.sh script
#!/bin/bash
PROJECTS=(
  "/Users/veronelazio/Developer/Private/hive"
  "/Users/veronelazio/Developer/Private/hivetechs-website"
)

for project in "${PROJECTS[@]}"; do
  echo "Syncing $project..."
  ./sync-to-project.sh "$project"
done
```

---

## Bidirectional Sync (Improvements Back to claude-pattern)

If you improve an agent in your project and want to share it:

### Step 1: Identify Improved Agent

```bash
cd /path/to/your/project

# Example: You improved rust-backend-specialist.md
file=".claude/agents/implementation/rust-backend-specialist.md"
```

### Step 2: Copy to claude-pattern

```bash
# Copy improved file
cp "$file" /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents/implementation/

# Review diff
cd /Users/veronelazio/Developer/Private/claude-pattern
git diff .claude/agents/implementation/rust-backend-specialist.md
```

### Step 3: Commit if Valuable

```bash
# If improvement is valuable
git add .claude/agents/implementation/rust-backend-specialist.md
git commit -m "feat(agents): improve rust-backend-specialist with X enhancement"
```

### Step 4: Propagate to All Projects

```bash
# Next sync will propagate improvement everywhere
cd .claude/scripts
./sync-to-project.sh /Users/veronelazio/Developer/Private/hive
./sync-to-project.sh /Users/veronelazio/Developer/Private/hivetechs-website
```

---

## Rollback Strategy

If a sync causes issues:

### Option 1: Restore from Automatic Backup

```bash
cd /path/to/project/.claude

# List backups
ls agents.backup.*/

# Restore from specific backup
BACKUP="agents.backup.20251008_143000"
rm -rf agents
cp -r "$BACKUP/agents" ./
```

### Option 2: Re-run Setup

```bash
# Nuclear option: completely reset to claude-pattern state
cd /Users/veronelazio/Developer/Private/claude-pattern/.claude/scripts
./setup-new-project.sh /path/to/project  # Overwrites everything
```

---

## Status Line Integration

The status line should work immediately after setup. It shows:

- **Context %**: How much context is being used
- **Tokens**: Input/output token counts
- **Cost**: Estimated cost in USD
- **Burn Rate**: Tokens per minute
- **Model**: Which Claude model is active

### Troubleshooting Status Line

If status line doesn't appear:

```bash
# Check script exists and is executable
ls -la .claude/statusline.sh
chmod +x .claude/statusline.sh

# Test directly
.claude/statusline.sh < <(echo '{"type":"init"}')

# Check settings.local.json
cat .claude/settings.local.json | grep statusLine
```

---

## Verification Checklist

After initial setup or sync:

- [ ] `.claude/agents/` contains 70+ agent subdirectories
- [ ] `find .claude/agents -name "*.md" | wc -l` shows 112
- [ ] `.claude/statusline.sh` exists and is executable
- [ ] `.claude/.mcp.json` exists (MCP servers configured)
- [ ] `.claude/settings.local.json` exists (project-specific)
- [ ] Status line appears in Claude Code with context % and cost
- [ ] Can invoke agents: "Use the orchestrator to..."
- [ ] Backup directories preserved: `ls .claude/agents.backup.*/`

---

##Common Issues & Solutions

### Issue: "Agent not found"

**Solution**: Verify agent exists
```bash
find .claude/agents -name "*specialist.md" | grep -i keyword
```

### Issue: "Status line not showing"

**Solution 1**: Check settings.local.json
```bash
cat .claude/settings.local.json
```

**Solution 2**: Test script manually
```bash
.claude/statusline.sh < <(echo '{"type":"init"}')
```

### Issue: "Too many files synced"

**Solution**: Check exclusions in sync script
```bash
# Should exclude: settings.local.json, statusline.log, agents.backup.*
grep -A 5 "exclude=" /Users/veronelazio/Developer/Private/claude-pattern/.claude/scripts/sync-to-project.sh
```

### Issue: "Sync overwrote my custom settings"

**Solution**: Restore from backup
```bash
cp agents.backup.LATEST/settings.local.json .claude/
```

---

## Next Steps

### For New Projects
1. Create project-specific settings.local.json
2. Test orchestrator: "Use orchestrator to analyze this codebase"
3. Explore agents: `ls .claude/agents/*/`
4. Read agent registry: `.claude/agents/COMPLETE_AGENT_REGISTRY.md`

### For Existing Projects
1. Explore new agents (39 added)
2. Try new specialists: aws-specialist, kubernetes-specialist, databricks-specialist
3. Review research updates: `.claude/agents/research/2025_TECHNOLOGY_UPDATES.md`
4. Check coverage analysis: `.claude/agents/COVERAGE_GAP_ANALYSIS.md`

### General
1. Set up automated sync cron job (optional)
2. Document project-specific agent patterns
3. Contribute improvements back to claude-pattern
4. Monitor agent effectiveness

---

## Support & Resources

- **Agent Documentation**: `.claude/agents/COMPLETE_AGENT_REGISTRY.md`
- **SDK Reference**: `.claude/agents/research-planning/claude-sdk-expert/docs/`
- **Sync Strategy**: `.claude/docs/REPOSITORY_SYNC_STRATEGY.md`
- **MCP Guide**: `.claude/docs/MCP_USAGE_GUIDE.md`

---

**Quick Command Reference**:

```bash
# Initial setup
./setup-new-project.sh /path/to/project

# Ongoing sync
./sync-to-project.sh /path/to/project

# Dry run first
./sync-to-project.sh /path/to/project --dry-run

# Verify agents
find .claude/agents -name "*.md" | wc -l

# Test status line
.claude/statusline.sh
```
