# Custom Agent Sets

This directory is for **your personal agent set definitions**.

## Creating Custom Sets

```json
{
  "name": "my-workflow",
  "description": "Brief description of when to use this set",
  "agents": [
    "agent-name-1",
    "agent-name-2",
    "agent-name-3"
  ],
  "estimatedTokens": 3000,
  "categories": {
    "coordination": [],
    "implementation": [],
    "research-planning": []
  },
  "notes": "Additional context about this set"
}
```

## Example: Custom Rust + Cloudflare Workers Set

**File**: `custom/rust-cloudflare.json`

```json
{
  "name": "rust-cloudflare",
  "description": "Rust backend with Cloudflare Workers deployment",
  "agents": [
    "rust-backend-specialist",
    "cloudflare-expert",
    "database-expert",
    "security-expert",
    "performance-testing-specialist",
    "git-expert"
  ],
  "estimatedTokens": 4000,
  "notes": "For Rust APIs deployed to Cloudflare Workers with D1 database"
}
```

## Tips

1. **Keep sets focused**: 5-10 agents per set
2. **Name clearly**: Use descriptive names (not "set1", "set2")
3. **Estimate tokens**: ~700 tokens per agent average
4. **Document usage**: Add notes about when to use
5. **Review regularly**: Update based on actual usage patterns

## Sharing Sets

If you create a useful set, consider adding it to the parent `agent-sets/` directory so it's available across all projects.
