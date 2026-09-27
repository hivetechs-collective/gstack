# Routines Examples (Opt-In User-Side Automation)

Claude Code 2.1.x ships **Routines** — scheduled or webhook-triggered Claude Code sessions that run without an interactive user (`cron` schedule, GitHub webhook, or API endpoint). Routines are a Claude Code platform feature, not a /plan-w-team skill behavior. This file documents **example Routine configurations** that compose Routines with /plan-w-team to automate periodic work.

> **Read this file only if you want to automate /plan-w-team runs.** The skill works perfectly without Routines — every example here is strictly opt-in.

## Where a Routine runs decides what it can read

There are two ways to run scheduled work, and they see different files:

| Mode                                                      | Where it runs                                                                  | What it can read                                                                                                                        | Triggers                                                     |
| --------------------------------------------------------- | ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| **Cloud Routine** (`claude.ai/code/routines`, `/schedule`) | Anthropic-hosted. The repository is cloned from the default branch on every run | Committed files only. Gitignored or uncommitted files under `.claude/state/` are never there                                            | Schedule (one-hour minimum), API call, GitHub events         |
| **Desktop scheduled task**                                | Your machine, against the local checkout                                       | Everything on disk, gitignored state included                                                                                           | Schedule; fires only while the Desktop app is open and the machine is awake |

/plan-w-team state splits the same way:

- **Committed, so a cloud Routine sees it**: git history, `docs/specs/*.md`, and the follow-up ledger `.claude/state/plan-w-team-recursive-followups.jsonl`.
- **Gitignored, so only a Desktop scheduled task sees it**: the friction log `.claude/state/plan-w-team-friction-log.jsonl`, the retro records `.claude/state/plan-w-team-retro-<slug>.json`, goal-states and the other per-run artifacts.

An example whose prompt reads gitignored state has to run as a Desktop scheduled task. On the cloud the file is missing, the Routine reports nothing, and nothing tells you why. `tests/skill/cases/routines-examples-state-visibility.bats` checks every example below for this.

