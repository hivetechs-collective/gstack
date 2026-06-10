# Self-Regulation Rules

These rules apply to every builder agent spawned during execution.

> The **builder** rules begin at WTF-Likelihood below. The **supervisor**
> self-regulation rules (anti-park, issue-handling≠stop, single-item-blocker
> partitioning, honesty-floor-without-paralysis) are in the section immediately
> below — they govern the dispatch loop, not the builders.

## Supervisor Self-Regulation (anti-park) — PWT-ANTIPARK

These four rules govern the supervisor / origin-chat dispatch loop. They exist
because of the 2026-06-07 cleanscale incident: a supervisor correctly caught a
worker's fabricated "prod-verified GREEN", reverted it (honesty floor held), then
**parked** in "recalibration" and stopped with 5 of 6 epics unbuilt — one blocked
deploy gate halted the entire run including large safe unblocked work. Root cause:
`docs/operations/supervisor-no-park-rootcause-2026-06-07.md`.

The first three are now **enforced** at the goal-evaluator's Stop/yield decision
(not merely advised): the evaluator reads the run's slug-keyed objective progress
snapshot `.claude/state/supervisor-progress-<slug>.json` (written by
`supervisor-progress-check.sh --slug "$SLUG"`) — guarded against foreign-slug and
stale snapshots, fail-open, per `shared/goal-conditions.md` §Anti-Park Gate —
and refuses a supervisor yield that would be a silent park. Kill switch for the
enforced gate: `PLAN_W_TEAM_DISABLE_ANTIPARK=1` (fail-open to pre-fix behavior).

1. **Backlog-aware non-stop invariant.** Do NOT stop (yield/park) while the run's
   own backlog has unblocked, unattempted, or failed-but-retriable work. SUCCESS
   requires the backlog drained OR every remaining item provably blocked by a
   genuine hard-gate. An **empty/missing feature-AC contract is not-done, not
   done** — a stray `retro-complete` with no ACs and a non-zero objective backlog
   does NOT satisfy SUCCESS (enforced: goal-evaluator empty-AC branch). This is
   the promotion of `feedback_supervisor_progress_objective` from prose to a gate:
   a monitoring-only / "recalibration" tick while `backlog>0` is a DEFECT the run
   must self-correct, never a valid resting state.

2. **Single-item-blocker partitioning.** A per-item capability or hard-gate block
   (deploy token missing, secret-scan-allow, push-ack, a one-way door on item X)
   parks **that item only, with an escalation surfaced** — it does NOT halt the
   run. Keep dispatching every other unblocked backlog item. "Can't deploy" must
   never stop "can still build epics A–F." Only the 3 registered hard-gate sites
   (`push-ack`, `secret-scan-allow`, `scope-unlock-for-drift`) produce a
   whole-run `USER_ESCALATION_HALT`; a capability block is NOT one of them and
   therefore keeps the run building the rest (enforced by construction — the
   anti-park gate blocks the park while backlog remains).

3. **Issue-handling ≠ stop.** Catching a defect — a fabricated green, reverted
   work, a failed verify, a flaky test — triggers **harden the gate + re-queue the
   item + keep building the rest**, NEVER a whole-run halt. Catching a problem is
   the system working, not a terminal event. After you revert a bad change, your
   very next action is to dispatch the next unblocked item, not to "recalibrate"
   and wait.

4. **Honesty floor without paralysis.** Workers MUST emit honest 🟡 and MUST NOT
   self-certify unverifiable claims (e.g. "prod-verified GREEN" with no deploy
   capability). The evaluator/validator MUST reject self-reported green lacking
   independent evidence — the C3 worker-mode ship-verdict anti-spoof
   (`plan-w-team-goal-evaluator.sh`, honored only when the EVALUATOR wrote the
   terminal) stays in force and is NOT weakened. But rejecting a false-green
   **re-queues the verification and keeps the build loop running** — it never
   parks. Reject the claim, re-queue the proof, keep building. Honesty is a reason
   to redo the verification, never a reason to stop the program.

## WTF-Likelihood Score

Track a cumulative WTF-likelihood score, starting at 0%:

| Event                                                                        | Impact |
| ---------------------------------------------------------------------------- | ------ |
| Each revert                                                                  | +15%   |
| Each fix touching >3 files                                                   | +5%    |
| Touching files unrelated to current task                                     | +20%   |
| Re-implementing an existing function/helper/constant instead of importing it | +15%   |
| After 15 fixes, each additional fix                                          | +1%    |
| If all remaining issues are Low severity                                     | +10%   |

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

## Formatter Sync Discipline

If the project uses an auto-formatter (Biome, Prettier, ESLint --fix), run it on target files **before** your first Edit to prevent "file has been modified since read" errors. Auto-formatters rewrite files after Write/Edit, causing the next Edit's `old_string` to mismatch.

```bash
# Run once at start of task, before any edits
pnpm format:fix  # or: npx prettier --write <files>, npx biome check --write <files>
```

After formatting, re-Read any files you plan to edit. This ensures your `old_string` matches the on-disk content.

## Edit Atomicity Discipline

Both PostToolUse validators (TypeScript and ESLint) tolerate transient unused-variable
errors during multi-edit workflows:

| Validator  | Transient (allowed)                                                       | Real (blocks)         |
| ---------- | ------------------------------------------------------------------------- | --------------------- |
| TypeScript | TS6133 (unused imports/variables)                                         | All other type errors |
| ESLint     | `no-unused-vars`, `@typescript-eslint/no-unused-vars`, `unused-imports/*` | All other lint errors |

