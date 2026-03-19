# Claude Code Settings Best Practices

**Last Updated**: February 24, 2026
**CLI Version**: 2.1.52

Critical configuration patterns for reliable Claude Code setup.

---

## Settings File Hierarchy

Settings are loaded in order of precedence (highest wins):

| Priority | Source      | Location                              | Scope             |
| -------- | ----------- | ------------------------------------- | ----------------- |
| 1        | **Managed** | MDM/plist (macOS), registry (Windows) | Enterprise        |
| 2        | **CLI**     | Flags passed at invocation            | Session           |
| 3        | **Local**   | `.claude/settings.local.json`         | Project (private) |
| 4        | **Project** | `.claude/settings.json`               | Project (shared)  |
| 5        | **User**    | `~/.claude/settings.json`             | Global            |

### When to Use Each

- **Project** (`settings.json`): Shared team config - hooks, base permissions, statusLine
- **Local** (`settings.local.json`): Personal overrides - extra permissions, env vars (not committed)
- **User** (`~/.claude/settings.json`): Cross-project preferences
- **Managed**: Enterprise policies via MDM/plist (macOS) or registry (Windows)

---

## CRITICAL: statusLine Configuration Order

### Correct Structure

```json
{
  "permissions": { ... },
  "env": { ... },
  "respectGitignore": true,
  "statusLine": {
    "type": "command",
    "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/statusline.sh",
    "padding": 0
  },
  "hooks": { ... }
}
```

**Why:** Place `statusLine` before `hooks` for reliable loading. The recommended key order is:

1. `permissions`
2. `env`
3. `respectGitignore`
4. `statusLine`
5. `hooks`

### Incorrect Structure

```json
{
  "hooks": { ... (hundreds of lines) },
  "statusLine": { ... }  // TOO LATE - may not load reliably
}
```

---

## Complete Settings Reference

### Core Settings

| Setting            | Type    | Description                              |
| ------------------ | ------- | ---------------------------------------- |
| `permissions`      | Object  | allow/deny/ask arrays with tool patterns |
| `env`              | Object  | Environment variables to set             |
| `respectGitignore` | Boolean | Respect .gitignore in file operations    |
| `statusLine`       | Object  | Status line command configuration        |
| `hooks`            | Object  | Lifecycle hook configurations            |

### Model & Thinking

| Setting                 | Type    | Default    | Description                       |
| ----------------------- | ------- | ---------- | --------------------------------- |
| `model`                 | String  | `"sonnet"` | Default model (opus/sonnet/haiku) |
| `availableModels`       | Array   | All        | Restrict available model choices  |
| `alwaysThinkingEnabled` | Boolean | `false`    | Always use extended thinking      |

```json
{
  "model": "opus",
  "availableModels": ["opus", "sonnet"],
  "alwaysThinkingEnabled": true
}
```

### Output & UI

| Setting               | Type    | Default | Description                        |
| --------------------- | ------- | ------- | ---------------------------------- |
| `outputStyle`         | String  | —       | Output style (e.g., "Explanatory") |
| `language`            | String  | —       | Response language preference       |
| `spinnerVerbs`        | Array   | —       | Custom spinner verb phrases        |
| `spinnerTipsEnabled`  | Boolean | `true`  | Show tips in spinner               |
| `spinnerTipsOverride` | Array   | —       | Custom spinner tips                |
| `fileSuggestion`      | Boolean | `true`  | Enable @ autocomplete for files    |

```json
{
  "outputStyle": "Explanatory",
  "language": "English",
  "spinnerVerbs": ["Thinking", "Processing", "Analyzing"],
  "spinnerTipsEnabled": true
}
```

### Agent Teams

| Setting        | Type   | Default  | Description             |
| -------------- | ------ | -------- | ----------------------- |
| `teammateMode` | String | `"auto"` | Teammate execution mode |

