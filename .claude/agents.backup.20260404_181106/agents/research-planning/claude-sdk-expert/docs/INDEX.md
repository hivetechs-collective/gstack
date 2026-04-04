# Claude Agent SDK Documentation Index

**Last Updated**: 2025-12-22 **Total Files**: 30 documentation files (18 core +
7 Skills + 2 agent config + 3 updates) **Total Content**: ~6,500 lines of
comprehensive technical documentation **Documentation Size**: ~330KB

## Quick Start

**New to the SDK?** Start here:

1. [Overview](./overview.md) - Introduction and core capabilities
2. [Migration Guide](./migration-guide.md) - Upgrade from Claude Code SDK
3. [TypeScript SDK](./typescript.md) or [Python SDK](./python.md) -
   Language-specific guides

## Complete Documentation Library

### Skills Documentation (New Oct 2025)

| Document                                           | Description                       | Key Topics                                          |
| -------------------------------------------------- | --------------------------------- | --------------------------------------------------- |
| [Skills Summary](./SKILLS-SUMMARY.md)              | **Comprehensive Skills overview** | Progressive disclosure, use cases, best practices   |
| [Skills API Guide](./skills-api-guide.md)          | API integration for Skills        | Container parameter, file management, custom Skills |
| [Skills in Claude Code](./skills-claude-code.md)   | CLI usage patterns                | Storage locations, tool restrictions, examples      |
| [Skills User Guide](./skills-user-guide.md)        | Getting started tutorial          | Creating Skills, when to use, workflows             |
| [Skills Concepts](./skills-what-are-skills.md)     | Detailed concepts                 | Progressive disclosure, platform availability       |
| [Skills Engineering](./skills-engineering-blog.md) | Technical architecture            | Design principles, performance optimization         |
| [Skills Examples](./skills-github-examples.md)     | Community examples                | GitHub repository, contribution guide               |

### Core SDK Documentation

| Document                                | Description                         | Key Topics                                   |
| --------------------------------------- | ----------------------------------- | -------------------------------------------- |
| [Overview](./overview.md)               | SDK introduction and capabilities   | Installation, authentication, agent types    |
| [Migration Guide](./migration-guide.md) | Upgrade from Claude Code SDK        | Package changes, breaking changes, checklist |
| [TypeScript SDK](./typescript.md)       | TypeScript/JavaScript API reference | query(), tool(), createSdkMcpServer()        |
| [Python SDK](./python.md)               | Python API reference                | query(), ClaudeSDKClient, decorators         |

### Agent Configuration Documentation (Updated Nov 2025)

| Document                                            | Description                                | Key Topics                                                                  |
| --------------------------------------------------- | ------------------------------------------ | --------------------------------------------------------------------------- |
| [Agent Metadata Format](./agent-metadata-format.md) | Complete agent configuration reference     | Frontmatter fields, color vs x-color, best practices                        |
| [**2025-11-25 Update**](./2025-11-25-UPDATE.md)     | **LATEST**: November 2025 critical updates | **Sonnet 4.5 default, Haiku 4.5, model deprecations, SDK breaking changes** |
| [2025-10-30 Update](./2025-10-30-UPDATE.md)         | October refresh findings                   | Breaking changes, URL verification, known issues                            |

### Feature Documentation

| Document                                                  | Description                        | Key Topics                                     |
| --------------------------------------------------------- | ---------------------------------- | ---------------------------------------------- |
| [**Hooks**](./hooks.md)                                   | **Hook system reference (NEW)**    | Event types, matchers, configuration, examples |
| [Streaming vs Single Mode](./streaming-vs-single-mode.md) | Input mode comparison              | Streaming features, use cases, limitations     |
| [Permissions](./permissions.md)                           | Permission control mechanisms      | Permission modes, canUseTool, hooks            |
| [Sessions](./sessions.md)                                 | Session management                 | Session creation, resumption, forking          |
| [Modifying System Prompts](./modifying-system-prompts.md) | System prompt customization        | CLAUDE.md, output styles, presets              |
| [MCP](./mcp.md)                                           | Model Context Protocol integration | MCP configuration, transport types             |
| [Custom Tools](./custom-tools.md)                         | Building custom tools              | Tool structure, examples, error handling       |
| [Subagents](./subagents.md)                               | Specialized agent orchestration    | Benefits, definition methods, patterns         |
| [Slash Commands](./slash-commands.md)                     | Command system                     | Built-in commands, custom commands             |
| [Cost Tracking](./cost-tracking.md)                       | Usage and billing tracking         | Token tracking, deduplication, best practices  |
| [Todo Tracking](./todo-tracking.md)                       | Task management                    | Todo lifecycle, implementation patterns        |

### API Documentation

