# Board System Operations Guide

> **Last Updated:** 2026-04-10 **Script:** `scripts/board.sh` **Skill:**
> `/board` **Config:** `.github/board.json` **Spec:**
> `docs/specs/github-projects-board.md`,
> `docs/specs/template-based-board-bootstrap.md`

## What This Is

A GitHub Projects v2 integration that gives every feature a traceable lifecycle
— from spec to retro. Cards are GitHub Issues (not drafts), so you get PR
auto-linking, comment timelines, cross-references, and search for free.

The system is **multi-repo portable**: same `board.sh`, same `/board` skill,
same `/plan-w-team` pipeline work in any repo across any org. Each repo has its
own `.github/board.json` pointing to its board.

---

## Quick Start (5 Minutes)

### Automatic (via /plan-w-team)

Just run `/plan-w-team` in any repo. If no board exists, it auto-creates one:

1. Copies `board.sh` from `.claude/scripts/board.sh` to `scripts/board.sh`
2. Detects the GitHub org/user from the git remote
3. Runs `board.sh init` to create the board with standard field schema
4. Commits `scripts/board.sh` and `.github/board.json`

**Only prerequisite:** `gh` CLI authenticated (`gh auth status`).

### Manual Setup

#### Prerequisites

- `gh` CLI installed and authenticated (`gh auth status`)
- PAT with `project` scope (for board mutations beyond what `gh auth` provides)

#### If a board already exists (joining an existing repo)

```bash
# 1. Verify config exists
cat .github/board.json

# 2. Sync the local cache (downloads field/option IDs from GitHub)
scripts/board.sh sync

# 3. List cards to verify it works
scripts/board.sh list
```

#### If starting fresh (new project, new board)

```bash
# 1. Create a board on your org (or user account)
scripts/board.sh init --owner my-org --title "My Project Board"
# For personal projects:
scripts/board.sh init --owner @me --title "My Project Board"

# 2. Verify
scripts/board.sh list
```

That's it. `/board` and `/plan-w-team` are now wired up.

---

## Daily Usage

### Add a card

```bash
scripts/board.sh add "Fix login timeout" \
  --priority P0 --area web --type bug --size S \
  --body "Users see timeout after 30s on slow connections"
```

All flags are optional. Defaults to Backlog status.

### Move a card

```bash
scripts/board.sh move "Fix login timeout" "In Progress"
scripts/board.sh move "#42" "Done"
```

### Comment on a card

```bash
scripts/board.sh comment "#42" "## Update\nFixed the timeout. PR incoming."
```

### View card details

```bash
scripts/board.sh view "#42"
```

Shows full issue body, comments, linked PRs, and field values.

### List and filter

```bash
scripts/board.sh list                          # All non-archived cards
scripts/board.sh list "In Progress"            # By status
scripts/board.sh list --area api               # By swim lane
scripts/board.sh list --priority P0            # By priority
scripts/board.sh list "Todo" --area web        # Combined
```

### Search

```bash
scripts/board.sh search "email"
```

### Close

```bash
scripts/board.sh close "#42"                   # Completed
scripts/board.sh close "#42" not_planned       # Won't fix
```

### Backlog review

```bash
scripts/board.sh backlog                       # All backlog items
scripts/board.sh backlog --area mobile         # Filtered
```

---

## How It Works with /plan-w-team

Every `/plan-w-team` run automatically manages a board card through the full
pipeline. You don't need to touch `/board` manually during feature development.

```
Step 0: Scope Challenge     →  No board action (too early)
Step 1: Specification       →  add card + move to Todo
Step 2: Task Breakdown      →  comment with task checklist
Steps 3-4: Execute          →  move to In Progress + comment
Step 5: Fix-First Review    →  move to Review + comment with findings
Step 6: Ship                →  move to Done + comment with PR link
Step 7: Post-Ship Docs      →  comment with doc updates
Step 8: Retro               →  comment with retrospective
```

The card becomes a permanent record of the feature's entire history — every
decision, every review finding, every lesson learned.

### PR Auto-Linking

Step 6 creates the PR with `Closes #N` in the body. This creates a bidirectional
link between the PR and the Issue. When the PR merges:

1. GitHub closes the Issue automatically
2. A board workflow moves the card to Done
3. The card shows the merged PR inline

---

## Field Schema

Every card has these fields set at creation time:

