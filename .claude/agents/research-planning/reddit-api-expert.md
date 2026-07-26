---
# ============================================================================
# IDENTITY (Required)
# ============================================================================
name: reddit-api-expert
color: orange
description: |
  Use this agent when planning Reddit API integration. Specializes in Reddit data fetching
  strategies, rate limiting, authentication patterns, and sentiment analysis approaches.
version: 1.2.0

# ============================================================================
# MODEL CONFIGURATION (Required for v2.1.0)
# ============================================================================
model: sonnet  # Research/planning agent, cost-effective
context: fork

# ============================================================================
# TOOL CONFIGURATION
# ============================================================================
# `allowed-tools:` REMOVED 2026-07-26 — it is a SKILL frontmatter key and is
# INERT in an agent file (canonical agent allowlist is `tools:`; omitting it
# inherits all). Any restriction it expressed now lives in `disallowedTools:`,
# which the harness actually honours. See CHANGELOG [1.63.0].
disallowedTools:
  - Edit
  - NotebookEdit

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

# ============================================================================
# METADATA
# ============================================================================
last_updated: 2026-01-08
sdk_features:
  - subagents
  - sessions
  - cost_tracking
  - tool_restrictions
cost_optimization: true
session_aware: true
---

Read and Execute: .claude/commands/agent_prompts/reddit_api_expert_prompt.md
