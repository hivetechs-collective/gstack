# Claude Code Hooks Reference

**Last Updated**: 2025-12-22 **Source**: https://code.claude.com/docs/en/hooks
**Version**: Claude Code 2.x (December 2025)

## Overview

Hooks allow you to execute custom code at specific points during Claude Code's
operation. They enable automation, validation, logging, and integration with
external tools.

## Hook Event Types (10 Total)

| Event               | Description                          | Uses Matcher |
| ------------------- | ------------------------------------ | ------------ |
| `PreToolUse`        | Before tool execution                | ✅ Yes       |
| `PostToolUse`       | After tool completes successfully    | ✅ Yes       |
| `PermissionRequest` | When permission dialog shown         | ✅ Yes       |
| `Notification`      | When Claude Code sends notifications | ✅ Yes       |
| `UserPromptSubmit`  | Before processing user prompt        | ❌ No        |
| `Stop`              | When main agent finishes responding  | ❌ No        |
| `SubagentStop`      | When subagent (Task tool) finishes   | ❌ No        |
| `PreCompact`        | Before compact operation             | ❌ No        |
| `SessionStart`      | When session starts                  | ❌ No        |
| `SessionEnd`        | When session ends                    | ❌ No        |

## Matcher Format (CRITICAL)

**Matchers are STRINGS, not objects!**

```json
// ✅ CORRECT - String matcher
{
  "matcher": "Write",
  "hooks": [...]
}

// ❌ WRONG - Object matcher (OLD FORMAT - CAUSES ERRORS)
{
  "matcher": { "tool": "Write" },
  "hooks": [...]
}

// ❌ WRONG - Array matcher
{
  "matcher": { "tools": ["Write"] },
  "hooks": [...]
}
```

### Matcher Patterns

| Pattern         | Description              | Example               |
| --------------- | ------------------------ | --------------------- |
| `"Write"`       | Exact match              | Matches "Write" only  |
| `"Write\|Edit"` | Regex alternation        | Matches Write OR Edit |
| `"Notebook.*"`  | Regex pattern            | Matches NotebookEdit  |
| `"*"`           | Match all tools          | All tools             |
| `""`            | Empty string matches all | All tools             |
| `"mcp__.*"`     | MCP tools pattern        | All MCP server tools  |

### MCP Tool Naming Convention

MCP tools follow: `mcp__<server>__<tool>`

Examples:

- `mcp__memory__create_entities`
- `mcp__filesystem__read_file`
- `mcp__github__search_repositories`

## Configuration Structure

### Location and Priority

1. `~/.claude/settings.json` - User settings (highest priority)
2. `.claude/settings.json` - Project settings
3. `.claude/settings.local.json` - Local project (not committed)
4. Enterprise managed policy settings

### Basic Structure

```json
{
  "hooks": {
    "EventName": [
      {
        "matcher": "ToolPattern", // Only for PreToolUse, PostToolUse, PermissionRequest, Notification
        "hooks": [
          {
            "type": "command", // "command" or "prompt"
            "command": "your-script.sh",
            "timeout": 60 // Optional, default 60 seconds
          }
        ]
      }
    ]
  }
}
```

## Hook Types

### Command Type (Bash)

```json
{
  "type": "command",
  "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/my-script.sh",
  "timeout": 60
}
```

### Prompt Type (LLM-based)

For Stop/SubagentStop/UserPromptSubmit events:

```json
{
  "type": "prompt",
  "prompt": "Evaluate if task is complete: $ARGUMENTS",
  "timeout": 30
}
```

## Exit Code Handling

| Exit Code | Behavior                                          |
| --------- | ------------------------------------------------- |
| 0         | Success - stdout parsed for JSON control          |
| 2         | Blocking error - stderr shown, blocks operation   |
| Other     | Non-blocking error - stderr shown in verbose mode |

### Exit Code 2 Behavior by Event

| Event             | Exit 2 Behavior                           |
| ----------------- | ----------------------------------------- |
| PreToolUse        | Blocks tool call, shows stderr to Claude  |
| PermissionRequest | Denies permission, shows stderr to Claude |
| PostToolUse       | Shows stderr to Claude (tool already ran) |
| UserPromptSubmit  | Blocks prompt, shows stderr to user only  |
| Stop              | Blocks stoppage, shows stderr to Claude   |
| SubagentStop      | Blocks stoppage, shows stderr to subagent |

## Environment Variables

Available to all hooks:

| Variable             | Description                                      |
| -------------------- | ------------------------------------------------ |
| `CLAUDE_PROJECT_DIR` | Absolute path to project root                    |
| `CLAUDE_CODE_REMOTE` | "true" if web environment, empty for local CLI   |
| `CLAUDE_ENV_FILE`    | (SessionStart only) Path for persisting env vars |

## Input JSON Schema

### Common Fields (All Events)

