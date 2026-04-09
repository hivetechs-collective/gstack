# Streaming vs Single Message Input

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/agent-sdk/streaming-vs-single-mode

## Overview

The Claude Agent SDK provides two distinct input modes for agent interactions,
each suited to different use cases and architectural requirements.

## Streaming Input Mode (Recommended)

**Status:** Default and preferred approach

### Key Capabilities

Streaming input mode enables persistent, interactive sessions with full agent
functionality. It allows the agent to operate as a long lived process that takes
in user input, handles interruptions, surfaces permission requests, and handles
session management.

### Supported Features

- **Image Attachments:** Direct image uploads for visual analysis
- **Message Queuing:** Sequential processing of multiple messages with
  interruption capability
- **Tool Integration:** Complete access to all tools and custom MCP servers
- **Lifecycle Hooks:** Customization at various operational points
- **Real-time Feedback:** Streaming responses as they generate
- **Context Persistence:** Natural multi-turn conversation maintenance

### Implementation Pattern

```typescript
async function* generateMessages() {
  yield { type: 'user', message: { role: 'user', content: '...' } };
  await new Promise((resolve) => setTimeout(resolve, 2000));
  // Follow-up messages can include images
}

for await (const message of query({ prompt: generateMessages() })) {
  if (message.type === 'result') console.log(message.result);
}
```

## Single Message Input

**Status:** Simpler but limited alternative

### Appropriate Use Cases

Single message input suits scenarios requiring one-shot response without needing
image attachments, hooks, etc. or when operating in stateless environment, such
as a lambda function.

### Limitations

This mode explicitly does **not** support:

- Direct image attachments in messages
- Dynamic message queueing
- Real-time interruption
- Hook integration
- Natural multi-turn conversations

### Implementation Pattern

```typescript
for await (const message of query({
  prompt: 'Explain the authentication flow',
  options: { maxTurns: 1, allowedTools: ['Read', 'Grep'] },
})) {
  if (message.type === 'result') console.log(message.result);
}
```

## Related Documentation

- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [Sessions](./sessions.md)
