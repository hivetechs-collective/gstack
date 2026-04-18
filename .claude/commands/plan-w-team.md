# Plan With Team Command

Full-lifecycle planning and execution workflow: scope challenge, specification, parallel implementation, fix-first review, ship pipeline, post-ship documentation, and quantitative retrospective. A single command that takes a feature from idea to shipped, reviewed, documented code.

Based on IndyDevDan's claude-code-hooks-mastery pattern, extended with gstack-inspired lifecycle stages (scope challenge, fix-first review, ship pipeline, retro), self-regulation heuristics, cognitive frameworks, and artifact handoffs between stages.

## Usage

```
/plan-w-team [feature description]
/plan-w-team --resume        # Resume incomplete work from task list
/plan-w-team --ship-only     # Skip to Step 5+ (review/ship/docs/retro)
/plan-w-team --retro         # Run retro only on recent shipped work
```

For simple parallel changes across files (same pattern, no spec needed), use `/batch` instead. `/plan-w-team` is for spec-first features with dependencies between tasks.

## Intent Detection

The user does NOT need to remember flags. Infer intent from natural language and route accordingly:

| User says something like...                           | Route to                |
| ----------------------------------------------------- | ----------------------- |
| "Add alerting system with email notifications"        | Full lifecycle (0-8)    |
| "Review the auth module I just finished"              | Steps 5-8 (review+ship) |
| "Deep review of my changes, don't ship yet"           | Step 5 only (review)    |
| "Ship what's on this branch"                          | Steps 5-8 (review+ship) |
| "How did that feature go? What are the metrics?"      | Step 8 only (retro)     |
| "Pick up where we left off on the alerting work"      | Resume (3-4 then 5-8)   |
| "Just update the docs and changelog for this release" | Steps 7-8 (post-ship)   |

When ambiguous, ask. When clear, just start the right step — no flag needed.

Explicit flags (`--ship-only`, `--retro`, `--resume`) still work as shortcuts.

## Scope Mode

Before starting, select a scope mode that controls planning intensity:

| Mode                 | When to Use                            | Behavior                                                       |
| -------------------- | -------------------------------------- | -------------------------------------------------------------- |
| **EXPAND**           | Greenfield, exploring possibilities    | Dream big, propose expansions, opt-in ceremony per addition    |
| **SELECTIVE EXPAND** | Have a plan, open to cherry-picking    | Hold core scope + present expansion options individually       |
| **HOLD** (default)   | Clear requirements, execute with rigor | Maximum scrutiny on current plan, no scope additions           |
| **REDUCE**           | Tight deadline, MVP focus              | Strip to essentials, flag everything non-critical for deferral |

If the user does not specify, default to **HOLD**. Ask only if the feature description is ambiguous.

## Process

Each step is defined in a separate stage file. **Read the stage file when you reach that step** — do not load all stages upfront.

### Pre-Flight: Board Auto-Setup (MANDATORY)

Before starting any step, **run the preflight script**. This is a single command, not optional:

```bash
.claude/scripts/board-preflight.sh
```

This script is idempotent — if the board already exists, it exits immediately. If not, it:

1. Copies `board.sh` to `scripts/` if missing
2. Detects the repo owner from the git remote
3. Creates a GitHub Projects v2 board via `board.sh init` (which attempts to **clone from a canonical org template** before falling back to from-scratch creation)
4. Commits `scripts/board.sh` and `.github/board.json`

If the script fails with an auth error, tell the user to run `! gh auth login` before continuing.

**Do not skip this step. Do not inline the logic. Just run the script.**

#### If the Preflight Fails

The preflight script prints a reference to `docs/operations/BOARD_TEMPLATE_RUNBOOK.md` with a specific failure mode (FM-1 through FM-11) on every error path. When this happens:

1. **Read the matching failure mode** in the runbook. It documents every known failure with a diagnosis command and an exact recovery procedure.
2. **Apply the recovery** before retrying the preflight. Do not retry blindly — the runbook tells you whether the fix is a token refresh, a `--no-template` override, a stale-cache clear, or a template re-creation.
3. **If the failure mode is not documented**, read §8 of the runbook (Failure Modes & Recovery) end-to-end, then fall back to §9.6 (Throwaway test procedure) to reproduce the issue on a disposable repo before attempting further recovery on the user's repo.
4. **Never delete `.github/board.json` as a first recovery step** — it is the only pointer to the board. Use §9.3 (Re-init an existing repo) if a reset is needed.

