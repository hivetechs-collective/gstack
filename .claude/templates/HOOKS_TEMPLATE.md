# Hooks Template v2.1.0

**Last Updated**: 2026-01-08
**Claude Code Version**: v2.1.0+
**Purpose**: Standard templates for hook configurations in settings.json, agents, and skills

---

## Overview

Hooks allow you to run custom commands or prompts at specific points in Claude Code's execution. They can be defined at three levels:

1. **Global Hooks** - In `.claude/settings.json` (apply to all sessions)
2. **Agent Hooks** - In agent frontmatter (apply when agent is active)
3. **Skill Hooks** - In skill frontmatter (apply when skill is loaded)

---

## Hook Types Reference

| Hook Type | Trigger | Use Case |
|-----------|---------|----------|
| `SessionStart` | Session begins | Initialize state, check environment |
| `SessionEnd` | Session ends | Cleanup, save state |
| `PreToolUse` | Before tool executes | Validate input, modify params |
| `PostToolUse` | After tool executes | Log output, trigger actions |
| `PreCompact` | Before compaction | Save state |
| `Stop` | Agent/task finishes | Verify completion |
| `SubagentStart` | Subagent spawns | Track subagent activity |
| `SubagentStop` | Subagent finishes | Process subagent results |
| `Notification` | System alerts | Custom handlers |
| `PermissionRequest` | Permission prompt | Auto-approve/deny |
| `UserPromptSubmit` | User sends message | Validate, add context |

---

## Template: Global Hooks (settings.json)

```json
{
  "hooks": {
    "SessionStart": [
      {
        "command": ".claude/hooks/session-start.sh",
        "timeout": 10000,
        "once": true
      }
    ],
    "SessionEnd": [
      {
        "command": ".claude/hooks/session-end.sh"
      }
    ],
    "PreCompact": [
      {
        "command": ".claude/hooks/pre-compact.sh"
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "command": ".claude/hooks/validate-bash.sh"
      },
      {
        "matcher": "Write|Edit",
        "command": ".claude/hooks/validate-write.sh"
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "command": ".claude/hooks/log-command.sh"
      }
    ],
    "UserPromptSubmit": [
      {
        "command": ".claude/hooks/check-blocked-request.sh"
      }
    ]
  }
}
```

---

## Template: Agent Hooks (YAML Frontmatter)

```yaml
---
name: security-expert
description: |
  Security analysis with pre-execution validation and post-execution logging.
version: 1.2.0

# ... other fields ...

# ============================================================================
# HOOKS CONFIGURATION (New in v2.1.0)
# ============================================================================
hooks:
  # Validate all bash commands before execution
  - type: PreToolUse
    matcher: Bash
    command: ".claude/hooks/security-validate-command.sh"

  # Log all file writes for audit trail
  - type: PostToolUse
    matcher: Write|Edit
    command: ".claude/hooks/audit-file-changes.sh"

  # Verify security checks passed before completing
  - type: Stop
    prompt: "Verify all security checks passed and no vulnerabilities remain"
    model: haiku  # Use cheaper model for verification
---
```

---

## Template: Skill Hooks (YAML Frontmatter)

```yaml
---
name: code-review-checklist
description: |
  Comprehensive code review with validation hooks.
version: 1.1.0

# ... other fields ...

# ============================================================================
# HOOKS CONFIGURATION (New in v2.1.0)
# ============================================================================
hooks:
  # Validate file paths before reading
  - type: PreToolUse
    matcher: Read
    command: ".claude/hooks/validate-file-access.sh"

  # Verify review completed all checklist items
  - type: Stop
    prompt: "Confirm all code review checklist items have been addressed"
    model: haiku
---
```

---

## Hook Script Templates

### PreToolUse Validator Script

```bash
#!/bin/bash
# .claude/hooks/validate-bash.sh
# Validates bash commands before execution

# Read hook input from stdin
INPUT=$(cat)

# Extract command from JSON input
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Check for dangerous patterns
if echo "$COMMAND" | grep -qE 'rm -rf|sudo|chmod 777|curl.*\|.*sh'; then
    echo '{"decision": "block", "reason": "Potentially dangerous command blocked"}'
    exit 0
fi

# Check for unbounded output commands
if echo "$COMMAND" | grep -qE '^(pnpm test|npm test|pnpm build|npm run build)$'; then
    # Suggest bounded version
    echo '{"decision": "ask", "message": "Consider adding output limits: '"$COMMAND"' 2>&1 | head -100"}'
    exit 0
fi

# Allow command
echo '{"decision": "allow"}'
```

