# Claude SDK Documentation Refresh Guide

**Purpose**: Instructions for updating the local Claude SDK documentation
library **Last Updated**: 2025-10-17 **Current Documentation Version**: Latest
(as of 2025-10-17)

## Overview

This directory contains a complete offline copy of Claude SDK documentation
fetched from official Anthropic sources. The documentation is refreshed
periodically to ensure accuracy and completeness.

## Documentation Sources (35+ Total)

### Core SDK Documentation (API)

1. https://docs.anthropic.com/en/api/getting-started
2. https://docs.anthropic.com/en/api/messages
3. https://docs.anthropic.com/en/api/claude-code
4. https://docs.anthropic.com/en/api/anthropic-api
5. https://docs.anthropic.com/en/api/errors

### Claude Agent SDK (Renamed Oct 2025)

6. https://docs.claude.com/en/api/agent-sdk/overview
7. https://docs.claude.com/en/api/agent-sdk/typescript
8. https://docs.claude.com/en/api/agent-sdk/python
9. https://docs.claude.com/en/docs/claude-code/sdk/migration-guide
10. https://www.anthropic.com/engineering/building-agents-with-the-claude-agent-sdk

### TypeScript/Python SDKs

11. https://github.com/anthropics/anthropic-sdk-typescript
12. https://github.com/anthropics/anthropic-sdk-python
13. https://github.com/anthropics/claude-agent-sdk-typescript (NEW)
14. https://github.com/anthropics/claude-agent-sdk-python (NEW)
15. https://www.npmjs.com/package/@anthropic-ai/sdk
16. https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk (NEW)
17. https://pypi.org/project/anthropic/
18. https://pypi.org/project/claude-agent-sdk/ (NEW)

### Claude Code Configuration

19. https://docs.claude.com/en/docs/claude-code/settings
20. https://claudelog.com/mechanics/custom-agents/
21. https://claudelog.com/configuration/
22. https://github.com/anthropics/claude-code/issues/8501 (Agent metadata
    documentation gap)
23. https://github.com/anthropics/claude-code/issues/9319 (Colored badges bug)

### Model Context Protocol (MCP)

24. https://modelcontextprotocol.io/introduction
25. https://github.com/modelcontextprotocol/servers
26. https://docs.anthropic.com/en/docs/build-with-claude/mcp
27. https://docs.claude.com/en/api/agent-sdk/mcp

### Advanced Features

28. https://docs.anthropic.com/en/docs/build-with-claude/tool-use
29. https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching
30. https://docs.anthropic.com/en/docs/build-with-claude/streaming
31. https://docs.claude.com/en/api/agent-sdk/streaming-vs-single-mode
32. https://docs.anthropic.com/en/api/rate-limits
33. https://www.anthropic.com/news/prompt-caching

### Skills Documentation (New Oct 2025)

34. https://docs.claude.com/en/api/agent-sdk/skills
35. https://docs.claude.com/en/api/skills-guide
36. https://docs.claude.com/en/docs/claude-code/skills
37. https://support.claude.com/en/articles/12580051-teach-claude-your-way-of-working-using-skills
38. https://support.claude.com/en/articles/12512176-what-are-skills
39. https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills
40. https://github.com/anthropics/skills (Examples repository)

## Documentation Files

### Core Documentation (17 files)

- `overview.md` - Complete SDK architecture overview
- `typescript.md` - TypeScript SDK comprehensive guide
- `python.md` - Python SDK comprehensive guide
- `migration-guide.md` - Migration from custom implementations
- `cost-tracking.md` - Token usage and cost optimization
- `custom-tools.md` - Building custom agent tools
- `subagents.md` - Multi-agent orchestration patterns
- `sessions.md` - Session management and persistence
- `permissions.md` - User permission workflows
- `analytics-api.md` - Usage analytics and reporting
- `mcp-integration.md` - Model Context Protocol integration
- `code-execution.md` - Code execution capabilities
- `streaming.md` - Streaming responses
- `prompt-caching.md` - Cache strategies and optimization
- `rate-limits.md` - API rate limiting
- `error-handling.md` - Error recovery patterns
- `INDEX.md` - Complete documentation index

### Skills Documentation (7 files - New Oct 2025)

- `skills-api-guide.md` - API integration for Skills
- `skills-claude-code.md` - Using Skills in CLI
- `skills-user-guide.md` - Getting started with Skills
- `skills-what-are-skills.md` - Concepts and overview
- `skills-engineering-blog.md` - Technical deep dive
- `skills-github-examples.md` - Community examples
- `SKILLS-SUMMARY.md` - Comprehensive Skills reference

### Total Files: 26 documentation files + INDEX.md + REFRESH.md + 2025-10-30-UPDATE.md = 29 files

## Refresh Process

### When to Refresh

Refresh documentation when:

1. **Major SDK releases** - New versions of @anthropic-ai/sdk
2. **API changes** - New endpoints or parameter changes
3. **Feature announcements** - New capabilities (like Skills)
4. **Quarterly review** - At minimum every 3 months
5. **Bug reports** - If documentation appears outdated

### How to Refresh

#### 1. Use WebFetch Tool

For each URL in the list above:

```
WebFetch URL with prompt: "Extract the complete [topic] documentation, including all sections, code examples, and best practices."
```

#### 2. Save to Markdown Files

Create/update corresponding `.md` files in this directory with:

- Clean markdown formatting
- Preserved code examples
- Maintained section structure
- Updated metadata (Last Updated date)

#### 3. Update INDEX.md

After refreshing files, update `INDEX.md` with:

- New sections added
- Changed file names
- Updated statistics (total files, lines, etc.)
- New categories if applicable

#### 4. Update REFRESH.md