```json
{
  "session_id": "string",
  "transcript_path": "path/to/conversation.jsonl",
  "cwd": "/current/working/directory",
  "permission_mode": "default|plan|acceptEdits|bypassPermissions",
  "hook_event_name": "EventName"
}
```

### PreToolUse Input

```json
{
  "hook_event_name": "PreToolUse",
  "tool_name": "Write",
  "tool_input": {
    "file_path": "/path/to/file.txt",
    "content": "content"
  },
  "tool_use_id": "toolu_01ABC123..."
}
```

### PostToolUse Input

```json
{
  "hook_event_name": "PostToolUse",
  "tool_name": "Write",
  "tool_input": {
    /* tool input */
  },
  "tool_response": {
    /* tool response */
  },
  "tool_use_id": "toolu_01ABC123..."
}
```

### UserPromptSubmit Input

```json
{
  "hook_event_name": "UserPromptSubmit",
  "prompt": "User's prompt text"
}
```

### PreCompact Input

```json
{
  "hook_event_name": "PreCompact",
  "trigger": "manual|auto",
  "custom_instructions": ""
}
```

### SessionStart Input

```json
{
  "hook_event_name": "SessionStart",
  "source": "startup|resume|clear|compact"
}
```

### SessionEnd Input

```json
{
  "hook_event_name": "SessionEnd",
  "reason": "clear|logout|prompt_input_exit|other"
}
```

## Output JSON Schema

### Common Fields (All Events)

```json
{
  "continue": true, // Whether Claude should continue
  "stopReason": "string", // Message when continue is false
  "suppressOutput": true, // Hide stdout from transcript
  "systemMessage": "string" // Warning message shown to user
}
```

### PreToolUse Decision Control

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow|deny|ask",
    "permissionDecisionReason": "My reason",
    "updatedInput": {
      "field": "new value" // Modify tool inputs
    }
  }
}
```

### PermissionRequest Decision Control

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow|deny",
      "updatedInput": {
        /* optional */
      },
      "message": "Why denied",
      "interrupt": false
    }
  }
}
```

## Complete Configuration Examples

### Example 1: Block Protected Paths (PreToolUse)

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/block-protected-paths.sh"
          }
        ]
      },
      {
        "matcher": "Edit",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/block-protected-paths.sh"
          }
        ]
      }
    ]
  }
}
```

### Example 2: Session Lifecycle

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/session-start.sh"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/session-end.sh"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/pre-compact.sh"
          }
        ]
      }
    ]
  }
}
```

### Example 3: Post-Write Formatting

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/format-code.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

### Example 4: User Prompt Validation

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/check-blocked-request.sh"
          }
        ]
      }
    ]
  }
}
```

## Security Considerations

### Disclaimer

**USE AT YOUR OWN RISK**: Hooks execute arbitrary shell commands automatically.

- You are solely responsible for configured commands
- Hooks can access any files your user account can access
- Malicious or poorly written hooks can cause data loss
- Anthropic provides no warranty and assumes no liability

### Best Practices

1. **Validate inputs** - Never trust input data blindly
2. **Quote variables** - Use `"$VAR"` not `$VAR`
3. **Block path traversal** - Check for `..` in file paths
4. **Use absolute paths** - Specify full paths for scripts
5. **Skip sensitive files** - Avoid `.env`, `.git/`, keys

### Configuration Safety

- Hooks are captured at startup (snapshot)
- External modifications require review in `/hooks` menu
- Changes don't take effect until approved

## Debugging

Enable debug output:

```bash
claude --debug
```

Shows:

- Hook execution details
- Matched hooks
- Command execution status
- Output and error messages

## Common Errors

### Error: "Expected string, but received object"

**Cause**: Using old object-style matcher format

```json
// ❌ OLD FORMAT (causes error)
{ "matcher": { "tool": "Write" } }

// ✅ NEW FORMAT (correct)
{ "matcher": "Write" }
```

### Error: Hook not executing

**Causes**:

1. Matcher doesn't match tool name (case-sensitive)
2. Script not executable (`chmod +x script.sh`)
3. Wrong path to script
4. Timeout too short

### Error: Exit code 2 but no message

**Cause**: Using stdout instead of stderr for error messages

```bash
# ✅ Correct - use stderr for exit 2
echo "Error message" >&2
exit 2

# ❌ Wrong - stdout ignored on exit 2
echo "Error message"
exit 2
```

## Migration from Old Format

If you have old-style matchers:

```bash
# Find old format
grep -r '"tool":' .claude/settings.json

# Replace object matchers with strings
# OLD: { "matcher": { "tool": "Write" } }
# NEW: { "matcher": "Write" }
```

## Related Documentation

- [Permissions](./permissions.md) - Permission control mechanisms
- [Custom Tools](./custom-tools.md) - Building custom tools
- [Sessions](./sessions.md) - Session management
