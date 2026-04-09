# Board Integration — GitHub Issues + /plan-w-team Pipeline

> **Last Updated:** 2026-04-09
> **Script:** `scripts/board.sh`
> **Skill:** `/board`
> **Board:** GitHub Projects v2, Project #1

## Auto-Setup

`/plan-w-team` automatically creates a board if one doesn't exist. This runs as a pre-flight before Step 0:

1. If `scripts/board.sh` is missing → copies from `.claude/scripts/board.sh`
2. If `.github/board.json` is missing → detects org/user from git remote, runs `board.sh init`
3. Commits `scripts/board.sh` and `.github/board.json` so the board persists

**No manual setup required.** The first `/plan-w-team` run in any repo creates the board automatically.

Prerequisites: `gh` CLI authenticated (`gh auth status`). If not, the user is prompted to run `! gh auth login`.

## Overview

Every feature managed by `/plan-w-team` gets a **GitHub Issue** on the project board. This Issue serves as the single source of truth for the feature's lifecycle — from spec to retro. Each pipeline stage adds structured comments that create a permanent timeline, and PRs are auto-linked via GitHub's `Closes #N` keyword.

### Why Issues (not Draft Items)

Draft items are lightweight but invisible to GitHub's core features. Issues unlock:

- **PR auto-linking** — `Closes #42` in a PR description creates a bidirectional link
- **Auto-close on merge** — merged PR closes the Issue, board workflow moves to Done
- **Comment timeline** — each pipeline stage adds a comment, creating a full audit trail
- **Cross-reference** — commits mentioning `#42` appear on the Issue automatically
- **Searchable** — Issues appear in repo search, filters, and GitHub's global search
- **Assignable** — can assign team members as the team grows
- **Labelable** — can add labels for additional categorization

## Full Pipeline Flow

```
/plan-w-team "<feature>"
      │
      ▼
┌─────────────────────────────────────────────────────┐
│ Step 0: Scope Challenge                             │
│   No board action (too early — feature may be       │
│   scrapped at this stage)                           │
└──────────────────────┬──────────────────────────────┘
                       │ Proceed
                       ▼
┌─────────────────────────────────────────────────────┐
│ Step 1: Specification                               │
│                                                     │
│   board.sh add "<feature>" \                        │
│     --priority P1 --area api --type feature \       │
│     --size M --body "<spec summary + AC>"           │
│                                                     │
│   board.sh move "<feature>" "Todo"                  │
│                                                     │
│   → Creates Issue #N with rich body                 │
│   → Store #N in spec: <!-- Board: #42 -->           │
│   → Card appears in Backlog → Todo                  │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│ Step 2: Task Breakdown                              │
│                                                     │
│   board.sh comment "<feature>" "## Task Breakdown   │
│   - [ ] T1: Shared types                            │
│   - [ ] T2: API endpoints                           │
│   - [ ] T3: Frontend components                     │
│   - [ ] T4: Tests                                   │
│   Strategy: parallel builders, 3 agents"            │
│                                                     │
│   → Comment added to Issue #N                       │
│   → Future devs see how work was decomposed         │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│ Steps 3-4: Execute                                  │
│                                                     │
│   board.sh move "<feature>" "In Progress"           │
│   board.sh comment "<feature>" "## Execution        │
│   Branch: feat/my-feature                           │
│   Tasks: 4, Strategy: parallel builders             │
│   Started: 2026-04-09T19:00:00Z"                    │
│                                                     │
│   → Card moves to In Progress column                │
│   → You can see active work at a glance             │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│ Step 5: Fix-First Review                            │
│                                                     │
│   board.sh move "<feature>" "Review"                │
│   board.sh comment "<feature>" "## Review           │
│   Pass 1 Critical: None                             │
│   Pass 2 Info: 2 items (dead code, stale comment)   │
│   Auto-Fixed: 2 items                               │
│   Evaluator: PASS"                                  │
│                                                     │
│   → Card moves to Review column                     │
│   → Review findings permanently recorded            │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│ Step 6: Ship                                        │
│                                                     │
│   gh pr create --body "... Closes #42 ..."          │
│                                                     │
│   board.sh move "<feature>" "Done"                  │
│   board.sh comment "<feature>" "## Shipped          │
│   PR: https://github.com/.../pull/55                │
│   Tests: 340+ passing, ★★★                          │
│   Commits: 5 bisectable"                            │
│                                                     │
│   → PR linked to Issue (bidirectional)              │
│   → When PR merges: Issue auto-closes               │
│   → Board workflow: closed → Done (automatic)       │
│   → Card shows PR status inline                     │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│ Step 7: Post-Ship Documentation                     │
│                                                     │
│   board.sh comment "<feature>" "## Post-Ship        │
│   Docs updated: README, ARCHITECTURE, SDD           │
│   Cross-doc consistency: verified                   │
│   Deferred items: 1 remaining"                      │
│                                                     │
│   → Documentation changes recorded                  │
└──────────────────────┬──────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────┐
│ Step 8: Retro                                       │
│                                                     │
│   board.sh comment "<feature>" "## Retrospective    │
│   Commits: 18 | Lines: +847 / -23                   │
│   Sessions: 3 (2 deep, 1 medium)                    │
│   Self-assessment: 9/10                              │
│   What went well: Clean parallel execution           │
│   What to improve: Spec missed edge case"            │
│                                                     │
│   → Final comment closes the feature story          │
│   → Card is now a complete historical record        │
└─────────────────────────────────────────────────────┘
```

