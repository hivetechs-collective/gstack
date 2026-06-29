---
name: version-uplift
description: Detect Claude Code CLI version changes, fetch the changelog between the last-seen and current version, and classify each new feature against /plan-w-team integration points (hook events, permission syntax, model IDs, slash commands, lifecycle stages). Produces a markdown + JSON report identifying already-adopted, candidate-for-adoption, not-applicable, and breaking-change-required entries.
---

# Claude Code Version Uplift

## When to use

- After upgrading the Claude Code CLI (`npm install -g @anthropic-ai/claude-code` or equivalent).
- Periodically (e.g., monthly) as a maintenance sweep — re-running with `--force` will regenerate the report.
- Before authoring a `/plan-w-team` improvement — the report enumerates candidate surfaces to adopt.

The skill is **read-only with respect to repo logic**: it does not modify
`CLAUDE.md`, stage files, or hook configs. It only writes:

1. `.claude/state/last-claude-version.json` (persisted version)
2. `docs/operations/version-uplift-reports/<date>-<version>.{md,json}` (report)

Acting on the report is a separate `/plan-w-team` run.

## Invocation

### Default (interactive shell)

```bash
# Run the orchestrator directly:
./.claude/commands/plan-w-team/version-uplift/uplift.sh
```

The script chains:

1. `.claude/scripts/version-uplift/detect-version.sh`
2. `.claude/scripts/version-uplift/fetch-changelog.sh`
3. `.claude/scripts/version-uplift/evaluate-features.sh`

### From this skill (agent-driven)

When invoked via the Skill mechanism, the agent should:

1. Run `./.claude/commands/plan-w-team/version-uplift/uplift.sh --dry-run`
   first to confirm version-change detection.
2. If no local changelog mirror is configured AND no fixture flag is passed,
   the agent **fetches** the official Claude Code changelog via WebFetch from
   `https://docs.claude.com/en/release-notes/claude-code` (or the GitHub
   release notes), writes the markdown into a temp file, then re-invokes:
   `uplift.sh --changelog-file=<tmp>`.
3. Surface the resulting report path to the user.

### Flags

| Flag                    | Purpose                                                  |
| ----------------------- | -------------------------------------------------------- |
| `--force`               | Run even if no version change                            |
| `--dry-run`             | Print classification, do not write state/report          |
| `--since=VERSION`       | Override the "previous" version (e.g. `--since=2.1.139`) |
| `--to=VERSION`          | Override the "current" version (testing)                 |
| `--changelog-file=PATH` | Use a local changelog markdown instead of mirror/fixture |
| `--allow-fixture`       | Fall through to the bundled test fixture if no source    |
| `--report-dir=PATH`     | Override report output directory                         |
| `--quiet`               | Suppress informational logging                           |

## Output

A markdown report (e.g. `docs/operations/version-uplift-reports/2026-05-22-2.1.148.md`) with:

- **Summary table** — counts per classification.
- **Per-version findings** — each changelog entry with classification, matched surface, and rationale.
- **Next steps** — what to do with each classification.

A sibling `<basename>.json` file carries the same data in machine-readable form.

## Classifications

| Classification             | Meaning                                                                       | Action                                           |
| -------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------ |
| `already-adopted`          | Surface keyword matched AND repo probe shows surface is in use.               | Informational — confirm CLAUDE.md mentions it.   |
| `candidate-for-adoption`   | Surface matched but no repo probe matched (not yet used in this repo).        | Open a `/plan-w-team` ticket to adopt.           |
| `not-applicable`           | No integration-point keyword matched (IDE plugins, billing, telemetry, etc.). | Ignore.                                          |
| `breaking-change-required` | Surface IS in use AND changelog marks `BREAKING`.                             | Schedule a migration `/plan-w-team` immediately. |

## Integration points

The catalog is at `.claude/scripts/version-uplift/integration-points.json`.
Each surface defines `keywords` (substring match against changelog entries)
and `repo_probes` (filesystem paths checked via `[ -e ... ]` to decide
"used vs not used"). Edit the catalog to add new surfaces — the classifier
re-reads it on every run.

Catalog surfaces (as of v1):

- `hook-event` — PreToolUse, PostToolUse, Setup, PermissionRequest, etc.
- `permission-syntax` — `Bash(*)`, `Agent(*)`, wildcards
- `model-id` — `claude-opus-4-8`, `opus`/`sonnet`/`haiku` aliases
- `slash-command` — `/goal`, `/loop`, `/btw`, `/batch`, `/simplify`, `/fork`
- `agent-tool` — Agent/Task launcher, worktree isolation
- `bg-session` — `--bg`, `claude agents`, agent dashboard
- `pwt-stage` — /plan-w-team lifecycle stages
- `pwt-pause-site` — push-ack, secret-scan-allow, scope-unlock-for-drift
- `effort-level` — `--effort`, `$CLAUDE_EFFORT`, `effort.level`
- `mcp` — MCP servers, `CLAUDE_PROJECT_DIR`
- `tool-search` — deferred tool loading
- `worktree-baseref` — `worktree.baseRef` config
- `scheduled-jobs` — CronCreate/CronDelete/routines
- `task-tool` — Task\* persistent tools
- `agent-teams` — SendMessage (TeamCreate/TeamDelete removed in 2.1.178)

## Tests

`tests/version-uplift/version-uplift.bats` covers:

- detect: empty state, prior state with change, prior state no change, `--force`
- fetch: fixture parse, version range filtering, JSON shape
- evaluate: classification correctness (each of the 4 outcomes), summary counts
- orchestrator: dry-run produces no writes; non-dry-run writes report files

Run with `bats tests/version-uplift/version-uplift.bats`.

## Files

```
.claude/commands/plan-w-team/version-uplift/
├── SKILL.md                                 # this file
└── uplift.sh                                # orchestrator entry point

.claude/scripts/version-uplift/
├── detect-version.sh                        # version detection + state persistence
├── fetch-changelog.sh                       # changelog retrieval + parsing
├── evaluate-features.sh                     # classification engine
└── integration-points.json                  # surface catalog

docs/operations/version-uplift-reports/
└── <date>-<version>.{md,json}               # generated reports

tests/version-uplift/
├── version-uplift.bats                      # test suite
└── fixtures/
    └── changelog-fixture.md                 # synthetic changelog for tests
```
