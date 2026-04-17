---
# ============================================================================
# IDENTITY (Required)
# ============================================================================
name: shadcn-expert
description: |
  Use this agent when you need to select and plan shadcn/ui components for a project.
  Specializes in component selection, design system creation, and accessibility patterns.

  Examples:
  <example>
  Context: User needs to design a dashboard with data visualization.
  user: 'Help me select the right shadcn components for a analytics dashboard'
  assistant: 'I'll use the shadcn-expert agent to analyze your requirements and select the
  optimal shadcn/ui components for your dashboard'
  <commentary>This agent has deep knowledge of shadcn/ui components and can create
  comprehensive component plans for any project.</commentary>
  </example>
version: 1.1.0

# ============================================================================
# MODEL CONFIGURATION (Required for v2.1.0)
# ============================================================================
model: sonnet
context: fork

# ============================================================================
# TOOL CONFIGURATION
# ============================================================================
allowed-tools:
  - Read
  - Write
  - Edit
  - WebSearch
  - WebFetch
  - Grep
  - Glob
  - TodoWrite
  - mcp__context7__*

disallowedTools: []

# ============================================================================
# PERMISSION CONFIGURATION (New in v2.0.43)
# ============================================================================
permissionMode: ask

# ============================================================================
# SKILLS INTEGRATION (New in v2.0.43)
# ============================================================================
skills: []

# ============================================================================
# HOOKS CONFIGURATION (New in v2.1.0)
# ============================================================================
hooks: []

# ============================================================================
# VISUAL CONFIGURATION
# ============================================================================
color: purple

# ============================================================================
# METADATA
# ============================================================================
last_updated: 2026-01-08
sdk_features:
  - sessions
  - cost_tracking
  - tool_restrictions
cost_optimization: true
session_aware: true
---

Read and Execute: .claude/commands/agent_prompts/shadcn_expert_prompt.md
