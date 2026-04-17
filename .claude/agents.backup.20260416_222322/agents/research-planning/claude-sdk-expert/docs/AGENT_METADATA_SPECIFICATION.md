# Agent Metadata Specification v1.0.0

**Status**: Definitive Specification **Version**: 1.0.0 **Last Updated**:
2025-11-25 **Applies To**: All agents in
`/Users/veronelazio/Developer/Private/claude-pattern/.claude/agents/`

---

## Overview

This specification defines the canonical format for agent metadata in YAML
frontmatter. All agents in the claude-pattern repository MUST conform to this
specification to ensure consistency, tooling compatibility, and maintainability
across 79+ agents.

---

## Frontmatter Structure

Agent files are Markdown documents (`.md`) with YAML frontmatter enclosed in
triple-dash delimiters:

```yaml
---
# Required Fields
name: agent-name
version: 1.0.0
description: |
  Concise description with usage triggers and examples...
color: blue
# Recommended Fields
model: inherit
sdk_features: [feature1, feature2, feature3]
cost_optimization: true
session_aware: true
last_updated: 2025-11-25

# Optional Fields
category: research-planning
tools: [Read, Write, Edit, Bash]
supports_subagent_creation: true
supports_parallel_execution: true
---
# Agent Content (Markdown)
...
```

---

## Required Fields

### `name`

**Type**: `string` **Format**: `kebab-case` (lowercase, hyphen-separated)
**Description**: Unique identifier for the agent.

```yaml
# CORRECT
name: database-expert
name: react-typescript-specialist
name: github-security-orchestrator

# INCORRECT
name: Database Expert        # No spaces
name: databaseExpert         # No camelCase
name: DATABASE_EXPERT        # No uppercase or underscores
```

### `version`

