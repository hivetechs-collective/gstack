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
- Run `git fetch origin <base> --quiet` to ensure local base branch is current. This prevents phantom diffs from stale local state.

### Execution

1. TeamCreate with descriptive team name
2. Spawn N named builders using Agent tool with worktree isolation:

   ```
   Agent(
     description: "Implement alert rule engine",
     prompt: "You are rules-builder. Claim tasks from the pool and implement them.

     Read `.claude/commands/plan-w-team/shared/self-regulation.md` for WTF-likelihood
     tracking, regression attribution, and commit discipline rules. Follow them exactly.

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
11. When all builders complete, merge worktree branches to main in bisectable order. Git handles most merges automatically; lead resolves any git merge conflicts.
12. TeamDelete to clean up

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