The runbook is the single source of truth for template-clone behavior, GraphQL constraints, and what `copyProjectV2` does and does not preserve. Read §7 (What Gets Inherited) before telling the user a board is "missing" something — Sprint fields, views, and workflow enabled-state are only inherited from templates, not created from scratch.

### Pre-Flight: Untracked Baseline Capture (MANDATORY)

Immediately after board preflight (and before Step 0), snapshot the current untracked file set. This is the anchor the Step 5 ship gate uses to distinguish pre-existing dirt from files the run itself introduces.

```bash
SLUG="<feature-slug>"  # same slug used for the spec file
mkdir -p .claude/state

# Ensure baseline/retro patterns are gitignored (idempotent — sync scripts don't touch .gitignore)
if ! grep -q "plan-w-team-untracked-baseline-" .gitignore 2>/dev/null; then
  printf '\n.claude/state/plan-w-team-untracked-baseline-*.txt\n.claude/state/plan-w-team-retro-*.json\n' >> .gitignore
  echo "✓ added /plan-w-team state patterns to .gitignore"
fi

git ls-files --others --exclude-standard | sort \
  > .claude/state/plan-w-team-untracked-baseline-"$SLUG".txt
```

**Why this runs here, not later**: Capturing at preflight is the only point that reliably excludes pre-existing dirt. Any later capture would miss Step 0-4 artifacts as "new" and force unnecessary classification prompts, or (worse) misclassify the feature's own spec file as pre-existing.

**Why this file lives under `.claude/state/`**: The baseline/retro patterns are gitignored (the preflight adds them if missing), the directory survives compaction, and the file is keyed by `<slug>` so parallel `/plan-w-team` runs on different features never collide.

The baseline is consumed by Step 5 (Ship) and deleted by Step 8 (Retro) on successful completion. Failed runs leave it intact so `--resume` can read it.

Full decision matrix, IGNORE pattern guidance, DISCARD value-carrier guard, and worked examples live in `.claude/commands/plan-w-team/shared/untracked-hygiene.md`. Read that file when you reach Step 5 — do not load it here.

### Step 0: Scope Challenge

Read `.claude/commands/plan-w-team/00-scope-challenge.md` and execute it.
Challenge the premise before writing any spec. Can kill bad ideas early.

### Step 1: Generate Specification

Read `.claude/commands/plan-w-team/01-specification.md` and execute it.
Create a persistent spec at `docs/specs/<feature-name>.md` with requirements, technical design, error maps, shadow paths, and test plan.

### Step 2: Create Task Breakdown

Read `.claude/commands/plan-w-team/02-task-breakdown.md` and execute it.
Decompose by feature into tasks with metadata, dependencies, scope tags, and bisectable ordering.

### Step 3-4: Choose Strategy & Execute

Read `.claude/commands/plan-w-team/03-execute.md` and execute it.
Select execution strategy, spawn parallel builders with worktree isolation, monitor progress, merge in bisectable order.

### Step 5: Fix-First Review

Read `.claude/commands/plan-w-team/04-fix-first-review.md` and execute it.
Two-pass review (CRITICAL blockers + INFORMATIONAL items). Auto-fix mechanical issues, batch ASK items for user.

### Step 6: Ship

Read `.claude/commands/plan-w-team/05-ship.md` and execute it.
Test suite, coverage audit, version bump, CHANGELOG, bisectable commits, push/PR.

### Step 7: Post-Ship Documentation

Read `.claude/commands/plan-w-team/06-post-ship.md` and execute it.
Documentation audit, cross-doc consistency, TODOS cleanup, deferred items check.

### Step 8: Retro

Read `.claude/commands/plan-w-team/07-retro.md` and execute it.
Quantitative retrospective with metrics, quality signals, streak tracking, self-assessment.

## Flag Routing

| Flag          | Steps Executed                              | Notes                                  |
| ------------- | ------------------------------------------- | -------------------------------------- |
| (none)        | 0 -> 1 -> 2 -> 3-4 -> 5 -> 6 -> 7 -> 8      | Full lifecycle                         |
| `--resume`    | 3-4 (with resume logic) -> 5 -> 6 -> 7 -> 8 | Read 03-execute.md, use Resume section |
| `--ship-only` | 5 -> 6 -> 7 -> 8                            | Assumes code is already implemented    |
| `--retro`     | 8 only                                      | Retro on recent shipped work           |

## Model Strategy (ACTIVE)

