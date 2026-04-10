# Claude Agent SDK Overview

**Last Updated**: 2025-11-25 **Source**:
https://docs.claude.com/en/api/agent-sdk/overview **SDK Version**: Latest
(renamed from Claude Code SDK) **Default Model**: Claude Sonnet 4.6
(`claude-sonnet-4-6`)

## Introduction

The Claude Agent SDK (formerly Claude Code SDK) is a production-ready framework
for building custom AI agents. Built on the agent harness powering Claude Code,
it provides comprehensive tools for creating specialized agents across various
domains.

**Important Name Change**: The package was renamed from
`@anthropic-ai/claude-code` to `@anthropic-ai/claude-agent-sdk` to reflect its
expanded capabilities beyond just coding tasks.

## Installation

**TypeScript:**

```bash
npm install @anthropic-ai/claude-agent-sdk
```

**Python:**

```bash
pip install claude-agent-sdk
```

## Core Capabilities

The SDK delivers several foundational features:

### Context Management

The system automatically compacts and manages context to prevent agents from
exhausting their token limits during extended operations. This ensures reliable
performance even in long-running sessions.

### Tool Ecosystem

Agents access:

- **File operations**: Read, Write, Edit, Glob, Grep
- **Code execution**: Bash
- **Web capabilities**: WebSearch, WebFetch
- **Extensibility**: MCP (Model Context Protocol) for custom tools

### Permission Controls

Fine-grained settings allow developers to specify which tools agents can access:

- `allowedTools` - Explicit whitelist of permitted tools
- `disallowedTools` - Explicit blacklist of forbidden tools
- `permissionMode` - Global permission strategy
- `canUseTool` - Runtime permission callback

### Production Features

Built-in capabilities ensure reliability in deployed environments:

- Error handling and recovery
- Session management and resumption
- Usage tracking and cost monitoring
- Todo tracking for complex workflows

## Authentication Methods

### Standard API Key

Retrieve an API key from the [Claude Console](https://console.anthropic.com/)
and set the `ANTHROPIC_API_KEY` environment variable:

```bash
export ANTHROPIC_API_KEY=sk-ant-api03-...
```

### Alternative Providers

**Amazon Bedrock:**

```bash
export CLAUDE_CODE_USE_BEDROCK=1
# Configure AWS credentials via standard AWS methods
```

**Google Vertex AI:**

```bash
export CLAUDE_CODE_USE_VERTEX=1
# Configure Google Cloud credentials
```

## Agent Types You Can Build

### Coding Agents

- **SRE Systems**: Diagnose production issues, analyze logs
- **Security Auditors**: Review code for vulnerabilities
- **Incident Triage**: Classify and prioritize incidents
- **Code Review Bots**: Enforce standards and best practices

### Business Agents

- **Legal Contract Reviewers**: Analyze agreements and terms
- **Financial Analysts**: Process reports and generate insights
- **Customer Support Specialists**: Handle inquiries and tickets
- **Content Creation Assistants**: Generate marketing copy and documentation

## Claude Code Feature Support

The SDK provides access to all Claude Code features through file system
configuration. **Important**: You must explicitly set `settingSources` to load
these features.

### Subagents

Specialized agents stored as Markdown files in `./.claude/agents/`. Each
subagent has:

- YAML frontmatter with configuration
- System prompt defining behavior
- Tool restrictions for safety
- Model selection overrides

### Hooks

Custom commands configured in `./.claude/settings.json` responding to tool
events:

- `OnMessage` - React to messages
- `OnToolUse` - Intercept tool execution
- `PreToolUse` / `PostToolUse` - Before/after tool execution

### Slash Commands

Custom commands defined as Markdown files in `./.claude/commands/`:

- **Project-level**: `.claude/commands/`
- **Personal**: `~/.claude/commands/`
- Supports arguments, bash execution, file references

### Memory

Project context maintained through:

- `CLAUDE.md` or `.claude/CLAUDE.md` - Project instructions
- `~/.claude/CLAUDE.md` - Global user preferences

To load memory files, explicitly set `settingSources`:

```typescript
const result = query({
  prompt: "Analyze this project",
  options: {
    settingSources: ["project", "global"],
  },
});
```

## Quick Start Example

**TypeScript:**

```typescript
import { query } from "@anthropic-ai/agent-sdk"; // Note: package renamed!

for await (const message of query({
  prompt: "Analyze the authentication flow in this codebase",
  options: {
    model: "claude-sonnet-4-6", // New default model (Nov 2025)
    allowedTools: ["Read", "Grep", "Glob"],
    settingSources: ["project"], // Required to load CLAUDE.md
  },
})) {
  if (message.type === "result" && message.subtype === "success") {
    console.log(message.result);
  }
}
```

**Cost-Optimized with Haiku 4.5:**

```typescript
import { query } from "@anthropic-ai/agent-sdk";

// Use Haiku 4.5 for lightweight tasks (3x cheaper, 2x faster)
for await (const message of query({
  prompt: "List all TypeScript files in src/",
  options: {
    model: "claude-haiku-4-5", // 90% of Sonnet performance
    allowedTools: ["Glob"],
    settingSources: ["project"],
  },
})) {
  // ...
}
```

**Python:**

```python
from claude_agent_sdk import query, ClaudeAgentOptions

async for message in query(
  prompt="Analyze the authentication flow in this codebase",
  options=ClaudeAgentOptions(
    model="claude-sonnet-4-6",  # New default model (Nov 2025)
    allowed_tools=["Read", "Grep", "Glob"],
    setting_sources=['project']  # Required to load CLAUDE.md
  )
):
  if message.type == "result" and message.subtype == "success":
    print(message.result)
```

## BREAKING CHANGES (November 2025)

### System Prompt No Longer Included

**CRITICAL**: The SDK no longer uses Claude Code's system prompt by default. You
must either:

1. **Use settingSources** to load CLAUDE.md files (recommended):

```typescript
options: {
  settingSources: ["project", "global"];
}
```

2. **Provide explicit system prompt**:

```typescript
options: {
  systemPrompt: { type: "text", text: "Your custom prompt" }
}
```

3. **Append to default** (if available):

```typescript
options: {
  appendSystemPrompt: "Additional instructions";
}
```

### Model Deprecations

The following models are **deprecated and will error**:

- ❌ `claude-3-sonnet-*` → Use `claude-sonnet-4-6`
- ❌ `claude-2*` → Use `claude-sonnet-4-6`
- ❌ `claude-3-5-sonnet-*` → Use `claude-sonnet-4-6`

## Next Steps

- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [Creating Custom Tools](./custom-tools.md)
- [Working with Subagents](./subagents.md)
- [Session Management](./sessions.md)
- [Cost Tracking](./cost-tracking.md)