| Field    | Values                                                      |
| -------- | ----------------------------------------------------------- |
| Status   | Backlog, Todo, In Progress, Blocked, Review, Done, Archived |
| Priority | P0 (critical), P1 (high), P2 (medium), P3 (low)             |
| Area     | api, web, admin, website, mobile, db, shared, infra, docs   |
| Type     | feature, bug, chore, infra                                  |
| Size     | S (<2h), M (2-8h), L (8-24h), XL (24h+)                     |

---

## Multi-Repo Setup

### Architecture

```
org-a (org)                      org-b (org)
+----------------------+         +----------------------+
| Org A Board          |         | Org B Board          |
|  .github/board.json: |         |  .github/board.json: |
|  project_number: 1   |         |  project_number: 1   |
|  owner: "org-a"      |         |  owner: "org-b"      |
|                      |         |                      |
| Same board.sh        |         | Same board.sh        |
| Same /plan-w-team    |         | Same /plan-w-team    |
| Same field schema    |         | Same field schema    |
+----------------------+         +----------------------+
```

Boards are completely isolated — different orgs, different access, different
data. The only shared thing is the tooling and field schema.

### Per-Repo Config: `.github/board.json`

```json
{
  "project_number": 1,
  "owner": "@me",
  "owner_type": "user",
  "schema_version": 1,
  "fields": {
    "Status": [
      "Backlog",
      "Todo",
      "In Progress",
      "Blocked",
      "Review",
      "Done",
      "Archived"
    ],
    "Priority": ["P0", "P1", "P2", "P3"],
    "Area": [
      "api",
      "web",
      "admin",
      "website",
      "mobile",
      "db",
      "shared",
      "infra",
      "docs"
    ],
    "Type": ["feature", "bug", "chore", "infra"],
    "Size": ["S", "M", "L", "XL"]
  }
}
```

| Field            | Description                                                     |
| ---------------- | --------------------------------------------------------------- |
| `project_number` | The GitHub Projects v2 number (visible in the project URL)      |
| `owner`          | Org name or `@me` for user-level projects                       |
| `owner_type`     | `user` or `organization` — determines which API endpoint to use |
| `schema_version` | Schema version for forward compatibility (currently `1`)        |
| `fields`         | Canonical field schema with allowed values per field            |

This file is **committed to git** so every developer and agent gets it.

### Adding a New Repo to an Existing Board

1. Copy `.github/board.json` from a repo that already points to the board
2. Copy `scripts/board.sh` to the new repo
3. Run `scripts/board.sh sync` to populate the local cache
4. Done — `/plan-w-team` and `/board` work immediately

### Creating a New Board for a New Org

```bash
# Creates project, custom fields, status options, writes board.json
scripts/board.sh init --owner my-org --title "My Org Development"

# Or clone schema from the current repo's board
scripts/board.sh clone-schema --to-owner my-org --title "My Org Board"
```

