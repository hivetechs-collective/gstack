# Feature Blocking Configuration

This file is a template. Configure your blocked features in `.claude/project.json`.

## Configuration

Features are configured in `.claude/project.json`:

```json
{
  "features": [
    {
      "id": "F-1.1",
      "name": "Core Feature 1",
      "status": "unblocked",
      "path": "src/features/feature1/**"
    },
    {
      "id": "F-1.2",
      "name": "Core Feature 2",
      "status": "blocked",
      "path": "src/features/feature2/**"
    }
  ]
}
```

## Status Values

- `unblocked` - Feature can be implemented
- `blocked` - Feature requires approval before implementation

## Enforcement

The `block-protected-paths.sh` hook reads from project.json and:
1. Blocks writes to paths matching blocked feature patterns
2. Warns on prompts mentioning blocked features

## Implementation Guidelines

When implementing features:

1. **Check** `.claude/project.json` for feature status
2. **Verify** the feature is unblocked before starting work
3. **Follow** architectural patterns in your docs
4. **Register** any new stubs with proper format

## Updating Feature Status

To unblock a feature:

```json
// In .claude/project.json
{
  "id": "F-1.2",
  "name": "Core Feature 2",
  "status": "unblocked",  // Changed from "blocked"
  "path": "src/features/feature2/**"
}
```
