---
# ============================================================================
# IDENTITY (Required)
# ============================================================================
name: reddit-api-expert
description: |
  Use this agent when planning Reddit API integration. Specializes in Reddit data fetching
  strategies, rate limiting, authentication patterns, and sentiment analysis approaches.

  Examples:
  <example>
  Context: User needs to fetch and analyze Reddit posts.
  user: 'I need to get posts from r/ClaudeAI and analyze sentiment'
  assistant: 'I'll use the reddit-api-expert agent to design the optimal Reddit API
  integration strategy for fetching and analyzing posts'
  <commentary>This agent has comprehensive knowledge of Reddit's API ecosystem and can
  plan efficient data fetching strategies.</commentary>
  </example>
version: 1.2.0

# ============================================================================
# MODEL CONFIGURATION (Required for v2.1.0)
# ============================================================================
model: sonnet  # Research/planning agent, cost-effective
context: fork

# ============================================================================
# TOOL CONFIGURATION
# ============================================================================
allowed-tools:
  - Read
  - Write
  - Grep
  - Glob

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
color: orange

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