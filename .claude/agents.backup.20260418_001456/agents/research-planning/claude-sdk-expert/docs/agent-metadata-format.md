# Claude Code Agent Metadata Format

**Last Updated**: 2025-10-30 **Source**: GitHub Issues #8501, #9319, Official
Documentation Research **Category**: Claude Code / Agent Configuration

## Overview

This document provides the authoritative reference for Claude Code agent
metadata format based on official documentation, GitHub issues, and community
findings. It covers both **documented** and **undocumented but functional**
fields.

## Current Status (October 2025)

⚠️ **Important**: The official documentation at docs.claude.com does NOT include
complete agent metadata specification. GitHub Issue #8501 (opened September
2025, still OPEN) reports this gap.

## Agent File Structure

Agents are stored as Markdown files with YAML frontmatter:

```markdown
---
name: agent-name
description: Agent purpose and capabilities
tools: optional, comma-separated, list
model: sonnet
color: purple
---

System prompt content defining the agent's role and behavior.
```

## Storage Locations

**Priority order (highest to lowest)**:

1. **Project agents**: `.claude/agents/` (highest priority)
2. **User agents**: `~/.claude/agents/` (lower priority)

## Officially Documented Fields

These fields appear in the official Claude Code documentation at
docs.claude.com:

| Field         | Required | Type   | Description                                                            | Official Docs |
| ------------- | -------- | ------ | ---------------------------------------------------------------------- | ------------- |
| `name`        | ✅ Yes   | string | Unique identifier using lowercase letters and hyphens                  | ✅ Documented |
| `description` | ✅ Yes   | string | Natural language description of agent's purpose                        | ✅ Documented |
| `tools`       | ❌ No    | string | Comma-separated list of specific tools. If omitted, inherits all tools | ✅ Documented |
| `model`       | ❌ No    | enum   | Model to use: `sonnet`, `opus`, `haiku`, or `inherit`                  | ✅ Documented |

### Field Details

#### `name` (Required)

- **Format**: Lowercase letters and hyphens only
- **Convention**: `category-specialty` (e.g., `react-typescript-specialist`,
  `database-expert`)
- **Purpose**: Unique identifier for invoking the agent
- **Example**: `name: security-audit-specialist`

#### `description` (Required)

- **Format**: Natural language string (can be multiline with `|` syntax)
- **Purpose**: Explains when and how to use the agent
- **Best Practice**: Include:
  - Agent's specialty and expertise
  - When to invoke this agent
  - Example use cases
  - Key capabilities

**Example (Single-line)**:

```yaml
description:
  Expert in React and TypeScript development with focus on performance
  optimization
```

**Example (Multiline with examples)**:

```yaml
description: |
  Expert in security auditing and vulnerability assessment.

  Use when:
  - Reviewing code for security issues
  - Analyzing authentication flows
  - Checking for common vulnerabilities

  Examples:
  - "Audit the authentication module for security issues"
  - "Check this API endpoint for SQL injection vulnerabilities"
```

#### `tools` (Optional)

- **Format**: Comma-separated list of tool names
- **Default**: If omitted, agent inherits ALL available tools
- **Purpose**: Restrict agent to specific tools for focused operations
- **Available Tools**: Read, Write, Edit, Glob, Grep, Bash, WebFetch, WebSearch,
  Task, TodoWrite, NotebookEdit, etc.

**Examples**:

```yaml
# Code analysis agent (read-only)
tools: Read, Grep, Glob

# Full development agent
tools: Read, Write, Edit, Bash, Grep, Glob

# Research agent
tools: Read, WebFetch, WebSearch, Grep
```

#### `model` (Optional)

- **Format**: Model name or `inherit`
- **Options**:
  - `sonnet` - Claude 3.5 Sonnet (balanced, default)
  - `opus` - Claude 3 Opus (most capable, slower, expensive)
  - `haiku` - Claude 3 Haiku (fastest, cheapest, less capable)
  - `inherit` - Use same model as parent/main agent
- **Default**: Inherits from Claude Code settings
- **Purpose**: Optimize cost/performance for specific agent roles

**Cost Optimization Examples**:

```yaml
# High-value complex reasoning
model: opus

# Standard development tasks
model: sonnet

# Simple formatting or linting
model: haiku

# Match parent agent model
model: inherit
```

## Undocumented but Functional Fields

These fields work in Claude Code but are NOT mentioned in official
documentation:

| Field     | Status          | Type   | Description                                 | Evidence                   |
| --------- | --------------- | ------ | ------------------------------------------- | -------------------------- |
| `color`   | ⚠️ Undocumented | string | Visual badge color for agent identification | GitHub #8501, #9319        |
| `version` | ⚠️ Undocumented | semver | Agent version number                        | Community usage            |
| `x-color` | ❓ Unknown      | string | Possible alternative to `color`             | Mentioned in issue reports |

### `color` Field (Undocumented but Functional)

**Status**: Works in practice but not officially documented

**Purpose**: Visual identification in CLI output (colored badges around agent
names)

**Format**: Color name or hex code

**Examples from `/agents` command output**:

```yaml
color: purple
color: yellow
color: blue
color: red
color: green
```

**Known Issues**:

- ⚠️ Colored badges **removed in Claude Code v2.0.11** (Oct 2025) due to system
  prompt optimization
- GitHub Issue #9319 reports this as a bug (marked as duplicate of #9272)
- Visual feedback now reduced to plain text with bullet points
- Color field still accepted but no longer displayed visually

**Best Practice**: Include `color` field for future compatibility if/when visual
badges are restored.

### `version` Field (Community Usage)

**Status**: Not officially documented, widely used in community

**Format**: Semantic versioning (e.g., `1.0.0`, `1.2.3`)

**Purpose**: Track agent iterations and breaking changes

**Example**:

```yaml
version: 1.2.0
```

### `x-color` Field (Unconfirmed)

**Status**: Mentioned in some issue reports, unclear if functional

**Theory**: Possible namespaced alternative to `color` for forward compatibility

**Recommendation**: **Use `color` instead** until official documentation
clarifies

## Extended Metadata Fields (Custom/Community)

These fields are NOT part of Claude Code's official specification but are used
by community tools and enhanced agent systems:

| Field               | Type    | Description                           | Used By                   |
| ------------------- | ------- | ------------------------------------- | ------------------------- |
| `sdk_features`      | array   | SDK features used by agent            | claude-pattern repository |
| `cost_optimization` | boolean | Whether agent uses cost optimization  | claude-pattern repository |
| `session_aware`     | boolean | Whether agent maintains session state | claude-pattern repository |
| `sdk_self_aware`    | boolean | Agent understands SDK architecture    | claude-pattern repository |
| `last_updated`      | date    | Last modification date                | claude-pattern repository |

**Example (Extended Metadata)**:

```yaml
---
name: claude-sdk-expert
version: 1.1.0
description: Universal Claude Agent SDK specialist
color: purple
model: inherit
sdk_features: [subagents, sessions, cost_tracking, tool_restrictions]
cost_optimization: true
session_aware: true
sdk_self_aware: true
last_updated: 2025-10-30
---
```

⚠️ **Important**: Extended fields are ignored by Claude Code but can be useful
for:

- Custom agent management tools
- Documentation generation
- Agent discovery systems
- Version tracking

## Agent Creation Workflows

### Method 1: Interactive Creation (Recommended for Beginners)

```bash
# Use built-in command
/agents

# Claude Code will:
# 1. Ask for agent purpose
# 2. Generate appropriate description
# 3. Suggest tools and model
# 4. Create with color selection
# 5. Save to .claude/agents/
```

### Method 2: Manual Creation (Recommended for Advanced Users)

```bash
# Create agent file
touch .claude/agents/my-specialist.md

# Edit with your preferred editor
# Follow the template format
```

**Template**:

```markdown
---
name: my-specialist
description: |
  Brief one-line summary of specialty.

  Detailed explanation of capabilities and when to use this agent.

  Examples:
  - "Example use case 1"
  - "Example use case 2"
tools: Read, Write, Grep, Bash
model: sonnet
color: blue
---

You are a specialist in [domain]. Your role is to [primary responsibility].

## Core Expertise

- Expertise area 1
- Expertise area 2
- Expertise area 3

## Approach

When asked to [task], you:

1. First step
2. Second step
3. Third step

## Output Standards

Your work must include:

- Quality standard 1
- Quality standard 2
- Quality standard 3
```

### Method 3: Programmatic Creation (SDK)

**Important**: Agents created programmatically via SDK do NOT create filesystem
`.md` files automatically. They exist only in the SDK configuration.

**TypeScript Example**:

```typescript
import { query } from '@anthropic-ai/claude-agent-sdk';

const result = query({
  prompt: 'Analyze this code',
  options: {
    agents: {
      'security-auditor': {
        description: 'Security vulnerability specialist',
        prompt: 'You are a security expert. Analyze code for vulnerabilities.',
        tools: ['Read', 'Grep', 'Glob'],
        model: 'sonnet',
      },
    },
  },
});
```

**Python Example**:

```python
from claude_agent_sdk import query, ClaudeAgentOptions

options = ClaudeAgentOptions(
    agents={
        'security-auditor': {
            'description': 'Security vulnerability specialist',
            'prompt': 'You are a security expert.',
            'tools': ['Read', 'Grep', 'Glob'],
            'model': 'sonnet'
        }
    }
)

result = query(prompt="Analyze this code", options=options)
```

## Best Practices

### 1. Naming Conventions

- Use lowercase with hyphens
- Format: `{category}-{specialty}` or `{domain}-{role}`
- Examples: `react-typescript-specialist`, `database-expert`, `security-auditor`

### 2. Description Quality

- **First line**: One-sentence summary
- **Body**: Detailed capabilities and use cases
- **Examples**: Include 2-3 example invocations
- **Keywords**: Help Claude match agent to user intent

### 3. Tool Restrictions

- **Principle of Least Privilege**: Only grant tools the agent needs
- **Read-only agents**: Limit to Read, Grep, Glob for analysis tasks
- **Full-access agents**: Include Write, Edit, Bash for implementation tasks
- **Research agents**: Include WebFetch, WebSearch

### 4. Model Selection

- **Opus**: Complex reasoning, critical decisions, high-value work
- **Sonnet**: General-purpose development, balanced cost/performance (default)
- **Haiku**: Simple tasks, formatting, linting, fast feedback
- **Inherit**: Match parent agent (useful for subagent consistency)

### 5. Color Assignment (When Restored)

- Use distinct colors for frequently-used agents
- Color-code by category (e.g., all security agents = red)
- Avoid duplicate colors for better visual distinction

## Common Issues and Troubleshooting

### Issue: Agent not found when invoked

**Symptoms**:

```
Error: Agent 'my-agent' not found
```

**Solutions**:

1. Check file exists: `ls .claude/agents/my-agent.md`
2. Verify name matches filename: `my-agent.md` → `name: my-agent`
3. Check YAML syntax is valid
4. Restart Claude Code if using CLI

### Issue: Agent uses wrong tools

**Symptoms**: Agent attempts to use tools not in `tools` field

**Solutions**:

1. Verify `tools` field is set (if omitted, agent gets ALL tools)
2. Check tool names are spelled correctly
3. Tool names are case-sensitive: `Read` not `read`

### Issue: Color not displaying

**Symptoms**: No colored badges, plain text output

**Known Cause**: Claude Code v2.0.11+ removed colored badges (system prompt
optimization)

**Status**: GitHub Issue #9319 (closed as duplicate), no official fix timeline

**Workaround**: None currently available

## Version History & Breaking Changes

| Claude Code Version | Date        | Change                   | Impact               |
| ------------------- | ----------- | ------------------------ | -------------------- |
| v1.0.60             | Unknown     | Custom agents introduced | ✅ New feature       |
| v2.0.10             | Oct 7, 2025 | Colored badges working   | ✅ Visual feedback   |
| v2.0.11             | Oct 8, 2025 | Colored badges removed   | ⚠️ Visual regression |
| v2.0.12-2.0.29      | Oct 2025    | Badges still missing     | ⚠️ Ongoing issue     |

## References

- **Official Documentation**:
  https://docs.claude.com/en/docs/claude-code/settings
- **GitHub Issue #8501**: YAML frontmatter documentation gap (OPEN)
- **GitHub Issue #9319**: Colored badges removed (Closed as duplicate)
- **Community Documentation**: https://claudelog.com/mechanics/custom-agents/

## Future Considerations

### Anticipated Changes

1. **Complete Official Specification**: GitHub #8501 requests authoritative
   field list
2. **Colored Badges Restoration**: Community requests visual feedback return
3. **Extended Metadata**: Possible addition of version, tags, categories

### Monitoring for Updates

- Watch GitHub anthropics/claude-code repository
- Check Claude Code release notes
- Monitor official documentation updates
- Follow community discussions

---

**Documentation Status**: ✅ Current as of Claude Code v2.0.29 (October 2025)

**Known Gaps**: Official documentation incomplete; relying on implementation
behavior and community findings

**Next Review**: When GitHub #8501 is resolved or major Claude Code release
