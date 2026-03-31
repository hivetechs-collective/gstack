# Claude Agent SDK Session Management

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/agent-sdk/sessions

## Overview

The Claude Agent SDK provides session management capabilities for maintaining
conversation state across multiple interactions. Sessions automatically capture
context and enable resumption of previous conversations.

## Core Concepts

### Session Creation

When initiating a query, the SDK automatically generates a session and returns a
session ID in the initial system message. This identifier allows developers to
preserve and restore conversation history.

### Getting the Session ID

The first message received contains initialization data with the session ID that
can be captured for later use.

**TypeScript Example:**

```typescript
const response = query({
  prompt: 'Help me build a web application',
  options: { model: 'claude-sonnet-4-5' },
});

for await (const message of response) {
  if (message.type === 'system' && message.subtype === 'init') {
    sessionId = message.session_id;
  }
}
```

## Session Resumption

Developers can continue previous conversations by passing a saved session ID to
the `resume` option. The SDK automatically loads conversation history and
context, enabling Claude to pick up exactly where it left off.

**TypeScript Example:**

```typescript
const response = query({
  prompt: 'Continue implementing the authentication system',
  options: {
    resume: 'session-xyz',
    model: 'claude-sonnet-4-5',
  },
});
```

## Session Forking

By default, resuming a session appends new messages to the original
conversation. The `forkSession` option creates a new branch starting from the
resumed state, preserving the original session unchanged.

### Use Cases for Forking

- Exploring alternative approaches from the same starting point
- Creating multiple conversation branches without modifying originals
- Testing changes independently
- Maintaining separate experimental paths

### Forking vs. Continuing

| Aspect     | Continue (default)  | Fork               |
| ---------- | ------------------- | ------------------ |
| Session ID | Remains same        | New ID generated   |
| History    | Appends to original | Creates new branch |
| Original   | Modified            | Preserved          |

**TypeScript Example:**

```typescript
const forkedResponse = query({
  prompt: 'Redesign as GraphQL instead',
  options: {
    resume: 'session-xyz',
    forkSession: true,
  },
});
```

## Related Documentation

- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [Streaming vs Single Mode](./streaming-vs-single-mode.md)
