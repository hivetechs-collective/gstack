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
