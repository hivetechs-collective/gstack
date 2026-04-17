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
| Tightly-coupled tasks in same module      | Lead implements directly, sequential           | `auto` | No             |

**Default mode is `auto`** — builders execute without permission prompts for uninterrupted implementation. Use `mode: "plan"` only for security-critical work where each builder must submit an implementation plan via ExitPlanMode before coding starts.

Use `/fork` before committing to a strategy if unsure about the decomposition.

## Step 4: Execute

### Board Update (Auto)

Move the feature card to In Progress and add an execution start comment. Fire-and-forget — failures must NOT block execution.

```bash
scripts/board.sh move "<feature-name>" "In Progress" || true

# Log execution start with strategy details
scripts/board.sh comment "<feature-name>" "## Execution Started

**Strategy:** <parallel builders | single builder | lead-implements-directly>
**Branch:** \`$(git branch --show-current)\`
**Tasks:** <N> tasks, <N> parallel builders
**Started:** $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
```

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
- **Verify acceptance criteria exist** (evaluator pre-flight): Scan the spec for evaluable criteria. Detection order:
  1. Spec has `### Functional Criteria` with real `- [ ] AC` items → evaluator WILL run in Step 4b
  2. Spec has `- [ ] AC` pattern under any `## Acceptance Criteria` heading → evaluator WILL run (backward compat)
  3. No criteria found, or only template placeholders (`[Subject] [verb]`) → warn: "⚠️ No acceptance criteria detected — evaluator loop will skip. Add criteria now or proceed without evaluation?"
     This is a warning, not a blocker. The lead can proceed without criteria (Step 5 review still runs).

### Edit Atomicity & PostToolUse Hook Behavior

Both PostToolUse validators (TypeScript and ESLint) run after every Edit/Write call. They tolerate transient unused-variable errors during multi-edit workflows:

| Validator  | Transient (allowed)                                                       | Blocking (must fix)        |
| ---------- | ------------------------------------------------------------------------- | -------------------------- |
| TypeScript | TS6133 (unused imports/variables)                                         | All other type errors      |
| ESLint     | `no-unused-vars`, `@typescript-eslint/no-unused-vars`, `unused-imports/*` | All other lint rule errors |

This means builders can safely use multiple Edit calls for multi-location changes (e.g., add import → edit usage site) without being blocked by intermediate unused-variable warnings. Real type errors and real lint errors still block immediately.

**Recommended edit ordering**: When making changes that span multiple locations in a file, prefer adding the usage site first, then the import/declaration — this avoids even the transient warning. But either order works.

**Large coordinated refactors**: If a fix requires 6+ edits to one file where every intermediate state triggers real (non-transient) errors, use Write to apply the complete file atomically instead of sequential Edits. This avoids the hook-per-edit friction entirely.

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

### Tmux Visual Orchestration

When running inside tmux, builders get colored status panes automatically via the `agent-tmux-panes` hook:

- **Layout**: main-vertical — orchestrator keeps 60% left, builder panes stack vertically on the right
- **Colors**: Each builder gets a unique border color from an 8-color palette (RED, GRN, BLU, ORG, PRP, YLW, CYN, MAG)
- **Live timer**: Each pane shows agent name, task description, and a running clock
- **Completion**: When a builder finishes, its pane flashes "✓ COMPLETED" then closes after 5 seconds
- **Cleanup**: Stale panes from crashed sessions are auto-pruned on next run; `session-end` hook cleans up all panes

Disable with `CLAUDE_AGENT_PANES=0` or `CLAUDE_DISABLED_HOOKS=subagent:tmux-panes`.

### Execution

1. TeamCreate with descriptive team name
2. **Use task `agent_type` from Step 2**: Each task already has a specialist assigned from the roster. If you need the full list, read `.claude/commands/plan-w-team/shared/agent-roster.md` (85+ specialists with domain and color).

