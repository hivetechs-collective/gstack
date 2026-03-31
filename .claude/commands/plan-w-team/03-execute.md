# Steps 3-4: Choose Strategy & Execute

## Step 3: Choose Execution Strategy

| Scenario                                  | Strategy                                       | Mode   | Plan Approval? |
| ----------------------------------------- | ---------------------------------------------- | ------ | -------------- |
| 3+ tasks, new feature                     | Parallel builders, self-claiming pool          | `auto` | Optional       |
| 1-2 simple tasks                          | Single builder, direct assignment              | `auto` | No             |
| Security-critical                         | Parallel builders + validator for final review | `plan` | Yes            |
| Bug fix                                   | Single builder, direct                         | `auto` | No             |
| One-way door tasks                        | Any strategy + extra review in Step 5          | `auto` | Recommended    |
| Large feature (>5 tasks or multi-session) | Lead implements directly, no worktrees         | `auto` | No             |

**Default mode is `auto`** — builders execute without permission prompts for uninterrupted implementation. Use `mode: "plan"` only for security-critical work where each builder must submit an implementation plan via ExitPlanMode before coding starts.

Use `/fork` before committing to a strategy if unsure about the decomposition.

## Step 4: Execute

### Pre-flight Checks

- Require clean working tree (`git status` must show no uncommitted changes). This ensures builder changes can be cleanly attributed. If dirty, ask user to commit or stash first.
- **Prune stale worktrees**: Run `git worktree list` and remove any orphaned worktrees from previous runs before spawning new agents. Stale worktrees cause agents to operate on old code.
  ```bash
  git worktree list                    # identify orphans
  git worktree remove <path> --force   # remove stale ones
  git worktree prune                   # clean up references
  ```
- Sync local base branch to remote:
  ```bash
  git fetch origin <base> --quiet
  git merge --ff-only origin/<base>   # advance local branch to match remote
  ```
  If fast-forward fails (local has diverged), stop and ask the user to resolve before spawning builders. This prevents the stale-base bug where worktrees fork from an old commit.
- Record the base commit SHA: `BASE_SHA=$(git rev-parse HEAD)`. All worktrees must branch from this exact commit. Log it in the team context so post-merge can verify ancestry.
- **Verify shared file analysis**: Confirm Step 2's shared file conflict detection was completed. If any task lacks `files_touched` metadata, fill it in now before spawning builders.

### Edit Atomicity & PostToolUse Hook Behavior

The TypeScript PostToolUse hook runs `tsc --noEmit` after every Edit/Write call. Builders should understand the error triage:

| Error Code | Severity | Hook Behavior             | Builder Action                                                                                                         |
| ---------- | -------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| TS6133     | Warning  | **Allowed** — not blocked | None needed. Transient during multi-edit workflows (e.g., adding an import before its usage site). Resolves naturally. |
| All others | Error    | **Blocked** — must fix    | Fix immediately before continuing.                                                                                     |

This means builders can safely use multiple Edit calls for multi-location changes (e.g., add import → edit usage site) without being blocked by intermediate unused-import warnings. However, real type errors (wrong types, missing properties, bad signatures) still block immediately.

**Recommended edit ordering**: When making changes that span multiple locations in a file, prefer adding the usage site first, then the import/declaration — this avoids even the TS6133 warning. But either order works.

### PreToolUse Blocking Hooks

Several PreToolUse hooks will block operations. Builders must understand these to avoid confusion:

| Hook                         | Trigger                                     | What It Blocks                                                                                                                                           | Builder Action                                                                                                                                          |
| ---------------------------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **config-protection**        | Edit/Write to linter/formatter configs      | `.eslintrc*`, `prettier.config.*`, `biome.json`, `.ruff.toml`, `.stylelintrc*`, `.markdownlint*`                                                         | Fix the source code to satisfy lint rules — do NOT weaken the config. Override: `CLAUDE_DISABLED_HOOKS=pre:edit:config-protection`                      |
| **pre-commit-quality**       | `git commit` via Bash                       | Commits containing `debugger` statements, AWS/GitHub/OpenAI keys, `api_key` assignments in staged files                                                  | Remove the offending code before committing. Warns (but allows) `console.log` and non-conventional commit messages.                                     |
| **auto-tmux-dev**            | Bash commands matching dev server patterns  | `npm run dev`, `pnpm dev`, `yarn dev`, `next dev`, `vite`, `cargo run`, `uvicorn`, `flask run`, `python manage.py runserver`                             | The command is NOT failing — it was redirected to a tmux session running in the background. Check with `tmux attach -t dev-*`. Requires tmux installed. |
| **damage-control (secrets)** | Edit/Write content matching secret patterns | AWS access keys (`AKIA...`), GitHub tokens (`ghp_...`), OpenAI keys (`sk-...`), private key blocks, generic `secret=`/`password=`/`api_key=` assignments | Use placeholder values (`YOUR_KEY_HERE`) or environment variable references instead of hardcoded secrets.                                               |
| **suggest-compact**          | Edit/Write (every call)                     | Nothing — informational only                                                                                                                             | At 50 tool calls, suggests `/compact`. Reminds every 25 calls after. No blocking.                                                                       |

**Hook profiles**: All hooks respect `CLAUDE_HOOK_PROFILE` (default: `standard`). Set to `minimal` to disable most hooks, or `strict` for all hooks including governance audit. Individual hooks can be disabled via `CLAUDE_DISABLED_HOOKS=hook_id1,hook_id2`.

### Execution