Options: `"auto"` | `"in-process"` | `"tmux"`

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "teammateMode": "auto"
}
```

### Sandbox (Preview)

| Setting                        | Type    | Description                 |
| ------------------------------ | ------- | --------------------------- |
| `sandbox.enabled`              | Boolean | Enable sandboxing           |
| `sandbox.network`              | Object  | Network access restrictions |
| `sandbox.network.allowedHosts` | Array   | Whitelisted hosts           |

```json
{
  "sandbox": {
    "enabled": true,
    "network": {
      "allowedHosts": ["api.anthropic.com", "registry.npmjs.org", "github.com"]
    }
  }
}
```

### Attribution

| Setting              | Type    | Description                      |
| -------------------- | ------- | -------------------------------- |
| `attribution.commit` | Boolean | Add co-author to commits         |
| `attribution.pr`     | Boolean | Add co-author to PR descriptions |

```json
{
  "attribution": {
    "commit": true,
    "pr": true
  }
}
```

### Plans & Plugins

| Setting          | Type   | Description                  |
| ---------------- | ------ | ---------------------------- |
| `plansDirectory` | String | Directory for saved plans    |
| `enabledPlugins` | Array  | List of enabled plugin names |

```json
{
  "plansDirectory": ".claude/plans",
  "enabledPlugins": ["claude-code-setup"]
}
```

### Updates

| Setting              | Type   | Default    | Description    |
| -------------------- | ------ | ---------- | -------------- |
| `autoUpdatesChannel` | String | `"stable"` | Update channel |

Options: `"stable"` | `"beta"` | `"disabled"`

```json
{
  "autoUpdatesChannel": "stable"
}
```

---

## Permission Patterns

### Syntax

```json
{
  "permissions": {
    "allow": [
      "Bash(npm *)",
      "Bash(git *)",
      "Bash(cargo *)",
      "Read(**)",
      "WebFetch(domain:docs.anthropic.com)",
      "mcp__memory__*",
      "Task(*)"
    ],
    "deny": ["Bash(rm -rf /*)"]
  }
}
```

### Pattern Reference

| Pattern                        | Matches                    |
| ------------------------------ | -------------------------- |
| `Bash(npm *)`                  | Any npm command            |
| `Bash(git status*)`            | git status with any suffix |
| `Read(**)`                     | Read any file              |
| `Read(src/**)`                 | Read files under src/      |
| `WebFetch(domain:example.com)` | Fetch from specific domain |
| `mcp__server__*`               | All tools from MCP server  |
| `mcp__server__tool`            | Specific MCP tool          |
| `Task(*)`                      | Launch any subagent        |

### PermissionRequest Hooks

Automate permission decisions:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "Bash(git status*)",
        "hooks": [
          {
            "type": "command",
            "command": "echo '{\"decision\": \"allow\"}'"
          }
        ]
      }
    ]
  }
}
```

---

## Managed Settings (Enterprise)

Enterprise administrators can enforce settings via MDM:

### macOS (plist)

```xml
<key>com.anthropic.claude-code</key>
<dict>
  <key>permissions</key>
  <dict>
    <key>deny</key>
    <array>
      <string>Bash(rm -rf /*)</string>
    </array>
  </dict>
</dict>
```

### Windows (Registry)

```
HKCU\Software\Anthropic\ClaudeCode\permissions\deny
```

Managed settings have the **highest priority** and cannot be overridden by any other settings source.

---

## Configuration File Types

### settings.json (Shared, Version Controlled)

**Use when:** Team-wide configuration for hooks, base permissions, status line.

```json
{
  "permissions": {
    "allow": ["Bash(npm *)", "Bash(git *)"]
  },
  "respectGitignore": true,
  "statusLine": {
    "type": "command",
    "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/statusline.sh",
    "padding": 0
  },
  "hooks": { ... }
}
```

### settings.local.json (Private, Not Committed)

**Use when:** Personal permissions, API keys, local overrides.

```json
{
  "permissions": {
    "allow": ["Bash(docker *)", "Read(/path/to/private/logs/**)"]
  },
  "env": {
    "CUSTOM_API_KEY": "sk-..."
  }
}
```

### ~/.claude/settings.json (User Global)

**Use when:** Cross-project preferences.

```json
{
  "model": "opus",
  "alwaysThinkingEnabled": true,
  "autoUpdatesChannel": "stable"
}
```

---

## Integration Checklist

When integrating claude-pattern into a new project:

- [ ] Copy `.claude/statusline.sh` to target project
- [ ] Make statusline.sh executable: `chmod +x .claude/statusline.sh`
- [ ] If project has no settings.json: Copy template `settings.json`
- [ ] If project has existing settings.json: Merge `statusLine` before `hooks`
- [ ] Verify JSON syntax: `python3 -c "import json; json.load(open('.claude/settings.json'))"`
- [ ] Restart Claude Code session
- [ ] Verify status line appears

---

## Troubleshooting

### Status Line Not Appearing

**Diagnosis:**

```bash
# Check statusLine position in config
python3 -c "
import json
with open('.claude/settings.json') as f:
    data = json.load(f)
print('statusLine' in data)
print(list(data.keys()))
"
```

**Fix:**

1. Ensure `statusLine` is present and before `hooks`
2. Validate JSON syntax
3. Make statusline.sh executable: `chmod +x .claude/statusline.sh`
4. Restart Claude Code

### Settings Not Taking Effect

**Check precedence:**

1. Is there a managed policy overriding? (Enterprise only)
2. Is there a CLI flag overriding?
3. Is `settings.local.json` overriding `settings.json`?
4. Is the setting in the correct file?

### JSON Validation

```bash
# Validate settings.json
python3 -c "import json; json.load(open('.claude/settings.json')); print('Valid')"

# Pretty-print for inspection
python3 -m json.tool .claude/settings.json
```

---

## Key Takeaways

1. **Settings priority**: Managed > CLI > Local > Project > User
2. **statusLine before hooks**: Always place statusLine before the hooks block
3. **Use settings.local.json**: For personal overrides that shouldn't be committed
4. **Permission patterns**: Use specific patterns over broad wildcards
5. **Validate JSON**: Always validate after manual edits
