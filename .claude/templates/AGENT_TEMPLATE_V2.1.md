# Agent Template v2.1.0

**Last Updated**: 2026-01-08
**Claude Code Version**: v2.1.0+
**Purpose**: Standard template for all agent definitions with full v2.1.0 feature support

---

## Template: Standard Agent (Opus - Complex Tasks)

```yaml
---
# ============================================================================
# IDENTITY (Required)
# ============================================================================
name: agent-name-specialist
description: |
  Use this agent when you need to [primary capability]. Specializes in
  [domain expertise] with [specific technologies/frameworks]. Examples:
  <example>
  Context: User needs [scenario].
  user: '[example user request]'
  assistant: 'I'll use the agent-name-specialist agent to [action]'
  <commentary>[Why this agent is appropriate]</commentary>
  </example>
version: 1.0.0

# ============================================================================
# MODEL CONFIGURATION (Required for v2.1.0)
# ============================================================================
# Model Selection Guide:
# - opus: Complex reasoning, coding, architecture, debugging, security (80.9% SWE-bench)
# - sonnet: Documentation, simple tasks, cost-effective standard work
# - haiku: MECHANICAL ONLY - file ops, builds, logs (95% cost savings)
model: opus

# ============================================================================
# TOOL CONFIGURATION
# ============================================================================
# YAML list format (preferred in v2.1.0)
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Grep
  - Glob
  - WebFetch
  - WebSearch
  - Task          # For spawning subagents
  - TodoWrite     # For task tracking

# Explicit tool blocking (new in v2.0.30+)
# Use sparingly - only block dangerous or inappropriate tools
disallowedTools: []

# ============================================================================
# PERMISSION CONFIGURATION (New in v2.0.43)
# ============================================================================
# Options:
# - ask: Prompt for each permission (default)
# - allow: Auto-approve allowed tools
# - deny: Deny by default, require explicit approval
permissionMode: ask

# ============================================================================
# SKILLS INTEGRATION (New in v2.0.43)
# ============================================================================
# Skills auto-loaded when this agent starts
# Reference skills by name from .claude/skills/
skills:
  - code-review-checklist
  # Add relevant skills for this agent's domain

# ============================================================================
# HOOKS CONFIGURATION (New in v2.1.0)
# ============================================================================
# Agent-scoped hooks for workflow automation
hooks:
  # Validate inputs before tool execution
  # - type: PreToolUse
  #   matcher: Bash
  #   command: ".claude/hooks/validate-bash.sh"

  # Log or process outputs after tool execution
  # - type: PostToolUse
  #   command: ".claude/hooks/log-output.sh"

  # Verify completion before agent finishes
  # - type: Stop
  #   prompt: "Verify all requirements are met before completing"
  #   model: haiku  # Use cheaper model for verification

# ============================================================================
# VISUAL CONFIGURATION
# ============================================================================
# Available colors: blue, cyan, green, purple, pink, red, orange, yellow, magenta, black
color: purple

# ============================================================================
# METADATA
# ============================================================================
last_updated: 2026-01-08
sdk_features:
  - sessions
  - cost_tracking
  - tool_restrictions
  - subagents
  - hooks
cost_optimization: true
session_aware: true
---

# Agent Name Specialist

## Overview

Brief description of what this agent does and its primary use cases.

## Core Capabilities

1. **Capability 1**: Description
2. **Capability 2**: Description
3. **Capability 3**: Description

## When to Use This Agent

- Scenario 1
- Scenario 2
- Scenario 3

## When NOT to Use This Agent

- Anti-pattern 1 (use @other-agent instead)
- Anti-pattern 2

## Workflow

### Standard Workflow

1. **Understand**: Analyze the request and gather context
2. **Plan**: Create implementation plan using TodoWrite
3. **Execute**: Implement with proper testing
4. **Verify**: Run tests and validate
5. **Document**: Update relevant documentation

### Subagent Delegation

When appropriate, delegate to specialized subagents:

- Use `@file-scanner` (Haiku) for file operations
- Use `@log-parser` (Haiku) for log analysis
- Use `@build-runner` (Haiku) for build/test execution

## Output Format

[Specify expected output format, structure, and quality standards]

## Examples

### Example 1: [Common Use Case]

**User Request**: "[example]"

**Agent Response**: [detailed example of what agent produces]

### Example 2: [Complex Use Case]

**User Request**: "[example]"

**Agent Response**: [detailed example]

## Integration with Skills

This agent automatically loads these skills when invoked:
- `skill-name-1`: Purpose
- `skill-name-2`: Purpose

## Token Optimization

- Delegate mechanical operations to Haiku agents
- Use progressive disclosure for large codebases
- Fork context for large operations when appropriate

## Related Agents

- `@related-agent-1`: When to use instead
- `@related-agent-2`: Complementary use cases
```

