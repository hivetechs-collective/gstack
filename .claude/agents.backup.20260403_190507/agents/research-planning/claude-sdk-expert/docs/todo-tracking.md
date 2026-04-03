# Todo Lists Documentation

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/agent-sdk/todo-tracking

## Overview

The Claude Agent SDK provides built-in todo functionality for organizing complex
workflows and displaying progress to users.

## Todo Lifecycle

Todos progress through four states:

1. **Created** as `pending` when tasks are identified
2. **Activated** to `in_progress` when work begins
3. **Completed** when the task finishes successfully
4. **Removed** when all tasks in a group are completed

## When Todos Are Used

The SDK automatically creates todos for:

- **Complex multi-step tasks** requiring 3 or more distinct actions
- **User-provided task lists** when multiple items are mentioned
- **Non-trivial operations** that benefit from progress tracking
- **Explicit requests** when users ask for todo organization

## Implementation Patterns

### Monitoring Todo Changes

Listen for `TodoWrite` tool calls within the message stream. When the assistant
updates todos, access the updated list and display status changes to users.

### Real-time Progress Display

```typescript
class TodoTracker {
  track(message: any) {
    if (message.type === 'tool_use' && message.name === 'TodoWrite') {
      const todos = message.input.todos;
      const completed = todos.filter((t) => t.status === 'completed').length;
      const inProgress = todos.filter((t) => t.status === 'in_progress').length;
      const total = todos.length;

      console.log(
        `Progress: ${completed}/${total} completed, ${inProgress} in progress`
      );

      todos.forEach((todo) => {
        const icon =
          todo.status === 'completed'
            ? '✅'
            : todo.status === 'in_progress'
              ? '🔧'
              : '⏳';
        console.log(`${icon} ${todo.content}`);
      });
    }
  }
}
```

## Related Resources

- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [Streaming vs Single Mode](./streaming-vs-single-mode.md)
- [Custom Tools](./custom-tools.md)