1. TeamCreate with descriptive team name
2. Spawn N named builders using Agent tool with worktree isolation:

   ```
   Agent(
     description: "Implement alert rule engine",
     prompt: "You are rules-builder. Claim tasks from the pool and implement them.

     Read `.claude/commands/plan-w-team/shared/self-regulation.md` for WTF-likelihood
     tracking, regression attribution, commit discipline, EDIT ATOMICITY, and TYPE
     PRESERVATION rules. Follow them exactly.

     TYPE PRESERVATION (critical — prevents merge conflicts):
     - NEVER create simplified versions of existing interfaces/types. Import and use
       the canonical types from the codebase.
     - Before defining any new type, search the codebase for existing types that cover
       your needs: Grep pattern='interface|type.*=' glob='**/*.ts'
     - If a canonical type has fields you don't need, use Pick<T, 'field1' | 'field2'>
       or Omit<T, 'field3'> — do NOT create a new interface with fewer fields.
     - When your task requires extending a type, use `extends` or intersection (`&`)
       with the existing type rather than redefining it.

     TASK CLAIMING:
     - Use TaskList to find unassigned, unblocked tasks
     - Use TaskUpdate to claim a task (assign to yourself)
     - Implement, commit, mark complete with metadata
     - Check TaskList for next task (self-claiming loop)
     ...",
     isolation: "worktree",
     mode: "auto"
   )
   ```

3. Each builder gets its own git worktree — full repo copy, no file conflicts
4. Builders self-claim from unassigned task pool via TaskList
5. If plan approval: builders submit plans, lead approves before coding starts
6. Builders implement, PostToolUse hooks validate, commit atomically to worktree branch
7. On completion: TaskUpdate with metadata: {commit_sha, verification, builder_name, wtf_score}
8. Builder checks TaskList for next task (self-claiming loop)
9. Lead monitors progress — use `/loop 2m check TaskList and report status` or CronCreate for automated monitoring instead of manual checks
10. When all tasks complete: SendMessage(shutdown_request) to all builders
11. When all builders complete, merge worktree branches to main in bisectable order:
    - Merge in dependency order (infrastructure first, then models, then controllers, then tests)
    - **Shared file owners merge first** — tasks with `shared_file_owner: true` go before tasks that depend on them
    - After EACH merge, run `npx tsc --noEmit` (or project equivalent) to catch type conflicts immediately
    - If type errors appear, fix them BEFORE merging the next branch — this prevents error cascading
    - Git handles most merges automatically; lead resolves any git merge conflicts
12. **Clean up worktrees immediately after merge**: `git worktree remove <path>` for each merged branch. Do NOT leave worktrees around for later — they consume disk and cause stale-base bugs if re-used.
13. Verify the final merged state: run full test suite + type check before proceeding to Step 5
14. TeamDelete to clean up

### Worktree Lifecycle Rules

| Phase                   | Action                                           | Why                                                             |
| ----------------------- | ------------------------------------------------ | --------------------------------------------------------------- |
| Pre-flight              | Prune all stale worktrees                        | Prevents agents from inheriting old code                        |
| Builder spawn           | Each builder gets fresh worktree from `BASE_SHA` | Ensures consistent starting point                               |
| After each merge        | Remove merged worktree immediately               | Prevents accumulation and stale-base bugs                       |
| Before fix-first agents | Re-record `BASE_SHA=$(git rev-parse HEAD)`       | Fix agents must branch from post-merge state, not original base |
| End of pipeline         | `git worktree prune` to catch any stragglers     | Clean slate for next run                                        |

### Context Budget Awareness

Large parallel builds consume lead context fast. Mitigate:

- **Use line ranges** when reading builder outputs — don't read entire files to check status
- **Delegate status checks** to a haiku `@build-runner` agent instead of reading worktree diffs yourself
- **Clean up worktrees after merge** — fewer branches = less state to track
- **If compaction approaches (>60%)**: finish merging current batch, prune worktrees, then `/compact` before spawning new agents
- **Limit concurrent builders**: 4-6 is the sweet spot. More than 6 risks context exhaustion from tracking them all

### Multi-Session Feature Detection

If Step 2 produced >5 tasks or the total estimated AI effort exceeds 45 minutes, the feature will likely span multiple context windows. Worktree builders expire when the lead's context compacts or the session ends — spawning them for multi-session work wastes allocation overhead.

**For multi-session features, use the "lead implements directly" strategy:**

1. Lead works on main (no worktrees, no builder agents)
2. Commit after each task completes (preserves progress across sessions)
3. Use `--resume` to pick up where the previous session left off
4. TaskList persists across sessions — task metadata survives compaction

This avoids the worktree expiration problem entirely. Reserve parallel worktree builders for features that fit within a single session.

### Pre-Edit Formatter Sync

If the project uses an auto-formatter (Biome, Prettier, ESLint --fix), run it **before** editing files to prevent "file has been modified since read" errors:

```bash
# Before editing, ensure files are format-stable
pnpm format:fix  # or: npx prettier --write src/, npx biome check --write src/
```

This prevents the cycle: Read file -> Edit file -> formatter rewrites file -> next Edit fails because content changed. Run the formatter once up front so all subsequent reads match the on-disk state.

## Resume Incomplete Work

When invoked with `--resume`:

1. TaskList -> identify tasks with status != "completed"
2. For completed tasks: verify metadata.commit_sha exists in git log
3. Reset orphaned in_progress tasks (no living builder) to "pending"
4. Check for stale worktree branches with `git worktree list` — prune any orphaned worktrees
5. Read metadata.spec_path from any task to reload requirements
6. Reload taste calibration and door labels from spec
7. TeamCreate, spawn builders for remaining work
8. Builders self-claim incomplete tasks
9. Normal execution continues from Step 4 above
