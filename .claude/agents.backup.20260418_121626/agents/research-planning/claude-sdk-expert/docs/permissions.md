# Claude Agent SDK Permissions

**Last Updated**: 2025-10-17 **Source**:
https://docs.claude.com/en/api/agent-sdk/permissions

## Overview

The Claude Agent SDK provides four complementary permission control mechanisms:

1. **Permission Modes** - Global settings affecting all tools
2. **canUseTool Callback** - Runtime handler for uncovered cases
3. **Hooks** - Fine-grained execution control
4. **Permission Rules (settings.json)** - Declarative allow/deny policies

## Permission Modes

### Available Modes

| Mode                | Behavior                                          |
| ------------------- | ------------------------------------------------- |
| `default`           | Standard permission checks apply                  |
| `plan`              | Planning mode (read-only tools only)              |
| `acceptEdits`       | Auto-approve file edits and filesystem operations |
| `bypassPermissions` | Skip all permission checks (use cautiously)       |

### Setting Permission Mode

**Initial Configuration:**

```typescript
const result = await query({
  prompt: 'Help me refactor this code',
  options: {
    permissionMode: 'default',
  },
});
```

**Dynamic Changes (Streaming Only):**

```typescript
const q = query({
  prompt: streamInput(),
  options: { permissionMode: 'default' },
});

await q.setPermissionMode('acceptEdits');
```

## Mode-Specific Behaviors

### Accept Edits Mode

Auto-approves file operations including edits, filesystem commands (mkdir,
touch, rm, mv, cp), and file creation/deletion. Other tools require normal
permissions.

### Bypass Permissions Mode

Automatically approves ALL tool uses without prompts. Hooks still execute and
can block operations. Recommended only for controlled environments.

## Permission Flow Priority

Processing order:

1. PreToolUse Hook
2. Deny Rules
3. Allow Rules
4. Ask Rules
5. Permission Mode Check
6. canUseTool Callback
7. PostToolUse Hook

**Key principle:** Explicit deny rules override all modes; hooks always execute
first.

## canUseTool Callback Implementation

```typescript
async function promptForToolApproval(toolName: string, input: any) {
  console.log(`\n🔧 Tool Request: ${toolName}`);

  if (input && Object.keys(input).length > 0) {
    console.log(`Arguments: ${JSON.stringify(input, null, 2)}`);
  }

  // Get user approval
  const approval = await getUserInput('Approve? (y/n): ');

  return approval.toLowerCase() === 'y'
    ? { behavior: 'allow' }
    : { behavior: 'deny', message: 'User denied permission' };
}
```

## Related Documentation

- [TypeScript SDK Reference](./typescript.md)
- [Python SDK Reference](./python.md)
- [Hooks Documentation](./overview.md#hooks)
