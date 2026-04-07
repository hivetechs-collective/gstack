# System Prompts Modification Guide

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/agent-sdk/modifying-system-prompts

## Overview

The Claude Agent SDK provides four distinct approaches to customize system
prompts, each suited to different use cases and persistence requirements.

## Four Methods

### 1. CLAUDE.md Files (Project-Level Instructions)

**Purpose:** Persistent, team-shared project context

**Key Requirements:**

- Must explicitly configure `settingSources: ['project']` (TypeScript) or
  `setting_sources=['project']` (Python)
- The `claude_code` preset alone does NOT automatically load CLAUDE.md
- Locations: `CLAUDE.md`, `.claude/CLAUDE.md`, or `~/.claude/CLAUDE.md`

**Best For:**

- Team-shared context that should be version controlled
- Coding standards and conventions
- Common build/test commands
- Long-term project memory

### 2. Output Styles (Persistent Configurations)

**Purpose:** Saved, reusable prompt modifications across sessions

**Storage:** Markdown files in `~/.claude/output-styles` or
`.claude/output-styles`

**Activation Methods:**

- CLI: `/output-style [style-name]`
- Settings: `.claude/settings.local.json`
- Creation: `/output-style:new [description]`

**Best For:**

- Specialized assistants (code reviewers, data scientists)
- Complex, versioned prompt modifications
- Cross-project reusability

### 3. systemPrompt with Append

**Syntax:**

```typescript
systemPrompt: {
  type: "preset",
  preset: "claude_code",
  append: "Your custom instructions here"
}
```

**Advantages:**

- Preserves Claude Code's built-in tools and safety guidelines
- Session-specific customization
- Maintains environment context

**Best For:**

- Adding coding standards or formatting preferences
- Domain-specific knowledge enhancement
- Response verbosity modifications

### 4. Custom System Prompts

**Approach:** Replace default entirely with custom string

**Trade-offs:**

- Complete behavioral control
- Loses default tools unless explicitly included
- Must provide environment context manually

**Best For:**

- Specialized single-session tasks
- Testing new prompt strategies
- Unique agent behaviors

## Related Documentation

- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [Overview](./overview.md)