**Type**: `string` **Format**: Semantic Versioning (`MAJOR.MINOR.PATCH`)
**Description**: Version number following [SemVer 2.0.0](https://semver.org/).

```yaml
# CORRECT
version: 1.0.0
version: 2.1.3
version: 1.12.0

# INCORRECT
version: 1.0      # Missing patch number
version: v1.0.0   # No "v" prefix
version: 1        # Must be full semver
```

**Versioning Rules**:

- `MAJOR`: Breaking changes to agent behavior or interface
- `MINOR`: New capabilities, backward-compatible features
- `PATCH`: Bug fixes, documentation updates, minor improvements

### `description`

**Type**: `string` **Format**: Single line or multi-line (using `|` or `>`)
**Description**: Comprehensive description including:

1. When to use this agent (activation triggers)
2. Core capabilities
3. One or more `<example>` blocks demonstrating usage

```yaml
# CORRECT - Single line with examples
description: Use this agent when you need to design database schemas, optimize SQL queries, implement SQLite databases, or ensure ACID compliance. Specializes in SQLite (all versions), PostgreSQL, database normalization, indexing strategies, and transaction management. Examples: <example>Context: User needs to design a database schema for a new application. user: 'Design a database schema for a blog platform with users, posts, comments, and tags' assistant: 'I'll use the database-expert agent to create a normalized schema with proper indexes and foreign key constraints' <commentary>Database schema design requires expertise in normalization, relationships, and performance optimization.</commentary></example>

# CORRECT - Multi-line
description: |
  Use this agent when you need to design database schemas, optimize SQL
  queries, or implement SQLite databases. Specializes in SQLite, PostgreSQL,
  database normalization, and query optimization.
  <example>
    Context: User needs schema design.
    user: 'Design a blog database'
    assistant: 'I'll use database-expert for normalized schema'
    <commentary>Schema design requires normalization expertise.</commentary>
  </example>
```

**Required Elements in Description**:

1. "Use this agent when..." clause (activation trigger)
2. List of specializations/capabilities
3. At least one `<example>` block

### `color`

**Type**: `string` **Format**: Lowercase color name **Description**: Display
color for the agent in tooling/UI.

**Canonical Color Values**: | Color | Meaning | Example Agents |
|-------|---------|----------------| | `red` | Security, critical operations |
security-expert, github-security-orchestrator | | `blue` | Coordination,
orchestration | orchestrator, mcp-expert | | `green` | Backend, databases,
publishing | nodejs-specialist, database-expert, npm-publisher | | `purple` |
AI/ML, data, documentation | chatgpt-expert, nextjs-expert, documentation-expert
| | `cyan` | Frontend, skills, implementation | react-typescript-specialist,
skills-expert | | `yellow` | UI/UX, observability, style | ui-designer,
observability-specialist, style-theme-expert | | `orange` | Python, ML,
performance | python-ml-expert, performance-testing-specialist | | `magenta` |
DevOps, automation | devops-automation-expert | | `pink` | Planning,
requirements | prd-writer | | `black` | Framework specialists | nextjs-expert
(alternate) |

```yaml
# CORRECT
color: blue
color: cyan
color: red

# INCORRECT
color: BLUE        # Must be lowercase
color: Blue        # Must be lowercase
color: #0000FF     # No hex codes
color: rgb(0,0,255) # No RGB values
```

---

## Recommended Fields

### `model`

**Type**: `string` **Format**: Model name or `inherit` **Description**: The
Claude model to use for this agent.

```yaml
# CORRECT
model: inherit                      # Use parent/default model
model: claude-sonnet-4-6           # Specific model
model: claude-haiku-4-5            # Cost-optimized model
model: claude-opus-4-6              # High-capability model

# DEPRECATED (do not use)
model: claude-3-5-sonnet-20241022  # Old format
model: claude-3-haiku-20240307     # Old format
```

**Note**: `inherit` is the recommended default, allowing orchestrators to set
the model contextually.

### `sdk_features`

**Type**: `array<string>` **Format**: YAML array `[item1, item2, item3]`
**Description**: SDK capabilities this agent is designed to leverage.

**Canonical Feature Values**: | Feature | Description |
|---------|-------------| | `subagents` | Can spawn specialized subagents | |
`sessions` | Supports session management (resume, fork) | | `cost_tracking` |
Tracks API costs via hooks | | `tool_restrictions` | Enforces limited tool
access | | `lifecycle_hooks` | Uses PreToolUse/PostToolUse hooks | |
`todo_coordination` | Uses TodoWrite for task tracking |

```yaml
# CORRECT - Array format (canonical)
sdk_features: [subagents, sessions, cost_tracking]
sdk_features: [sessions, cost_tracking, tool_restrictions]

# INCORRECT - Nested object format (deprecated)
sdk_features:
  context_management:
    - smart-chaining
  reasoning:
    - sequential-thinking
# This format is deprecated - migrate to array format
```

**Migration Note**: The nested object format
(`sdk_features: { context_management: [...] }`) found in some agents is
deprecated. Convert to the canonical array format.

### `cost_optimization`

**Type**: `boolean` **Format**: `true` or `false` **Description**: Indicates if
the agent is optimized for cost efficiency.

```yaml
# CORRECT
cost_optimization: true
cost_optimization: false

# INCORRECT - Nested object format (deprecated)
cost_optimization:
  strategy: "Use Haiku for simple queries..."
# This format is deprecated - migrate to boolean
```

**Migration Note**: If you need to document cost optimization strategy, include
it in the agent's body content, not in frontmatter.

### `session_aware`

**Type**: `boolean` **Format**: `true` or `false` **Description**: Indicates if
the agent maintains session context.

```yaml
# CORRECT
session_aware: true
session_aware: false
```

### `last_updated`

**Type**: `string` **Format**: ISO 8601 date (`YYYY-MM-DD`) **Description**:
Date of last significant update.

```yaml
# CORRECT
last_updated: 2025-11-25
last_updated: 2025-10-20

# INCORRECT
last_updated: 11/25/2025     # Wrong format
last_updated: Nov 25, 2025   # Wrong format
last_updated: 2025-11-25T10:30:00Z  # Too specific (date only)
```

---

## Optional Fields

### `category`

**Type**: `string` **Format**: `kebab-case` **Description**: Organizational
category matching directory structure.

**Canonical Category Values**: | Category | Description | Directory |
|----------|-------------|-----------| | `coordination` | Orchestrators, project
managers | `agents/coordination/` | | `implementation` | Language/framework
specialists | `agents/implementation/` | | `research-planning` | Research,
design, documentation | `agents/research-planning/` | | `hive` | Hive-specific
agents | `agents/hive/` |

```yaml
# CORRECT
category: research-planning
category: coordination
category: implementation

# USAGE
# Include when agent might be in multiple directories
# or when category differs from directory location
```

**Note**: This field is OPTIONAL because category is typically inferred from the
file path. Include only when disambiguation is needed.

### `tools`

**Type**: `array<string>` or `string` **Format**: Array of tool names, or
wildcard `*` **Description**: Tools this agent is authorized to use.

**Canonical Tool Values**: | Tool | Description | |------|-------------| |
`Read` | Read files from filesystem | | `Write` | Write/create files | | `Edit`
| Edit existing files | | `Bash` | Execute shell commands | | `Grep` | Search
file contents | | `Glob` | Find files by pattern | | `WebFetch` | Fetch web
content | | `WebSearch` | Search the web | | `TodoWrite` | Manage todo lists |

```yaml
# CORRECT - Explicit tool list
tools: [Read, Write, Edit, Bash]
tools: [Read, Grep, Glob]
tools: Read, Write, Edit, WebFetch, WebSearch

# CORRECT - Wildcard (all tools)
tools: "*"

# CORRECT - Omitted (inherits default tools)
# (field not present)

# INCORRECT
tools: [read, write]           # Must be capitalized
tools: [FileRead, FileWrite]   # Use canonical names
```

**When to Use**:

- **Explicit list**: For security-sensitive agents (limit capabilities)
- **Wildcard `*`**: For orchestrators needing full access
- **Omitted**: For agents using default tool set

### `supports_subagent_creation`

**Type**: `boolean` **Format**: `true` or `false` **Description**: Indicates if
the agent can create subagents.

```yaml
# CORRECT
supports_subagent_creation: true
supports_subagent_creation: false
```

### `supports_parallel_execution`

**Type**: `boolean` **Format**: `true` or `false` **Description**: Indicates if
the agent supports parallel execution.

```yaml
# CORRECT
supports_parallel_execution: true
supports_parallel_execution: false
```

### `sdk_self_aware`

**Type**: `boolean` **Format**: `true` or `false` **Description**: Indicates if
the agent understands SDK internals.

```yaml
# CORRECT
sdk_self_aware: true

# Use for agents like claude-sdk-expert that guide SDK usage
```

### `memory`

**Type**: `string` **Format**: One of `user`, `project`, `local`
**Description**: Enables persistent agent memory across sessions. Controls where
the agent stores learned patterns and context.

```yaml
# CORRECT
memory: user       # Stored in ~/.claude/memory/ (shared across projects)
memory: project    # Stored in .claude/memory/ (project-specific)
memory: local      # Stored in agent's local directory

# USAGE
# Omit if agent does not need persistent memory
```

**Scope**:

- `user`: Global memory shared across all projects (e.g., user preferences)
- `project`: Memory scoped to the current project (e.g., architectural patterns)
- `local`: Memory private to the agent instance

### `background`

**Type**: `boolean` **Format**: `true` or `false` **Description**: Indicates if
the agent should run in the background without blocking the main session.

```yaml
# CORRECT
background: true    # Agent runs in background
background: false   # Agent runs in foreground (default)

# USAGE
# Use for long-running agents like dev servers or file watchers
```

### `isolation`

**Type**: `string` **Format**: `worktree` **Description**: Specifies the
isolation mode for the agent. Currently only `worktree` is supported, which
creates a temporary git worktree so the agent works on an isolated copy of the
repository.

```yaml
# CORRECT
isolation: worktree # Agent gets its own git worktree


# USAGE
# Use for agents that make file changes that shouldn't affect
# the main working tree until explicitly merged
```

### `maxTurns`

**Type**: `number` **Format**: Positive integer **Description**: Limits the
maximum number of agentic turns (API round-trips) before the agent stops. Use to
prevent runaway agents or to control cost.

```yaml
# CORRECT
maxTurns: 10     # Agent stops after 10 turns
maxTurns: 50     # Agent stops after 50 turns

# USAGE
# Omit for unlimited turns (default behavior)
# Set lower for simple, bounded tasks
# Set higher for complex, multi-step workflows
```

### `mcpServers`

**Type**: `array<string>` **Format**: YAML array of MCP server names
**Description**: Specifies which MCP (Model Context Protocol) servers the agent
has access to. Allows per-agent control over external tool integrations.

```yaml
# CORRECT
mcpServers: [memory, filesystem]
mcpServers: [github, playwright]
mcpServers: [memory, filesystem, github, sequential-thinking]

# USAGE
# Only include servers the agent actually needs
# Omit to use no MCP servers (or inherit from parent config)
```

**Common MCP Servers**: | Server | Description |
|--------|-------------| | `memory` | Persistent entity storage | |
`filesystem` | Extended file operations | | `github` | GitHub API access | |
`sequential-thinking` | Step-by-step reasoning | | `playwright` | Browser
automation |

---

## Deprecated Fields (Do Not Use)

### `x-` Prefixed Fields

**Status**: DEPRECATED **Migration**: Remove prefix, use canonical field name

```yaml
# DEPRECATED
x-color: blue
x-version: 1.0.0
x-sdk_features: [...]

# MIGRATE TO
color: blue
version: 1.0.0
sdk_features: [...]
```

### Nested `sdk_features` Object

**Status**: DEPRECATED **Migration**: Convert to flat array

```yaml
# DEPRECATED
sdk_features:
  context_management:
    - smart-chaining
  reasoning:
    - sequential-thinking
  memory:
    - pattern-learning
  cost_optimization:
    - model-selection

# MIGRATE TO
sdk_features: [sessions, cost_tracking, tool_restrictions]
```

### Nested `cost_optimization` Object

**Status**: DEPRECATED **Migration**: Convert to boolean

```yaml
# DEPRECATED
cost_optimization:
  strategy: "Use Haiku for simple queries ($0.01-0.02)..."

# MIGRATE TO
cost_optimization: true
# Document strategy in agent body content if needed
```

### `tool_restrictions` Field

**Status**: DEPRECATED **Migration**: Use `tools` field or document in body

```yaml
# DEPRECATED
tool_restrictions:
  - "Use Read tool for relevant files only"
  - "Use Bash for necessary commands"

# MIGRATE TO
tools: [Read, Bash, WebSearch]
# Document usage guidance in agent body
```

### `sdk_utilization` Field

**Status**: DEPRECATED **Migration**: Remove (not actionable metadata)

```yaml
# DEPRECATED
sdk_utilization: 60%

# REMOVE - This is documentation, not metadata
```

---

## Complete Examples

### Minimal Compliant Agent

```yaml
---
name: simple-helper
version: 1.0.0
description: Use this agent for simple helper tasks. Provides basic assistance with common operations. <example>Context: User needs help. user: 'Help me organize my files' assistant: 'I'll use simple-helper for basic organization' <commentary>Simple task delegation.</commentary></example>
color: green
---

# Simple Helper Agent

You are a simple helper agent...
```

### Full-Featured Agent

```yaml
---
name: database-expert
version: 1.1.0
description: Use this agent when you need to design database schemas, optimize SQL queries, implement SQLite databases, or ensure ACID compliance. Specializes in SQLite (all versions), PostgreSQL, database normalization, indexing strategies, and transaction management. Examples: <example>Context: User needs to design a database schema for a new application. user: 'Design a database schema for a blog platform with users, posts, comments, and tags' assistant: 'I'll use the database-expert agent to create a normalized schema with proper indexes and foreign key constraints' <commentary>Database schema design requires expertise in normalization, relationships, and performance optimization.</commentary></example>
color: purple
model: inherit
sdk_features: [subagents, sessions, cost_tracking, tool_restrictions]
cost_optimization: true
session_aware: true
supports_subagent_creation: true
last_updated: 2025-11-25
---

# Database Expert Agent

You are a database specialist...
```

### Orchestrator Agent

```yaml
---
name: orchestrator
version: 1.3.0
description: Use this agent when you have complex, multi-faceted goals that require coordination between multiple specialist agents working simultaneously. Now with 77 agents covering 96.0% of modern tech stacks. <example>Context: User wants to build a full-stack application. user: 'Create a task management app with React frontend, Python backend, and deploy to AWS' assistant: 'I'll use the orchestrator agent to coordinate specialists' <commentary>Complex multi-domain request benefits from orchestration.</commentary></example>
color: blue
model: inherit
sdk_features: [subagents, sessions, cost_tracking, todo_coordination, tool_restrictions, lifecycle_hooks]
cost_optimization: true
session_aware: true
supports_parallel_execution: true
last_updated: 2025-11-25
---

# Task Orchestrator

You are the Task Orchestrator...
```

### Security Agent

```yaml
---
name: security-expert
version: 1.1.0
description: Use this agent when you need to review code for security vulnerabilities, implement authentication systems, design zero-trust architectures, or ensure OWASP Top 10 compliance. Specializes in web security (XSS, CSRF, SQLi), authentication (OAuth 2.0, JWT), encryption (TLS, AES), secrets management, and container security. Has web search capability for latest CVEs. <example>Context: User needs security review. user: 'Review my JWT authentication implementation' assistant: 'I'll use security-expert to audit JWT implementation' <commentary>Authentication security requires OWASP expertise.</commentary></example>
tools: [Read, WebSearch, WebFetch]
color: red
model: inherit
sdk_features: [subagents, sessions, cost_tracking, tool_restrictions]
cost_optimization: true
session_aware: true
supports_subagent_creation: true
last_updated: 2025-11-25
---

# Security Expert Agent

You are a security specialist...
```

---

## Field Order Convention

For consistency, fields SHOULD appear in this order:

```yaml
---
# Identity (Required)
name:
version:
description:
color:

# Execution (Recommended)
model:
sdk_features:
cost_optimization:
session_aware:

# Capabilities (Optional)
category:
tools:
supports_subagent_creation:
supports_parallel_execution:
sdk_self_aware:

# Runtime (Optional)
memory:
background:
isolation:
maxTurns:
mcpServers:

# Metadata (Recommended)
last_updated:
---
```

---

## Migration Guide

### Step 1: Identify Non-Compliant Agents

Run the validation checklist (see AGENT_METADATA_CHECKLIST.md) against all
agents.

### Step 2: Fix Required Fields

1. Ensure `name` is kebab-case
2. Add `version` if missing (start with `1.0.0`)
3. Ensure `description` has activation triggers and examples
4. Add `color` if missing (choose from canonical values)

### Step 3: Standardize Recommended Fields

1. Convert nested `sdk_features` to array format
2. Convert nested `cost_optimization` to boolean
3. Add `model: inherit` if missing
4. Add `session_aware: true/false`
5. Add `last_updated` date

### Step 4: Remove Deprecated Fields

1. Remove `x-` prefixes from field names
2. Remove `sdk_utilization` field
3. Remove `tool_restrictions` (use `tools` instead)
4. Move cost strategy documentation to agent body

### Step 5: Validate

Run validation checklist again to confirm compliance.

---

## Changelog

### v1.0.0 (2025-11-25)

- Initial specification
- Defined required, recommended, and optional fields
- Established canonical formats for all fields
- Documented deprecated patterns
- Created migration guide
- Added complete examples

---

## Related Documents

- `AGENT_METADATA_CHECKLIST.md` - Validation checklist
- `docs/overview.md` - SDK overview
- `docs/migration-guide.md` - SDK migration patterns
