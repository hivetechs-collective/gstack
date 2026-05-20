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

| pattern                                                    | writer_grep                                                | reader_grep                                               | mode      | purpose                                                                                                      |
| ---------------------------------------------------------- | ---------------------------------------------------------- | --------------------------------------------------------- | --------- | ------------------------------------------------------------------------------------------------------------ |
| `.claude/state/plan-w-team-untracked-baseline-$SLUG.txt`   | `plan-w-team-untracked-baseline-.*\.txt`                   | `BASELINE=".claude/state/plan-w-team-untracked-baseline`  | enforcing | Ship gate anchor (Step 5 hygiene)                                                                            |
| `.claude/state/plan-w-team-ac-snapshot-$SLUG.md`           | `SNAPSHOT=".claude/state/plan-w-team-ac-snapshot`          | `SNAPSHOT=".claude/state/plan-w-team-ac-snapshot`         | enforcing | AC contract integrity (evaluator + Step 5)                                                                   |
| `.claude/state/plan-w-team-scope-lock-$SLUG.json`          | `cat > ".claude/state/plan-w-team-scope-lock`              | `LOCK=".claude/state/plan-w-team-scope-lock`              | enforcing | Scope drift detection (Step 5 + Step 8)                                                                      |
| `.claude/state/plan-w-team-scope-unlock-$SLUG`             | `plan-w-team-scope-unlock-`                                | `UNLOCK=".claude/state/plan-w-team-scope-unlock`          | handoff   | User ack for mid-flight scope expansion                                                                      |
| `.claude/state/plan-w-team-retro-$SLUG.json`               | `plan-w-team-retro-\$SLUG\.json`                           | `RETRO_STATE=".claude/state/plan-w-team-retro`            | handoff   | Cross-stage hygiene handoff (Step 5 → Step 8)                                                                |
| `.claude/state/plan-w-team-friction-log.jsonl`             | `LOG=".claude/state/plan-w-team-friction-log`              | `plan-w-team-friction-log\.jsonl`                         | enforcing | Global feedback loop (3-in-30d detector)                                                                     |
| `.claude/state/plan-w-team-friction-ack-<category>`        | `plan-w-team-friction-ack-`                                | `plan-w-team-friction-ack-`                               | handoff   | User dismissal of friction pattern                                                                           |
| `.claude/state/plan-w-team-autofix-$SLUG.md`               | `plan-w-team-autofix-\$SLUG\.md`                           | `plan-w-team-autofix-\$SLUG\.md`                          | handoff   | Auto-fix scope fence (reviewer → builder)                                                                    |
| `.claude/state/plan-w-team-review-findings-$SLUG.md`       | `FINDINGS=".claude/state/plan-w-team-review-findings`      | `FINDINGS=".claude/state/plan-w-team-review-findings`     | enforcing | Review findings handoff (Step 5 → Step 6)                                                                    |
| `.claude/state/plan-w-team-ack-$SLUG`                      | `ACK_FILE=".claude/state/plan-w-team-ack`                  | `ACK_FILE=".claude/state/plan-w-team-ack`                 | enforcing | Push confirmation gate                                                                                       |
| `.claude/state/plan-w-team-push.lock`                      | `PUSH_LOCK_DIR=".claude/state/plan-w-team-push\.lock`      | `PUSH_LOCK_DIR=".claude/state/plan-w-team-push\.lock`     | enforcing | Concurrent push serialization (mkdir lock)                                                                   |
| `.claude/state/plan-w-team-secret-scan-allow-$SLUG`        | `ALLOW_FILE=".claude/state/plan-w-team-secret-scan-allow`  | `ALLOW_FILE=".claude/state/plan-w-team-secret-scan-allow` | handoff   | User-curated allowlist for secret-scan false positives                                                       |
| `.claude/state/plan-w-team-workflow-$SLUG.lock`            | `WORKFLOW_LOCK_DIR=".claude/state/plan-w-team-workflow`    | `WORKFLOW_LOCK_DIR=".claude/state/plan-w-team-workflow`   | enforcing | Per-SLUG concurrent /plan-w-team session lock                                                                |
| `.claude/state/plan-w-team-postship-$SLUG.json`            | `ARTIFACT=".claude/state/plan-w-team-postship`             | `plan-w-team-postship-\$SLUG\.json`                       | handoff   | Step 7 docs audit handoff to Step 8 retro §8d                                                                |
| `.claude/state/plan-w-team-friction-log.lock`              | `LOCK_DIR=".claude/state/plan-w-team-friction-log\.lock`   | `LOCK_DIR=".claude/state/plan-w-team-friction-log\.lock`  | enforcing | Concurrent retro friction-log mkdir lock                                                                     |
| `.claude/state/plan-w-team-coupling-$SLUG.json`            | `plan-w-team-coupling-\$\{slug\}\.json`                    | `COUPLING_REPORT=`                                        | handoff   | Stage 2 import-coupling matrix (T2 reads, scope-lock gates)                                                  |
| `.claude/state/plan-w-team-coupling-ack-$SLUG`             | `> "?\.claude/state/plan-w-team-coupling-ack`              | `COUPLING_ACK=`                                           | handoff   | User ack for intentional coupling (escape hatch for scope-lock)                                              |
| `.claude/state/plan-w-team-fleet-$SLUG.jsonl`              | `FLEET_FILE="\$STATE_DIR/plan-w-team-fleet-`               | `FLEET_FILE="\$STATE_DIR/plan-w-team-fleet-`              | handoff   | Subagent spawn/complete events (T3-04 retro reads, lead reads via fleet-query.sh)                            |
| `.claude/state/plan-w-team-supervisor-actions-$SLUG.jsonl` | `ACTIONS_LOG="\$STATE_DIR/plan-w-team-supervisor-actions-` | `SUP_LOG=".claude/state/plan-w-team-supervisor-actions-`  | handoff   | Persistent supervisor (PWT-T4) action audit log (07-retro §8j-quater reads)                                  |
| `.claude/state/plan-w-team-goal-$SLUG.json`                | `plan-w-team-goal-\$\{SLUG\}\.json`                        | `plan-w-team-goal-\*\.json`                               | handoff   | T5b goal evaluator state (slug, started_at, terminal_state, terminal_reason, feature_specific_done_criteria) |

