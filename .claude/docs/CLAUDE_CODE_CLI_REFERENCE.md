# Claude Code CLI Complete Reference

**Last Updated**: March 12, 2026
**CLI Version**: 2.1.74
**Source**: Official Anthropic Documentation

This document provides the authoritative reference for Claude Code CLI features, tools, and capabilities based on official Anthropic documentation.

---

## Table of Contents

1. [Task Management Systems](#1-task-management-systems)
2. [Built-in Tools](#2-built-in-tools)
3. [Subagent System](#3-subagent-system)
4. [Slash Commands](#4-slash-commands)
5. [Hooks System](#5-hooks-system)
6. [MCP (Model Context Protocol)](#6-mcp-model-context-protocol)
7. [Context Management](#7-context-management)
8. [Checkpointing & Rewind](#8-checkpointing--rewind)
9. [Models](#9-models)
10. [Keyboard Shortcuts](#10-keyboard-shortcuts)
11. [Environment Variables](#11-environment-variables)
12. [Agent Teams](#12-agent-teams)
13. [CLI Flags](#13-cli-flags)
14. [Permission System](#14-permission-system)
    14.5. [Auto Mode](#145-auto-mode)
    14.6. [Effort Levels](#146-effort-levels)
    14.7. [Plugin System](#147-plugin-system)
    14.8. [Skill System](#148-skill-system)
    14.9. [Auto-Memory](#149-auto-memory)
15. [Sandboxing](#15-sandboxing)
16. [Remote Control](#16-remote-control)

---

## 1. Task Management Systems

Claude Code CLI has **two complementary task systems**:

### TodoWrite (Session-Level Planning)

**Purpose**: Real-time task planning and tracking within a session.

**Storage**: `~/.claude/todos/*.json`

**Usage**: Claude is instructed to use TodoWrite "VERY frequently" for:

- Breaking down complex tasks into steps
- Tracking progress on multi-step work
- Giving users visibility into current work

**Command**: `/todos` - Shows current TodoWrite items

### Task Tools (Multi-Session Persistence)

**Purpose**: Persistent task management with dependency tracking across sessions.

**Storage**: `~/.claude/tasks/`

**Tools**:

| Tool         | Purpose                          |
| ------------ | -------------------------------- |
| `TaskCreate` | Create new persistent tasks      |
| `TaskList`   | List all tasks with status       |
| `TaskGet`    | Retrieve task details by ID      |
| `TaskUpdate` | Update task status/details/owner |

**Features**:

- Dependency tracking (`blocks` / `blockedBy` fields)
- Cross-session persistence
- Progress indicators (`pending`, `in_progress`, `completed`)
- Task ownership for multi-agent coordination
- Metadata support for arbitrary key-value pairs
- Survives context compaction

**Command**: `/tasks` - Shows background running tasks

**Environment Variable**: `CLAUDE_CODE_TASK_LIST_ID=my-project` - Use named task directory

### Agent (Subagent Launcher)

The `Agent` tool launches specialized subagents in isolated contexts:

```
Agent(description, prompt, subagent_type, [options])
```

Options: `model`, `mode`, `max_turns`, `isolation` ("worktree" for git worktree isolation), `run_in_background`, `resume`, `team_name`, `name`

> **Note**: `Task` is still accepted as an alias but `Agent` is the canonical name since v2.1.63.

### When to Use Each

| Scenario                    | System     | Reason                                        |
| --------------------------- | ---------- | --------------------------------------------- |
| Quick planning during work  | TodoWrite  | Lightweight, immediate                        |
| Multi-step implementation   | TaskCreate | Persists, tracks dependencies                 |
| Complex project work        | Both       | TodoWrite for immediate, Tasks for persistent |
| Parallel agent coordination | Task tools | Agents can read/update shared tasks           |
| Spawning subagents          | Agent      | Isolated context, specialized agents          |

---

## 2. Built-in Tools

Claude Code CLI provides 22+ built-in tools:

### File Operations

| Tool    | Purpose                                      |
| ------- | -------------------------------------------- |
| `Read`  | Read file contents with optional line ranges |
| `Write` | Create/overwrite files                       |
| `Edit`  | Exact string replacements in files           |
| `Glob`  | Find files by glob pattern                   |
| `Grep`  | Search file contents with regex (ripgrep)    |

### Execution

| Tool    | Purpose                           |
| ------- | --------------------------------- |
| `Bash`  | Execute shell commands            |
| `Agent` | Run subagents in isolated context |

> **Note**: `Agent` replaces `Task` (alias still works).

### Scheduling

| Tool         | Purpose                  |
| ------------ | ------------------------ |
| `CronCreate` | Schedule recurring tasks |
| `CronList`   | List active cron jobs    |
| `CronDelete` | Remove a cron job        |

### Task Management

| Tool         | Purpose                    |
| ------------ | -------------------------- |
| `TaskCreate` | Create persistent tasks    |
| `TaskList`   | List persistent tasks      |
| `TaskGet`    | Get task details by ID     |
| `TaskUpdate` | Update task status/details |

### User Interaction

| Tool              | Purpose                      |
| ----------------- | ---------------------------- |
| `AskUserQuestion` | Prompt user for input/choice |
| `Skill`           | Execute custom skills        |

### Web

| Tool        | Purpose                     |
| ----------- | --------------------------- |
| `WebFetch`  | Fetch and analyze web pages |
| `WebSearch` | Search the web              |

### Planning & Workflow

| Tool            | Purpose                                    |
| --------------- | ------------------------------------------ |
| `EnterPlanMode` | Transition to plan mode                    |
| `ExitPlanMode`  | Submit plan for user approval              |
| `EnterWorktree` | Create isolated git worktree               |
| `ExitWorktree`  | Exit and optionally merge worktree changes |
| `NotebookEdit`  | Edit Jupyter notebook cells                |

### Agent Teams

| Tool          | Purpose                         |
| ------------- | ------------------------------- |
| `TeamCreate`  | Create a team with shared tasks |
| `TeamDelete`  | Remove team and task dirs       |
| `SendMessage` | Message teammates               |

---

## 3. Subagent System

Subagents are specialized Claude instances with isolated context windows, launched via the `Agent` tool (formerly `Task`, which still works as an alias).

### Built-in Subagents

| Subagent              | Model    | Tools           | Purpose                               |
| --------------------- | -------- | --------------- | ------------------------------------- |
| **Explore**           | Inherits | Read-only       | Fast codebase search and analysis     |
| **Plan**              | Inherits | Read-only       | Research during plan mode             |
| **general-purpose**   | Inherits | All             | Complex multi-step tasks              |
| **Bash**              | Inherits | Bash only       | Terminal commands in separate context |
| **statusline-setup**  | Inherits | Read, Edit      | Configure status line settings        |
| **claude-code-guide** | Inherits | Read-only + Web | Questions about Claude Code features  |

### Explore Subagent Thoroughness Levels

When invoking Explore, specify thoroughness:

- **quick** - Targeted lookups
- **medium** - Balanced exploration
- **very thorough** - Comprehensive analysis

### Custom Subagents

**Locations** (priority order):

1. `--agents` CLI flag (session only, JSON)
2. `.claude/agents/` (project level)
3. `~/.claude/agents/` (user level)
4. Plugin agents

**Definition Format** (YAML frontmatter + Markdown):

```yaml
---
name: code-reviewer
description: Reviews code for quality and best practices
tools: Read, Grep, Glob
disallowedTools: Write, Edit
model: sonnet
permissionMode: default
maxTurns: 50
skills:
  - api-conventions
mcpServers:
  - memory
memory: project
background: false
isolation: worktree
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./validate.sh"
---
You are a code reviewer. Analyze code and provide specific feedback.
```

### Frontmatter Fields

| Field             | Required | Description                                                              |
| ----------------- | -------- | ------------------------------------------------------------------------ |
| `name`            | Yes      | Unique identifier (lowercase, hyphens)                                   |
| `description`     | Yes      | When Claude should delegate to this agent                                |
| `tools`           | No       | Allowlist of tools (inherits all if omitted)                             |
| `disallowedTools` | No       | Denylist of tools                                                        |
| `model`           | No       | `sonnet`, `opus`, `haiku`, or inherits parent                            |
| `permissionMode`  | No       | `default`, `acceptEdits`, `dontAsk`, `bypassPermissions`, `plan`, `auto` |
| `maxTurns`        | No       | Maximum agentic turns before stopping                                    |
| `skills`          | No       | Skills to preload into context                                           |
| `mcpServers`      | No       | MCP servers available to this agent                                      |
| `memory`          | No       | Memory scope: `user`, `project`, or `local`                              |
| `background`      | No       | Run in background (default: false)                                       |
| `isolation`       | No       | `worktree` for git worktree isolation                                    |
| `hooks`           | No       | Lifecycle hooks for this subagent                                        |

### Subagent Execution Modes

- **Foreground** (default): Blocking, permission prompts passed through
- **Background**: Concurrent via `run_in_background: true`, auto-deny unpre-approved permissions
- **Resume**: Continue a previous subagent by passing its agent ID
- **Worktree**: Isolated git worktree via `isolation: "worktree"`

### Key Constraints

- Subagents **cannot spawn other subagents** (no nesting)
- Subagent context is **isolated** from main conversation
- Results return to main conversation when complete
- Background agents write output to a file (check with `Read` or `TaskOutput`)

---

## 4. Slash Commands

### Core Commands

| Command                   | Purpose                                 |
| ------------------------- | --------------------------------------- |
| `/help`                   | Get usage help                          |
| `/clear`                  | Clear conversation history              |
| `/compact [instructions]` | Manual compaction with optional focus   |
| `/rewind`                 | Restore code/conversation to checkpoint |
| `/rename <name>`          | Rename current session                  |
| `/exit`                   | Exit Claude Code session                |

### Task & Planning

| Command                      | Purpose                                      |
| ---------------------------- | -------------------------------------------- |
| `/init`                      | Initialize project with CLAUDE.md            |
| `/plan-mode`                 | Toggle plan mode on/off                      |
| `/loop [interval] [command]` | Run command on recurring interval            |
| `/btw <question>`            | Side-channel query without interrupting flow |
| `/fork`                      | Fork current session for exploration         |
| `/batch <instructions>`      | Run same change across multiple files        |
| `/simplify`                  | Review changed code for quality and simplify |

### Configuration

| Command           | Purpose                       |
| ----------------- | ----------------------------- |
| `/agents`         | Manage subagents              |
| `/mcp`            | Manage MCP server connections |
| `/permissions`    | View/update permissions       |
| `/hooks`          | Configure hooks               |
| `/skills`         | Manage skills                 |
| `/plugins`        | Manage plugins                |
| `/settings`       | Open settings interface       |
| `/reload-plugins` | Reload installed plugins      |

### Session Management

| Command              | Purpose                               |
| -------------------- | ------------------------------------- |
| `/resume [session]`  | Resume by ID/name or open picker      |
| `/teleport`          | Resume remote session from claude.ai  |
| `/stats`             | Usage statistics, streaks, history    |
| `/export [filename]` | Export conversation to file/clipboard |
| `/copy`              | Copy last response to clipboard       |

### Model & Thinking

| Command           | Purpose                                 |
| ----------------- | --------------------------------------- |
| `/model`          | Select or change AI model               |
| `/fast`           | Toggle fast mode (same model)           |
| `/thinking`       | Toggle extended thinking                |
| `/effort [level]` | Set effort level (low/medium/high/auto) |

### Utilities

| Command           | Purpose                        |
| ----------------- | ------------------------------ |
| `/doctor`         | Check installation health      |
| `/statusline`     | Set up status line UI          |
| `/terminal-setup` | Configure terminal shortcuts   |
| `/theme`          | Change color theme             |
| `/vim`            | Enable vim editing mode        |
| `/memory`         | Edit CLAUDE.md files           |
| `/context`        | Visualize context usage        |
| `/cost`           | Show token usage statistics    |
| `/usage`          | Show plan limits (subscribers) |

### Collaboration

| Command    | Purpose                          |
| ---------- | -------------------------------- |
| `/add-dir` | Add additional working directory |
| `/desktop` | Open Claude Desktop integration  |
| `/sandbox` | Configure sandboxing (preview)   |

### Account

| Command     | Purpose                    |
| ----------- | -------------------------- |
| `/login`    | Log in to Anthropic        |
| `/logout`   | Log out                    |
| `/bug`      | Report a bug               |
| `/feedback` | Send feedback              |
| `/remind`   | Set a reminder             |
| `/vision`   | Toggle vision capabilities |

### MCP Prompts

MCP servers expose prompts as `/mcp__<server>__<prompt>` commands.

---

## 5. Hooks System

Hooks tie deterministic code to specific moments in Claude Code's lifecycle.

### Hook Events

| Event                | Matcher    | When                               | Can Block    |
| -------------------- | ---------- | ---------------------------------- | ------------ |
| `PreToolUse`         | Tool name  | Before tool execution              | Yes (exit 2) |
| `PostToolUse`        | Tool name  | After tool execution               | No           |
| `UserPromptSubmit`   | -          | Before processing user input       | Yes (exit 2) |
| `Notification`       | -          | When Claude sends alerts           | No           |
| `Stop`               | -          | When response finishes             | No           |
| `SubagentStart`      | Agent name | When subagent begins               | No           |
| `SubagentStop`       | Agent name | When subagent completes            | No           |
| `SessionStart`       | -          | Session initialization             | No           |
| `SessionEnd`         | -          | Session termination                | No           |
| `PreCompact`         | -          | Before auto-compaction             | No           |
| `Setup`              | -          | With `--init`/`--maintenance`      | No           |
| `PermissionRequest`  | Tool name  | Permission dialog shown            | Yes          |
| `TeammateIdle`       | -          | When a teammate goes idle          | No           |
| `TaskCompleted`      | -          | When a task is marked completed    | No           |
| `WorktreeCreate`     | -          | When a git worktree is created     | No           |
| `WorktreeRemove`     | -          | When a git worktree is removed     | No           |
| `ConfigChange`       | -          | When settings/config changes       | No           |
| `PostToolUseFailure` | Tool name  | After tool execution fails         | No           |
| `InstructionsLoaded` | -          | When instructions/rules are loaded | No           |

### Hook Configuration

**In settings.json**:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "./validate.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit",
        "hooks": [
          {
            "type": "command",
            "command": "./format.sh",
            "statusMessage": "Formatting..."
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "once": true,
        "hooks": [
          {
            "type": "command",
            "command": "./startup.sh"
          }
        ]
      }
    ]
  }
}
```

### Hook Types

| Type      | Description             | Example                                         |
| --------- | ----------------------- | ----------------------------------------------- |
| `command` | Shell command (default) | `"command": "./validate.sh"`                    |
| `http`    | HTTP webhook            | `"type": "http", "url": "https://..."`          |
| `prompt`  | Inject prompt text      | `"type": "prompt", "prompt": "Remember to..."`  |
| `mcp`     | Call MCP tool           | `"type": "mcp", "server": "...", "tool": "..."` |

### Hook Input/Output

**Input**: JSON via stdin containing tool_input, tool_name, session_id, etc.

**Exit Codes**:

| Code | Behavior                                 |
| ---- | ---------------------------------------- |
| 0    | Allow/continue                           |
| 1    | Fail (error logged)                      |
| 2    | Block execution (stderr shown to Claude) |

### PostToolUse Features

- `statusMessage`: Short message shown in CLI during hook execution
- Cannot block execution, only observe and annotate

### PermissionRequest Hook Output

```json
{
  "decision": "allow"
}
```

Valid decisions: `"allow"`, `"deny"`, or omit to show normal permission dialog.

### Hook Options

| Field     | Description                         |
| --------- | ----------------------------------- |
| `matcher` | Tool name or glob pattern to match  |
| `once`    | Run only once per session (boolean) |
| `hooks`   | Array of hook commands              |

---

## 6. MCP (Model Context Protocol)

### Transports

| Transport | Command                                                | Use Case                   |
| --------- | ------------------------------------------------------ | -------------------------- |
| **stdio** | `claude mcp add --transport stdio <name> -- <command>` | Local processes            |
| **HTTP**  | `claude mcp add --transport http <name> <url>`         | Remote servers (preferred) |
| **SSE**   | Deprecated                                             | Use HTTP instead           |

### Configuration Scopes

| Scope   | Location            | Visibility                 |
| ------- | ------------------- | -------------------------- |
| Local   | `.claude/.mcp.json` | Private, per-project       |
| Project | `.mcp.json`         | Shared, version controlled |
| User    | `~/.claude.json`    | Cross-project, private     |

**Precedence**: Local > Project > User > Plugin

### MCP Tool Search (Automatic)

**Feature**: Dynamically loads tool definitions on-demand instead of preloading all.

**Trigger**: Automatically when MCP tools exceed 10% of context window.

**Token Savings**: 134k → 5k tokens in testing.

**Control**:

```bash
ENABLE_TOOL_SEARCH=auto       # Default
ENABLE_TOOL_SEARCH=auto:15    # Custom threshold (15%)
ENABLE_TOOL_SEARCH=true       # Always enabled
ENABLE_TOOL_SEARCH=false      # Disabled
```

### MCP Tool Annotations

MCP tools can include annotations for:

- `readOnlyHint` - Tool doesn't modify state
- `destructiveHint` - Tool may destructively modify state
- `idempotentHint` - Safe to retry
- `openWorldHint` - Tool interacts with external entities

### MCP Resources

Reference via `@server:protocol://path` in prompts.

### MCP Strict Config

Use `--strict-mcp-config` flag to fail on MCP server startup errors instead of continuing.

---

## 7. Context Management

### Auto-Compaction

- **Trigger**: ~95% context capacity (configurable)
- **Process**: Clears older tool outputs, summarizes conversation
- **Override**: `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80` (trigger at 80%)

### Manual Compaction

```
/compact [instructions]
```

Provide focus instructions to guide what to preserve.

### Context Clearing

```
/clear
```

Completely clears conversation history (more aggressive than compact).

### Context Preservation Strategies

- Subagents have isolated context (don't pollute main)
- Skills load on-demand (descriptions at start, content on use)
- Use line ranges with Read tool for efficiency
- MCP Tool Search reduces tool definition overhead

### Monitoring

- `/context` - Visual grid of context usage
- Check regularly during long sessions
- At 70%+, plan to wrap up or spawn subagent
- At 85%+, manual `/compact` immediately

---

## 8. Checkpointing & Rewind

### How It Works

- **Automatic**: Every user prompt creates a checkpoint
- **Storage**: Session transcript files
- **Tracks**: File edits via Write/Edit tools only

### Commands

| Method        | Action                       |
| ------------- | ---------------------------- |
| `/rewind`     | Interactive rewind selection |
| `Esc` + `Esc` | Quick rewind shortcut        |

### Rewind Options

When rewinding, choose what to restore:

- **Conversation only** - Restore conversation state, keep file changes
- **Code only** - Restore file states, keep conversation
- **Both** - Restore conversation and code together

### Limitations

- Does NOT track file changes made by `Bash` commands (`rm`, `mv`, `cp`)
- Does NOT track external edits (IDE, other tools)
- NOT a Git replacement - session-level recovery only

**NOTE**: There is NO `/checkpoints` command - use `/rewind` only.

---

## 9. Models

### Current Models (March 2026)

| Model          | ID                          | Alias    | Best For                      |
| -------------- | --------------------------- | -------- | ----------------------------- |
| **Opus 4.6**   | `claude-opus-4-6`           | `opus`   | All coding, extended thinking |
| **Sonnet 4.6** | `claude-sonnet-4-6`         | `sonnet` | Balanced, default             |
| **Haiku 4.5**  | `claude-haiku-4-5-20251001` | `haiku`  | Fast, mechanical tasks        |

### Selection

```bash
claude --model opus          # Most capable
claude --model sonnet        # Balanced (default)
claude --model haiku         # Fast, cost-efficient
```

Subagent model in frontmatter:

```yaml
model: sonnet # or opus, haiku (inherits parent if omitted)
```

### Deprecated Model Names (DO NOT USE)

| Old Name                     | Replace With        |
| ---------------------------- | ------------------- |
| `claude-opus-4-5-20251101`   | `claude-opus-4-6`   |
| `claude-sonnet-4-5-20250929` | `claude-sonnet-4-6` |
| `claude-sonnet-4-5`          | `claude-sonnet-4-6` |
| `claude-opus-4-5`            | `claude-opus-4-6`   |
| `claude-3-5-sonnet-*`        | `claude-sonnet-4-6` |
| `claude-3-sonnet-*`          | `claude-sonnet-4-6` |
| `claude-3-haiku-*`           | `claude-haiku-4-5`  |
| `claude-3-opus-*`            | `claude-opus-4-6`   |

---

## 10. Keyboard Shortcuts

### General

| Shortcut     | Action                         |
| ------------ | ------------------------------ |
| `Ctrl+C`     | Cancel input/generation        |
| `Ctrl+D`     | Exit session                   |
| `Ctrl+L`     | Clear terminal screen          |
| `Ctrl+O`     | Toggle verbose output          |
| `Ctrl+B`     | Background running tasks       |
| `Ctrl+G`     | Open in external editor        |
| `Ctrl+R`     | Reverse search history         |
| `Ctrl+T`     | Show task list                 |
| `Ctrl+F`     | Kill background task           |
| `Esc+Esc`    | Rewind                         |
| `Shift+Tab`  | Toggle permission modes        |
| `Shift+Down` | Show teammates panel           |
| `?`          | Show help / keyboard shortcuts |

### Model/Thinking

| Shortcut             | Action                   |
| -------------------- | ------------------------ |
| `Alt+P` / `Option+P` | Switch model             |
| `Alt+T` / `Option+T` | Toggle extended thinking |

### Multiline Input

| Method       | Shortcut                                 |
| ------------ | ---------------------------------------- |
| Quick escape | `\` + `Enter`                            |
| Shift+Enter  | Works in iTerm2, Kitty, Ghostty, WezTerm |
| Control      | `Ctrl+J`                                 |

### Quick Prefixes

| Prefix | Action                         |
| ------ | ------------------------------ |
| `/`    | Slash commands and skills      |
| `!`    | Bash mode (direct execution)   |
| `@`    | File path mention autocomplete |

---

## 11. Environment Variables

### Authentication

| Variable               | Purpose                      |
| ---------------------- | ---------------------------- |
| `CLAUDE_API_KEY`       | API authentication key       |
| `ANTHROPIC_API_KEY`    | Alternative API key variable |
| `ANTHROPIC_AUTH_TOKEN` | OAuth/session token          |

### Cloud Providers

| Variable                  | Purpose                          |
| ------------------------- | -------------------------------- |
| `CLAUDE_CODE_USE_BEDROCK` | Use AWS Bedrock as provider      |
| `CLAUDE_CODE_USE_VERTEX`  | Use Google Vertex AI as provider |
| `CLAUDE_CODE_USE_FOUNDRY` | Use Anthropic Foundry            |
| `ANTHROPIC_BASE_URL`      | Custom API base URL              |
| `AWS_REGION`              | Bedrock AWS region               |
| `CLOUD_ML_REGION`         | Vertex AI region                 |
| `ANTHROPIC_PROJECT_ID`    | Vertex project ID                |
| `ANTHROPIC_MODEL`         | Override default model           |

### Context & Performance

| Variable                          | Purpose                              |
| --------------------------------- | ------------------------------------ |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | Auto-compact threshold (default 95)  |
| `CLAUDE_CODE_DISABLE_1M_CONTEXT`  | Disable 1M context window            |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS`   | Maximum output tokens per response   |
| `MAX_THINKING_TOKENS`             | Maximum tokens for extended thinking |
| `MAX_MCP_OUTPUT_TOKENS`           | Maximum tokens for MCP tool outputs  |

### Task Management

| Variable                   | Purpose                   |
| -------------------------- | ------------------------- |
| `CLAUDE_CODE_TASK_LIST_ID` | Named task list directory |
| `CLAUDE_CODE_ENABLE_TASKS` | Toggle task system        |

### Background Tasks & Shell

| Variable                               | Purpose                                         |
| -------------------------------------- | ----------------------------------------------- |
| `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` | Set to 1 to disable background tasks            |
| `BASH_DEFAULT_TIMEOUT_MS`              | Timeout before auto-background (default 120000) |
| `CLAUDE_CODE_SHELL`                    | Override shell (e.g., `/bin/bash`)              |

### MCP

| Variable             | Purpose                                   |
| -------------------- | ----------------------------------------- |
| `ENABLE_TOOL_SEARCH` | Tool search mode (auto/true/false/auto:N) |
| `MCP_TIMEOUT`        | MCP server startup timeout                |

### Features & UI

| Variable                                  | Purpose                         |
| ----------------------------------------- | ------------------------------- |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY`         | Disable automatic memory saving |
| `CLAUDE_CODE_SIMPLE`                      | Simplified UI mode              |
| `CLAUDE_CODE_DISABLE_CRON`                | Disable cron/scheduling system  |
| `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS` | Timeout for SessionEnd hooks    |

### Proxy

| Variable      | Purpose           |
| ------------- | ----------------- |
| `HTTP_PROXY`  | HTTP proxy URL    |
| `HTTPS_PROXY` | HTTPS proxy URL   |
| `NO_PROXY`    | Proxy bypass list |

### Logging

| Variable            | Purpose              |
| ------------------- | -------------------- |
| `CLAUDE_CODE_DEBUG` | Enable debug logging |
| `CLAUDE_LOG_LEVEL`  | Log verbosity level  |

### Agent Teams

| Variable                               | Purpose                         |
| -------------------------------------- | ------------------------------- |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | Enable agent teams (set to "1") |

### Recommended Configuration

```bash
# Add to ~/.zshrc or ~/.bashrc

# Earlier compaction (default 95%, recommend 80%)
export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=80

# Project-specific task lists
export CLAUDE_CODE_TASK_LIST_ID=my-project

# Longer timeout before auto-background (default 2min, recommend 5min)
export BASH_DEFAULT_TIMEOUT_MS=300000

# Enable agent teams (experimental)
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
```

---

## 12. Agent Teams

**Status**: Experimental (requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`)

### Overview

Agent Teams allow multiple Claude instances to collaborate on complex tasks with shared task lists and direct messaging.

### Tools

| Tool          | Purpose                                |
| ------------- | -------------------------------------- |
| `TeamCreate`  | Create team with shared task list      |
| `TeamDelete`  | Remove team and task directories       |
| `SendMessage` | Direct message, broadcast, or shutdown |

### TeamCreate

Creates a team at `~/.claude/teams/{team-name}.json` with a corresponding task list at `~/.claude/tasks/{team-name}/`.

```json
{
  "team_name": "my-project",
  "description": "Working on feature X"
}
```

### SendMessage Types

| Type                     | Purpose                               |
| ------------------------ | ------------------------------------- |
| `message`                | Direct message to specific teammate   |
| `broadcast`              | Message all teammates (use sparingly) |
| `shutdown_request`       | Request teammate to shut down         |
| `shutdown_response`      | Respond to shutdown request           |
| `plan_approval_response` | Approve/reject teammate's plan        |

### Teammate Modes

| Mode         | Description                          |
| ------------ | ------------------------------------ |
| `auto`       | System decides (default)             |
| `in-process` | Teammates run in same process        |
| `tmux`       | Teammates run in separate tmux panes |

Set via `--teammate-mode` CLI flag.

### Workflow

1. Create team with `TeamCreate`
2. Create tasks with `TaskCreate`
3. Spawn teammates with `Agent` tool (pass `team_name` and `name`)
4. Assign tasks via `TaskUpdate` with `owner`
5. Teammates communicate via `SendMessage`
6. Shutdown teammates via `SendMessage` with `type: "shutdown_request"`

### Team Config

Teammates discover each other via `~/.claude/teams/{team-name}/config.json`:

```json
{
  "members": [
    { "name": "team-lead", "agentId": "...", "agentType": "..." },
    { "name": "researcher", "agentId": "...", "agentType": "..." }
  ]
}
```

---

## 13. CLI Flags

### Common Flags

| Flag                        | Purpose                                |
| --------------------------- | -------------------------------------- |
| `--model <model>`           | Select model (opus/sonnet/haiku)       |
| `--print` / `-p`            | Non-interactive mode, print and exit   |
| `--output-format <fmt>`     | Output format: text, json, stream-json |
| `--resume [session]`        | Resume a previous session              |
| `--continue`                | Continue most recent session           |
| `--verbose`                 | Enable verbose logging                 |
| `--max-turns <n>`           | Maximum conversation turns             |
| `--max-budget-usd <n>`      | Maximum budget in USD                  |
| `--system-prompt <text>`    | Override system prompt                 |
| `--allowedTools <tools>`    | Restrict available tools               |
| `--disallowedTools <tools>` | Exclude specific tools                 |
| `--agents <json>`           | Provide agent definitions inline       |
| `--permission-prompt-tool`  | Custom permission prompt handler       |
| `--effort <level>`          | Set effort level (low/medium/high)     |
| `--brief`                   | Brief output mode                      |
| `--tools <tools>`           | Specify available tools                |
| `--permission-mode auto`    | Enable auto permission mode            |

### Session & Collaboration

| Flag                       | Purpose                            |
| -------------------------- | ---------------------------------- |
| `--fork-session <id>`      | Fork an existing session           |
| `--from-pr <url>`          | Start session from a pull request  |
| `--add-dir <path>`         | Add additional working directories |
| `--no-session-persistence` | Don't save session for resumption  |
| `--worktree` / `-w`        | Run in git worktree isolation      |
| `--tmux`                   | Run teammates in tmux panes        |

### Agent Teams

| Flag                     | Purpose                                  |
| ------------------------ | ---------------------------------------- |
| `--teammate-mode <mode>` | Set teammate mode (auto/in-process/tmux) |

### Remote

| Flag         | Purpose                             |
| ------------ | ----------------------------------- |
| `--remote`   | Start a remote-controllable session |
| `--teleport` | Resume a remote session locally     |

### MCP & Plugins

| Flag                       | Purpose                           |
| -------------------------- | --------------------------------- |
| `--strict-mcp-config`      | Fail on MCP server startup errors |
| `--chrome`                 | Enable Chrome/browser integration |
| `--plugin-dir <path>`      | Additional plugin directory       |
| `--mcp-config <path>`      | Path to MCP configuration file    |
| `--session-id <id>`        | Set specific session ID           |
| `--setting-sources <json>` | Override settings sources         |
| `--settings <json>`        | Inline settings override          |

### Output

| Flag                       | Purpose                               |
| -------------------------- | ------------------------------------- |
| `--json-schema <schema>`   | Structured output (JSON schema)       |
| `--fallback-model <model>` | Fallback model if primary unavailable |

### Initialization

| Flag     | Purpose                        |
| -------- | ------------------------------ |
| `--init` | Run setup hooks and initialize |

---

## 14. Permission System

### Permission Levels

| Level   | Behavior                                                          |
| ------- | ----------------------------------------------------------------- |
| `allow` | Tool executes without prompt                                      |
| `ask`   | User prompted for each execution                                  |
| `deny`  | Tool execution blocked                                            |
| `auto`  | Auto mode classifies tool calls and auto-approves safe operations |

### Settings Hierarchy

**Precedence** (highest to lowest):

1. **Managed** - Enterprise/admin policies
2. **CLI** - Flags passed at invocation
3. **Local** - `.claude/settings.local.json`
4. **Project** - `.claude/settings.json`
5. **User** - `~/.claude/settings.json`

### Permission Patterns

```json
{
  "permissions": {
    "allow": [
      "Bash(npm *)",
      "Bash(git *)",
      "Read(**)",
      "WebFetch(domain:docs.anthropic.com)",
      "mcp__memory__*",
      "Agent(*)"
    ],
    "deny": ["Bash(rm -rf /*)"]
  }
}
```

### Pattern Syntax

| Pattern                        | Matches                                         |
| ------------------------------ | ----------------------------------------------- |
| `Bash(npm *)`                  | Any npm command                                 |
| `Bash(git status*)`            | git status with any suffix                      |
| `Read(**)`                     | Read any file                                   |
| `Read(src/**)`                 | Read files under src/                           |
| `WebFetch(domain:example.com)` | Fetch from specific domain                      |
| `mcp__server__*`               | All tools from MCP server                       |
| `mcp__server__tool`            | Specific MCP tool                               |
| `Agent(*)`                     | Launch any subagent (Task still works as alias) |

### PermissionRequest Hook

Automate permission decisions:

```json
{
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
```

---

## 14.5. Auto Mode

**Purpose**: Automatically classify and approve safe tool operations without user prompts.

### Configuration

```bash
claude --permission-mode auto
# or in-session
/effort auto
```

### How It Works

- Tool calls are classified as safe/unsafe by the permission classifier
- Safe operations (read files, run tests, search) are auto-approved
- Unsafe operations (write to sensitive paths, destructive commands) still prompt
- Configurable via `claude auto-mode config` and `claude auto-mode defaults`

---

## 14.6. Effort Levels

Control thinking depth and response detail.

### Levels

| Level    | Symbol | Behavior                                       |
| -------- | ------ | ---------------------------------------------- |
| `low`    | ⚡     | Quick responses, minimal reasoning             |
| `medium` | 🔄     | Balanced (default)                             |
| `high`   | 🧠     | Deep reasoning, extended thinking (ultrathink) |
| `auto`   | 🤖     | System determines based on query complexity    |

### Usage

```bash
claude --effort high
# or in-session
/effort high
```

---

## 14.7. Plugin System

Extend Claude Code with community and custom plugins.

### Commands

```bash
claude plugins install <name>    # Install plugin
claude plugins list              # List installed
claude plugins remove <name>     # Remove plugin
/reload-plugins                  # Reload in session
```

### Plugin Sources

- Marketplace plugins
- Local plugin directories via `--plugin-dir <path>`
- Plugins can provide: agents, skills, hooks, MCP servers

---

## 14.8. Skill System

### Skill Frontmatter Fields

Skills support additional frontmatter fields beyond basic definitions:

| Field                      | Description                           |
| -------------------------- | ------------------------------------- |
| `context: fork`            | Skill forks the session               |
| `agent`                    | Skill delegates to a specific agent   |
| `allowed-tools`            | Restrict tools available to the skill |
| `hooks`                    | Skill-specific hooks                  |
| `disable-model-invocation` | Skill runs without model call         |
| `user-invocable`           | Whether skill appears in `/` menu     |

### Skill Template Variables

| Variable               | Resolves To            |
| ---------------------- | ---------------------- |
| `${CLAUDE_SKILL_DIR}`  | Skill's directory path |
| `${CLAUDE_SESSION_ID}` | Current session ID     |

### Inline Shell Execution

Use `` !`command` `` syntax in skill body for inline shell execution.

---

## 14.9. Auto-Memory

### `autoMemoryDirectory` Setting

Controls where auto-memory files are stored. Configure in settings to customize the directory used for automatic memory saving.

```json
{
  "autoMemoryDirectory": ".claude/memory"
}
```

When `CLAUDE_CODE_DISABLE_AUTO_MEMORY` is set, auto-memory is disabled entirely.

---

## 15. Sandboxing

**Status**: Preview feature

### Overview

Sandboxing restricts Claude Code's access to the filesystem and network for enhanced security.

### Configuration

In settings.json:

```json
{
  "sandbox": {
    "enabled": true,
    "network": {
      "allowedHosts": ["api.anthropic.com", "registry.npmjs.org"]
    }
  }
}
```

### Options

| Setting                        | Purpose                     |
| ------------------------------ | --------------------------- |
| `sandbox.enabled`              | Enable/disable sandboxing   |
| `sandbox.network`              | Network access restrictions |
| `sandbox.network.allowedHosts` | Whitelist of allowed hosts  |

### Command

```
/sandbox
```

Configure sandboxing interactively.

---

## 16. Remote Control

### Remote Sessions

Start a session that can be controlled from another machine:

```bash
claude --remote
```

This outputs a session ID that can be used to connect.

### Teleport

Resume a remote session locally:

```bash
claude --teleport
# or
/teleport
```

Connects to a remote session started on claude.ai or another machine.

---

## Settings Files

### `.claude/settings.json` (Project)

Primary project configuration. Contains permissions, hooks, env, statusLine.

### `.claude/settings.local.json` (Local Override)

Project-specific overrides, not checked into version control.

### `~/.claude/settings.json` (User Global)

User-wide settings applied to all projects.

### `.claude/rules/` Directory

Markdown files in `.claude/rules/` are loaded as additional instructions. Supports subdirectories for organization (e.g., `.claude/rules/governance/`).

---

## Sources

- [Claude Code Official Docs](https://code.claude.com/docs/overview)
- [Claude Code Subagents](https://code.claude.com/docs/sub-agents)
- [Claude Code Hooks](https://code.claude.com/docs/hooks)
- [Claude Code MCP](https://code.claude.com/docs/mcp)
- [Claude Code GitHub](https://github.com/anthropics/claude-code)
- [Claude Code CHANGELOG](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md)