This means:

- **Multi-edit is safe**: You can add an import in one Edit call and use it in a second
  Edit call. The intermediate unused-variable warning will not block you.
- **Prefer usage-first ordering**: When possible, add the usage site first, then the
  import/declaration. This avoids even the warning.
- **Never combine unrelated changes** into a single Edit just to avoid warnings. Keep
  edits logically coherent — the hooks are designed to tolerate intermediate states.
- **Real errors still block immediately**: Non-transient type errors or lint errors
  must be fixed before continuing.
- **For large coordinated refactors** (6+ edits to one file): if every intermediate
  state triggers real (non-transient) errors, use Write to apply the complete file
  atomically instead of sequential Edits.

## File Operation Discipline

Builders must use the correct tool for each file operation to avoid accidental rewrites:

| files_touched annotation | File exists? | Tool          | Action                                        |
| ------------------------ | ------------ | ------------- | --------------------------------------------- |
| `(create)`               | No           | Write         | Create new file                               |
| `(create)`               | Yes          | Edit          | File already exists — modify, don't overwrite |
| `(modify)`               | Yes          | Edit          | Read first, then targeted edits               |
| `(modify)`               | No           | Write         | File was deleted — recreate                   |
| No annotation            | Unknown      | Read → decide | Check if file exists, then Edit or Write      |

**Rule**: NEVER use Write on an existing file unless you intend to replace its entire content. For adding/changing/removing specific sections, always use Edit.

**Why**: A builder that uses Write on an existing file destroys all content not included in the Write call. This happened when a builder rewrote `campaign-topic-loader.ts` from scratch instead of modifying the existing implementation, losing existing logic and requiring post-merge fixes.

**WTF impact**: Using Write to rewrite an existing file that should have been edited adds **+10%** to WTF-likelihood.

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

## Code Preservation Discipline

Type Preservation (above) is the type-level case of a broader rule: **do not reinvent code that already exists.** Before writing a new function, helper, utility, constant, enum, or config value, builders MUST grep for an existing one and prefer call / import / extend over re-implementing. This is the canonical reuse-first rule (`shared/reuse-first.md`), embedded here so it travels into worktree-isolated builders.

| Rule                                                                          | Rationale                                       |
| ----------------------------------------------------------------------------- | ----------------------------------------------- |
| Grep for an existing function/helper/util before writing a new one            | Prevents code bloat + divergent duplicate logic |
| Prefer import/call over copy-paste; extend (new param/wrapper) over fork      | Single source of truth; one place to fix bugs   |
| Search by concept, not just exact name (`formatCurrency`, `slugify`, `retry`) | Near-duplicates hide behind different names     |
| If you must duplicate (genuinely different semantics), say why in the commit  | Makes the deliberate exception auditable        |

**Positive exemplar**: task needs currency formatting → grep finds `formatCurrency()` in `src/util/money.ts` → `import` and call it. **Anti-pattern**: writing a fresh `fmtMoney()` that duplicates it.

**WTF impact**: Re-implementing an existing function/helper/constant instead of importing it adds **+15%** to WTF-likelihood (same as the type rule — it causes equivalent rework + bloat).

## Shared File Discipline

Builders MUST respect the shared file ownership established in Step 2:

- **Check your task's `files_touched` list** — only modify files assigned to your task
- **Never edit a file owned by another task** unless your task explicitly depends on it and the owner has completed
- **Barrel/entrypoint files** (`index.ts`, `mod.rs`, `__init__.py`): only the designated barrel owner edits these. If you need an export added, note it in your task completion metadata and let the barrel owner handle it
- **If you discover you need to modify an unplanned file**: STOP, report to lead via task metadata, and wait for reassignment rather than editing a file that may be owned by another builder

**WTF impact**: Editing a file owned by another builder adds **+25%** to WTF-likelihood (worse than a revert — it creates merge conflicts that cascade).

## Browser QA Self-Regulation (when browse binary is available)

- CSS-only fixes contribute +0% to WTF-likelihood (safe, presentation-only)
- JSX/TSX fixes contribute +5% (can break functionality)
- Hard cap: 30 browser-related fixes per session (lower than code cap of 50)
- Before/after screenshots required for every browser fix

## Testing Style Discipline

**Core rule**: Prefer fixtures and fakes over mocks. Only use mocks when verifying side effects (e.g., email was sent) or when the real implementation is unavailable.

| Pattern             | TypeScript                                                  | Rust                                  | Python                           | Shell                          |
| ------------------- | ----------------------------------------------------------- | ------------------------------------- | -------------------------------- | ------------------------------ |
| Fixtures over mocks | Factory functions, not `jest.fn()` for deps with real impls | Struct builders, fakes over `mockall` | `@pytest.fixture`, `factory_boy` | `mktemp -d` with known content |
| HTTP seams          | `msw` (Mock Service Worker)                                 | `wiremock-rs`                         | `respx` or `responses`           | Local `nc -l` or tiny server   |
| Property-based      | `fast-check`                                                | `proptest`                            | `hypothesis`                     | N/A                            |

- **Property-based tests**: For pure functions with domain > 10 inputs, write at least one property test using the language-appropriate library above.
- **Tautological test avoidance**: Tests must verify behavior, not implementation. Avoid `expect(fn).toHaveBeenCalled()` on internals — test observable outcomes (return values, state changes, API responses).
- **WTF impact**: Writing tests that only assert mock calls were made (no behavioral verification) adds **+5%** to WTF-likelihood.