## File-by-File Wiring

Each `/plan-w-team` stage file has a **Board Integration** or **Board Update** section near the top. These sections contain the exact `board.sh` commands and comment templates that run automatically during that stage.

| Stage              | File                       | Section                  | Board Operations                                                                   |
| ------------------ | -------------------------- | ------------------------ | ---------------------------------------------------------------------------------- |
| Step 1: Spec       | `01-specification.md:158`  | Board Integration (Auto) | `add` → create Issue with body; `move` → Todo; store `<!-- Board: #42 -->` in spec |
| Step 2: Tasks      | `02-task-breakdown.md:129` | Board Integration (Auto) | `comment` → task checklist, strategy, effort estimate, files touched               |
| Steps 3-4: Execute | `03-execute.md:21`         | Board Update (Auto)      | `move` → In Progress; `comment` → strategy, branch, task count, start time         |
| Step 5: Review     | `04-fix-first-review.md:5` | Board Update (Auto)      | `move` → Review; `comment` → Pass 1/2 findings, auto-fix count, evaluator verdict  |
| Step 6: Ship       | `05-ship.md:5`             | Board Update (Auto)      | `move` → Done; `comment` → PR link, tests, coverage, commits, version              |
| Step 6: Ship       | `05-ship.md:87`            | Link PR to Board Issue   | `gh pr create` with `Closes #N` in body for auto-close chain                       |
| Step 7: Post-Ship  | `06-post-ship.md:5`        | Board Comment (Auto)     | `comment` → docs updated, cross-doc consistency, deferred items                    |
| Step 8: Retro      | `07-retro.md:5`            | Board Comment (Auto)     | `comment` → commits, lines, sessions, self-assessment, lessons                     |

### Supporting Files

| File                              | Purpose                                                                                       |
| --------------------------------- | --------------------------------------------------------------------------------------------- |
| `scripts/board.sh`                | CLI tool — all board operations (`add`, `move`, `comment`, `close`, `view`, `list`, `search`) |
| `.claude/commands/board.md`       | `/board` skill definition — argument parsing and usage reference                              |
| `.claude/state/board-config.json` | Cached field/option IDs from GitHub Projects (auto-synced)                                    |

## Board Commands Reference