---

## Template: Mechanical Agent (Haiku - Token Optimization)

```yaml
---
# ============================================================================
# IDENTITY - MECHANICAL AGENT
# ============================================================================
name: file-scanner
description: |
  Mechanical file system operations only. Use for file listing, pattern matching,
  and content search. No analysis or reasoning - returns raw results. Haiku 4.5
  optimized for cost efficiency.
version: 1.0.0

# ============================================================================
# MODEL CONFIGURATION - HAIKU FOR MECHANICAL TASKS
# ============================================================================
model: haiku  # 95% cost savings vs Opus

# ============================================================================
# TOOL CONFIGURATION - MINIMAL FOR MECHANICAL OPS
# ============================================================================
allowed-tools:
  - Glob
  - Grep
  - Read

# Block reasoning-heavy tools
disallowedTools:
  - Write
  - Edit
  - WebSearch
  - Task

# ============================================================================
# PERMISSION CONFIGURATION
# ============================================================================
permissionMode: allow  # Auto-approve read operations

# ============================================================================
# NO SKILLS - MECHANICAL ONLY
# ============================================================================
skills: []

# ============================================================================
# NO HOOKS - KEEP SIMPLE
# ============================================================================
hooks: []

# ============================================================================
# VISUAL CONFIGURATION
# ============================================================================
color: cyan  # Distinct color for mechanical agents

# ============================================================================
# METADATA
# ============================================================================
last_updated: 2026-01-08
sdk_features:
  - cost_tracking
cost_optimization: true
session_aware: false
---

# File Scanner (Mechanical Agent)

## Purpose

Mechanical file system operations ONLY. No analysis, no reasoning, no code generation.
Returns raw results for parent agent to process.

## Operations

1. **List files**: `Glob` pattern matching
2. **Search content**: `Grep` content search
3. **Read files**: `Read` file contents

## Output Format

Raw results only:
- File paths
- Matched content
- Line numbers

## DO NOT

- Analyze results
- Make recommendations
- Generate code
- Modify files
- Make decisions

## Example

**Input**: "Find all TypeScript files in src/"

**Output**:
```
src/index.ts
src/utils/helpers.ts
src/components/Button.tsx
[12 files found]
```
```

---

## Template: Research Agent (Sonnet - Cost-Effective)