Split model tiers by cognitive demand to conserve daily allowance. Builder agents consume ~80% of total tokens but need execution speed, not deep reasoning. Reserve the newest model generation for roles where reasoning quality directly affects outcomes.

| Role               | Tier  | Pinned Model      | Agent Definition                               | Rationale                                      |
| ------------------ | ----- | ----------------- | ---------------------------------------------- | ---------------------------------------------- |
| Lead (you)         | Brain | Opus 4.7 (alias)  | invoking session default                       | Orchestration, judgment calls, scope decisions |
| Evaluator          | Brain | `claude-opus-4-7` | `.claude/agents/team/evaluator.md` frontmatter | Independent quality assessment                 |
| Fix-First Reviewer | Brain | `claude-opus-4-7` | lead-invoked Pass 1/2 review                   | Security review, one-way door scrutiny         |
| Validator          | Brain | `claude-opus-4-7` | `.claude/agents/team/validator.md` frontmatter | Security-critical read-only review             |
| Builder agents     | Hands | `claude-opus-4-6` | `.claude/agents/team/builder.md` frontmatter   | Implementation, file edits, test writing       |
| Ship pipeline      | Lead  | lead session      | lead-invoked mechanical steps                  | Version bump, changelog, push (~5% of tokens)  |
| Retro              | Lead  | lead session      | lead-invoked metrics phase                     | Metrics collection, streak tracking (minor)    |

### How tier pinning works (IMPORTANT — read before editing Agent calls)

The Agent tool's `model` parameter **only accepts the aliases `opus` / `sonnet` / `haiku`**. It does NOT accept full model IDs like `claude-opus-4-7`. Passing a full ID will fail the tool's input validation.

To pin a specific generation (4.7 vs 4.6):

1. **Set the full model ID in the agent-definition frontmatter** (e.g., `model: claude-opus-4-7` in `.claude/agents/team/evaluator.md`).
2. **Do NOT set `model:` in the Agent tool call** — if you do, the alias will override the frontmatter pin and defeat the tier split.
3. For mechanical work done directly by the lead (ship, retro), no pinning is needed — the lead's session model is used. These phases are short (~5% of total tokens combined), so running them on the lead's Brain-tier model is not a meaningful cost concern. If you want to force Hands-tier for ship/retro, delegate to a `builder`-type subagent for the mechanical steps.

When a new model generation ships:

- Update Brain-tier frontmatter pins to the new generation (e.g., `claude-opus-4-7` → `claude-opus-4-8`).
- Demote the previous Brain model to the Hands tier (e.g., update `builder.md` to `claude-opus-4-7`).

### Boris Cherny's Opus 4.7 Practices

Lead and Brain-tier agents follow the patterns in `shared/opus-4-7-practices.md`:

- **Front-load task specification** — give the full task shape upfront (intent, constraints, AC, files).
- **Adaptive thinking** — guide intent ("think carefully" / "respond quickly"), don't fix a token budget.
- **Deliberate subagent spawning** — 4.7 is judicious; state "spawn N parallel builders" explicitly when parallelism is wanted.
- **Auto mode + completion hooks** — let runs proceed without polling; rely on desktop notifications.
- **Default effort: high** — drop to medium/low only for narrow cost/latency-sensitive tasks.
- **Delegate outcomes, not instructions** — Opus 4.7 is a capable engineer, not a line-by-line pair.

Read `shared/opus-4-7-practices.md` at the start of any Brain-tier stage (Step 0/1/5).

## Worktree Isolation

Each builder runs in its own git worktree, providing a complete isolated copy of the repository:

- **No file conflicts**: Builders can modify any file without coordinating exclusive ownership
- **Full repo access**: Every builder sees the complete codebase
- **Branch-per-builder**: Each worktree has its own branch for commits
- **Merge at end**: When builders complete, their worktree branches are merged to main via standard git merge in bisectable order
- **Conflict resolution**: Git handles most merges automatically. The lead resolves any git merge conflicts after all builders finish.

This replaces the old file assignment protocol. There is no need for `assigned_files` metadata or exclusive file ownership.

## Session Awareness

When 3+ concurrent `/plan-w-team` sessions are detected (check for multiple active teams via TaskList), enable **re-grounding mode**: every question to the user includes:

- Project name and branch
- Which step we are in
- What was just completed
- What decision is needed

This prevents context confusion when running parallel planning sessions.

## Shared Resources

Stage files reference these shared components on-demand (only loaded when needed by the stage):

