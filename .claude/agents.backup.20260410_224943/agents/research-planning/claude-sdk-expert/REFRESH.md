# Documentation Refresh Guide

This guide explains how to update the local Claude Agent SDK documentation
library with the latest content from Anthropic's official documentation.

## When to Refresh

Refresh documentation when:

- New SDK versions are released (check
  [npm](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk) or
  [PyPI](https://pypi.org/project/claude-agent-sdk/))
- Major feature announcements from Anthropic
- Quarterly maintenance (recommended: every 3 months)
- After encountering outdated information

## Documentation Sources

All documentation is fetched from official Anthropic documentation URLs:

### Core SDK Documentation

1. https://docs.claude.com/en/docs/claude-code/sdk/migration-guide
2. https://docs.claude.com/en/api/agent-sdk/overview
3. https://docs.claude.com/en/api/agent-sdk/typescript
4. https://docs.claude.com/en/api/agent-sdk/python

### Feature Documentation

5. https://docs.claude.com/en/api/agent-sdk/streaming-vs-single-mode
6. https://docs.claude.com/en/api/agent-sdk/permissions
7. https://docs.claude.com/en/api/agent-sdk/sessions
8. https://docs.claude.com/en/api/agent-sdk/modifying-system-prompts
9. https://docs.claude.com/en/api/agent-sdk/mcp
10. https://docs.claude.com/en/api/agent-sdk/custom-tools
11. https://docs.claude.com/en/api/agent-sdk/subagents
12. https://docs.claude.com/en/api/agent-sdk/slash-commands
13. https://docs.claude.com/en/api/agent-sdk/cost-tracking
14. https://docs.claude.com/en/api/agent-sdk/todo-tracking

### API Documentation

15. https://docs.claude.com/en/api/messages-examples
16. https://docs.claude.com/en/api/messages-batch-examples
17. https://docs.claude.com/en/api/claude-code-analytics-api

## Automated Refresh Process

### Using Claude Code

Ask Claude Code to refresh the documentation:

```
Refresh the Claude Agent SDK documentation in .claude/agents/research-planning/claude-sdk-expert/docs/

Fetch all 17 documentation URLs and update the markdown files. After updating, regenerate the INDEX.md with new timestamps and any content changes.
```

Claude Code will:

1. Fetch all URLs using WebFetch tool
2. Save updated content to markdown files
3. Regenerate INDEX.md with new metadata
4. Report any structural changes or new sections

### Manual Refresh Process

If you need to manually update documentation:

1. **Fetch Documentation**

   ```bash
   cd /Users/veronelazio/Developer/Private/claude-pattern/.claude/agents/research-planning/claude-sdk-expert/docs/
   ```

2. **Use WebFetch or curl** to download each URL:

   ```bash
   # Example with curl
   curl https://docs.claude.com/en/api/agent-sdk/overview > overview-temp.md
   ```

3. **Extract Content**: Remove navigation, headers, footers (keep only main
   content)

4. **Update Markdown Files**: Replace existing files with new content

5. **Update INDEX.md**:
   - Update "Last Updated" timestamp
   - Add new sections if documentation structure changed
   - Update documentation statistics

6. **Verify Links**: Check all internal links in INDEX.md still work

## Refresh Verification Checklist

After refreshing documentation, verify:

- [ ] All 17 markdown files updated successfully
- [ ] No broken internal links in INDEX.md
- [ ] Code examples still use correct SDK versions
- [ ] No deprecated features referenced
- [ ] New features documented (if any)
- [ ] INDEX.md timestamp updated
- [ ] Agent definition updated if major changes occurred

## Change Detection

Compare old vs new documentation to identify:

### Breaking Changes

- Deprecated functions/methods
- Changed API signatures
- Removed features
- New required parameters

### New Features

- New SDK functions
- Additional configuration options
- New tool types
- Enhanced capabilities

### Documentation Improvements

- Better examples
- Clarified explanations
- Additional use cases
- Performance tips

## Updating the Agent Definition

If documentation refresh reveals major changes, update the agent definition at:
`.claude/agents/research-planning/claude-sdk-expert.md`

Update sections:

- **Core Expertise**: Add new feature areas
- **SDK Architecture Patterns**: Update with new patterns
- **Integration Patterns**: Add new runtime examples
- **Output Standards**: Update with new best practices

## Version Tracking

Track SDK versions in this file:

| Date       | TypeScript SDK Version | Python SDK Version | Notes                                                                    |
| ---------- | ---------------------- | ------------------ | ------------------------------------------------------------------------ |
| 2025-10-08 | 0.1.0                  | 0.1.0              | Initial documentation fetch                                              |
| 2025-10-17 | Latest                 | Latest             | Full refresh for electron-debug-expert agent creation + 2025 SDK updates |

Update this table with each refresh:

```
| YYYY-MM-DD | x.y.z | x.y.z | Brief description of changes |
```

## Common Issues and Solutions

### Issue: WebFetch returns incomplete content

**Solution**: Manually fetch with curl and extract content

### Issue: Documentation structure changed

**Solution**: Update INDEX.md navigation structure to match

### Issue: New documentation pages added

**Solution**: Add new URLs to source list, fetch content, update INDEX.md

### Issue: Deprecated features still referenced

**Solution**: Add deprecation notices, update examples to new APIs

## Quality Standards

Refreshed documentation must maintain:

1. **Completeness**: All sections preserved from source
2. **Code Quality**: Examples must be runnable and tested
3. **Formatting**: Consistent markdown formatting
4. **Links**: All internal links functional
5. **Accuracy**: Content matches official documentation exactly

## Automation Ideas

Consider automating refresh with:

### GitHub Actions Workflow

```yaml
name: Refresh SDK Docs
on:
  schedule:
    - cron: '0 0 1 * *' # Monthly on 1st
  workflow_dispatch:

jobs:
  refresh:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Refresh documentation
        run: |
          # Use Claude Code or custom script to fetch docs
          # Commit changes if detected
```

### Shell Script

```bash
#!/bin/bash
# refresh-sdk-docs.sh

DOCS_DIR=".claude/agents/research-planning/claude-sdk-expert/docs"
URLS=(
  "https://docs.claude.com/en/api/agent-sdk/overview"
  "https://docs.claude.com/en/api/agent-sdk/typescript"
  # ... add all URLs
)

for url in "${URLS[@]}"; do
  filename=$(basename "$url").md
  curl -s "$url" | extract-content > "$DOCS_DIR/$filename"
done

# Update INDEX.md timestamp
sed -i "s/Last Updated: .*/Last Updated: $(date +%Y-%m-%d)/" "$DOCS_DIR/INDEX.md"
```

## Next Refresh Due

**Recommended Next Refresh**: 2026-01-08 (3 months from initial fetch)

Set a reminder to check for updates quarterly or when new SDK versions are
released.

## Contact for Updates

If you notice outdated documentation:

1. Check Anthropic's official docs for changes
2. Follow refresh process above
3. Update this REFRESH.md with findings
4. Consider opening an issue/PR if part of a shared repository
