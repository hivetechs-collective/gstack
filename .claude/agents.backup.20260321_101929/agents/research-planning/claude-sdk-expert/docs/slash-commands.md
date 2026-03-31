# Slash Commands in the Claude Agent SDK

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/agent-sdk/slash-commands

## Overview

Slash commands provide a mechanism to control Claude Code sessions through the
SDK with special commands prefixed by `/`. These enable actions like
conversation management and custom workflows.

## Built-in Commands

### `/compact`

Reduces conversation history size by summarizing older messages while preserving
essential context. Access compaction metadata through the `compact_boundary`
system message.

### `/clear`

Initiates a fresh conversation by removing all previous history. Returns a new
`init` system message with updated session information.

## Discovering Available Commands

The system initialization message contains available slash commands. Access this
information when your session starts:

```typescript
if (message.type === 'system' && message.subtype === 'init') {
  console.log('Available slash commands:', message.slash_commands);
}
```

## Creating Custom Slash Commands

Custom commands are defined as markdown files in designated directories:

- **Project scope**: `.claude/commands/`
- **Personal scope**: `~/.claude/commands/`

### File Format

The filename (minus `.md` extension) becomes the command name. Optional YAML
frontmatter provides configuration:

```markdown
---
allowed-tools: Read, Grep, Glob
description: Command description
model: claude-sonnet-4-5-20250929
---

Command instructions and behavior definition.
```

### Advanced Features

**Arguments**: Use `$1`, `$2` placeholders with `argument-hint` frontmatter

**Bash execution**: Include output via \`!backticks\` syntax

**File references**: Use `@filename` to include file contents

**Namespacing**: Organize commands in subdirectories for better structure

## Usage Through SDK

Once defined, custom commands are automatically available:

```typescript
for await (const message of query({
  prompt: '/custom-command arg1 arg2',
  options: { maxTurns: 3 },
})) {
  // Process results
}
```

## Related Documentation

- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [Sessions](./sessions.md)
