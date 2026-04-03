# OpenCode Documentation Refresh Guide

**Last Updated**: 2025-10-18 **Version**: 1.0.0

This guide provides detailed instructions for updating the OpenCode
documentation library.

## Table of Contents

1. [Quick Start](#quick-start)
2. [Update Process Overview](#update-process-overview)
3. [Manual Update Steps](#manual-update-steps)
4. [Automated Update Scripts](#automated-update-scripts)
5. [Verification](#verification)
6. [Troubleshooting](#troubleshooting)
7. [Multi-Repository Sync](#multi-repository-sync)
8. [Version Tracking](#version-tracking)

---

## Quick Start

**For most users, use the automated script:**

```bash
# Navigate to any repository with opencode-expert
cd /Users/veronelazio/Developer/Private/hive

# Run the update script
~/.claude/commands/update-opencode-docs.sh

# Verify the update
cat .claude/agents/research-planning/opencode-expert/docs/.version
```

**Expected time**: 2-3 minutes

---

## Update Process Overview

### What Gets Updated

The documentation refresh process updates:

1. **Core Documentation** (3 files)
   - Introduction to OpenCode
   - Configuration guide
   - Enterprise features

2. **Usage Modes** (7 files)
   - TUI, CLI, IDE, Zen, Share, GitHub, GitLab

3. **Configuration Topics** (8 files)
   - Rules, models, themes, keybinds, commands, formatters, permissions, LSP

4. **Tools** (2 files)
   - Built-in tools
   - Custom tool creation

5. **Extension Systems** (5 files)
   - Agents, MCP servers, SDK, Server, Plugins

6. **Providers** (1 file)
   - LLM provider configuration

7. **Support** (1 file)
   - Troubleshooting guide

8. **GitHub Resources** (1 file)
   - Repository information (manually maintained)

**Total**: 28 markdown files + 1 index + 1 version file

### What Doesn't Change

- **Agent definition** (`.claude/agents/research-planning/opencode-expert.md`)
- **Update scripts** (`.claude/commands/update-opencode-docs.sh` and
  `fetch-opencode-docs.py`)
- **GitHub repository guide** (`docs/github/repository.md`) - manually
  maintained
- **Integration summaries** (`INTEGRATION_SUMMARY.md`,
  `GITHUB_INTEGRATION_UPDATE.md`)

---

## Manual Update Steps

If you prefer manual control or need to troubleshoot:

### Step 1: Backup Current Documentation

```bash
cd /Users/veronelazio/Developer/Private/hive
cp -r .claude/agents/research-planning/opencode-expert/docs \
     .claude/agents/research-planning/opencode-expert/docs.backup.$(date +%Y%m%d-%H%M%S)
```

### Step 2: Run Python Fetch Script

```bash
python3 .claude/commands/fetch-opencode-docs.py
```

**What this script does**:

- Fetches all pages from https://opencode.ai/docs/
- Converts HTML to clean markdown
- Preserves directory structure
- Adds metadata headers (source URL, fetch timestamp)
- Skips the GitHub repository guide (manually maintained)

### Step 3: Update Version File

```bash
echo "$(date '+%Y-%m-%d %H:%M:%S')" > \
  .claude/agents/research-planning/opencode-expert/docs/.version
```

### Step 4: Verify File Count

```bash
find .claude/agents/research-planning/opencode-expert/docs -name "*.md" | wc -l
```

**Expected**: 29 files (28 docs + 1 INDEX.md)

### Step 5: Review Changes

```bash
# Compare with backup
diff -r \
  .claude/agents/research-planning/opencode-expert/docs.backup.* \
  .claude/agents/research-planning/opencode-expert/docs
```

### Step 6: Clean Up Old Backups

```bash
# Keep only last 3 backups
ls -t .claude/agents/research-planning/ | grep "docs.backup" | tail -n +4 | \
  while read dir; do
    rm -rf ".claude/agents/research-planning/$dir"
  done
```

---

## Automated Update Scripts

### Primary Script: `update-opencode-docs.sh`

**Location**: `~/.claude/commands/update-opencode-docs.sh` or
`.claude/commands/update-opencode-docs.sh`

**Usage**:

```bash
# Interactive mode (asks for confirmation)
./update-opencode-docs.sh

# Force mode (no confirmation)
./update-opencode-docs.sh --force
```

**Features**:

- ✅ Automatic backup creation
- ✅ Python script execution
- ✅ Version file updates
- ✅ Rollback on failure
- ✅ Old backup cleanup (keeps last 3)
- ✅ File count verification
- ✅ Colored output

**Success Output**:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Update Complete!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Updated: 2025-10-18 14:30:45
Backup: .../docs.backup.20251018-143040
Total files: 29

Next steps:
  1. Review changes: diff -r <backup> <docs>
  2. Test with: @opencode-expert <query>
  3. Sync to other repos if needed

Additional Resources:
  • GitHub Repository: https://github.com/sst/opencode.git
  • Clone: git clone https://github.com/sst/opencode.git
  • To explore source code, examples, and latest development
```

### Secondary Script: `fetch-opencode-docs.py`

**Location**: `.claude/commands/fetch-opencode-docs.py`

**Direct Usage** (advanced):

```bash
python3 .claude/commands/fetch-opencode-docs.py
```

**Features**:

- HTML-to-Markdown conversion
- Metadata header injection
- Directory structure preservation
- Error handling and retries

---

## Verification

### Quick Verification Checklist

```bash
# 1. Check version file exists and has recent timestamp
cat .claude/agents/research-planning/opencode-expert/docs/.version

# 2. Verify file count (should be 29)
find .claude/agents/research-planning/opencode-expert/docs -name "*.md" | wc -l

# 3. Spot-check a few files for content
head -20 .claude/agents/research-planning/opencode-expert/docs/core/intro.md
head -20 .claude/agents/research-planning/opencode-expert/docs/sdk/sdk.md

# 4. Verify INDEX.md is up to date
cat .claude/agents/research-planning/opencode-expert/docs/INDEX.md | grep "Total Documents"

# 5. Test the agent
@opencode-expert What's new in the latest OpenCode documentation?
```

### Expected Directory Structure

```
opencode-expert/
├── opencode-expert.md                    # Agent definition
├── INTEGRATION_SUMMARY.md                # Original integration doc
├── GITHUB_INTEGRATION_UPDATE.md          # GitHub integration doc
├── REFRESH.md                            # This file
└── docs/
    ├── INDEX.md                           # Master index
    ├── .version                           # Last update timestamp
    ├── core/                              # 3 files
    ├── usage/                             # 7 files
    ├── configure/                         # 8 files
    ├── tools/                             # 2 files
    ├── agents/                            # 1 file
    ├── mcp-servers/                       # 1 file
    ├── sdk/                               # 1 file
    ├── server/                            # 1 file
    ├── plugins/                           # 1 file
    ├── providers/                         # 1 file
    ├── github/                            # 1 file (manually maintained)
    └── troubleshooting/                   # 1 file
```

**Total**: 30 files in docs/ (29 markdown + 1 version file)

---

## Troubleshooting

### Issue: "Python script not found"

**Solution**:

```bash
# Verify script location
ls -la .claude/commands/fetch-opencode-docs.py

# If missing, you may be in wrong directory
cd /Users/veronelazio/Developer/Private/hive
ls -la .claude/commands/fetch-opencode-docs.py
```

### Issue: "Permission denied"

**Solution**:

```bash
# Make scripts executable
chmod +x .claude/commands/update-opencode-docs.sh
chmod +x .claude/commands/fetch-opencode-docs.py
```

### Issue: "Update failed, backup restored"

**Cause**: Network error, invalid HTML, or Python error

**Solution**:

1. Check internet connection
2. Try again in a few minutes (OpenCode website may be down)
3. Run Python script directly to see error:
   ```bash
   python3 .claude/commands/fetch-opencode-docs.py
   ```
4. Check Python dependencies:
   ```bash
   python3 -c "import html.parser; print('OK')"
   ```

### Issue: "Wrong file count"

**Expected**: 29 markdown files

**If different**:

1. Check for new documentation pages on https://opencode.ai/docs/
2. Update Python script to include new pages
3. Check for deleted pages (update script to remove)
4. Verify GitHub repository guide still exists (manually maintained)

### Issue: "Metadata headers missing"

**Cause**: Python script issue

**Solution**:

1. Verify Python script is latest version
2. Check file contents:
   ```bash
   head -5 .claude/agents/research-planning/opencode-expert/docs/core/intro.md
   ```
3. Should see:
   ```markdown
   ---
   source: https://opencode.ai/docs/
   fetched: 2025-10-18 14:30:45
   ---
   ```

---

## Multi-Repository Sync

After updating documentation in one repository, sync to others:

### Sync to All Repositories

```bash
# Source: hive repository
SRC="/Users/veronelazio/Developer/Private/hive/.claude/agents/research-planning/opencode-expert"

# Target 1: claude-pattern
cp -r "$SRC/docs" \
  /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents/research-planning/opencode-expert/

# Target 2: hivetechs-website
cp -r "$SRC/docs" \
  /Users/veronelazio/Developer/Private/hivetechs-website/.claude/agents/research-planning/opencode-expert/
```

### Verify Sync

```bash
# Check file counts match
find /Users/veronelazio/Developer/Private/hive/.claude/agents/research-planning/opencode-expert/docs -name "*.md" | wc -l
find /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents/research-planning/opencode-expert/docs -name "*.md" | wc -l
find /Users/veronelazio/Developer/Private/hivetechs-website/.claude/agents/research-planning/opencode-expert/docs -name "*.md" | wc -l
```

**All should show**: 29

### When to Sync

- ✅ After successful documentation update
- ✅ After manual fixes to documentation
- ✅ Before committing changes to git
- ❌ Not needed for agent definition changes (handled separately)

---

## Version Tracking

### Version File Format

**Location**: `.claude/agents/research-planning/opencode-expert/docs/.version`

**Format**:

```
2025-10-18 14:30:45
```

**Purpose**:

- Track last documentation update
- Displayed by update script
- Used for change detection
- Referenced in agent responses

### Checking Current Version

```bash
# Read version file
cat .claude/agents/research-planning/opencode-expert/docs/.version

# Check file modification time as fallback
ls -l .claude/agents/research-planning/opencode-expert/docs/.version

# Check INDEX.md header
grep "Last Updated" .claude/agents/research-planning/opencode-expert/docs/INDEX.md
```

### Update Frequency Recommendations

**Recommended**: Monthly or when major OpenCode releases happen

**How to know when to update**:

1. Check OpenCode GitHub releases: https://github.com/sst/opencode/releases
2. Check OpenCode website for "What's New": https://opencode.ai/docs/
3. Monitor OpenCode Discord for announcements
4. Run update if agent responses seem outdated

**Manual check**:

```bash
# Compare your version with current date
CURRENT=$(cat .claude/agents/research-planning/opencode-expert/docs/.version)
echo "Last updated: $CURRENT"
echo "Current date: $(date '+%Y-%m-%d %H:%M:%S')"

# If more than 30 days old, consider updating
```

---

## Best Practices

### Before Updating

- ✅ Ensure stable internet connection
- ✅ Close OpenCode applications (avoid file conflicts)
- ✅ Review current version timestamp
- ✅ Check OpenCode website for major changes

### During Update

- ✅ Let script run without interruption
- ✅ Review any warnings or errors
- ✅ Verify file count matches expected (29)

### After Update

- ✅ Review changes with diff command
- ✅ Spot-check updated files
- ✅ Test agent with sample questions
- ✅ Sync to other repositories if needed
- ✅ Commit updated documentation if in git repo
- ✅ Update agent definition version if major changes

---

## Maintenance Schedule

**Recommended schedule**:

| Frequency                         | Task                                      |
| --------------------------------- | ----------------------------------------- |
| **Monthly**                       | Run documentation update                  |
| **Quarterly**                     | Review and update agent definition        |
| **After major OpenCode releases** | Immediate documentation update            |
| **Annually**                      | Review entire integration, update scripts |

**Commands to run monthly**:

```bash
# Update documentation
~/.claude/commands/update-opencode-docs.sh --force

# Verify
find .claude/agents/research-planning/opencode-expert/docs -name "*.md" | wc -l

# Sync to other repos
# (use multi-repo sync commands above)

# Test
@opencode-expert What are the latest OpenCode features?
```

---

## Emergency Rollback

If update causes issues:

```bash
# Find most recent backup
ls -lt .claude/agents/research-planning/ | grep docs.backup | head -1

# Restore backup (replace <timestamp> with actual)
rm -rf .claude/agents/research-planning/opencode-expert/docs
mv .claude/agents/research-planning/opencode-expert/docs.backup.<timestamp> \
   .claude/agents/research-planning/opencode-expert/docs

# Verify restoration
find .claude/agents/research-planning/opencode-expert/docs -name "*.md" | wc -l
```

---

## Support and Issues

**If you encounter issues**:

1. **Check troubleshooting section** in this guide
2. **Review script output** for error messages
3. **Verify Python installation**: `python3 --version` (3.7+ required)
4. **Check internet connection** to https://opencode.ai
5. **Try manual update steps** instead of automated script

**Documentation issues**:

- GitHub Issues: https://github.com/sst/opencode/issues
- Discord: https://opencode.ai/discord

**Agent integration issues**:

- Check `.claude/agents/AGENT_INTEGRATION_SUMMARY.md`
- Review `INTEGRATION_SUMMARY.md` for setup details

---

## Quick Reference

### Essential Commands

```bash
# Update documentation
~/.claude/commands/update-opencode-docs.sh

# Check version
cat .claude/agents/research-planning/opencode-expert/docs/.version

# Verify file count
find .claude/agents/research-planning/opencode-expert/docs -name "*.md" | wc -l

# Test agent
@opencode-expert <your question>

# Create backup manually
cp -r .claude/agents/research-planning/opencode-expert/docs \
     .claude/agents/research-planning/opencode-expert/docs.backup.$(date +%Y%m%d)
```

---

**Last Updated**: 2025-10-18 **Maintainer**: OpenCode Expert Agent Integration
**Version**: 1.0.0
