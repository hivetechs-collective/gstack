# State Artifact Registry

Every `.claude/state/plan-w-team-*` file has an entry here. This registry is the authoritative list consumed by `.claude/scripts/plan-w-team-symmetry-check.sh` (invoked in Step 5 review).

## Purpose

Prevent the "write-only by accident" defect class: artifacts whose writer is wired but whose reader was promised in prose and never implemented. A registry entry declares intent; the checker verifies the intent matches the code.

## Modes

| Mode          | Fail condition                             | Step 5 behavior                                    |
| ------------- | ------------------------------------------ | -------------------------------------------------- |
| `enforcing`   | Registry entry has no matching reader      | Fail-closed (exit 1, blocks ship)                  |
| `handoff`     | Registry entry has no matching reader      | Fail-closed (exit 1) — handoff with no consumer    |
| `audit-trail` | Reader optional; reported but non-blocking | Advisory warning only                              |
| _(any)_       | Writer grep has no registry entry          | ASK item — either register it or remove the writer |

## Registry

<!-- Format: one row per artifact. Columns parsed by symmetry-check.sh.
     - `pattern`: path with `$SLUG` placeholder or literal for global files
     - `writer_grep`: ripgrep pattern scoped to a code-block match (excluding prose mentions)
     - `reader_grep`: ripgrep pattern matching at least one reader location
     - `mode`: enforcing | handoff | audit-trail
     Do NOT add prose columns before/after without updating the checker's awk. -->

| pattern                                                  | writer_grep                                           | reader_grep                                              | mode      | purpose                                       |
| -------------------------------------------------------- | ----------------------------------------------------- | -------------------------------------------------------- | --------- | --------------------------------------------- |
| `.claude/state/plan-w-team-untracked-baseline-$SLUG.txt` | `plan-w-team-untracked-baseline-.*\.txt`              | `BASELINE=".claude/state/plan-w-team-untracked-baseline` | enforcing | Ship gate anchor (Step 5 hygiene)             |
| `.claude/state/plan-w-team-ac-snapshot-$SLUG.md`         | `SNAPSHOT=".claude/state/plan-w-team-ac-snapshot`     | `SNAPSHOT=".claude/state/plan-w-team-ac-snapshot`        | enforcing | AC contract integrity (evaluator + Step 5)    |
| `.claude/state/plan-w-team-scope-lock-$SLUG.json`        | `cat > ".claude/state/plan-w-team-scope-lock`         | `LOCK=".claude/state/plan-w-team-scope-lock`             | enforcing | Scope drift detection (Step 5 + Step 8)       |
| `.claude/state/plan-w-team-scope-unlock-$SLUG`           | `plan-w-team-scope-unlock-`                           | `UNLOCK=".claude/state/plan-w-team-scope-unlock`         | handoff   | User ack for mid-flight scope expansion       |
| `.claude/state/plan-w-team-retro-$SLUG.json`             | `plan-w-team-retro-\$SLUG\.json`                      | `RETRO_STATE=".claude/state/plan-w-team-retro`           | handoff   | Cross-stage hygiene handoff (Step 5 → Step 8) |
| `.claude/state/plan-w-team-friction-log.jsonl`           | `LOG=".claude/state/plan-w-team-friction-log`         | `plan-w-team-friction-log\.jsonl`                        | enforcing | Global feedback loop (3-in-30d detector)      |
| `.claude/state/plan-w-team-friction-ack-<category>`      | `plan-w-team-friction-ack-`                           | `plan-w-team-friction-ack-`                              | handoff   | User dismissal of friction pattern            |
| `.claude/state/plan-w-team-autofix-$SLUG.md`             | `plan-w-team-autofix-\$SLUG\.md`                      | `plan-w-team-autofix-\$SLUG\.md`                         | handoff   | Auto-fix scope fence (reviewer → builder)     |
| `.claude/state/plan-w-team-ack-$SLUG`                    | `ACK_FILE=".claude/state/plan-w-team-ack`             | `ACK_FILE=".claude/state/plan-w-team-ack`                | enforcing | Push confirmation gate                        |
| `.claude/state/plan-w-team-push.lock`                    | `PUSH_LOCK_DIR=".claude/state/plan-w-team-push\.lock` | `PUSH_LOCK_DIR=".claude/state/plan-w-team-push\.lock`    | enforcing | Concurrent push serialization (mkdir lock)    |

## When adding a new state artifact

1. Add a row to the table above **in the same commit** as the writer code.
2. Run `.claude/scripts/plan-w-team-symmetry-check.sh` locally — it must exit 0.
3. If the artifact is write-only (audit trail), set `mode: audit-trail` and put a dash (`-`) in `reader_grep`.
4. If the checker flags a false positive, scope the grep patterns tighter (quote the variable assignment) rather than relaxing the mode.

## Checker invocation

```bash
.claude/scripts/plan-w-team-symmetry-check.sh                     # exit 0 = pass
.claude/scripts/plan-w-team-symmetry-check.sh --json               # machine-readable
.claude/scripts/plan-w-team-symmetry-check.sh --registry <path>    # alt registry (testing)
```

Exit codes:

- `0` — symmetric
- `1` — enforcing orphan (registry entry with no reader grep match)
- `2` — stale registry entry (no writer grep match — likely renamed or removed)
- `3` — environment failure (ripgrep missing, registry malformed)

## Where this runs

- **Step 5 review** — fail-closed for exit 1 or 2; advisory for audit-trail-only warnings.
- **Step 8 retro** — score 5 (pass) / 3 (audit-trail warnings only) / 1 (enforcing fail in Step 5). Score <4 feeds §8i friction log with category `spec-gap`.
