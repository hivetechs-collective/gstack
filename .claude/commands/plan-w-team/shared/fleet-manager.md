# Fleet State — JSONL artifact, hook writer, query reader

This document is the authoritative reference for the `/plan-w-team` fleet
state artifact (PWT-T3, 2026-05-19). It captures every subagent spawn and
completion during a /plan-w-team run, enabling backpressure-aware continuous
dispatch in Step 3-4 and parallelism efficiency metrics in Step 8 retro.

Spec: `docs/specs/pwt-supervisor-goal.md`
Hook (writer): `.claude/hooks/plan-w-team-fleet-writer.sh`
Reader: `.claude/scripts/plan-w-team-fleet-query.sh`
Tests: `.claude/scripts/plan-w-team-fleet-query.test.sh`
Registry: `shared/state-artifacts.md` (one row, mode `handoff`)

## Overview

| Concern                                          | How it's solved                                                                  |
| ------------------------------------------------ | -------------------------------------------------------------------------------- |
| Which subagent spawned and when                  | `SubagentStart` hook writes a `spawn` row                                        |
| Which subagent finished and when                 | `SubagentStop` hook writes a `complete` row                                      |
| Which SLUG owns the event                        | Hook derives from active `plan-w-team-workflow-*.lock` dir                       |
| Mapping `agent_id` → `task_id`                   | Sidecar `plan-w-team-fleet-intent-<slug>.jsonl` written by 03-execute.md (T3-04) |
| Spawning the next ready task without batch waits | Lead calls `fleet-query.sh next-spawnable <slug>` before each `Agent()`          |
| Retro auditing of parallelism                    | Step 8 `§8j-ter` reads the log + intent sidecar                                  |

The hook is **observability infrastructure**: it must never block agent
workflow. Every error path exits 0 with a stderr message; payload gaps are
recorded as `event=error` rows that retro surfaces.

## JSONL Schema

Each row is a single self-contained JSON object. Rows < 4 KiB are POSIX-
atomic on `>>` append (single-line writes through the page cache do not
interleave), so the hook does not need an explicit lock for the fleet log
itself.

### Hook-written rows (in fleet log)

```jsonl
{"ts":"2026-05-19T22:00:00Z","event":"spawn","slug":"<SLUG>","agent_id":"AGT-...","agent_type":"react-typescript-specialist","cwd":"/repo"}
{"ts":"2026-05-19T22:05:00Z","event":"complete","slug":"<SLUG>","agent_id":"AGT-...","last_msg":"Implementation complete..."}
{"ts":"2026-05-19T22:00:00Z","event":"error","slug":"<SLUG>","reason":"missing agent_id in SubagentStart payload"}
```

| Field        | Events         | Required | Source                                                                 |
| ------------ | -------------- | -------- | ---------------------------------------------------------------------- |
| `ts`         | all            | yes      | hook timestamp (ISO8601 UTC)                                           |
| `event`      | all            | yes      | `spawn` / `complete` / `error`                                         |
| `slug`       | all            | yes      | derived from `.claude/state/plan-w-team-workflow-*.lock` dir name      |
| `agent_id`   | spawn/complete | yes      | hook payload `agent_id` field                                          |
| `agent_type` | spawn          | no       | hook payload `agent_type` field                                        |
| `cwd`        | spawn          | no       | hook payload `cwd` field                                               |
| `last_msg`   | complete       | no       | hook payload `last_assistant_message`, truncated 100 chars             |
| `reason`     | error          | yes      | what went wrong (missing payload field, no active workflow lock, etc.) |

### Lead-written sidecar rows (T3-04)

The lead writes one row per `Agent()` spawn to
`.claude/state/plan-w-team-fleet-intent-<slug>.jsonl` so the reader can join
`agent_id` → `task_id`. Schema:

```jsonl
{
  "ts": "2026-05-19T22:00:00Z",
  "agent_id": "AGT-...",
  "task_id": "187",
  "blocks": [
    "190"
  ],
  "worktree": ".claude/worktrees/builder-187"
}
```

The hook cannot populate `task_id` itself because the SubagentStart payload
does not include the agent's prompt content. The sidecar is the lead's
authoritative record of the spawn intent.

## Query Subcommand Reference

```bash
.claude/scripts/plan-w-team-fleet-query.sh <subcommand> <slug>
```

| Subcommand              | Returns                                                                                       | Used by                                                             |
| ----------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `next-spawnable <slug>` | JSON array of task IDs ready to spawn (status=pending, not running, all `blockedBy` complete) | 03-execute.md continuous-dispatch loop (T3-04)                      |
| `running <slug>`        | JSON array of `{agent_id, task_id?}` for in-flight agents                                     | 03-execute.md backpressure check, 07-retro.md §8j-ter               |
| `completed <slug>`      | JSON array of `{agent_id, task_id?, spawned_at, completed_at}`                                | 07-retro.md duration analysis                                       |
| `summary <slug>`        | Object `{spawned, completed, failed, running, max_concurrent}`                                | 07-retro.md §8j-ter (computes parallelism % from this + task graph) |

