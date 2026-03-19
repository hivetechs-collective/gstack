---
description: Scaffold a new feature with governance compliance
argument-hint: <feature-name>
allowed-tools: Read, Bash, Write
---

Create a new feature scaffold with full governance compliance.

Feature name: $ARGUMENTS

## Pre-Flight Checks

1. **Check if blocked**: Read `/docs/review-status.md`
   - If feature touches blocked areas, STOP and report which review is needed

2. **Check existing code**: Read `/docs/governance/CODE_INVENTORY.md`
   - Verify no duplicate implementation exists

3. **Check compliance rules**: Read `/docs/governance/COMPLIANCE_RULES.md`
   - Identify applicable rules for this feature type

## If Safe to Proceed

Create the feature scaffold following PROJECT_STRUCTURE.md conventions:

1. Determine correct location based on feature type:
   - API endpoint → `apps/api/src/routes/`
   - Shared type → `packages/shared/src/types/`
   - Validation → `packages/validation/src/`
   - Database → `packages/db/src/schema/`

2. Create placeholder files with proper stubs:

   ```typescript
   // TODO(claude): Implement $FEATURE_NAME [DEADLINE]
   ```

3. Update CODE_INVENTORY.md with new scaffolded component

4. Add entry to STUB_REGISTRY.md

Report what was created and next steps for implementation.
