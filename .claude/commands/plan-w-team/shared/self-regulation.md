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

## Browser QA Self-Regulation (when browse binary is available)

- CSS-only fixes contribute +0% to WTF-likelihood (safe, presentation-only)
- JSX/TSX fixes contribute +5% (can break functionality)
- Hard cap: 30 browser-related fixes per session (lower than code cap of 50)
- Before/after screenshots required for every browser fix