**Definition of "done" for `next-spawnable`**: A `blockedBy` entry is satisfied if EITHER (a) its `agent_id` has a fleet `event=complete` row joinable via the sidecar, OR (b) the task's status in `~/.claude/tasks/<list>/<id>.json` is `completed`. The union covers tasks completed before T3-01 shipped (no fleet log) and tasks completed in the current run.

## Kill Switch Contract

Environment variable `PLAN_W_TEAM_FLEET_DISABLE=1`:

- Hook (`fleet-writer.sh`): exit 0 without appending to fleet log.
- Reader (`fleet-query.sh`): return empty arrays for list subcommands, return zero-count object for `summary`. Exit 0.

The kill switch is **graceful degradation** — `/plan-w-team` still completes,
just without fleet observability. Use during incident response or when
debugging fleet logic itself.

## Retro Metric Formula (computed by 07-retro.md §8j-ter, T3-04)

```
parallelism_efficiency = (∫ concurrent_agents dt) / (max_possible_concurrent × total_seconds)
                        ┌──────────────────┐    ┌─────────────────────────────────────────────┐
                        │   actual work    │    │ what would have been possible given the     │
                        │   in agent-seconds │  │ task dependency graph (no idle waits)       │
                        └──────────────────┘    └─────────────────────────────────────────────┘
```

Where `max_possible_concurrent` at time `t` = number of tasks whose
`blockedBy` is fully satisfied by tasks completed at `t`. Compute by walking
the dep graph at each event timestamp.

Score: 1.0 = perfectly parallel (every task spawned the moment it became
spawnable); 0.5 = half the achievable parallelism; <0.3 = severe batch waits.

The reader's `summary` returns `max_concurrent` (raw count); the retro
computes the full efficiency metric because it has the task-graph
denominator.

## Failure Modes & Recovery

| Failure                                                                   | Behavior                                                | Recovery                                                            |
| ------------------------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------- |
| Missing `$CLAUDE_AGENT_TASK_ID`                                           | Hook writes `event=error` row, exits 0                  | Retro flags as data-quality warning; no impact on workflow          |
| No active workflow lock when hook fires                                   | Hook exits 0 silently (not a /plan-w-team-driven spawn) | Expected; hook is no-op outside /plan-w-team                        |
| Multiple active workflow locks (parallel /plan-w-team on different slugs) | Hook picks newest lock; warns to stderr                 | Acceptable; cross-run misattribution is rare and visible in retro   |
| Fleet log corrupted (manual edit, crash mid-write)                        | Reader skips bad rows with stderr warn                  | Retro reports corrupt-row count; consider re-running affected stage |
| Reader called before any spawn                                            | All subcommands return empty/zero                       | Expected; lead falls back to legacy batch dispatch                  |
| `jq` not installed                                                        | Reader prints error to stderr, returns empty            | Install `jq` (already a /plan-w-team dependency)                    |

The hook NEVER blocks an agent spawn. The reader NEVER crashes /plan-w-team.

## Adding a New Event Type

If a future enhancement (T4 supervisor, T5 /goal wrapper) needs a new event:

1. Add a row to the JSONL Schema table in this file with the event name, required fields, and source.
2. Update `fleet-writer.sh`'s `case "$EVENT_NAME"` block.
3. Update `fleet-query.sh`'s subcommand logic to handle the new event in `summary` and `running`/`completed` if applicable.
4. Add a test case in `fleet-query.test.sh`.
5. Update the symmetry-check registry row if the on-disk path changes.
6. Document in retro (`07-retro.md §8j-ter`) how the new event affects metrics.

## Where This Runs

- **Hook**: spawned as a subprocess by Claude Code at `SubagentStart` and `SubagentStop`. Order matters: this hook runs AFTER `agent-tmux-panes.sh` and `subagent-track.sh` (see `.claude/settings.json`) so a crash here cannot poison existing hooks.
- **Reader**: invoked from `03-execute.md` (continuous dispatch, T3-04) and `07-retro.md` (§8j-ter, T3-04). Also useful standalone for manual fleet inspection.
- **Cleanup**: `07-retro.md` removes `.claude/state/plan-w-team-fleet-<slug>.jsonl` and `.claude/state/plan-w-team-fleet-intent-<slug>.jsonl` on successful retro completion. Failed runs retain both for `--resume`.