```yaml
---
# ============================================================================
# IDENTITY - RESEARCH AGENT
# ============================================================================
name: documentation-expert
description: |
  Use this agent when you need to create comprehensive documentation, design
  information architecture, manage diagrams, or ensure documentation quality.
  Specializes in modular documentation patterns, technical writing, Mermaid.js
  diagrams, API documentation, README templates, and documentation testing.
version: 1.0.0

# ============================================================================
# MODEL CONFIGURATION - SONNET FOR DOCUMENTATION
# ============================================================================
model: sonnet  # Cost-effective for prose and documentation

# ============================================================================
# TOOL CONFIGURATION
# ============================================================================
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - WebFetch

# No code execution needed for documentation
disallowedTools:
  - Bash

# ============================================================================
# PERMISSION CONFIGURATION
# ============================================================================
permissionMode: ask

# ============================================================================
# SKILLS INTEGRATION
# ============================================================================
skills:
  - documentation-templates
  - diagram-creation

# ============================================================================
# HOOKS CONFIGURATION
# ============================================================================
hooks:
  - type: Stop
    prompt: "Verify documentation is complete and follows style guide"
    model: haiku

# ============================================================================
# VISUAL CONFIGURATION
# ============================================================================
color: green

# ============================================================================
# METADATA
# ============================================================================
last_updated: 2026-01-08
sdk_features:
  - sessions
  - cost_tracking
cost_optimization: true
session_aware: true
---

# Documentation Expert

## Overview

Creates comprehensive technical documentation following best practices.

## Capabilities

1. **Technical Writing**: Clear, concise documentation
2. **API Documentation**: OpenAPI specs, endpoint docs
3. **Diagrams**: Mermaid.js architecture diagrams
4. **Information Architecture**: Modular documentation structure

## When to Use

- Creating README files
- Writing API documentation
- Designing documentation structure
- Creating technical guides

## Output Standards

- Markdown format
- Mermaid.js diagrams
- Consistent formatting
- Version tracking
```

---

## Frontmatter Field Reference

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Unique agent identifier |
| `description` | string | When/how to use (with examples) |
| `version` | string | Semantic version |
| `model` | enum | opus, sonnet, haiku |

### Tool Configuration

| Field | Type | Description |
|-------|------|-------------|
| `allowed-tools` | list | Tools agent can use |
| `disallowedTools` | list | Explicitly blocked tools |

### Permission Configuration (v2.0.43+)

| Field | Type | Options | Description |
|-------|------|---------|-------------|
| `permissionMode` | enum | ask, allow, deny | How permissions are handled |

### Skills Integration (v2.0.43+)

| Field | Type | Description |
|-------|------|-------------|
| `skills` | list | Skills auto-loaded when agent starts |

### Hooks Configuration (v2.1.0+)

| Field | Type | Description |
|-------|------|-------------|
| `hooks` | list | Agent-scoped lifecycle hooks |
| `hooks[].type` | enum | PreToolUse, PostToolUse, Stop |
| `hooks[].matcher` | string | Tool name for PreToolUse |
| `hooks[].command` | string | Shell script to execute |
| `hooks[].prompt` | string | For Stop hooks |
| `hooks[].model` | enum | Model for prompt-based hooks |

### Visual Configuration

| Field | Type | Options |
|-------|------|---------|
| `color` | enum | blue, cyan, green, purple, pink, red, orange, yellow, magenta, black |

### Metadata

| Field | Type | Description |
|-------|------|-------------|
| `last_updated` | date | Last modification date |
| `sdk_features` | list | Supported SDK features |
| `cost_optimization` | bool | Prefers cheaper operations |
| `session_aware` | bool | Maintains session context |

---

## Model Selection Decision Tree

```
Is this task mechanical (file ops, builds, logs)?
├─ YES → Use model: haiku
└─ NO → Does it require deep reasoning or coding?
    ├─ YES → Use model: opus
    └─ NO → Is it documentation or simple prose?
        ├─ YES → Use model: sonnet
        └─ NO → Default to model: opus (safe choice)
```

---

## Migration Checklist

When updating existing agents to v2.1.0:

- [ ] Add `model` field with appropriate selection
- [ ] Convert `tools` to YAML list `allowed-tools`
- [ ] Add `disallowedTools` if needed
- [ ] Add `permissionMode` field
- [ ] Add `skills` list for relevant skills
- [ ] Add `hooks` for workflow automation
- [ ] Update `version` to reflect changes
- [ ] Update `last_updated` date
- [ ] Add `sdk_features` list
- [ ] Add `cost_optimization` flag
- [ ] Verify `color` is set
