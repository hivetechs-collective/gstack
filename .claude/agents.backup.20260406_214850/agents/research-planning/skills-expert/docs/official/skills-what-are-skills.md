# What Are Skills?

**Last Updated**: 2025-10-17 **Source**:
https://support.claude.com/en/articles/12512176-what-are-skills **Category**:
Agent Skills / Overview

## Definition

Skills are dynamic folders containing instructions, scripts, and resources that
Claude loads to enhance performance on specialized tasks. They enable Claude to
complete specific work consistently, whether applying brand guidelines,
analyzing data with organizational workflows, or automating personal tasks.

## Core Functionality

> "Skills work through progressive disclosure—Claude determines which Skills are
> relevant and loads the information it needs to complete that task, helping to
> prevent context window overload."

This approach allows Claude to:

1. Review available Skills
2. Load pertinent ones based on task context
3. Apply their instructions when you request task completion

This is fundamentally different from static knowledge that always consumes
context.

## How Skills Work

### Progressive Disclosure

**Three-tier information hierarchy**:

1. **Metadata Layer**: Skill name and description loaded into the system prompt
   at startup
   - Claude can determine relevance
   - No context consumption for full content

2. **Primary Content**: The `SKILL.md` file containing core instructions
   - Loaded only when Claude identifies the skill as relevant
   - Contains main procedural knowledge

3. **Supplementary Resources**: Additional bundled files
   - Referenced on-demand based on task requirements
   - Examples: `reference.md`, `templates/`, `scripts/`

**Result**: Efficient context usage—only load what's needed for the current
task.

## Skill Categories

### Anthropic Skills

**Pre-built capabilities** maintained by Anthropic for enhanced document
creation:

- **Excel**: `xlsx` - Advanced spreadsheet generation
- **Word**: `docx` - Document creation with formatting
- **PowerPoint**: `pptx` - Presentation generation
- **PDF**: `pdf` - PDF creation and manipulation

These invoke automatically when relevant tasks are detected.

### Custom Skills

**Organization-created capabilities** for specialized workflows:

**Brand Guidelines**:

- Apply company colors, fonts, logos
- Enforce voice and tone standards
- Ensure compliance across all outputs

**Email Templates**:

- Generate emails following company standards
- Customer support responses
- Internal communications
- Sales outreach

**Meeting Notes**:

- Structure notes in standard format
- Extract action items
- Assign owners and deadlines

**Task Creation**:

- Create tasks in tools like JIRA
- Follow team conventions for stories/bugs
- Apply proper labels and priorities

**Data Analysis**:

- Execute organization-specific analysis workflows
- Generate standard reports
- Apply company metrics and KPIs

**Personal Automation**:

- Individual workflow preferences
- Personal productivity systems
- Custom research frameworks

## Key Advantages

Skills deliver three primary benefits:

### 1. Improved Claude Performance

Claude performs better on specialized tasks when given:

- Detailed procedural knowledge
- Domain-specific context
- Proven frameworks and templates
- Reference materials

**Example**: A "Code Review" Skill produces more comprehensive, consistent
reviews than ad-hoc prompting.

### 2. Organizational Knowledge Capture

Skills package workflows and best practices:

- Tribal knowledge becomes shareable
- Standards applied consistently
- Team alignment on processes
- New team members ramp up faster

**Example**: Sales team's proven pitch structure becomes a Skill used by entire
team.

### 3. Accessible Customization

Creating Skills requires only:

- **Markdown** for simple implementations
- **Executable scripts** for advanced functionality (optional)

No deep technical expertise needed—if you can write documentation, you can
create Skills.

## Platform Availability

### Claude.ai (Web Interface)

**Availability**: Feature preview for paid plans

- Claude Pro
- Claude Max
- Claude Team
- Claude Enterprise

**Requirements**:

- Enable code execution in account settings
- Toggle Skills in Settings > Capabilities

**Usage**: Skills activate automatically when relevant

### Claude Code (CLI)

**Availability**: Beta for all Claude Code users

**Storage Locations**:

- Personal Skills: `~/.claude/skills/`
- Project Skills: `.claude/skills/`
- Plugin Skills: Bundled with plugins