| Shared File                      | Used By                                  | Content                                                                                                         |
| -------------------------------- | ---------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `shared/self-regulation.md`      | 03-execute                               | WTF-likelihood, fix caps, commits                                                                               |
| `shared/cognitive-frameworks.md` | 00-scope, 01-spec, 05-ship               | Named frameworks reference                                                                                      |
| `shared/artifact-storage.md`     | 05-ship, 07-retro                        | SLUG, paths, formats                                                                                            |
| `shared/browser-qa.md`           | 04-review, 05-ship                       | Playwright MCP + browse binary QA                                                                               |
| `shared/board-integration.md`    | All stages (01-07)                       | GitHub Issues board sync, fire-and-forget                                                                       |
| `shared/opus-4-7-practices.md`   | 00-scope, 01-spec, 03-execute, 04-review | Cherny's Opus 4.7 patterns — front-load, adaptive thinking, deliberate subagents                                |
| `shared/state-artifacts.md`      | 04-review (enforcing), 07-retro (metric) | Authoritative registry of `.claude/state/plan-w-team-*` artifacts — checked by `plan-w-team-symmetry-check.sh`  |
| `shared/shell-safety.md`         | all stage-file authors                   | Shell injection primer — safe/unsafe patterns, assert helpers                                                   |
| `shared/secret-safety.md`        | 05-ship (§6a-ter), pre-commit, sync      | Secret-leak defense-in-depth: pattern catalog, placeholder rules, how to add a pattern, history-rewrite runbook |

All shared files are at `.claude/commands/plan-w-team/shared/`.

## Example

```
/plan-w-team Add alerting system with email and in-app notifications

> Step 0: Scope Challenge
>   Premise: passes "regret in 10 years" test. Leverage existing notification_service.ts.
>   Dream state: CURRENT (in-app only) -> THIS PLAN (email + in-app) -> IDEAL (multi-channel)
>   Complexity: 6 files, 1 new service — passes smell check
>   Door labels: DB schema = one-way door. Taste calibration: auth_service.ts (good), legacy_mailer.ts (bad)
>   -> PROCEED with HOLD scope mode
>
> Step 1: Spec -> docs/specs/alerting-system.md (Error Map, Shadow Paths, State Matrix, Diagrams, Test Plan)
>
> Step 2: Tasks (5 total, unassigned, with metadata, bisectable ordering)
>   1. Alert rule engine (BACKEND, high, two-way) | human ~4h, AI ~20min
>   2. notification_preferences schema (DATABASE, one-way, blockedBy: [1])
>   3. Email channel (BACKEND, medium, blockedBy: [1])
>   4. In-app channel (FRONTEND, medium, blockedBy: [1])
>   5. Integration (high, blockedBy: [2,3,4])
>
> Step 3-4: Parallel builders, auto mode, worktree isolation
>   Pre-flight: clean tree, base fetched. TeamCreate -> 2 builders -> self-claim loop -> merge
>
> Step 5: Fix-First Review
>   Pass 1 CRITICAL: 0 issues. Pass 2: 3 auto-fixed (unused imports, stale comment)
>   Design Review Lite (task 4 FRONTEND): clean, no AI slop
>
> Step 6: Ship
>   47/47 tests passing. Coverage: 82% lines. Version: 1.3.0 -> 1.4.0 (MINOR)
>   CHANGELOG: "You can now receive alerts via email in addition to in-app notifications"
>
> Step 7: Post-Ship Docs (README updated, ARCHITECTURE diagram updated, 1 stale TODO flagged)
>
> Step 8: Retro (18 commits, 847 lines, fix ratio 11%, streak: 4 features, self-assessment: 9/10)
```

## Notes

- Specs are saved for future reference and can be used across sessions
- The validator is optional — use for security-critical or compliance tasks
- Builder must address all validator findings before proceeding
- Task metadata persists at `~/.claude/tasks/` for cross-session resumption
- Use `/btw` during execution for side-channel queries that don't interrupt the current task flow
- Use `/loop` or CronCreate for automated progress monitoring instead of manually polling TaskList
- For simple parallel changes (same pattern across files), prefer `/batch` over `/plan-w-team`
- Steps 6-8 can be run independently with `--ship-only` or `--retro` flags
- The self-assessment in Step 8 is a feedback loop — patterns that score below 8 should be investigated and the workflow updated
- All artifacts are stored under `~/.claude/plan-w-team/projects/<SLUG>/` for cross-session persistence
- Browser QA requires gstack's browse binary — install once, benefits all projects
