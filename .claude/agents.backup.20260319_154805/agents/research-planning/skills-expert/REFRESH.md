# Skills Knowledge Refresh Process

**Purpose**: Keep skills-expert agent's knowledge current with latest Anthropic
documentation **Frequency**: Monthly (or when significant updates announced)
**Last Refresh**: 2025-10-20 **Next Refresh**: 2025-11-20

---

## Official Documentation Sources

### 1. Support Articles (Help Center)

**Base URL**: https://support.claude.com/en/articles/

| Article                               | URL      | Local File                                        | Content                     |
| ------------------------------------- | -------- | ------------------------------------------------- | --------------------------- |
| **How to Create Custom Skills**       | 12512198 | `docs/official/skills-how-to-create.md`           | Step-by-step creation guide |
| **What Are Skills**                   | 12512176 | `docs/official/skills-what-are-skills.md`         | Overview and concepts       |
| **Using Skills**                      | 12512180 | `docs/official/skills-using.md`                   | End-user guide              |
| **Teach Claude Using Skills**         | 12580051 | `docs/official/skills-user-guide.md`              | Teaching workflows          |
| **Create Skill Through Conversation** | 12599426 | `docs/official/skills-conversational-creation.md` | AI-assisted creation        |

### 2. Developer Documentation (docs.claude.com)

**Base URL**: https://docs.claude.com/en/docs/agents-and-tools/agent-skills/

| Document           | Path                | Local File                               | Content                  |
| ------------------ | ------------------- | ---------------------------------------- | ------------------------ |
| **Overview**       | /overview           | `docs/official/skills-overview.md`       | Complete specification   |
| **Best Practices** | /best-practices     | `docs/official/skills-best-practices.md` | Official best practices  |
| **Quickstart**     | /quickstart         | `docs/official/skills-quickstart.md`     | Getting started tutorial |
| **API Guide**      | /api/skills-guide   | `docs/official/skills-api-guide.md`      | API integration          |
| **Claude Code**    | /claude-code/skills | `docs/official/skills-claude-code.md`    | CLI implementation       |

### 3. GitHub Repository

**URL**: https://github.com/anthropics/skills

| Content   | Local File                                 | Purpose             |
| --------- | ------------------------------------------ | ------------------- |
| README    | `docs/official/skills-github-readme.md`    | Repository overview |
| Examples  | `docs/official/skills-github-examples.md`  | Community examples  |
| Templates | `docs/official/skills-github-templates.md` | Starter templates   |

### 4. Engineering Blog

**URL**: https://www.anthropic.com/engineering/

| Article              | Local File                                 | Content             |
| -------------------- | ------------------------------------------ | ------------------- |
| **Equipping Agents** | `docs/official/skills-engineering-blog.md` | Technical deep dive |

---

## Refresh Procedure

### Step 1: Check for Updates

**Frequency**: Monthly on the 20th

```bash
# Run this command to start refresh
claude "Check Anthropic documentation for Skills updates since 2025-10-20"
```

**What to check**:

1. Skills API version (currently `skills-2025-10-02`)
2. New beta headers or requirements
3. Changes to YAML frontmatter spec
4. New official examples
5. Updated best practices
6. Security advisories

### Step 2: Fetch Latest Documentation

For each official source, fetch and save:

```bash
# Example for support articles
@skills-expert "Fetch latest version of 'How to Create Custom Skills' and save to docs/official/skills-how-to-create.md"

# Example for dev docs
@skills-expert "Fetch latest Skills Best Practices and update docs/official/skills-best-practices.md"

# Example for GitHub
@skills-expert "Check anthropics/skills repository for new examples and update docs/official/skills-github-examples.md"
```

### Step 3: Compare Changes

```bash
# For each updated file, review changes
git diff docs/official/skills-best-practices.md

# Document significant changes
@skills-expert "Summarize changes in Skills Best Practices since last refresh"
```

### Step 4: Update Local Knowledge

**Areas to update**:

1. **skills-expert.md agent definition**
   - Update `last_updated` field
   - Add new capabilities if specs changed
   - Update version history

