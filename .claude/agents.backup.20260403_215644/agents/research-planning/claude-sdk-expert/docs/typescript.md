# TypeScript Agent SDK Documentation

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/agent-sdk/typescript

## Installation

```typescript
npm install @anthropic-ai/claude-agent-sdk
```

## Core Functions

### `query()`

The primary interface for interacting with Claude Code. Returns an async
generator streaming messages.

```typescript
function query({
  prompt,
  options,
}: {
  prompt: string | AsyncIterable<SDKUserMessage>;
  options?: Options;
}): Query;
```

**Key capabilities:**

- Accepts string prompts or async iterables for streaming
- Returns `Query` object extending `AsyncGenerator<SDKMessage, void>`
- Provides `interrupt()` and `setPermissionMode()` methods

### `tool()`

Creates type-safe MCP tool definitions using Zod schemas.

```typescript
function tool<Schema extends ZodRawShape>(
  name: string,
  description: string,
  inputSchema: Schema,
  handler: (args, extra) => Promise<CallToolResult>
): SdkMcpToolDefinition<Schema>;
```

### `createSdkMcpServer()`

Instantiates an in-process MCP server.

```typescript
function createSdkMcpServer(options: {
  name: string;
  version?: string;
  tools?: Array<SdkMcpToolDefinition<any>>;
}): McpSdkServerConfigWithInstance;
```

## Configuration Options

The `Options` type supports:

| Property            | Type              | Default         | Purpose                     |
| ------------------- | ----------------- | --------------- | --------------------------- |
| `model`             | string            | CLI default     | Claude model selection      |
| `cwd`               | string            | `process.cwd()` | Working directory           |
| `permissionMode`    | `PermissionMode`  | `'default'`     | Permission handling         |
| `settingSources`    | `SettingSource[]` | `[]`            | Load filesystem settings    |
| `maxThinkingTokens` | number            | undefined       | Extended thinking limit     |
| `mcpServers`        | Record            | `{}`            | MCP server configs          |
| `agents`            | Record            | undefined       | Subagent definitions        |
| `hooks`             | Partial<Record>   | `{}`            | Event callbacks             |
| `allowedTools`      | string[]          | undefined       | Tool whitelist              |
| `disallowedTools`   | string[]          | undefined       | Tool blacklist              |
| `canUseTool`        | Function          | undefined       | Runtime permission callback |

## Permission Modes

- `'default'` - Standard permissions
- `'acceptEdits'` - Auto-accept file edits
- `'bypassPermissions'` - Skip all checks
- `'plan'` - Planning mode, no execution

## Built-in Tool Types

The SDK includes built-in tools like:

- `Bash` - Execute shell commands
- `Read` - Read files
- `Write` - Write files
- `Edit` - Modify files
- `WebSearch` - Search the web
- `Grep` - Search file contents
- `Glob` - Pattern-based file finding

## Example: Basic Query

```typescript
import { query } from '@anthropic-ai/claude-agent-sdk';

async function main() {
  for await (const message of query({
    prompt: 'Help me refactor this code',
    options: {
      model: 'claude-sonnet-4-5',
      allowedTools: ['Read', 'Edit', 'Grep'],
    },
  })) {
    if (message.type === 'result') {
      console.log(message.result);
    }
  }
}

main();
```

## Example: Custom Tool Creation

```typescript
import {
  query,
  tool,
  createSdkMcpServer,
} from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';

const weatherServer = createSdkMcpServer({
  name: 'weather-tools',
  version: '1.0.0',
  tools: [
    tool(
      'get_weather',
      'Get current weather for a location',
      {
        location: z.string().describe('City name'),
        units: z.enum(['celsius', 'fahrenheit']).default('celsius'),
      },
      async (args) => {
        // Implementation
        return {
          content: [
            {
              type: 'text',
              text: `Weather data for ${args.location}`,
            },
          ],
        };
      }
    ),
  ],
});

async function main() {
  for await (const message of query({
    prompt: "What's the weather in London?",
    options: {
      mcpServers: {
        'weather-tools': weatherServer,
      },
      allowedTools: ['mcp__weather-tools__get_weather'],
    },
  })) {
    console.log(message);
  }
}
```

## Example: Streaming Input

```typescript
import { query } from '@anthropic-ai/claude-agent-sdk';

async function* generateMessages() {
  yield {
    type: 'user' as const,
    message: {
      role: 'user' as const,
      content: 'Analyze this codebase',
    },
  };

  yield {
    type: 'user' as const,
    message: {
      role: 'user' as const,
      content: 'Now check for security issues',
    },
  };
}

async function main() {
  for await (const message of query({
    prompt: generateMessages(),
    options: {
      maxTurns: 10,
      allowedTools: ['Read', 'Grep', 'Glob'],
    },
  })) {
    if (message.type === 'assistant') {
      console.log(message.content);
    }
  }
}
```

## Related Documentation

- [Python SDK Reference](./python.md)
- [Streaming vs Single Mode](./streaming-vs-single-mode.md)
- [Custom Tools](./custom-tools.md)
- [Permissions](./permissions.md)
