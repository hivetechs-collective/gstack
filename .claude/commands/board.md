# Board Management

Manage the GitHub Projects v2 development board. All operations go through `scripts/board.sh`.

If `scripts/board.sh` does not exist in this repo, copy it from `.claude/scripts/board.sh` first:

```bash
cp .claude/scripts/board.sh scripts/board.sh && chmod +x scripts/board.sh
```

## Usage

```
/board <subcommand> [args]
```

## Subcommands

### Add a card (creates GitHub Issue)

```
/board add "Title" --priority P1 --area api --type feature --size M --body "description"
```

Creates a **GitHub Issue** and adds it to the board. Defaults to **Backlog** status. All flags are optional.
Returns the issue number (e.g., `#42`) for use in PR linking and comments.

### Move a card

```
/board move "card title or #42" "In Progress"
```

Statuses: `Backlog`, `Todo`, `In Progress`, `Blocked`, `Review`, `Done`, `Archived`

### Comment on a card

```
/board comment "card title or #42" "## Stage Update\nDetails here..."
```

Adds a comment to the GitHub Issue. Used by `/plan-w-team` to build a timeline of work history on each card.

### Close a card

```
/board close "card title or #42"              # Close as completed
/board close "card title or #42" not_planned  # Close as not planned
```

### List cards

```
/board list                          # All non-archived cards
/board list "In Progress"            # Filter by status
/board list --area api               # Filter by swim lane
/board list --priority P0            # Filter by priority
/board list "Todo" --area web        # Combined filters
```

### View card details

```
/board view "card title or #42"
```

Shows full issue details including body, comments, and linked pull requests.

### Show backlog

```
/board backlog                       # All backlog items
/board backlog --area mobile         # Backlog filtered by area
```

### Search cards

```
/board search "email"
```

### Sync cache

```
/board sync
```

Refreshes the cached field/option IDs from GitHub. Run this if you've edited the board columns or fields in the GitHub UI.

### Archive old cards

```
/board archive
```

Lists Done items for review. Move old ones to Archived manually.

### Initialize a new board

```
/board init --owner my-org --title "My Project Board"
/board init --owner @me --title "My Projects"
```

Creates a new GitHub Projects v2 board with the standard field schema (Status, Priority, Area, Type, Size), writes `.github/board.json`, and syncs the cache. Auto-detects whether the owner is an org or user.

### Clone board schema

```
/board clone-schema --to-owner my-org --title "New Board"
```

Creates a new board on the target owner with the same field schema as the current repo's board. Useful for setting up consistent boards across orgs.

## Instructions for Claude

When the user runs `/board`, parse the subcommand and arguments, then execute using the Bash tool:

```bash
scripts/board.sh <subcommand> [args]
```

**Important behaviors:**

1. **Parse arguments carefully**: Quoted strings are single arguments. `--priority P1` is a flag with value.
2. **Show the output directly**: The script produces human-readable tables. Display them as-is.
3. **Handle errors gracefully**: If the script fails, suggest `/board sync` to refresh the cache.
4. **Never block on board failures**: If called from `/plan-w-team`, board errors should be warnings, not blockers.

### Argument Parsing Examples

| User types                                                                | Script call                                                                         |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `/board add "Fix login bug" --priority P0 --area web --type bug --size S` | `scripts/board.sh add "Fix login bug" --priority P0 --area web --type bug --size S` |
| `/board move "Fix login bug" "In Progress"`                               | `scripts/board.sh move "Fix login bug" "In Progress"`                               |
| `/board comment #42 "Started implementation"`                             | `scripts/board.sh comment "#42" "Started implementation"`                           |
| `/board close #42`                                                        | `scripts/board.sh close "#42"`                                                      |
| `/board view #42`                                                         | `scripts/board.sh view "#42"`                                                       |
| `/board list --area api`                                                  | `scripts/board.sh list --area api`                                                  |
| `/board backlog`                                                          | `scripts/board.sh backlog`                                                          |
| `/board init --owner my-org --title "Board"`                              | `scripts/board.sh init --owner my-org --title "Board"`                              |
| `/board clone-schema --to-owner my-org --title "Board"`                   | `scripts/board.sh clone-schema --to-owner my-org --title "Board"`                   |
| `/board` (no args)                                                        | `scripts/board.sh help`                                                             |

### Quick Reference

| Field    | Values                                                      |
| -------- | ----------------------------------------------------------- |
| Status   | Backlog, Todo, In Progress, Blocked, Review, Done, Archived |
| Priority | P0 (critical), P1 (high), P2 (medium), P3 (low)             |
| Size     | S (small), M (medium), L (large), XL (extra large)          |
| Area     | api, web, admin, website, mobile, db, shared, infra, docs   |
| Type     | feature, bug, chore, infra                                  |

### PR Linking

Cards are GitHub Issues, so PRs can reference them:

- Put `Closes #42` in a PR description to auto-close the issue on merge
- The board workflow moves closed issues to Done automatically
- Linked PRs are visible on the card via `/board view #42`

### Multi-Repo Configuration

Board config lives in `.github/board.json` (committed to git). Each repo points to its own board:

```json
{
  "project_number": 1,
  "owner": "@me",
  "owner_type": "user"
}
```

- **Same `board.sh`** works in any repo — reads config from `.github/board.json`
- **Cache** lives in `.claude/state/board-config.json` (local, gitignored)
- **New repos**: copy `board.json` + `board.sh`, run `/board sync`
- **New boards**: run `/board init --owner <org> --title "Title"`

ARGUMENTS: $ARGUMENTS