**Usage**: Model-invoked based on task context

### Claude API

**Availability**: All API users

**Requirements**:

- Code execution tool enabled
- Beta headers:
  - `code-execution-2025-08-25`
  - `skills-2025-10-02`
  - `files-api-2025-04-14`

**Usage**: Specify Skills via `container` parameter

## Distinction from Related Features

### Skills vs. Projects

**Projects** (Static, Always-Loaded Knowledge):

- Persistent context for specific initiatives
- Always consume context window
- Product launches, research, development work

**Skills** (Dynamic, On-Demand Procedures):

- Activate only when relevant
- Load progressively as needed
- Procedural knowledge and workflows

**Use Together**: Projects for context + Skills for procedures

### Skills vs. MCP (Model Context Protocol)

**MCP** (External Service Connections):

- Connect to external tools and data sources
- Real-time data access
- API integrations

**Skills** (Procedural Knowledge):

- Instructions and reference materials
- Internal to Claude
- How to use information, not where to get it

**Complementary**: MCP provides data, Skills provide expertise

### Skills vs. Custom Instructions

**Custom Instructions** (Broadly Applied Preferences):

- Universal behavior settings
- "Ask clarifying questions"
- "Use formal tone"
- "Prefer TypeScript"

**Skills** (Targeted, Detailed Procedures):

- Specific to particular task types
- Comprehensive reference libraries
- Activate only for relevant work

**Hierarchy**: Custom Instructions always apply, Skills activate selectively

## Skill Structure

### Required: SKILL.md

Every Skill must have a `SKILL.md` file with YAML frontmatter:

```yaml
---
name: Skill Name
description: What it does and when to activate
---

# Skill Name

## Instructions

[Detailed procedural guidance for Claude]

## Examples

[Concrete examples of desired outputs]
```

### Optional: Supporting Files

Additional resources Claude can load on-demand:

- **Reference materials**: `reference.md`, `guidelines.pdf`
- **Templates**: `templates/report-template.md`
- **Scripts**: `scripts/data-processing.py`
- **Data files**: `data/metrics.json`

### Optional: Tool Restrictions

Limit Claude's tool access for security or workflow constraints:

```yaml
---
name: Read-Only Analysis
description: Analyze code without making changes
allowed-tools: Read, Grep, Glob
---
```

## Use Cases

### Individual Productivity

**Personal Research Framework**:

- Systematic literature review process
- Note-taking standards
- Citation management

**Writing Style**:

- Preferred tone and voice
- Sentence structure preferences
- Vocabulary choices

**Task Management**:

- How to break down projects
- Priority assessment framework
- Progress tracking format

### Team Collaboration

**Code Review Standards**:

- Security checklist
- Performance criteria
- Style guide enforcement

**Documentation Templates**:

- API documentation format
- Architecture decision records
- Runbook structure

**Communication Patterns**:

- Status update format
- Incident reports
- Release notes structure

### Enterprise Workflows

**Compliance Requirements**:

- Regulatory standards application
- Audit trail generation
- Risk assessment framework

**Brand Management**:

- Visual identity guidelines
- Messaging standards
- Content approval workflow

**Data Governance**:

- PII handling procedures
- Data classification rules
- Retention policy application

## Getting Started

### 1. Enable Skills

**Claude.ai**:

- Settings > Capabilities > Skills
- Toggle on pre-built examples

**Claude Code**:

- Already enabled in beta
- Create Skills in `~/.claude/skills/`

**API**:

- Add required beta headers
- Enable code execution tool

### 2. Try Pre-Built Skills

Test Anthropic Skills with document tasks:

```
Create an Excel spreadsheet analyzing Q4 sales data
```

### 3. Create Your First Skill

Start with something simple you do often:

**Example - Weekly Update Skill**:

```yaml
---
name: Weekly Update
description: Generate weekly team update emails
---

# Weekly Update

## Format

1. Highlights (3-5 bullet points)
2. Metrics (table)
3. Challenges (2-3 items)
4. Next week (3-5 priorities)

## Tone

Professional but conversational, celebrate wins, present challenges constructively.
```

### 4. Iterate and Refine

Use the Skill, observe results, improve:

- Add more examples
- Clarify ambiguous instructions
- Include edge cases
- Reference supporting materials

## Best Practices

### Descriptive Names

Use clear, specific names:

- **Good**: "TypeScript API Client Generator"
- **Poor**: "API Tool"

### Precise Descriptions

Include activation triggers:

- **Good**: "Generate test suites when the user needs tests for
  TypeScript/JavaScript code"
- **Poor**: "Test generator"

### Comprehensive Examples

Show exactly what you want:

```markdown
## Example

**Input**: "Review the authentication module"

**Output**:

## Code Review: Authentication Module

### Critical Issues

1. **SQL Injection Vulnerability** (auth.ts:45) [Detailed explanation and fix]

[Complete example output]
```

### Progressive Disclosure

Structure large Skills with primary content in SKILL.md and detailed references
in supporting files:

```markdown
# Enterprise Architecture

## Quick Start

[Brief overview]

## Detailed Patterns

Load specific patterns as needed:

- Microservices: `cat patterns/microservices.md`
- Event-Driven: `cat patterns/event-driven.md`
```

### Version Control

For project Skills, commit to git:

```bash
git add .claude/skills/
git commit -m "feat: add code review Skill"
```

Team members automatically get Skills when they pull.

## Security Considerations

### Tool Restrictions

Use `allowed-tools` to enforce constraints:

**Read-only workflows**:

```yaml
allowed-tools: Read, Grep, Glob
```

**Full development**:

```yaml
allowed-tools: Read, Write, Edit, Bash, Grep, Glob
```

### Sensitive Information

**Never include** in Skills:

- API keys or secrets
- Passwords or credentials
- Customer data
- Proprietary algorithms (if Skills are shared publicly)

**Instead**:

- Reference external secure storage
- Document authentication processes without credentials
- Use placeholders for sensitive values

### Code Execution

Skills with executable scripts:

- Review code before adding to Skills
- Understand what scripts do
- Test in safe environments first
- Use version control for audit trail

## Performance Tips

### Efficient Context Usage

- **Metadata-driven activation**: Write precise descriptions
- **Lazy loading**: Reference detailed content in files, don't inline
- **Focused Skills**: Create specific Skills, not monolithic ones

### Skill Composition

Multiple focused Skills work better than one large Skill:

**Good**:

- Brand Guidelines Skill
- PowerPoint Template Skill
- Sales Messaging Skill

(All activate together for branded sales presentation)

**Poor**:

- "Everything About Sales Presentations" Skill

### File Organization

```
.claude/skills/brand-guidelines/
├── SKILL.md (core instructions)
├── reference.md (detailed guidelines)
├── colors.json (color palette data)
├── logo-usage.md (logo guidelines)
└── templates/
    ├── presentation.md
    └── document.md
```

Claude loads `SKILL.md` first, then additional files only as needed.

## Troubleshooting

### Skill Not Activating

**Check**:

1. Description matches task context
2. File location correct (`~/.claude/skills/` or `.claude/skills/`)
3. YAML frontmatter valid
4. Code execution enabled (if required)

**Try**:

- Explicit trigger: "Use the [Skill Name] skill to..."
- More specific description
- Verify file exists: `ls ~/.claude/skills/`

### Inconsistent Results

**Improve**:

1. Add more concrete examples
2. Be more prescriptive about format
3. Include templates and expected structure
4. Document edge cases explicitly

### Context Window Issues

**Optimize**:

1. Use progressive disclosure (reference files, don't inline)
2. Create focused Skills, not encyclopedic ones
3. Let Claude load content as needed

## Related Documentation

- [Skills API Guide](skills-api-guide.md) - API integration
- [Skills in Claude Code](skills-claude-code.md) - CLI usage
- [Skills User Guide](skills-user-guide.md) - Getting started
- [Skills Engineering Blog](skills-engineering-blog.md) - Technical deep dive
- [Skills Examples](skills-github-examples.md) - Community examples

## Additional Resources

- **Official Documentation**: https://docs.claude.com/
- **Skills Repository**: https://github.com/anthropics/skills
- **Community Forums**: https://community.anthropic.com/
- **Support**: https://support.claude.com/