| Document                                        | Description             | Key Topics                              |
| ----------------------------------------------- | ----------------------- | --------------------------------------- |
| [Messages Examples](./messages-examples.md)     | Messages API patterns   | Request/response, conversations, vision |
| [Batch Examples](./messages-batch-examples.md)  | Batch processing        | Creating batches, polling, results      |
| [Analytics API](./claude-code-analytics-api.md) | Analytics API reference | Metrics, endpoints, admin keys          |

## Documentation by Use Case

### Getting Started with Skills (New!)

1. [Skills Summary](./SKILLS-SUMMARY.md) - Understand Skills architecture
2. [Skills User Guide](./skills-user-guide.md) - Create your first Skill
3. [Skills Examples](./skills-github-examples.md) - Learn from examples
4. [Skills in Claude Code](./skills-claude-code.md) - Use Skills in CLI

### Building Your First Agent

1. [Overview](./overview.md) - Understand core concepts
2. [TypeScript SDK](./typescript.md) or [Python SDK](./python.md) - Choose your
   language
3. [Permissions](./permissions.md) - Configure tool access
4. [Sessions](./sessions.md) - Manage conversation state

### Adding Custom Capabilities

1. [Custom Tools](./custom-tools.md) - Build custom tools
2. [MCP](./mcp.md) - Integrate MCP servers
3. [Subagents](./subagents.md) - Create specialized subagents
4. [Slash Commands](./slash-commands.md) - Add custom commands

### Production Deployment

1. [Cost Tracking](./cost-tracking.md) - Monitor usage and costs
2. [Permissions](./permissions.md) - Implement security controls
3. [Streaming vs Single Mode](./streaming-vs-single-mode.md) - Choose
   appropriate mode
4. [Analytics API](./claude-code-analytics-api.md) - Track productivity metrics

### Migration from Claude Code SDK

1. [Migration Guide](./migration-guide.md) - Step-by-step migration
2. [Modifying System Prompts](./modifying-system-prompts.md) - Restore Claude
   Code behavior
3. [Overview](./overview.md) - Understand new features

## Quick Reference

### Common Tasks

