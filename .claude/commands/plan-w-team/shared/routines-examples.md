# Routines Examples (Opt-In User-Side Automation)

Claude Code 2.1.x ships **Routines** — scheduled or webhook-triggered Claude Code sessions that run without an interactive user (`cron` schedule, GitHub webhook, or API endpoint). Routines are a Claude Code platform feature, not a /plan-w-team skill behavior. This file documents **example Routine configurations** that compose Routines with /plan-w-team to automate periodic work.

> **Read this file only if you want to automate /plan-w-team runs.** The skill works perfectly without Routines — every example here is strictly opt-in.

## Example 1: Weekly Retro Digest

Run `/plan-w-team --retro` every Monday at 9 AM. The session reads recent shipped features, scores them, and posts a digest to a Slack channel.

### Routine config (web UI)

| Field          | Value                                                                                                           |
| -------------- | --------------------------------------------------------------------------------------------------------------- |
| **Trigger**    | Cron — `0 9 * * 1` (Monday 9 AM, project's local timezone)                                                      |
| **Repo**       | The repo where /plan-w-team has been shipping features                                                          |
| **Prompt**     | `/plan-w-team --retro` (just the command; the skill picks up recent shipped work from board comments + git log) |
| **Connectors** | Slack (write to `#dev-retros` or equivalent)                                                                    |
| **Execution**  | Remote (Anthropic-hosted) preferred over local — local requires the laptop awake at 9 AM                        |

### What it does

1. /plan-w-team enters via the `--retro` flag — routes to Step 8 only (per the flag-routing table in `plan-w-team.md`).
2. Step 8 reads `git log` and board state for the past week, computes metrics, scores stability, generates the retro narrative.
3. Slack connector posts the retro summary to the configured channel.
4. Friction-log entries that triggered 3-in-30-day thresholds during the week surface as warnings in the digest.

### Why it's useful

Without this Routine, retros require manual `--retro` invocation, which is easy to skip when nothing visibly failed. The weekly cadence catches slow-burning friction (e.g., a steadily-rising fix ratio across features) that no single retro would surface. The Slack post is also visible to a team, even when the skill is solo-developer.

## Example 2: Auto-Retro on PR Merge

Run `/plan-w-team --retro` automatically whenever a PR labeled `plan-w-team` is merged. The retro runs against the just-shipped feature.

### Routine config (web UI)

| Field          | Value                                                                                                                                   |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| **Trigger**    | GitHub webhook — event `pull_request`, action `closed`, condition `merged == true && labels contains 'plan-w-team'`                     |
| **Repo**       | Same repo as the PR                                                                                                                     |
| **Prompt**     | `/plan-w-team --retro` with feature-name extracted from PR title (Routine variable substitution supports `{{pr.title}}`, `{{pr.body}}`) |
| **Connectors** | GitHub (post retro as PR comment), optional Slack                                                                                       |

### What it does

1. PR merges with the `plan-w-team` label → webhook fires → Routine spins up a Claude Code session.
2. /plan-w-team --retro runs against the just-merged feature (extracted from `{{pr.title}}`).
3. Retro is posted back as a comment on the PR — closes the feedback loop for anyone reviewing the PR later.

### Why it's useful

Solo developers often skip retros on small features. Auto-retro on merge eliminates that gap. The PR comment also creates a discoverable archive of retro outcomes per feature — useful when revisiting a feature months later to understand why it shipped the way it did.

### Caveat

If a PR is rebased+force-pushed before merge, the `pr.title` may not match the spec slug used during planning. The retro will still run but may not find the matching `.claude/state/plan-w-team-retro-$SLUG.json` artifact. Mitigation: enforce a PR-title convention (`feat(<slug>): …`) and read the slug from there.

## Example 3: Daily Friction-Log Scan

Scan the friction log for emerging patterns every day. If a category just crossed the 3-in-30-day threshold, post a warning to Slack.

### Routine config (web UI)

| Field          | Value                                                                                                                                                                                                                       |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Trigger**    | Cron — `0 18 * * 1-5` (weekdays 6 PM)                                                                                                                                                                                       |
| **Repo**       | The repo                                                                                                                                                                                                                    |
| **Prompt**     | Read `.claude/state/plan-w-team-friction-log.jsonl`. For each category, count entries in the past 30 days. If any category just crossed 3 (i.e., crossed today, not in past triggers), surface it. Otherwise, exit quietly. |
| **Connectors** | Slack (only post when a threshold is crossed — silent on no-op days)                                                                                                                                                        |

### What it does

The /plan-w-team preflight surfaces friction thresholds at the start of the next interactive run. This Routine surfaces them **earlier**, so the user sees the pattern before they're mid-feature.

### Why it's useful

The preflight friction warning only fires when /plan-w-team is invoked. If a week goes by with no /plan-w-team work, the warning sits invisible. A daily scan + Slack post catches the pattern when it crosses, not when the next feature happens to start.

## When to Use vs Skip Routines

| Pattern                                             | Routine?                                                                                               |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Solo dev shipping 1-2 features/week                 | **Skip** — daily check-ins on Slack are noise; rely on preflight warnings                              |
| Team of 2-5 devs using /plan-w-team across repos    | **Adopt Example 1** (weekly digest) — gives the team shared visibility                                 |
| Anyone using /plan-w-team in a customer-facing repo | **Adopt Example 2** (auto-retro on merge) — creates an audit trail                                     |
| Sustained friction (3+ retros with score <8)        | **Adopt Example 3** temporarily — surfaces friction faster while you debug; remove once friction drops |

## Notes

- **Routines run as a separate Claude Code session** — they cannot read interactive session state. Any state /plan-w-team writes to `.claude/state/` is git-committed (or gitignored but persistent on disk), so Routines reading it work fine.
- **Authentication**: Routines use the same Anthropic account as the user. They count toward the Max subscription's session budget. Plan accordingly — a daily scan + weekly digest + on-merge retro can add up.
- **Failure handling**: If a Routine fails, Anthropic's Routines UI shows the error. Set the trigger to retry once; don't loop indefinitely.
- **Reference**: see Anthropic's Routines documentation for the canonical config schema and limits. This file shows /plan-w-team-flavored examples, not the platform docs.

## Rollback

To stop a Routine, delete it from the Routines dashboard. No /plan-w-team skill state needs to change — the skill never knew the Routine existed. Two-way door.