## Claude Code interactions (2.1.139+)

- **`claude project purge [path]`** removes all `.claude/state/plan-w-team-*` artifacts including in-flight baselines, scope-locks, AC snapshots, and retros. Treat purge mid-feature as equivalent to abandoning the SLUG — the workflow lock dir is removed but the workflow itself cannot detect this. If a user purges mid-run, instruct them to start a new SLUG rather than resume.
- **`worktree.baseRef` inheritance** — Builder worktrees spawned in Step 3-4 inherit the repo's `worktree.baseRef` setting. Default changed to `"fresh"` in Claude Code 2.1.133, which means builders branch from `origin/<default>` and CANNOT see the lead's local-only spec commit. Step 3-4 has a pre-fan-out guard that detects this and pushes the spec before spawning. If the repo has no remote, set `worktree.baseRef: "head"` in `.claude/settings.json` to restore pre-2.1.133 behavior.

## When adding a new state artifact

1. Add a row to the table above **in the same commit** as the writer code.
2. Run `.claude/scripts/plan-w-team-symmetry-check.sh` locally — it must exit 0.
3. If the artifact is write-only (audit trail), set `mode: audit-trail` and put a dash (`-`) in `reader_grep`.
4. If the checker flags a false positive, scope the grep patterns tighter (quote the variable assignment) rather than relaxing the mode.

## Checker invocation

```bash
# snippet-lint: skip — illustrative `<path>` placeholder, not executable as-is
.claude/scripts/plan-w-team-symmetry-check.sh                     # exit 0 = pass
.claude/scripts/plan-w-team-symmetry-check.sh --json               # machine-readable
.claude/scripts/plan-w-team-symmetry-check.sh --registry <path>    # alt registry (testing)
```

Exit codes:

- `0` — symmetric
- `1` — enforcing orphan (registry entry with no reader grep match)
- `2` — stale registry entry (no writer grep match — likely renamed or removed)
- `3` — environment failure (ripgrep missing, registry malformed)
- `4` — orphan reader (code references `.claude/state/plan-w-team-*` with no matching registry entry)

## Where this runs

- **Step 5 review** — fail-closed for exit 1 or 2; advisory for audit-trail-only warnings.
- **Step 8 retro** — score 5 (pass) / 3 (audit-trail warnings only) / 1 (enforcing fail in Step 5). Score <4 feeds §8i friction log with category `spec-gap`.