Update this file with:

- New documentation sources (if any)
- Refresh date in version history
- Any breaking changes noted
- New features documented

#### 5. Sync Across Repositories

Copy updated documentation to all agent repositories:

```bash
# Copy to claude-pattern
cp -r /path/to/hive/.claude/agents/research-planning/claude-sdk-expert/docs/* \
      /path/to/claude-pattern/.claude/agents/research-planning/claude-sdk-expert/docs/

# Copy to hivetechs-website
cp -r /path/to/hive/.claude/agents/research-planning/claude-sdk-expert/docs/* \
      /path/to/hivetechs-website/.claude/agents/research-planning/claude-sdk-expert/docs/
```

### Automation Script (Optional)

Create `refresh-docs.sh`:

```bash
#!/bin/bash

# Refresh Claude SDK Documentation
# Usage: ./refresh-docs.sh

DOCS_DIR="$(dirname "$0")"
URLS_FILE="$DOCS_DIR/urls.txt"

echo "Starting documentation refresh..."

# Read URLs and fetch each one
while IFS= read -r url; do
    # Extract filename from URL or pattern
    filename=$(echo "$url" | sed 's|.*/||' | sed 's|$|.md|')

    echo "Fetching: $url -> $filename"

    # Use WebFetch to get content
    # (This would need to be adapted to your actual tooling)

done < "$URLS_FILE"

echo "Updating INDEX.md..."
# Auto-generate INDEX.md based on files

echo "Documentation refresh complete!"
echo "Total files: $(ls -1 *.md | wc -l)"
```

## Version History

| Date       | SDK Version     | API Version | Changes                                                                       |
| ---------- | --------------- | ----------- | ----------------------------------------------------------------------------- |
| 2025-10-08 | Latest          | Latest      | Initial comprehensive documentation library created                           |
| 2025-10-17 | Latest          | Latest      | Full refresh + Skills documentation added (Oct 2025 announcement)             |
| 2025-10-30 | Latest (2.0.29) | Latest      | Agent metadata format documentation, color field resolution, URL verification |

## Quality Checks

After refreshing, verify:

1. **Completeness**: All 23 source URLs represented
2. **Code Examples**: All code blocks formatted correctly
3. **Links**: Internal cross-references work
4. **Consistency**: Naming conventions match across files
5. **Metadata**: "Last Updated" dates current
6. **File Count**: Expected number of files present

**Checklist**:

- [ ] All 23 sources fetched
- [ ] 24 documentation files created/updated
- [ ] INDEX.md updated with new content
- [ ] REFRESH.md version history updated
- [ ] Cross-references validated
- [ ] Code examples tested (spot check)
- [ ] Copied to all 3 repositories
- [ ] Git commit with clear message

## Breaking Changes Log

### 2025-10-17 - Skills Addition

- **Added**: 7 new Skills documentation files
- **Impact**: New capability, no breaking changes to existing SDK
- **Migration**: None required, Skills are additive feature

### Future Breaking Changes

Document any breaking changes here as they occur:

```
### YYYY-MM-DD - Change Title
- **Changed**: What changed
- **Impact**: Who/what affected
- **Migration**: How to adapt
```

## Documentation Gaps

### Known Gaps (to be filled in future updates)

1. **Advanced Adapter Patterns** - Need more runtime-specific examples
2. **Cost Optimization Case Studies** - Real-world savings analysis
3. **Enterprise Deployment Patterns** - Large-scale architecture examples
4. **Performance Benchmarks** - Quantitative performance data
5. **Security Best Practices** - Comprehensive security guide

### Requested Topics

Track requests for additional documentation here:

- [ ] Bun adapter implementation guide
- [ ] AWS Lambda adapter patterns
- [ ] Vercel Edge Functions integration
- [ ] WebSocket streaming patterns
- [ ] Multi-tenant agent architectures

## Maintenance Notes

### Fetch Techniques

**For GitHub README files**:

```
WebFetch: https://github.com/org/repo
Prompt: "Extract the complete README.md content with all sections and examples"
```

**For Anthropic docs**:

```
WebFetch: https://docs.anthropic.com/en/path
Prompt: "Extract the complete [topic] guide including all subsections, code examples, and best practices"
```

**For npm/PyPI**:

```
WebFetch: https://npmjs.com/package/name
Prompt: "Extract package documentation, installation instructions, and API reference"
```

### Content Organization

**File naming convention**:

- Use kebab-case: `prompt-caching.md`
- Descriptive names: `migration-guide.md` not `guide.md`
- Category prefixes for related docs: `skills-*.md`

**Frontmatter template**:

```markdown
# Document Title

**Last Updated**: YYYY-MM-DD **Source**: https://original-url.com **Category**:
Category / Subcategory
```

**Section structure**:

1. Overview/Introduction
2. Key Concepts
3. Implementation Examples
4. Best Practices
5. Troubleshooting
6. Related Documentation
7. See Also

## Contact and Contribution

**Maintained by**: HiveTechs Engineering **Agent**: claude-sdk-expert (v1.1.0)
**Repository**: `.claude/agents/research-planning/claude-sdk-expert/`

**To request documentation updates**:

1. Note the outdated/missing content
2. Provide source URL if available
3. Suggest priority (critical/important/nice-to-have)
4. Tag @claude-sdk-expert agent

## Related Files

- `INDEX.md` - Complete documentation index with search reference
- `SKILLS-SUMMARY.md` - Comprehensive Skills overview
- `overview.md` - SDK architecture and patterns
- All other `.md` files in this directory

---

**Last Refresh**: 2025-10-17 **Next Scheduled Refresh**: 2026-01-17 (quarterly)
**Documentation Status**: ✅ Current and Complete
