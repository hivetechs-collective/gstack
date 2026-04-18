# Claude Agent SDK Migration Guide

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/docs/claude-code/sdk/migration-guide

## Overview

The Claude Code SDK has been rebranded as the Claude Agent SDK to reflect its
expanded capabilities beyond coding tasks. This guide covers migrating
TypeScript/JavaScript and Python projects.

## Key Changes

| Aspect                    | Old                         | New                              |
| ------------------------- | --------------------------- | -------------------------------- |
| **TypeScript/JS Package** | `@anthropic-ai/claude-code` | `@anthropic-ai/claude-agent-sdk` |
| **Python Package**        | `claude-code-sdk`           | `claude-agent-sdk`               |
| **Documentation**         | Claude Code docs            | API Guide → Agent SDK section    |

## TypeScript/JavaScript Migration

**Step 1: Remove old package**

```bash
npm uninstall @anthropic-ai/claude-code
```

**Step 2: Install new package**

```bash
npm install @anthropic-ai/claude-agent-sdk
```

**Step 3: Update imports**

```javascript
// Before
import { query, tool, createSdkMcpServer } from '@anthropic-ai/claude-code';

// After
import {
  query,
  tool,
  createSdkMcpServer,
} from '@anthropic-ai/claude-agent-sdk';
```

## Python Migration

**Step 1: Remove old package**

```bash
pip uninstall claude-code-sdk
```

**Step 2: Install new package**

```bash
pip install claude-agent-sdk
```

**Step 3: Update imports and types**

```python
# Before
from claude_code_sdk import query, ClaudeCodeOptions

# After
from claude_agent_sdk import query, ClaudeAgentOptions

options = ClaudeAgentOptions(model="claude-sonnet-4-5")
```

## Breaking Changes

### System Prompt Behavior

The SDK no longer applies Claude Code's default system prompt. To restore
previous behavior:

```typescript
const result = query({
  prompt: 'Hello',
  options: {
    systemPrompt: { type: 'preset', preset: 'claude_code' },
  },
});
```

### Settings Sources

Filesystem settings (CLAUDE.md, settings.json, slash commands) are no longer
loaded by default. You must explicitly configure `settingSources`:

**TypeScript:**

```typescript
const result = query({
  prompt: 'Analyze this codebase',
  options: {
    settingSources: ['project', 'global'],
  },
});
```

**Python:**

```python
result = query(
  prompt="Analyze this codebase",
  options=ClaudeAgentOptions(
    setting_sources=['project', 'global']
  )
)
```

## Migration Checklist

- [ ] Update package dependencies
- [ ] Update import statements
- [ ] Add explicit `systemPrompt` configuration if using Claude Code preset
- [ ] Add `settingSources` if relying on CLAUDE.md or settings.json
- [ ] Test all existing functionality
- [ ] Update documentation references
- [ ] Review breaking changes in dependencies

## Additional Resources

- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [System Prompts Modification](./modifying-system-prompts.md)
- [Sessions Management](./sessions.md)