Sources: [Routines](https://code.claude.com/docs/en/routines.md) ("Each repository you add is cloned on every run"), [Desktop scheduled tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks.md).

## Example 1: Weekly Retro Digest

Run `/plan-w-team --retro` every Monday at 9 AM. The session reads recent shipped features, scores them, and posts a digest to a Slack channel.

### Routine config (web UI)

| Field          | Value                                                                                                                                                                                   |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Trigger**    | Cron — `0 9 * * 1` (Monday 9 AM, project's local timezone)                                                                                                                              |
| **Repo**       | The repo where /plan-w-team has been shipping features                                                                                                                                  |
| **Prompt**     | `/plan-w-team --retro` (just the command; the skill picks up recent shipped work from board comments + git log)                                                                         |
| **Connectors** | Slack (write to `#dev-retros` or equivalent)                                                                                                                                            |
| **Execution**  | Cloud Routine. The digest reads `git log` and the board, which a cloud run can reach, and it runs whether or not the laptop is awake. It cannot include the friction signal (see step 4) |

### What it does

1. /plan-w-team enters via the `--retro` flag — routes to Step 8 only (per the flag-routing table in `plan-w-team.md`).
2. Step 8 reads `git log` and board state for the past week, computes metrics, scores stability, generates the retro narrative.
3. Slack connector posts the retro summary to the configured channel.
4. The friction signal is not in a cloud digest: the friction log is gitignored, so the clone does not have it. If you want it on a schedule, add Example 3 as a Desktop scheduled task.

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
| **Execution**  | Cloud Routine (GitHub-event triggers belong to cloud Routines)                                                                          |

### What it does

1. PR merges with the `plan-w-team` label → webhook fires → Routine spins up a Claude Code session.
2. /plan-w-team --retro runs against the just-merged feature (extracted from `{{pr.title}}`).
3. Retro is posted back as a comment on the PR — closes the feedback loop for anyone reviewing the PR later.

### Why it's useful

Solo developers often skip retros on small features. Auto-retro on merge eliminates that gap. The PR comment also creates a discoverable archive of retro outcomes per feature — useful when revisiting a feature months later to understand why it shipped the way it did.

### Caveat

A cloud run never has the run's own retro record, `.claude/state/plan-w-team-retro-$SLUG.json`: that file is gitignored, so the clone does not contain it. The retro has to rebuild from what the merge committed: the spec at `docs/specs/<slug>.md`, `git log`, and the PR itself. To let the Routine find the spec, enforce a PR-title convention (`feat(<slug>): …`) and read the slug from the title. A PR that is rebased and force-pushed before merge can still end up with a title that no longer matches.

## Example 3: Daily Friction Triage-Due Check

Each weekday, check whether the friction log is due for triage, and post to Slack only when it is.

### Routine config (Desktop scheduled task)

| Field          | Value                                                                                                                                                                                                                                                      |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Trigger**    | Schedule — weekdays at 6 PM (`0 18 * * 1-5` in cron terms)                                                                                                                                                                                                 |
| **Repo**       | The repo's local checkout                                                                                                                                                                                                                                  |
| **Prompt**     | Run `.claude/scripts/plan-w-team-friction-triage-due.sh`, which reads `.claude/state/plan-w-team-friction-log.jsonl`. If it prints a line containing `FRICTION_TRIAGE_DUE`, post that line. If it prints nothing, exit quietly.                            |
| **Connectors** | Slack (only post when triage is due — silent on no-op days)                                                                                                                                                                                                |
| **Execution**  | Desktop scheduled task. This is required: the friction log is gitignored, so a cloud Routine's clone never has it and the check would always come back empty                                                                                               |

### What it does

`plan-w-team-friction-triage-due.sh` counts the friction-log rows written since the last `{"type":"triage"}` marker. At 5 or more (`PWT_FRICTION_TRIAGE_THRESHOLD`) it prints one line containing `FRICTION_TRIAGE_DUE`; otherwise it prints nothing. The same advisory already prints at session start and in the retro preflight. This task surfaces it on days nobody opens a session in the repo.

The prompt calls the script instead of describing the counting rule. An earlier version of this example described the rule in its own words, and kept describing the old one for three months after the detector changed.

### Why it's useful

The session-start advisory only fires when someone starts a session in the repo. If a week goes by with no /plan-w-team work, the advisory sits unseen. A daily check surfaces it when triage becomes due, not when the next feature happens to start.

## Drift scanning: not an example, by decision

A Routine that periodically compares recent commits with runbooks, trackers and memory ("Idea B") has been evaluated twice and is **NO-GO**. See `docs/operations/pwt-drift-guardrails-go-nogo-2026-07-02.md`, the 2026-07-02 record and its 2026-09-26 addendum. There is deliberately no example for it here. If you decide you want one, it has to follow three rules:

1. **Notify a person.** Post findings through a connector someone reads: Slack, or a PR or issue comment. A finding written to a file in a rarely opened repo reaches nobody.
2. **Never append to the follow-up ledger** (`.claude/state/plan-w-team-recursive-followups.jsonl`). Where the follow-up drain is enabled, every ledger row becomes an autonomous `/plan-w-team` run, worked oldest row first. A drift row would either cost a full pipeline run or wait behind the whole backlog.
3. **Read only what the execution mode can see.** A cloud Routine sees committed files, which is enough for drift between commits and tracked docs. Anything under gitignored `.claude/state/` needs a Desktop scheduled task.

## When to Use vs Skip Routines

| Pattern                                             | Routine?                                                                                               |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Solo dev shipping 1-2 features/week                 | **Skip** — daily check-ins on Slack are noise; rely on preflight warnings                              |
| Team of 2-5 devs using /plan-w-team across repos    | **Adopt Example 1** (weekly digest) — gives the team shared visibility                                 |
| Anyone using /plan-w-team in a customer-facing repo | **Adopt Example 2** (auto-retro on merge) — creates an audit trail                                     |
| Sustained friction (3+ retros with score <8)        | **Adopt Example 3** temporarily — surfaces friction faster while you debug; remove once friction drops |

## Notes

- **A Routine is a separate Claude Code session.** It cannot read interactive session state. What it can read from `.claude/state/` depends on where it runs: a cloud Routine sees only committed files, a Desktop scheduled task sees the local checkout. See [Where a Routine runs decides what it can read](#where-a-routine-runs-decides-what-it-can-read).
- **Usage**: Routines use the same Anthropic account as the user and draw down subscription usage the same way interactive sessions do. Recurring runs also have a daily cap per account. Plan accordingly — a daily scan + weekly digest + on-merge retro can add up.
- **Failure handling**: If a Routine fails, Anthropic's Routines UI shows the error. Set the trigger to retry once; don't loop indefinitely.
- **Reference**: see Anthropic's [Routines](https://code.claude.com/docs/en/routines.md) and [Desktop scheduled tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks.md) documentation for the canonical config schema and limits. This file shows /plan-w-team-flavored examples, not the platform docs.

## Rollback

To stop a Routine, delete it from the Routines dashboard (or the scheduled task from the Desktop app). No /plan-w-team skill state needs to change — the skill never knew the Routine existed. Two-way door.
