# Subagents in the Claude Agent SDK

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/agent-sdk/subagents

## Overview

Subagents are specialized AI assistants orchestrated by a main agent. They
operate with separate contexts and can run concurrently, making them ideal for
complex workflows requiring focused expertise.

## Key Benefits

**Context Management**: Subagents maintain separate context from the main agent,
preventing information overload by isolating specialized tasks from the primary
conversation.

**Parallelization**: Multiple subagents execute simultaneously, dramatically
accelerating complex processes like code reviews that might otherwise take
minutes.

**Specialized Instructions**: Each subagent receives tailored system prompts
with domain-specific expertise, best practices, and operational constraints.

**Tool Restrictions**: Subagents can be limited to specific tools, reducing
unintended action risks.

## Definition Methods

### Programmatic Approach (Recommended)

Define subagents directly in code using the `agents` parameter:

```javascript
const result = query({
  prompt: 'Review the authentication module',
  options: {
    agents: {
      'code-reviewer': {
        description: 'Expert code review specialist',
        prompt: 'You are a code review specialist...',
        tools: ['Read', 'Grep', 'Glob'],
        model: 'sonnet',
      },
    },
  },
});
```

### Filesystem-Based Approach

Create markdown files in `.claude/agents/` directories with YAML frontmatter
defining agent configuration and system prompts.

## AgentDefinition Configuration

| Field         | Type     | Required | Purpose                         |
| ------------- | -------- | -------- | ------------------------------- |
| `description` | string   | Yes      | When to invoke this agent       |
| `prompt`      | string   | Yes      | System prompt defining behavior |
| `tools`       | string[] | No       | Allowed tool names              |
| `model`       | string   | No       | Model override option           |

## Integration Patterns

**Automatic Invocation**: Claude automatically selects appropriate subagents
based on task context and agent descriptions.

**Explicit Invocation**: Users can request specific subagents directly in
prompts.

**Dynamic Configuration**: Agents can be programmatically created based on
application requirements.

## Common Tool Combinations

- **Read-only Analysis**: `['Read', 'Grep', 'Glob']`
- **Code Modification**: `['Read', 'Edit', 'Write']`
- **Web Research**: `['WebSearch', 'WebFetch', 'Read']`
- **System Operations**: `['Bash', 'Read', 'Write']`

## Related Documentation

- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [Custom Tools](./custom-tools.md)
