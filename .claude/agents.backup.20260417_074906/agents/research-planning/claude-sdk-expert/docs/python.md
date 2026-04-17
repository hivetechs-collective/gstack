# Python Agent SDK Reference

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/agent-sdk/python

## Installation

```bash
pip install claude-agent-sdk
```

## Core Functions

### `query()`

Creates a new session for each interaction. Returns an async iterator yielding
messages as they arrive.

```python
async def query(
    *,
    prompt: str | AsyncIterable[dict[str, Any]],
    options: ClaudeAgentOptions | None = None
) -> AsyncIterator[Message]
```

**Use case:** One-off questions where you don't need conversation history

### `ClaudeSDKClient`

Maintains conversation session across multiple exchanges, enabling context
retention and follow-up interactions.

```python
async with ClaudeSDKClient(options=options) as client:
    await client.query("Initial prompt")
    async for message in client.receive_response():
        print(message)
```

**Key methods:**

- `connect()` - Establish connection
- `query()` - Send request in streaming mode
- `receive_messages()` - Get all messages as async iterator
- `receive_response()` - Get messages until ResultMessage
- `interrupt()` - Stop execution mid-task
- `disconnect()` - Close connection

## Tool Definition

### `@tool()` Decorator

```python
@tool("name", "description", {"param": type})
async def tool_func(args: dict[str, Any]) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": "result"}]}
```

### `create_sdk_mcp_server()`

```python
server = create_sdk_mcp_server(
    name="calculator",
    version="1.0.0",
    tools=[add, multiply]
)
```

## Configuration: ClaudeAgentOptions

Key parameters:

- `allowed_tools` - List of permitted tool names
- `system_prompt` - Custom or preset system instructions
- `mcp_servers` - MCP server configurations
- `permission_mode` - Control tool execution ("default", "acceptEdits", "plan",
  "bypassPermissions")
- `cwd` - Working directory
- `can_use_tool` - Custom permission callback

## Related Documentation

- [TypeScript SDK Reference](./typescript.md)
- [Streaming vs Single Mode](./streaming-vs-single-mode.md)
- [Custom Tools](./custom-tools.md)
- [Permissions](./permissions.md)
