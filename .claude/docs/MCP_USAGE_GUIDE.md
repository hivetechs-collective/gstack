# MCP Tool Usage Guide

**Last Updated**: February 24, 2026
**CLI Version**: 2.1.52

**Model Context Protocol (MCP)** servers extend Claude Code CLI with powerful integrations for file operations, git management, documentation lookups, and structured problem-solving.

---

## Configured MCP Servers

This template includes 5 MCP servers optimized for development workflows:

| Server                  | Purpose                     | When to Use                         | Performance Impact         |
| ----------------------- | --------------------------- | ----------------------------------- | -------------------------- |
| **Memory**              | Knowledge graph persistence | Automatic - always active           | Minimal (<10ms)            |
| **Filesystem**          | Secure file operations      | Reading/searching project files     | Low (<50ms)                |
| **Git**                 | Repository operations       | Analyzing commits, diffs, history   | Low (<100ms)               |
| **Sequential Thinking** | Structured problem-solving  | Complex debugging, multi-step tasks | Medium (+2-5s per thought) |
| **REF**                 | Documentation optimization  | Technical documentation lookups     | Low (<500ms, saves tokens) |

---

## MCP Transport Types

| Transport | Command                                                | Use Case        | Status                 |
| --------- | ------------------------------------------------------ | --------------- | ---------------------- |
| **stdio** | `claude mcp add --transport stdio <name> -- <command>` | Local processes | Recommended for local  |
| **HTTP**  | `claude mcp add --transport http <name> <url>`         | Remote servers  | Recommended for remote |
| **SSE**   | N/A                                                    | Deprecated      | Use HTTP instead       |

### Adding MCP Servers

```bash
# Local server (stdio)
claude mcp add --transport stdio memory -- npx -y @modelcontextprotocol/server-memory

# Remote server (HTTP)
claude mcp add --transport http my-remote-server https://mcp.example.com/api

# With scope
claude mcp add --scope project memory -- npx -y @modelcontextprotocol/server-memory
```

---

## Configuration Scopes

MCP servers can be configured at three levels with clear precedence:

| Scope       | Location            | Visibility                 | Precedence |
| ----------- | ------------------- | -------------------------- | ---------- |
| **Local**   | `.claude/.mcp.json` | Private, per-project       | Highest    |
| **Project** | `.mcp.json`         | Shared, version controlled | Medium     |
| **User**    | `~/.claude.json`    | Cross-project, private     | Lowest     |

**Precedence**: Local > Project > User > Plugin

### Local Configuration (`.claude/.mcp.json`)

```json
{
  "mcpServers": {
    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory"]
    },
    "filesystem": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "/path/to/project"
      ]
    }
  }
}
```

### Strict Configuration Mode

Use `--strict-mcp-config` to fail on MCP server startup errors instead of silently continuing:

```bash
claude --strict-mcp-config
```

---

## MCP Tool Search (Lazy Loading)

### Overview

MCP Tool Search dynamically loads tool definitions on-demand instead of preloading all tools into context. This provides **massive token savings** when many MCP tools are configured.

### Token Savings

| Scenario      | Without Tool Search | With Tool Search | Savings |
| ------------- | ------------------- | ---------------- | ------- |
| 50+ MCP tools | ~134k tokens        | ~5k tokens       | **96%** |
| 10-20 tools   | ~30k tokens         | ~5k tokens       | **83%** |
| 5 tools       | ~8k tokens          | ~5k tokens       | **37%** |

### How It Works

1. At startup, only tool names and short descriptions are loaded
2. When Claude needs a specific tool, full definition is fetched on-demand
3. Definitions are cached for the session duration
4. Transparent to both Claude and the user

### Configuration

```bash
# Default: auto-enable when tools exceed 10% of context
ENABLE_TOOL_SEARCH=auto

# Custom threshold (15% of context)
ENABLE_TOOL_SEARCH=auto:15

# Always enabled
ENABLE_TOOL_SEARCH=true

# Disabled (all tools loaded at startup)
ENABLE_TOOL_SEARCH=false
```

### When It Activates

- **Automatic**: When MCP tools exceed 10% of context window
- Tool Search is invisible to the user
- No configuration needed for the default behavior

---

## MCP Tool Annotations

MCP tools can include annotations that inform Claude about tool behavior:

| Annotation        | Description                           | Effect                |
| ----------------- | ------------------------------------- | --------------------- |
| `readOnlyHint`    | Tool doesn't modify state             | May skip confirmation |
| `destructiveHint` | Tool may destructively modify state   | Extra confirmation    |
| `idempotentHint`  | Safe to retry                         | Auto-retry on failure |
| `openWorldHint`   | Tool interacts with external entities | Network awareness     |

### Example Tool Definition with Annotations