3. Spawn N named builders using Agent tool with worktree isolation and **specialist subagent_type** (from task metadata `agent_type`):

   ```
   Agent(
     description: "Implement alert rule engine",
     subagent_type: "nodejs-specialist",   // ← REQUIRED: match to task domain
     model: "claude-opus-4-6",             // ← Hands tier: cost-effective for implementation
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
     - If your task description includes `creates_types`, create those types EXACTLY as
       specified. Another builder may create identical types — this is intentional for
       merge deduplication.

     FILE OPERATION DISCIPLINE (critical — prevents accidental rewrites):
     - Check your task's `files_touched` annotations: `(create)` = new file, `(modify)` = existing
     - For `(modify)` files: ALWAYS Read the file first, then use Edit to make targeted
       changes. NEVER use Write to replace an existing file from scratch.
     - For `(create)` files: use Write. Verify the path doesn't already exist first.
     - If `files_touched` has no annotations, default to: Read first. If file exists, Edit.
       If file doesn't exist, Write.

     TEST EXECUTION (run before marking any task complete):
     - Detect test runner once at task start using this priority order:
       Cargo.toml [workspace] → cargo test --workspace
       Cargo.toml (no workspace) → cargo test
       package.json with vitest devDep → npx vitest run
       package.json with jest devDep → npx jest
       package.json with test script → npm test
       pyproject.toml [tool.pytest] or conftest.py → pytest
       *.bats files → bats <dir>
       None of the above → skip (not an error, log test_runner: none)
     - Run detected test command with 60-second timeout before marking
       each task complete. If tests fail, fix and re-run.
     - If tests fail on code you didn't write, run the same tests on the
       base branch to attribute blame — pre-existing failures are not yours.
     - If no test runner detected, proceed without tests. Many repos
       (docs, config, shell scripts) legitimately have no test suite.

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

4. Each builder gets its own git worktree — full repo copy, no file conflicts
5. Builders self-claim from unassigned task pool via TaskList
6. If plan approval: builders submit plans, lead approves before coding starts
7. Builders implement, PostToolUse hooks validate, commit atomically to worktree branch
8. On completion: TaskUpdate with metadata: {commit_sha, verification, builder_name, wtf_score}
9. Builder checks TaskList for next task (self-claiming loop)
10. Lead monitors progress — use `/loop 2m check TaskList and report status` or CronCreate for automated monitoring instead of manual checks
11. When all tasks complete: SendMessage(shutdown_request) to all builders
12. When all builders complete, merge worktree branches to main in bisectable order:
    - Merge in dependency order (infrastructure first, then models, then controllers, then tests)
    - **Shared file owners merge first** — tasks with `shared_file_owner: true` go before tasks that depend on them
    - After EACH merge, run `npx tsc --noEmit` (or project equivalent) to catch type conflicts immediately
    - If type errors appear, fix them BEFORE merging the next branch — this prevents error cascading
    - Git handles most merges automatically; lead resolves any git merge conflicts
13. **Clean up worktrees immediately after merge**: `git worktree remove <path>` for each merged branch. Do NOT leave worktrees around for later — they consume disk and cause stale-base bugs if re-used.
14. Verify the final merged state: run full test suite + type check before proceeding to Step 5
15. TeamDelete to clean up

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

### Compaction Resilience

Context compaction can hit during any phase (build, review, merge). To survive it:

1. **Use Task tools, not TodoWrite**: Tasks persist across compaction. TodoWrite items do not.
2. **Tag tasks with pipeline step**: Include `pipeline_step: "build"` or `pipeline_step: "review"` in task metadata so post-compaction recovery knows where to resume.
3. **Pre-compact hook saves state**: The hook now detects active spec files, worktrees, and writes recovery instructions to `.claude/state/session-state.md`.
4. **Post-compaction**: Run `TaskList` immediately. The task metadata tells you which step was active, which tasks are done, and which need work.
5. **If compaction is imminent (>60%)**: Finish the current task, commit, update task metadata, then `/compact` cleanly. Don't start a new task at 70% context.

### Multi-Session Feature Detection

If Step 2 produced >5 tasks or the total estimated AI effort exceeds 45 minutes, the feature will likely span multiple context windows. Worktree builders expire when the lead's context compacts or the session ends — spawning them for multi-session work wastes allocation overhead.

**For multi-session features, use the "lead implements directly" strategy:**

1. Lead works on main (no worktrees, no builder agents)
2. Commit after each task completes (preserves progress across sessions)
3. **Scope check after each task**: Before starting the next task, verify it is in the spec's Must Have section — not in Deferred or Phase 2. If you've completed all Must Have tasks but feel compelled to keep building, STOP. That impulse is scope creep. Proceed to step 5.
4. Use `--resume` to pick up where the previous session left off
5. TaskList persists across sessions — task metadata survives compaction
6. **After all tasks complete: run Step 4b evaluator checkpoint** (same as parallel path — see below). Do NOT skip to Step 5 without checking for acceptance criteria.

This avoids the worktree expiration problem entirely. Reserve parallel worktree builders for features that fit within a single session.

> **Why scope enforcement matters here**: Parallel builders have natural scope limits — they only work on assigned tasks from the pool. The lead-implements-directly path has no such constraint. Without this check, the lead will finish Must Have items and seamlessly drift into Deferred items without noticing the boundary. This is the most common failure mode for this strategy.

### Pre-Edit Formatter Sync

If the project uses an auto-formatter (Biome, Prettier, ESLint --fix), run it **before** editing files to prevent "file has been modified since read" errors:

```bash
# Before editing, ensure files are format-stable
pnpm format:fix  # or: npx prettier --write src/, npx biome check --write src/
```

This prevents the cycle: Read file -> Edit file -> formatter rewrites file -> next Edit fails because content changed. Run the formatter once up front so all subsequent reads match the on-disk state.

## Step 4b: Evaluator-Driven Refinement (Iteration Loop)

**MANDATORY CHECKPOINT — ALL STRATEGIES**: After all implementation tasks are complete (whether via parallel builders + merge, or lead-implements-directly), and BEFORE proceeding to Step 5 review, run the evaluator loop if the spec has an Acceptance Criteria Contract. This applies regardless of execution strategy chosen in Step 3.

For parallel builders: this runs after worktrees are merged and cleaned up (step 14).
For lead-implements-directly: this runs after the last task is committed on main.

> "Agents tend to respond by confidently praising the work — even when, to a human observer, the quality is obviously mediocre." — Anthropic Labs, March 2026. The evaluator is intentionally separate from the builder to avoid this self-evaluation bias.

### When to Run

Detect criteria using pattern matching, not heading-name matching:

| Condition                                                                             | Action                               |
| ------------------------------------------------------------------------------------- | ------------------------------------ |
| Spec has `- [ ] AC` items under `### Functional Criteria` or `## Acceptance Criteria` | Run evaluator loop                   |
| Spec has `### Quality Rubrics` with a populated table (not template placeholders)     | Run evaluator loop (rubrics-only)    |
| No `- [ ] AC` items and no populated rubrics anywhere in spec                         | Skip to Step 5 (warn in pre-flight)  |
| Context usage > 60%                                                                   | Skip to Step 5 (budget conservation) |
| Feature is trivial (config, docs-only)                                                | Skip to Step 5                       |

