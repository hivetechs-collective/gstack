---
description: Create a properly formatted stub/TODO comment
argument-hint: <owner> <description>
allowed-tools: Read
---

Generate a governance-compliant stub comment.

Arguments: $ARGUMENTS

Parse the arguments to extract:

- Owner (first word, e.g., "claude" or developer name)
- Description (remaining text)

Calculate deadline: 14 days from today (maximum allowed per CLAUDE.md rules).

Output the properly formatted stub:

```typescript
// TODO($OWNER): $DESCRIPTION [$DEADLINE]
```

Example output:

```typescript
// TODO(claude): Implement input validation [2025-12-30]
```

Remind user:

1. Add this stub to the code where implementation is needed
2. Register in `/docs/governance/STUB_REGISTRY.md`
3. Deadline is 14 days max - extend only with justification
