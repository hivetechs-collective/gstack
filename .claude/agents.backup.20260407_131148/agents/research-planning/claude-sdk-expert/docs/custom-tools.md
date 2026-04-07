# Custom Tools Documentation

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/agent-sdk/custom-tools

## Overview

The Claude Agent SDK enables developers to build type-safe custom tools through
in-process MCP servers, extending Claude's capabilities to interact with
external services and APIs.

## Core Creation Pattern

Tools are defined using helper functions with structured schemas:

**Key Components:**

- `createSdkMcpServer()` - Initializes an MCP server with custom tools
- `tool()` - Defines individual tools with validation schemas
- Zod schemas - Provide runtime validation and TypeScript type safety

## Tool Structure

Each tool requires:

1. **Name** - Identifier for the tool
2. **Description** - Purpose and functionality explanation
3. **Schema** - Parameter definitions using Zod with type validation
4. **Handler** - Async function implementing tool logic

## Important Requirements

**Streaming Input Requirement:** Custom MCP tools mandate async
generator/iterable prompts rather than simple strings.

**Tool Naming Convention:** Tools follow the pattern
`mcp__{server_name}__{tool_name}` when exposed to Claude.

## Configuration

The `allowedTools` option controls which tools Claude can access, enabling
selective tool exposure within a single server.

## Example: Database Query Tool

```typescript
import {
  tool,
  createSdkMcpServer,
  query,
} from '@anthropic-ai/claude-agent-sdk';
import { z } from 'zod';

const dbServer = createSdkMcpServer({
  name: 'database',
  version: '1.0.0',
  tools: [
    tool(
      'query_users',
      'Query user database with SQL',
      {
        sql: z.string().describe('SQL query to execute'),
        params: z.array(z.any()).optional().describe('Query parameters'),
      },
      async (args) => {
        // Execute query
        const results = await db.query(args.sql, args.params);
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(results, null, 2),
            },
          ],
        };
      }
    ),
  ],
});
```

## Error Handling

Tools should gracefully manage failures by returning structured error messages
within the response content, maintaining consistent communication with Claude.

## Related Documentation

- [MCP Overview](./mcp.md)
- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
