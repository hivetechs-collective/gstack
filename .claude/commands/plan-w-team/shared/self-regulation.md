# Self-Regulation Rules

These rules apply to every builder agent spawned during execution.

## WTF-Likelihood Score

Track a cumulative WTF-likelihood score, starting at 0%:

| Event                                    | Impact |
| ---------------------------------------- | ------ |
| Each revert                              | +15%   |
| Each fix touching >3 files               | +5%    |
| Touching files unrelated to current task | +20%   |
| After 15 fixes, each additional fix      | +1%    |
| If all remaining issues are Low severity | +10%   |

**Threshold**: If WTF-likelihood exceeds 20%, STOP fixing, report status, ask lead for guidance.

**Hard cap**: 50 fixes per session, then stop and report regardless.

## Regression Attribution

Each fix must include a regression test with attribution comment:

```
// Regression: TASK-abc123, 2026-03-18, rules-builder
```

## Commit Discipline

- One commit per fix or logical unit
- Every commit must compile and pass tests independently (bisectable)
- Order: infrastructure first, then models, then controllers, then tests

## Type Preservation Discipline

Builders MUST preserve the codebase's canonical type system. Creating simplified or
duplicate interfaces is the #1 cause of post-merge type conflicts.

| Rule                                                            | Rationale                                                |
| --------------------------------------------------------------- | -------------------------------------------------------- |
| Search for existing types before defining new ones              | Prevents duplicates that conflict at merge               |
| Use `Pick<T, ...>` / `Omit<T, ...>` to narrow existing types    | Maintains single source of truth                         |
| Use `extends` or `&` to add fields to existing types            | Keeps type hierarchy intact                              |
| Never redefine an interface that already exists in the codebase | Direct cause of the "6 rounds of TS fixing" anti-pattern |
| Import types from their canonical location, not from re-exports | Prevents circular dependency issues                      |

**WTF impact**: Creating a duplicate/simplified interface that conflicts with an existing canonical type adds **+15%** to WTF-likelihood (same as a revert — it causes equivalent rework).

## Browser QA Self-Regulation (when browse binary is available)

- CSS-only fixes contribute +0% to WTF-likelihood (safe, presentation-only)
- JSX/TSX fixes contribute +5% (can break functionality)
- Hard cap: 30 browser-related fixes per session (lower than code cap of 50)
- Before/after screenshots required for every browser fix