| Task                  | Documentation                                                                                  |
| --------------------- | ---------------------------------------------------------------------------------------------- |
| Install SDK           | [Overview](./overview.md#installation)                                                         |
| Create basic query    | [TypeScript](./typescript.md#example-basic-query) \| [Python](./python.md#basic-usage-example) |
| Build custom tool     | [Custom Tools](./custom-tools.md#example-database-query-tool)                                  |
| Configure permissions | [Permissions](./permissions.md#permission-modes)                                               |
| Configure hooks       | [Hooks](./hooks.md#configuration-structure)                                                    |
| Resume conversation   | [Sessions](./sessions.md#session-resumption)                                                   |
| Track costs           | [Cost Tracking](./cost-tracking.md#implementation-example)                                     |
| Create subagent       | [Subagents](./subagents.md#programmatic-approach-recommended)                                  |

### SDK Features Matrix

| Feature            | TypeScript | Python | Documentation                                             |
| ------------------ | ---------- | ------ | --------------------------------------------------------- |
| Query Function     | ✅         | ✅     | [TypeScript](./typescript.md) \| [Python](./python.md)    |
| Custom Tools       | ✅         | ✅     | [Custom Tools](./custom-tools.md)                         |
| MCP Integration    | ✅         | ✅     | [MCP](./mcp.md)                                           |
| Subagents          | ✅         | ✅     | [Subagents](./subagents.md)                               |
| Session Management | ✅         | ✅     | [Sessions](./sessions.md)                                 |
| Streaming Input    | ✅         | ✅     | [Streaming vs Single Mode](./streaming-vs-single-mode.md) |
| Permission Control | ✅         | ✅     | [Permissions](./permissions.md)                           |
| Hooks              | ✅         | ✅     | [Hooks](./hooks.md)                                       |
| Cost Tracking      | ✅         | ✅     | [Cost Tracking](./cost-tracking.md)                       |
| Slash Commands     | ✅         | ✅     | [Slash Commands](./slash-commands.md)                     |

## Search by Keyword

**Authentication**: [Overview](./overview.md#authentication-methods) **Batch
Processing**: [Batch Examples](./messages-batch-examples.md) **Caching**:
[Cost Tracking](./cost-tracking.md#edge-cases) **Claude Code**:
[Migration Guide](./migration-guide.md),
[Overview](./overview.md#claude-code-feature-support),
[Skills in Claude Code](./skills-claude-code.md) **Context Management**:
[Overview](./overview.md#context-management),
[Skills Summary](./SKILLS-SUMMARY.md#how-skills-work) **Conversation History**:
[Sessions](./sessions.md), [Messages Examples](./messages-examples.md) **Error
Handling**: [Custom Tools](./custom-tools.md#error-handling) **Filesystem
Settings**:
[Modifying System Prompts](./modifying-system-prompts.md#1-claudemd-files-project-level-instructions)
**Forking Sessions**: [Sessions](./sessions.md#session-forking) **Hooks**:
[Hooks](./hooks.md) - **Complete hooks reference!** **Image Processing**:
[Messages Examples](./messages-examples.md#vision-capabilities) **MCP Servers**:
[MCP](./mcp.md), [Custom Tools](./custom-tools.md) **Parallel Execution**:
[Subagents](./subagents.md#key-benefits) **Permission Modes**:
[Permissions](./permissions.md#permission-modes) **Progressive Disclosure**:
[Skills Summary](./SKILLS-SUMMARY.md),
[Skills Engineering](./skills-engineering-blog.md) **Response Prefilling**:
[Messages Examples](./messages-examples.md#response-prefilling) **Security**:
[Permissions](./permissions.md),
[Skills Summary](./SKILLS-SUMMARY.md#security-considerations) **Skills**:
[Skills Summary](./SKILLS-SUMMARY.md) - **Start here!** **System Prompts**:
[Modifying System Prompts](./modifying-system-prompts.md) **Token Usage**:
[Cost Tracking](./cost-tracking.md),
[Skills Engineering](./skills-engineering-blog.md#performance-and-cost-optimization)
**Tool Creation**: [Custom Tools](./custom-tools.md),
[Skills API Guide](./skills-api-guide.md) **Tool Restrictions**:
[Subagents](./subagents.md#key-benefits),
[Skills in Claude Code](./skills-claude-code.md#tool-access-restrictions) **Zod
Schemas**: [TypeScript SDK](./typescript.md#tool),
[Custom Tools](./custom-tools.md)

## Version Information

**SDK Versions**:

- TypeScript: `@anthropic-ai/agent-sdk` (RENAMED from claude-agent-sdk)
- Python: `claude-agent-sdk`

**BEST MODEL FOR CODING**: Claude Opus 4.5 (`claude-opus-4-5`) - **80.9%
SWE-bench, WORLD'S BEST** **Default CLI Model**: Claude Sonnet 4.5
(`claude-sonnet-4-5`) **Mechanical Tasks Only**: Claude Haiku 4.5
(`claude-haiku-4-5`)

**Documentation Version**: 2025-12-22 (Updated with Hooks documentation)
**Previous Refresh**: 2025-11-25 (Opus 4.5 release)

**December 2025 Update**:

- 📚 **NEW**: Comprehensive Hooks documentation added
- 🔧 **FIX**: Matcher format clarified (string, not object)
- 📖 10 hook event types fully documented
- ⚙️ Complete configuration examples

**November 2025 Major Updates**:

- 🚀 **Claude Opus 4.5 RELEASED** (Nov 24) - Best coding model in the world!
- 🏆 **80.9% SWE-bench** - Beats GPT-5.1, Gemini 3, and all competitors
- 💰 **67% cheaper** than Opus 4.1 ($5/$25 vs $15/$75 per 1M tokens)
- ⚠️ **BREAKING**: SDK system prompt no longer included by default
- ⚠️ **DEPRECATED**: Claude 3 Sonnet, Claude 2.x models
- 🆕 Checkpoints & rewind for safe refactoring
- 🆕 VS Code extension (beta)
- 🆕 Claude Code in desktop app
- 40+ verified documentation sources

**MODEL HIERARCHY (ENFORCED)**: | Task | Model | |------|-------| | **All
Coding** | Opus 4.5 | | **Problem Solving** | Opus 4.5 | | **Critical Thinking**
| Opus 4.5 | | Documentation | Sonnet 4.5 | | Mechanical/Deployment | Haiku 4.5
|

## Related Resources

- **Anthropic Documentation**: https://docs.claude.com/
- **Claude Console**: https://console.anthropic.com/
- **GitHub Issues**: Report bugs and feature requests
- **Migration from Claude Code SDK**: See
  [Migration Guide](./migration-guide.md)

## Maintenance

This documentation is regularly refreshed from official Anthropic sources. For
refresh instructions, see [REFRESH.md](./REFRESH.md).

**Latest Update (2025-11-25)** - OPUS 4.5 RELEASE:

- 🚀 **Claude Opus 4.5 RELEASED** (Nov 24, 2025) - USE FOR ALL CODING
- 🏆 **80.9% SWE-bench** - World's best coding model
- 💰 **$5/$25 per 1M tokens** - 67% cheaper than Opus 4.1
- ⚠️ **SDK system prompt breaking change** - must be explicit now
- ⚠️ **Model deprecations** - Claude 3 Sonnet, Claude 2.x no longer work
- 🆕 Claude Code now in desktop app
- 🆕 Checkpoints/rewind, VS Code extension
- Total documentation: 40+ official sources + 29 markdown files

**MODEL SELECTION RULE**: Opus 4.5 for coding, Sonnet for docs, Haiku for
mechanical only

**Previous Update (2025-10-30)**:

- Added agent-metadata-format.md (comprehensive agent config reference)
- Resolved color vs x-color field question (use `color`)
- Documented Claude Code v2.0.11-2.0.29 changes
