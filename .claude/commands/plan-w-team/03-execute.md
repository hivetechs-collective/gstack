# Steps 3-4: Choose Strategy & Execute

## Step 3: Choose Execution Strategy

| Scenario              | Strategy                                       | Mode   | Plan Approval? |
| --------------------- | ---------------------------------------------- | ------ | -------------- |
| 3+ tasks, new feature | Parallel builders, self-claiming pool          | `auto` | Optional       |
| 1-2 simple tasks      | Single builder, direct assignment              | `auto` | No             |
| Security-critical     | Parallel builders + validator for final review | `plan` | Yes            |
| Bug fix               | Single builder, direct                         | `auto` | No             |
| One-way door tasks    | Any strategy + extra review in Step 5          | `auto` | Recommended    |

**Default mode is `auto`** — builders execute without permission prompts for uninterrupted implementation. Use `mode: "plan"` only for security-critical work where each builder must submit an implementation plan via ExitPlanMode before coding starts.

Use `/fork` before committing to a strategy if unsure about the decomposition.

## Step 4: Execute

### Pre-flight Checks

- Require clean working tree (`git status` must show no uncommitted changes). This ensures builder changes can be cleanly attributed. If dirty, ask user to commit or stash first.
- Sync local base branch to remote:
  ```bash
  git fetch origin <base> --quiet
  git merge --ff-only origin/<base>   # advance local branch to match remote
  ```
  If fast-forward fails (local has diverged), stop and ask the user to resolve before spawning builders. This prevents the stale-base bug where worktrees fork from an old commit.
- Record the base commit SHA: `BASE_SHA=$(git rev-parse HEAD)`. All worktrees must branch from this exact commit. Log it in the team context so post-merge can verify ancestry.

### Edit Atomicity & PostToolUse Hook Behavior

The TypeScript PostToolUse hook runs `tsc --noEmit` after every Edit/Write call. Builders should understand the error triage:

| Error Code | Severity | Hook Behavior             | Builder Action                                                                                                         |
| ---------- | -------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| TS6133     | Warning  | **Allowed** — not blocked | None needed. Transient during multi-edit workflows (e.g., adding an import before its usage site). Resolves naturally. |
| All others | Error    | **Blocked** — must fix    | Fix immediately before continuing.                                                                                     |

This means builders can safely use multiple Edit calls for multi-location changes (e.g., add import → edit usage site) without being blocked by intermediate unused-import warnings. However, real type errors (wrong types, missing properties, bad signatures) still block immediately.

**Recommended edit ordering**: When making changes that span multiple locations in a file, prefer adding the usage site first, then the import/declaration — this avoids even the TS6133 warning. But either order works.

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
    - After EACH merge, run `npx tsc --noEmit` (or project equivalent) to catch type conflicts immediately
    - If type errors appear, fix them BEFORE merging the next branch — this prevents error cascading
    - Git handles most merges automatically; lead resolves any git merge conflicts
12. Verify the final merged state: run full test suite + type check before proceeding to Step 5
13. TeamDelete to clean up

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