If an **org template** is discoverable (see the [Template-Clone Bootstrap](#template-clone-bootstrap) section below), `init` automatically clones it — you get views, workflows, Sprint field, and status descriptions for free. Otherwise, `init` falls back to from-scratch creation with no views and no workflows enabled, and you must configure them manually:

1. Go to **Project Settings > Workflows**
2. Enable: **"Item closed"** -> Set Status to "Done"
3. Enable: **"Pull request merged"** -> Set Status to "Done"

To skip template discovery on a particular run, pass `--no-template`.

---

## Template-Clone Bootstrap

New repos created via `/plan-w-team` auto-detect a canonical **org template** and clone it via GitHub's `copyProjectV2` mutation. The clone inherits:

- **Views** — Kanban Board and Table views, with swimlanes, grouping, and sorts preserved
- **Workflows** — all 7 default workflows, with the same enabled state as the template (Item closed, Pull request merged, Auto-add sub-issues, Auto-archive items)
- **Custom fields** — Priority, Area, Type, Size, Sprint (iteration field) with every option
- **Status descriptions** — the per-status helper text visible in the GitHub UI

From-scratch creation can never match a hand-configured template because GitHub's GraphQL API has no `createProjectV2View`, `createProjectV2Workflow`, or `enableProjectV2Workflow` mutations. The only way to get a fully-configured board is to clone one.

### Hard Constraint: Templates Must Live in an Organization

This is not obvious from the schema docs. GitHub rejects `markProjectV2AsTemplate` on user-owned projects with:

```
UNPROCESSABLE: Only projects owned by an Organization can be marked as a template.
```

However, **cross-owner copy is permitted**: an org-owned template can be cloned into a user account (`@me`) and the clone will have all views/workflows/fields intact. This drives a two-tier ownership pattern:

1. The canonical template lives in an organization the user controls (e.g., `cleanscale-io`).
2. Repos under user accounts discover that template by enumerating the user's org memberships (`gh api user/orgs`) and querying each org for `template: true` projects.
3. `copyProjectV2` is invoked with `projectId = <org template>` and `ownerId = <target owner>`. The result lands in the target owner's account regardless of where the template lives.

### Discovery Chain

When `board.sh init --owner <target>` runs:

| Target type       | Discovery behavior                                                                                        |
| ----------------- | --------------------------------------------------------------------------------------------------------- |
| `organization`    | Queries the target org directly for `projectsV2 { template }`. First template wins.                       |
| `user` or `@me`   | Enumerates the user's org memberships via `gh api user/orgs`, queries each org for templates. First wins. |
| No template found | Falls through to from-scratch creation (5 custom fields, status options, no views/workflows).             |

Template discovery failures (auth errors, network errors) degrade gracefully — `init` falls through to from-scratch with a warning. No GraphQL stack traces leak to the user.

### One-Time Setup: Promoting the Canonical Template

```bash
# 1. Create a new board in an org you control (or clone an existing well-configured one)
scripts/board.sh init --owner my-org --title "Standard Repo Template"

# 2. Configure it in the GitHub UI:
#    - Add Kanban Board view with swimlanes by Area
#    - Add Table view with all custom fields
#    - Enable workflows: Item closed → Done, Pull request merged → Done
#    - Add Sprint (iteration) field if using sprint planning
#    - Add helpful descriptions to each Status option

# 3. Promote it as a template
scripts/board.sh template-promote <project-number> --owner my-org

# 4. Done. Every future `board.sh init` (in any repo, under any owner you control)
#    will discover and clone this template.
```

**Idempotent:** If the project is already a template, `template-promote` prints `already a template` and exits 0.

**Rejection on user-owned targets:** Running `template-promote` with `--owner @me` (or any user) fails with a clear explanation of the org-only constraint and a recommended workflow to create an org template instead.

### Updating the Template

Clones are **one-shot** — they do not auto-update when the template changes. If you improve the canonical template (add a view, enable a new workflow), existing boards keep their old configuration. Only newly created boards inherit the improvements.

Re-sync is not currently automated. Options for propagating template updates to existing boards:

1. **Manual replication** — open each board in the GitHub UI and replicate the changes.
2. **Rebuild the board** — delete the existing project and re-run `board.sh init` (destructive; loses all cards).
3. **Future work** — a `board.sh template-sync` subcommand to diff template against existing board and apply deltas. See the Deferred Items section of `docs/specs/template-based-board-bootstrap.md`.

### Fallback: From-Scratch Path

If no template is discoverable (no org memberships, no templates in any org, or template lookup failed), `init` creates the board from scratch with:

- 6 custom fields: Status, Priority, Area, Type, Size, Sprint (empty iteration field)
- All single-select options with descriptions
- **No views** (you'll get GitHub's default view only)
- **6 default workflows**, none enabled

For user-owned targets, the post-init message recommends creating an org template first (since `template-promote` cannot mark user-owned projects). For org targets, it suggests running `template-promote` on the new board after configuring views/workflows in the UI.

### Verifying a Clone Worked

```bash
# Check the clone has inherited views, workflows, and fields
gh api graphql -f query='
  query {
    viewer {
      projectV2(number: <your-project-number>) {
        title
        views(first: 10) { totalCount nodes { name } }
        workflows(first: 20) { totalCount nodes { name enabled } }
        fields(first: 20) { totalCount nodes { ... on ProjectV2FieldCommon { name } } }
      }
    }
  }'
```

A successful clone has `views.totalCount >= 2`, `workflows.totalCount == 7` (with 3-4 enabled), and all 6 custom fields plus Status.

---

### Auto-Enrollment (GitHub Actions)

`.github/workflows/board-auto-add.yml` auto-adds new issues and PRs to the board
using the first-party `actions/add-to-project` action.

**Setup per repo:**

1. Create a PAT (classic) with `project` scope
2. Add as repository or org secret: `BOARD_TOKEN`
3. Set repository variable `BOARD_PROJECT_URL` to the project URL:
   - User: `https://github.com/users/USERNAME/projects/N`
   - Org: `https://github.com/orgs/ORG-NAME/projects/N`

The workflow only runs if `BOARD_PROJECT_URL` is set, so it's safe to have in
repos that haven't configured a board yet.

---

## File Layout

| File                                                       | Purpose                                   | Committed  |
| ---------------------------------------------------------- | ----------------------------------------- | ---------- |
| `scripts/board.sh`                                         | CLI tool — all board operations           | Yes        |
| `.github/board.json`                                       | Per-repo board config (project, owner)    | Yes        |
| `.github/workflows/board-auto-add.yml`                     | Auto-add issues/PRs to board              | Yes        |
| `.claude/commands/board.md`                                | `/board` skill definition for Claude Code | Yes        |
| `.claude/commands/plan-w-team/shared/board-integration.md` | Pipeline integration docs                 | Yes        |
| `.claude/state/board-config.json`                          | Cached field/option IDs from GitHub       | No (local) |

---

## How Identifiers Are Resolved

`board.sh` resolves card identifiers in this order:

1. **`#42`** or **`42`** — direct issue number lookup
2. **`PVTI_xxxxx`** — direct project item ID (internal)
3. **`"feature name"`** — title substring search across all project items

Title-based resolution searches all items on the board and matches the first
item whose title contains the search string (case-insensitive). Use issue
numbers when possible for precision.

---

## Troubleshooting

### "No board config found"

```
BOARD ERROR: No board config found at .github/board.json
```

The repo doesn't have a board configured yet. Either:

- Copy `.github/board.json` from another repo that has it
- Run `scripts/board.sh init --owner <org-or-@me> --title "Title"` to create a
  new board

### "Could not resolve field IDs"

```
BOARD ERROR: Could not resolve field/option IDs
```

The local cache is stale or missing. Fix:

```bash
scripts/board.sh sync
```

This re-fetches all field and option IDs from GitHub and writes them to
`.claude/state/board-config.json`.

### Cache is stale after editing the board in GitHub UI

If you add, remove, or rename columns/fields in the GitHub Projects UI, the
cached IDs become invalid. Fix:

```bash
scripts/board.sh sync
```

### Title-based lookup returns wrong card

If multiple cards have similar titles, the substring search may match the wrong
one. Use the issue number instead:

```bash
# Instead of:
scripts/board.sh move "Fix login" "Done"

# Use:
scripts/board.sh move "#42" "Done"
```

### GitHub API rate limiting

If you see 403 or rate limit errors, wait a few minutes and retry. The GitHub
GraphQL API has a 5,000 points/hour budget. Each board operation uses 1-3
points, so you'd need to run ~2,000 operations/hour to hit the limit.

### "gh: not logged in"

```bash
gh auth login
gh auth status  # Verify
```

### Board operations fail but pipeline continues

This is by design. All `/plan-w-team` board calls use the **fire-and-forget
pattern** (`|| true`). If the board is down or the API fails, the pipeline
continues. The board is for visibility — it's not in the critical path.

### Cache file location

The cache lives at `.claude/state/board-config.json`. It contains field IDs and
option value mappings fetched from GitHub. This file is:

- **Local only** (gitignored) — each developer/machine has its own cache
- **Auto-created** by `sync` or on first board operation
- **Safe to delete** — just run `sync` again to regenerate

### init fails with "could not resolve org type"

The `init` command auto-detects whether the owner is a user or org by calling
`gh api "orgs/$owner"`. If this fails:

- Ensure `gh` is authenticated
- For personal projects, use `--owner @me` (always resolves to user type)
- For orgs, ensure you have admin access to the org

---

## Business Isolation

Boards are scoped per-org or per-user. Different orgs get different boards with
different access controls. The tooling and field schema are identical everywhere
— learn once, use in every repo.

| Scope        | Board Location     | Access      | Repos          |
| ------------ | ------------------ | ----------- | -------------- |
| Organization | Org-level project  | Org members | All org repos  |
| Personal     | User-level project | You only    | Personal repos |

---

## Reference

### Full help

```bash
scripts/board.sh help
```

### Related documentation

| Document                                                   | Purpose                        |
| ---------------------------------------------------------- | ------------------------------ |
| `.claude/commands/board.md`                                | `/board` skill API reference   |
| `.claude/commands/plan-w-team/shared/board-integration.md` | Pipeline integration details   |
| `docs/specs/github-projects-board.md`                      | Original feature specification |