2. **Compliance criteria**
   - Update if requirements changed
   - Add new best practices
   - Revise quality standards

3. **Implementation docs**
   - Re-audit current skills against new specs
   - Update compliance reports if needed
   - Document any breaking changes

### Step 5: Test Against New Specs

```bash
# Run compliance audit with updated specs
@skills-expert "Audit all 39 skills against latest Anthropic specifications"

# Test skill creation with new requirements
@skills-expert "Create a test skill using latest best practices"
```

### Step 6: Update Change Log

Document changes in `docs/CHANGELOG.md`:

```markdown
## 2025-11-20 - Knowledge Refresh

### Official Documentation Updates

- Updated Best Practices: Added new progressive disclosure patterns
- API Version: skills-2025-10-02 → skills-2025-11-05
- New Beta Headers: Added xyz-2025-11-01

### Changes Impact

- ✅ All existing skills still compliant
- ⚠️ New optional field: `context_window_priority`
- 📚 3 new examples added to GitHub repository

### Actions Taken

- Updated all official docs in docs/official/
- Re-audited 39 skills: 100% compliant
- Updated skills-expert.md version to 1.1.0
```

### Step 7: Notify Stakeholders

```markdown
# Skills Knowledge Refresh Complete

**Date**: 2025-11-20 **Status**: ✅ Complete

## Changes Found

[Summary of updates]

## Impact on Existing Skills

[Compliance status]

## Recommended Actions

[Any updates needed]
```

---

## Automation Opportunities

### Scheduled Check

Create a monthly reminder:

```bash
# Add to calendar or automation system
# Every 20th of month: Run skills knowledge refresh

# Could create a slash command:
/refresh-skills-knowledge
```

### Automated Fetching

**Potential automation**:

```python
# Pseudocode for automation
def refresh_skills_knowledge():
    sources = [
        "https://support.claude.com/en/articles/12512198",
        "https://docs.claude.com/en/docs/agents-and-tools/agent-skills/best-practices",
        # ... all sources
    ]

    for url in sources:
        latest_content = fetch(url)
        local_file = get_local_file(url)

        if content_changed(latest_content, local_file):
            save(latest_content, local_file)
            notify_change(url, local_file)

    # Run compliance audit
    audit_skills_compliance()

    # Generate change report
    generate_changelog()
```

---

## Emergency Refresh

**When to run emergency refresh**:

- Anthropic announces breaking changes
- Security vulnerability discovered
- New API version required
- Skills stop working as expected

**Emergency procedure**:

1. Immediately fetch latest documentation
2. Identify breaking changes
3. Audit all skills for compliance
4. Fix critical issues first
5. Schedule full refresh for non-critical updates

---

## Version Tracking

### Anthropic API Versions

| Version             | Release Date | Local Updated | Notes           |
| ------------------- | ------------ | ------------- | --------------- |
| `skills-2025-10-02` | 2025-10-02   | 2025-10-20    | Current version |

### Local Knowledge Versions

| Version | Date       | Changes                | Updated By             |
| ------- | ---------- | ---------------------- | ---------------------- |
| 1.0.0   | 2025-10-20 | Initial knowledge base | skills-expert creation |

---

## Success Criteria

A successful refresh includes:

- ✅ All official documentation URLs checked
- ✅ Any changed content downloaded and saved
- ✅ Significant changes documented in CHANGELOG
- ✅ Compliance audit run against new specs
- ✅ All existing skills verified still compliant
- ✅ Agent definition updated with new version
- ✅ Stakeholders notified of changes

---

## Quick Reference Commands

```bash
# Start monthly refresh
@skills-expert "Run monthly skills knowledge refresh"

# Check specific source
@skills-expert "Check Skills Best Practices for updates"

# Emergency refresh
@skills-expert "URGENT: Refresh skills knowledge immediately - breaking changes announced"

# Compare versions
@skills-expert "Compare current docs with previous version and summarize changes"

# Audit after refresh
@skills-expert "Audit all skills against latest specifications"
```

---

**Next Scheduled Refresh**: 2025-11-20 **Responsible**: @skills-expert agent
**Backup**: Manual process documented above