```json
{
  "name": "database_query",
  "annotations": {
    "readOnlyHint": true,
    "destructiveHint": false,
    "idempotentHint": true,
    "openWorldHint": false
  }
}
```

---

## MCP Permission Patterns

Control access to MCP tools via `settings.json`:

```json
{
  "permissions": {
    "allow": ["mcp__memory__*", "mcp__filesystem__read_file", "mcp__git__log"],
    "deny": ["mcp__filesystem__write_file"]
  }
}
```

### Pattern Syntax

| Pattern             | Matches                 |
| ------------------- | ----------------------- |
| `mcp__server__*`    | All tools from a server |
| `mcp__server__tool` | Specific tool           |
| `mcp__*`            | All MCP tools           |

---

## MCP Environment Variables

| Variable                | Purpose                             | Default |
| ----------------------- | ----------------------------------- | ------- |
| `ENABLE_TOOL_SEARCH`    | Tool search mode                    | `auto`  |
| `MCP_TIMEOUT`           | Server startup timeout (ms)         | 30000   |
| `MAX_MCP_OUTPUT_TOKENS` | Maximum tokens for MCP tool outputs | —       |

---

## When Each MCP Tool Should Be Used

### 1. Memory (ALWAYS ACTIVE - Automatic)

**Purpose**: Persistent knowledge graph across Claude sessions

**Automatic Usage**:

- Claude uses this transparently to remember project context
- No explicit agent action needed
- Stores in `~/.claude/memory/knowledge-graph.json`

**What it remembers**:

- Project architecture and tech stack
- Past conversation context
- User preferences and patterns
- Previously explained concepts

**Agent guidelines**:

- Trust that context persists across sessions
- Reference past conversations naturally
- Don't re-explain project basics already discussed

---

### 2. Filesystem (PREFER over bash for reads)

**Purpose**: Secure file operations scoped to project directory

**Use filesystem MCP for**:

- Reading files: `filesystem.read_file(path="package.json")`
- Listing directories: `filesystem.list_directory(path="src")`
- Searching files: `filesystem.search_files(pattern="*.ts", query="useState")`
- Getting file info: `filesystem.get_file_info(path="README.md")`
- Writing files: `filesystem.write_file(path="config.json", content="...")`

**Use bash for**:

- Running executables (chmod, codesign, npm, cargo)
- Piping complex commands (grep -r | awk | sort)
- System operations outside project directory

**Why prefer MCP?**

- **Safer**: Scoped to project directory
- **Better errors**: Structured error messages
- **Structured output**: JSON instead of parsing strings
- **Tracked**: Operations are logged

---

### 3. Git (PREFER for analysis, bash for mutations)

**Purpose**: Git repository operations with structured JSON output

**Use git MCP for**:

- Reading commit history: `git.log(max_count=10, format="json")`
- Checking status: `git.status()` → returns structured data
- Reading diffs: `git.diff(commit="HEAD~1", file="src/app.ts")`
- Searching commits: `git.search_commits(query="fix: auth")`
- Showing file history: `git.log(path="src/main.ts")`

**Use bash for**:

- Creating commits (semantic commit messages)
- Pushing to remote
- Interactive operations
- Git hooks and complex workflows

---

### 4. Sequential Thinking (USE for complex problems)

**Purpose**: Dynamic problem-solving through structured thought sequences

**Always use sequential-thinking for**:

- Multi-step debugging (notarization failures, signing issues, build errors)
- Architecture decisions (exploring multiple alternatives)
- Complex refactoring (many interdependent files)
- Release coordination (multi-phase workflows)
- Performance optimization (profile → identify → test → verify)

**Don't use for**:

- Simple lookups
- Straightforward edits
- Quick answers
- Single-step tasks

**Performance considerations**:

- Each thought = 1 LLM call (adds 2-5 seconds per thought)
- Typical sequences: 5-15 thoughts
- Total overhead: 10-60 seconds
- Worth it for complex problems (saves hours of incorrect debugging)

---

### 5. REF (AUTOMATIC for docs, explicit for custom queries)

**Purpose**: Smart documentation lookups with 60-95% token reduction

**How token reduction works**:

- Traditional approach: Fetch entire docs page (20k tokens)
- REF approach: Analyze session context + query → return only relevant sections (5k tokens)
- Result: 75% token savings, faster responses, lower API costs

**Configuration**:

- Requires `REF_API_KEY` environment variable
- Get API key from https://ref.tools/
- Free tier available, paid plans ~$10-20/month

---

## MCP Resources

Reference MCP resources in prompts via:

```
@server:protocol://path
```

---

## Agent Decision Tree

