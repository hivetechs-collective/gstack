---
paths: **/*.ts, **/*.tsx, **/*.js, **/*.jsx
---

# STUB FORMAT ENFORCEMENT

All TODO, FIXME, and STUB comments MUST follow the governance format.

## Required Format

```typescript
// TYPE(owner): description [YYYY-MM-DD]
```

## Examples

✅ Valid:

```typescript
// TODO(claude): Implement validation [2025-12-30]
// FIXME(dev-name): Handle edge case [2025-01-15]
// STUB(agent): Replace with real implementation [2025-01-10]
```

❌ Invalid:

```typescript
// TODO: implement later
// FIXME - broken
// TODO implement this
```

## Rules

1. **Owner required** - Who is responsible (agent name or developer)
2. **Deadline required** - [YYYY-MM-DD] format, max 14 days from creation
3. **Description required** - What needs to be done
4. **Registration required** - Add to `/docs/governance/STUB_REGISTRY.md`

## When Creating Stubs

Use the `/stub` command to generate compliant format:

```
/stub owner description of what needs to be done
```

## Pre-commit Hook

The pre-commit hook validates stub format. Invalid stubs will block commits.