### PostToolUse Logger Script

```bash
#!/bin/bash
# .claude/hooks/log-command.sh
# Logs command execution for audit

INPUT=$(cat)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOG_FILE=".claude/state/command-log.txt"

# Extract details
TOOL=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // "N/A"' | head -c 200)
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_result.exit_code // "N/A"')

# Log entry
echo "[$TIMESTAMP] $TOOL: $COMMAND (exit: $EXIT_CODE)" >> "$LOG_FILE"
```

### SessionStart Initialization Script

```bash
#!/bin/bash
# .claude/hooks/session-start.sh
# Initialize session state

STATE_DIR=".claude/state"
mkdir -p "$STATE_DIR"

# Record session start
echo "Session started: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$STATE_DIR/session-log.txt"

# Check environment
if ! command -v node &> /dev/null; then
    echo "WARNING: Node.js not found"
fi

# Load project context
if [ -f "CLAUDE.md" ]; then
    echo "Project context loaded"
fi

# Output initialization message (shown to user)
cat << 'EOF'
Session initialized successfully.
EOF
```

### PreCompact State Preservation Script

```bash
#!/bin/bash
# .claude/hooks/pre-compact.sh
# Save state before context compaction

STATE_FILE=".claude/state/session-state.md"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Determine trigger type
TRIGGER="${COMPACT_TRIGGER:-auto}"

cat > "$STATE_FILE" << EOF
# Session State (Pre-Compact)

**Saved at**: $TIMESTAMP
**Trigger**: $TRIGGER

## Git Status
\`\`\`
$(git status --short 2>/dev/null | head -20)
\`\`\`

## Recent Commits
\`\`\`
$(git log --oneline -5 2>/dev/null)
\`\`\`

## Current Branch
$(git branch --show-current 2>/dev/null)
EOF

echo "State saved to $STATE_FILE"
```

---

## Hook Response Formats

### PreToolUse Response Options

```json
// Allow execution
{"decision": "allow"}

// Block execution
{"decision": "block", "reason": "Explanation shown to user"}

// Ask user for confirmation
{"decision": "ask", "message": "Custom message for user"}

// Modify tool input
{
  "decision": "allow",
  "updatedInput": {
    "command": "modified-command --with-flags"
  }
}
```

### PostToolUse Response

```json
// Continue normally (default)
{}

// Add context for next interaction
{"context": "Additional information to include"}
```

### Stop Hook Prompt Response

For prompt-based Stop hooks, the model evaluates and responds:
- Continue if verification passes
- Stop and report if verification fails

---

## Hook Configuration Options

| Option | Type | Description |
|--------|------|-------------|
| `command` | string | Path to executable script |
| `prompt` | string | LLM prompt (Stop hooks only) |
| `matcher` | string | Tool name regex pattern |
| `timeout` | number | Max execution time in ms (default: 60000) |
| `once` | boolean | Run only once per session (default: false) |
| `model` | string | Model for prompt hooks (default: inherit) |

---

## Best Practices

1. **Keep hooks fast** - Use timeout and avoid blocking operations
2. **Use `once: true`** for SessionStart initialization
3. **Use Haiku for Stop prompts** - Cheaper verification
4. **Log to .claude/state/** - Keep audit trails organized
5. **Handle errors gracefully** - Always return valid JSON
6. **Use matchers** - Avoid running on every tool call
7. **Test locally first** - Verify scripts work before committing

---

## Common Patterns

### Quality Gate Hook
```yaml
hooks:
  - type: Stop
    prompt: |
      Verify the following quality criteria are met:
      1. All tests pass
      2. No linting errors
      3. Code is properly documented
      Return PASS or FAIL with explanation.
    model: haiku
```

### Security Audit Hook
```yaml
hooks:
  - type: PreToolUse
    matcher: Bash
    command: ".claude/hooks/security-scan-command.sh"
  - type: PostToolUse
    matcher: Write|Edit
    command: ".claude/hooks/security-scan-file.sh"
```

### Context Preservation Hook
```yaml
hooks:
  - type: PreCompact
    command: ".claude/hooks/save-work-state.sh"
```

---

**For more examples, see `.claude/hooks/` directory.**