| Command            | Purpose                       | Used By                |
| ------------------ | ----------------------------- | ---------------------- |
| `board.sh add`     | Create Issue + add to board   | Step 1 (Spec)          |
| `board.sh move`    | Change status column          | Steps 1, 3, 5, 6       |
| `board.sh comment` | Add timeline comment          | Steps 2, 3, 5, 6, 7, 8 |
| `board.sh close`   | Close issue                   | Manual only            |
| `board.sh view`    | Show full issue with comments | Any time               |
| `board.sh list`    | List cards with filters       | Any time               |
| `board.sh search`  | Find cards by keyword         | Any time               |

## Issue Number Propagation

The issue number (`#N`) created in Step 1 must flow through all subsequent stages:

1. **Step 1** creates the issue and captures `#N`
2. **Spec file** stores it: `<!-- Board: #42 -->`
3. **Steps 2-8** reference by title (board.sh resolves title → issue number)
4. **Step 6** uses `Closes #42` in the PR body for auto-linking

### Resolving Issues

`board.sh` resolves identifiers in this order:

1. `#42` or `42` → direct issue number lookup
2. `PVTI_xxxxx` → direct project item ID
3. `"feature name"` → title substring search across all project items

## GitHub Workflows (Auto-Configured)

Two workflows are enabled on the project board:

| Trigger             | Action            | Effect                                     |
| ------------------- | ----------------- | ------------------------------------------ |
| Issue closed        | Set Status → Done | Closing an issue moves its card to Done    |
| Pull request merged | Set Status → Done | Merging a PR moves its linked card to Done |

Combined with `Closes #42` in PR descriptions, this creates a fully automatic chain:
**PR merged → Issue closed → Board card → Done**

## Custom Fields

Every card has these fields set at creation time:

| Field    | Values                                                            | Set By          |
| -------- | ----------------------------------------------------------------- | --------------- |
| Status   | Backlog → Todo → In Progress → Blocked → Review → Done → Archived | Pipeline stages |
| Priority | P0 (critical), P1 (high), P2 (medium), P3 (low)                   | Step 1          |
| Area     | api, web, admin, website, mobile, db, shared, infra, docs         | Step 1          |
| Type     | feature, bug, chore, infra                                        | Step 1          |
| Size     | S (<2h), M (2-8h), L (8-24h), XL (24h+)                           | Step 1          |

## Board Views

| View         | Purpose             | Configuration                         |
| ------------ | ------------------- | ------------------------------------- |
| Kanban Board | Sprint workflow     | Swimlanes by Area, sorted by Priority |
| Table        | Full field overview | All custom fields visible, sortable   |

## Fire-and-Forget Pattern

**Critical rule:** Board operations must NEVER block the pipeline. Every board call uses `|| true`:

```bash
scripts/board.sh move "<feature>" "In Progress" || true
scripts/board.sh comment "<feature>" "Started work" || true
```

If the board is down, the pipeline continues. The board is for visibility and history — it's not in the critical path.

## What This Gives You

### As a Solo Founder

- Visual overview of all work in flight (Kanban board)
- Click any Done card to see the full story from spec to retro
- See which PRs implemented which features
- Track velocity across sprints

### As the Team Grows

- New developers can read Issue timelines to understand past decisions
- Review comments show what was flagged and fixed
- Task breakdown comments show how complex features were decomposed
- Retro comments capture lessons learned
- PR links provide direct code traceability

### vs Azure DevOps Boards

| Feature                      | ADO                   | GitHub Projects v2 + This Integration |
| ---------------------------- | --------------------- | ------------------------------------- |
| Card ↔ PR linking            | Built-in (`AB#123`)   | `Closes #42` in PR body               |
| Auto "In Progress" on branch | Built-in              | `/plan-w-team` Step 3                 |
| Auto "Done" on PR merge      | Built-in              | GitHub workflow (configured)          |
| Comment timeline             | Built-in              | `/plan-w-team` Steps 2-8              |
| Custom fields                | Yes                   | Yes (Priority, Area, Type, Size)      |
| Sprint views                 | Built-in              | Kanban + Table views                  |
| Work item hierarchy          | Epic → Feature → Task | Flat (use labels/grouping)            |
| Spec linkage                 | Wiki/attachments      | Issue body + spec file reference      |