**Backward compatibility**: Specs written before the contract format (using `## Acceptance Criteria` with `- [ ] AC1:` items) still trigger the evaluator. The evaluator treats flat AC lists as functional criteria.

### Loop Protocol

```
iteration = 0
max_iterations = spec.max_eval_iterations or 3
previous_failures = []

while iteration < max_iterations:
    iteration += 1

    # 1. Spawn evaluator agent
    # CONTEXT ISOLATION: paste ONLY criteria + diff. Never include builder
    # reasoning, lead conversation, or planning context.
    Agent(
      description: "Evaluate build against acceptance criteria",
      subagent_type: "evaluator",      # custom team agent
      model: "claude-opus-4-7",        # Brain tier: reasoning quality matters for evaluation
      prompt: "You are the evaluator. Read your instructions at
        .claude/agents/team/evaluator.md

        CONTEXT ISOLATION: You receive ONLY the acceptance criteria and
        build output below. No builder reasoning or lead conversation is
        included. Judge the artifact, not the author's intent.

        INPUTS:
        - Acceptance Criteria: [paste ONLY the criteria from spec —
          functional criteria and/or quality rubrics. Do NOT paste
          the spec's technical design, overview, or builder notes]
        - Build diff: git diff <base>...HEAD
        - Iteration: {iteration}/{max_iterations}
        - Previous feedback: {previous_failures or 'First iteration'}
        - Dev server URL: {url if web project, else 'N/A'}

        Evaluate and return structured report.",
      mode: "auto"
    )

    # 2. Parse evaluator verdict
    if verdict == PASS:
        break  # proceed to Step 5
    elif verdict == ESCALATE:
        break  # proceed to Step 5 with report attached
    elif verdict == ITERATE:
        # 3. No-progress check
        if current_failures == previous_failures:
            # Builder is stuck — same failures twice
            escalate, break
        previous_failures = current_failures

        # 4. Feed feedback to builder for fixes
        # For lead-implements-directly: lead reads feedback and fixes
        # For worktree builders: spawn fix builder with evaluator feedback
        apply_fixes(evaluator_feedback)

        # 5. Re-verify (tests pass, compiles)
        run_tests()

# 6. Attach evaluator report to task metadata for Step 5
TaskUpdate(metadata: {evaluator_report: report, eval_iterations: iteration})

# 7. Write evaluator outcome to state file for compound learning
#    Shell hooks (capture-learnings.sh) can't access TaskList — this file
#    is the bridge between agent context and hook context.
#    Format: one JSON line per evaluation, matching learnings.jsonl schema.
Write(".claude/state/evaluator-outcomes.jsonl", append=true, content={
  "timestamp": now_iso8601(),
  "session_id": session_id,
  "type": "evaluator_outcome",
  "feature": spec.feature_name,
  "verdict": verdict,
  "iterations": iteration,
  "max_iterations": max_iterations,
  "functional_pass": count(criteria where verdict==PASS),
  "functional_fail": count(criteria where verdict==FAIL),
  "functional_total": len(criteria),
  "quality_scores": [score for each rubric],
  "quality_avg": mean(quality_scores) or null,
  "failure_categories": [category for each FAIL criterion],
  "project": basename(cwd)
})
```