```
User Request
    |
    +-- Need to remember past context? --> Memory (automatic)
    |
    +-- Simple file read/write?
    |   +-- Inside project directory? --> Use filesystem MCP
    |   +-- System-wide or execute? --> Use bash
    |
    +-- Git operation?
    |   +-- Reading data (log, diff, status)? --> Use git MCP
    |   +-- Mutation (commit, push, rebase)? --> Use bash git
    |
    +-- Complex multi-step problem?
    |   +-- Requires exploration/revision? --> Use sequential-thinking
    |   +-- Straightforward steps? --> Regular approach
    |
    +-- Documentation lookup?
    |   +-- REF handles automatically (if enabled)
    |
    +-- Execute command/script? --> Use bash
```

---

## Performance Considerations

### MCP Call Overhead (per operation)

| MCP Server          | Latency           | Notes                        |
| ------------------- | ----------------- | ---------------------------- |
| Memory              | <10ms             | Local file I/O               |
| Filesystem          | <50ms             | Local file operations        |
| Git                 | <100ms            | Runs git commands internally |
| Sequential Thinking | +2-5s per thought | LLM calls for each thought   |
| REF                 | <500ms            | HTTP API call to ref.tools   |

### When to Avoid MCP

- **Time-critical operations**: Building, testing (use bash)
- **User confirmation required**: Commits, deployments (use bash with approval)
- **System-wide operations**: Installing packages, system config (use bash)
- **Complex piping**: Multiple commands chained (use bash)

### When to Prefer MCP

- **Safe reads**: Analyzing code, searching files
- **Structured data**: Git history, file metadata
- **Complex reasoning**: Multi-step debugging, architecture decisions
- **Token efficiency**: Documentation lookups

---

## Setup Instructions

### 1. Install MCP Servers

All servers use `npx` for zero-installation convenience:

```bash
# Test that MCP servers work
npx -y @modelcontextprotocol/server-memory --help
npx -y @modelcontextprotocol/server-filesystem --help
npx -y @modelcontextprotocol/server-git --help
npx -y @modelcontextprotocol/server-sequential-thinking --help
```

### 2. Configure REF (Optional)

```bash
# 1. Get API key from https://ref.tools/
# 2. Copy environment template
cp .claude/.env.example .claude/.env
# 3. Edit .env and add your REF_API_KEY
# 4. Enable REF in .mcp.json by setting "enabled": true
```

### 3. Verify Configuration

```bash
# Check MCP configuration is valid JSON
jq . .claude/.mcp.json

# Verify memory directory exists
ls ~/.claude/memory/
```

### 4. Start Claude Code CLI

```bash
# MCP servers auto-start when Claude Code launches
claude

# Verify MCP tools are available
# Ask: "What MCP tools are available?"
```

---

## Troubleshooting

### MCP Server Not Starting

**Symptoms**: "MCP server 'X' failed to start"

**Solutions**:

```bash
# 1. Check npx is available
npx --version

# 2. Test server manually
npx -y @modelcontextprotocol/server-filesystem /path/to/project

# 3. Check .mcp.json syntax
jq . .claude/.mcp.json

# 4. Use strict mode to see errors
claude --strict-mcp-config
```

### MCP Tool Search Issues

**Symptoms**: Tools not found or unexpected tool behavior

**Solutions**:

```bash
# 1. Check tool search status
echo $ENABLE_TOOL_SEARCH

# 2. Force disable to load all tools
ENABLE_TOOL_SEARCH=false claude

# 3. Adjust threshold
ENABLE_TOOL_SEARCH=auto:20 claude
```

### REF Not Working

**Symptoms**: Documentation lookups use full pages, no token savings

**Solutions**:

```bash
# 1. Check REF is enabled
jq '.mcpServers.ref.enabled' .claude/.mcp.json

# 2. Verify API key is set
echo $REF_API_KEY

# 3. Test REF API manually
curl "https://api.ref.tools/mcp?apiKey=$REF_API_KEY"
```

### Sequential Thinking Too Slow

- Reduce thought count: Ask for "5 thoughts maximum"
- Reserve for truly complex problems
- Use regular approach for straightforward tasks

### Memory Not Persisting

```bash
# 1. Check memory file exists
ls ~/.claude/memory/knowledge-graph.json

# 2. Verify memory directory permissions
ls -la ~/.claude/memory/

# 3. Restart Claude Code CLI to reload memory
```

---

## Additional Resources

- **MCP Official Docs**: https://modelcontextprotocol.io/
- **MCP Server Registry**: https://github.com/modelcontextprotocol/servers
- **500+ Available MCP Servers**: https://mcp.so/
- **REF Tools**: https://ref.tools/
- **Claude Code MCP Docs**: https://docs.anthropic.com/en/docs/claude-code/mcp

---

## Version History

- **v2.0** (2026-02-24): Added MCP Tool Search, HTTP transport, tool annotations, permissions, config scopes
- **v1.0** (2025-10-04): Initial MCP integration with 5 servers

---

**For agent-specific MCP usage patterns, see individual agent `.md` files in `.claude/agents/`**
