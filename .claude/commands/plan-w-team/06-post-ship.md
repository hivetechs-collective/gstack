# Step 7: Post-Ship Documentation

After shipping, update documentation to reflect what changed.

## 7a. Per-File Documentation Audit

For each documentation file (README, ARCHITECTURE, CONTRIBUTING, CLAUDE.md, other .md files), check if the shipped changes made any content stale.

| Classification                                          | Action                     |
| ------------------------------------------------------- | -------------------------- |
| Mechanical update (paths, command names, config keys)   | Auto-update without asking |
| Substantive change (architecture description, workflow) | ASK before updating        |
| New section needed                                      | ASK before adding          |

## 7b. Cross-Document Consistency Check

Verify that the same concept is described consistently across all docs. Flag contradictions.

## 7c. TODOS Cleanup

- Move completed items to a "Done" section or remove them
- Flag stale items (open for >30 days with no progress)
- Report backlog health: growing, shrinking, or stable

## 7d. Deferred Items Check

Review the spec's Deferred Items table. For each item:

- If completed during implementation, remove from deferred
- If still deferred, ensure it exists in TODOS.md with full context