> **Why a state file?** Shell hooks run in bash, not in Claude's agent context. They cannot call TaskList or TaskGet. The `.claude/state/evaluator-outcomes.jsonl` file bridges this gap — the lead writes it during Step 4b, and `capture-learnings.sh` reads it at session end.

### Applying Fixes Between Iterations

| Strategy            | When                                            | How                                                    |
| ------------------- | ----------------------------------------------- | ------------------------------------------------------ |
| Lead fixes directly | Lead-implements-directly strategy, or < 3 fixes | Read evaluator feedback, apply fixes on main, commit   |
| Spawn fix builder   | Parallel strategy, or fixes are substantial     | Single builder with evaluator feedback as prompt input |

**Do NOT spawn multiple fix builders** — fixes from one evaluator cycle are usually interdependent. One builder, one commit, then re-evaluate.

### Cost Budget

Each iteration costs approximately one evaluator agent spawn + one fix round. For a typical 3-iteration loop:

| Component                       | Estimated Cost |
| ------------------------------- | -------------- |
| Evaluator spawn (per iteration) | ~$2-5          |
| Fix builder (per iteration)     | ~$3-8          |
| Full 3-iteration loop           | ~$15-40        |
| Skip (no contract)              | $0             |

If the feature's total cost is < $50, limit to 2 iterations. The evaluator loop should not exceed 30% of total feature cost.

### Interaction with Execution Strategy

| Strategy                 | Evaluator runs after...                       | Fixes happen on...           |
| ------------------------ | --------------------------------------------- | ---------------------------- |
| Parallel builders        | Worktrees merged and cleaned up (steps 13-14) | Main (no new worktrees)      |
| Lead implements directly | Last task committed on main                   | Main (lead applies directly) |
| Single builder           | Builder completes and worktree merged         | Main (no new worktrees)      |

In all cases: the evaluator evaluates the merged state on main. Fixes happen directly on main — the overhead of new worktrees isn't worth it for targeted fixes.

### Step 4 → Step 5 Transition Gate

**Do NOT proceed to Step 5 until this gate is satisfied:**

1. All tasks from Step 2 are marked `completed` in TaskList
2. If the spec contains `- [ ] AC` items or populated `### Quality Rubrics`: Step 4b evaluator loop has run (or was skipped due to context budget > 60%)
3. If the evaluator ran: its verdict and iteration count are recorded in task metadata AND written to `.claude/state/evaluator-outcomes.jsonl`

If you find yourself starting Step 5 without having checked for acceptance criteria, STOP and run Step 4b first. The most common way this gate is missed is on the "lead implements directly" path where there is no natural builder→merge→evaluate handoff.

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
