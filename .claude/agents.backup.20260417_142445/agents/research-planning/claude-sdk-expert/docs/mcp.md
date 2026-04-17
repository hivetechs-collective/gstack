# MCP in the SDK

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/agent-sdk/mcp

## Overview

The Model Context Protocol (MCP) extends Claude Code with custom tools and
capabilities. MCPs can operate as external processes, connect via HTTP/SSE, or
execute directly within SDK applications.

## Configuration

### Basic Setup

Configure MCP servers in `.mcp.json` at your project root:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["@modelcontextprotocol/server-filesystem"],
      "env": {
        "ALLOWED_PATHS": "/Users/me/projects"
      }
    }
  }
}
```

### SDK Integration

TypeScript example for querying with MCP servers:

```typescript
import { query } from '@anthropic-ai/claude-agent-sdk';

for await (const message of query({
  prompt: 'List files in my project',
  options: {
    mcpServers: {
      filesystem: {
        command: 'npx',
        args: ['@modelcontextprotocol/server-filesystem'],
        env: {
          ALLOWED_PATHS: '/Users/me/projects',
        },
      },
    },
    allowedTools: ['mcp__filesystem__list_files'],
  },
})) {
  if (message.type === 'result' && message.subtype === 'success') {
    console.log(message.result);
  }
}
```

## Transport Types

### stdio Servers

External processes communicating via stdin/stdout for local tool execution.

### HTTP/SSE Servers

Remote servers with network communication:

```json
{
  "mcpServers": {
    "remote-api": {
      "type": "sse",
      "url": "https://api.example.com/mcp/sse",
      "headers": {
        "Authorization": "Bearer ${API_TOKEN}"
      }
    }
  }
}
```

### SDK MCP Servers

In-process servers running within your application for custom tool creation.

## Resource Management

MCPs expose resources that Claude can list and read. Resources provide context
like file contents, API documentation, or database schemas.

## Related Documentation

- [Custom Tools](./custom-tools.md)
- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
