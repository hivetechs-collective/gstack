# Supervisor Protocol — Action Log, Transcript Surfacing, Delegation Contract

Authoritative reference for the PWT-T4 persistent supervisor agent (`.claude/agents/team/supervisor.md`). Companion to `shared/orchestrator-interception.md` (router classifier table) and `shared/fleet-manager.md` (T3 fleet artifact).

Spec: `docs/specs/pwt-t4-supervisor.md`
Agent: `.claude/agents/team/supervisor.md`
Wrapper: `.claude/scripts/plan-w-team-supervisor-route.sh`
Feature flag: `PLAN_W_TEAM_SUPERVISOR=1` (default OFF)
Kill switch: `PLAN_W_TEAM_DISABLE_SUPERVISOR=1` (overrides feature flag)

## Overview

The supervisor is a persistent Brain-tier agent that owns Step 3-4 dispatch for one `/plan-w-team` run. It replaces the lead's ad-hoc batch fan-out with a single coherent dispatcher. It is:

- **Persistent** within one run (not ephemeral per pause site like PWT-T1/T2 orchestrators)
- **Subordinate** to the lead session that spawned it
- **A caller** of `route_orchestrator` for pause-site classification (NOT a replacement)
- **A user-escalator** only on 3 hard-gate sites (push-ack, secret-scan-allow, scope-unlock-for-drift)
- **An audit-logger** via supervisor-actions JSONL
- **A transcript-surfacer** via per-turn summary block (the contract T5 `/goal` evaluator will consume)

## Supervisor-Actions JSONL Schema

Path: `.claude/state/plan-w-team-supervisor-actions-<SLUG>.jsonl`

Writer: supervisor agent (via Bash `printf >>`, NOT Write tool — supervisor lacks Write/Edit)
Reader: `07-retro.md` §8j-quater
Mode (in state-artifacts.md registry): `handoff`
Cleanup: `07-retro.md` removes on `RETRO_SUCCESS=1`

### Event types

| Event              | When                                          | Required fields                                                          |
| ------------------ | --------------------------------------------- | ------------------------------------------------------------------------ |
| `supervisor_start` | First action of the supervisor's invocation   | `ts`, `event`, `slug`, `supervisor_agent_id`                             |
| `spawn_decision`   | Before each `Agent()` builder spawn           | `ts`, `event`, `slug`, `task_id`, `agent_type`, `reason`                 |
| `route_delegation` | After each `route_orchestrator` call returns  | `ts`, `event`, `slug`, `call_site`, `router_choice`, `router_confidence` |
| `escalation`       | When supervisor hits a hard-gate site         | `ts`, `event`, `slug`, `call_site`, `reason`                             |
| `supervisor_stop`  | Final action before returning control to lead | `ts`, `event`, `slug`, `reason`, `duration_s`                            |

### Example log

```jsonl
{"ts":"2026-05-19T22:30:00Z","event":"supervisor_start","slug":"add-payment-api","supervisor_agent_id":"AGT-sup-1"}
{"ts":"2026-05-19T22:30:02Z","event":"spawn_decision","slug":"add-payment-api","task_id":"201","agent_type":"react-typescript-specialist","reason":"deps complete + capacity 3/4"}
{"ts":"2026-05-19T22:30:03Z","event":"spawn_decision","slug":"add-payment-api","task_id":"202","agent_type":"nodejs-specialist","reason":"deps complete + capacity 2/4"}
{"ts":"2026-05-19T22:31:15Z","event":"route_delegation","slug":"add-payment-api","call_site":"qa-tier-selection","router_choice":"standard","router_confidence":"high"}
{"ts":"2026-05-19T22:45:00Z","event":"escalation","slug":"add-payment-api","call_site":"push-ack","reason":"Step 6 reached; hard-gate requires user confirmation"}
{"ts":"2026-05-19T22:45:00Z","event":"supervisor_stop","slug":"add-payment-api","reason":"escalation:push-ack","duration_s":900}
```

### Field reference

| Field                 | Type                           | Notes                                                                                                                         |
| --------------------- | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| `ts`                  | string (ISO8601 UTC)           | Required on all rows                                                                                                          |
| `event`               | string enum                    | Required; one of the 5 event types above                                                                                      |
| `slug`                | string                         | Required; consuming /plan-w-team run's SLUG                                                                                   |
| `supervisor_agent_id` | string                         | Supervisor's own agent_id (from spawn context); appears on `supervisor_start` and `supervisor_stop` for join with fleet log   |
| `task_id`             | string                         | Required on `spawn_decision`                                                                                                  |
| `agent_type`          | string                         | Required on `spawn_decision`; matches `subagent_type` parameter passed to `Agent()`                                           |
| `reason`              | string                         | Free-form one-sentence rationale; required on `spawn_decision`, `escalation`, `supervisor_stop`                               |
| `call_site`           | string                         | Required on `route_delegation` and `escalation`; must match a label in `shared/orchestrator-interception.md` Classifier Table |
| `router_choice`       | string                         | Required on `route_delegation`; what the router returned                                                                      |
| `router_confidence`   | enum (`high`\|`medium`\|`low`) | Required on `route_delegation`; from router's decision block                                                                  |
| `duration_s`          | integer                        | Required on `supervisor_stop`; wall-clock seconds from `supervisor_start` to now                                              |

## Transcript-Surfacing Summary Block

Required at the **end of every turn** the supervisor emits. This is the contract T5 `/goal` evaluator will consume — the Haiku evaluator cannot run tools, so it judges progress from what the supervisor surfaces in conversation.

### Block format

````
```summary
{"fleet":{"running":N,"completed":N,"failed":N,"max_concurrent":N},
 "next_spawnable_count":N,
 "pending_escalations":["<call-site>",...],
 "supervisor_action_count":N,
 "goal_progress":"<one-sentence status>"}
```
````

### Field reference

| Field                     | Type     | How computed                                                                                                                                                             |
| ------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `fleet`                   | object   | From `fleet-query.sh summary <slug>`                                                                                                                                     |
| `fleet.running`           | integer  | Currently-running agent count                                                                                                                                            |
| `fleet.completed`         | integer  | Completed agent count                                                                                                                                                    |
| `fleet.failed`            | integer  | Error-event count (hook payload gaps)                                                                                                                                    |
| `fleet.max_concurrent`    | integer  | Peak concurrency observed                                                                                                                                                |
| `next_spawnable_count`    | integer  | Length of `fleet-query.sh next-spawnable <slug>`                                                                                                                         |
| `pending_escalations`     | string[] | Hard-gate sites currently blocked on user (empty array when none)                                                                                                        |
| `supervisor_action_count` | integer  | Row count in supervisor-actions JSONL                                                                                                                                    |
| `goal_progress`           | string   | One sentence describing dispatch state, e.g. "3 builders running, 2 unblocked tasks queued" / "blocked on push-ack escalation" / "all tasks complete, returning to lead" |

### Why this shape

The block is JSON inside a `summary`-tagged fenced block because:

- **Machine-readable** for T5 evaluator (jq can extract fields)
- **Human-readable** in the conversation transcript (it's pretty-printable)
- **Greppable** for retro analysis (`grep -A1 '```summary'`)
- **Stable** — schema is one-way once T5 ships; field additions are safe, renames are not

### Why each turn

T5 `/goal` evaluator fires after every supervisor turn. If the summary block is missing, the evaluator must treat that turn as non-progress. The supervisor's job is to make every turn observable.

## Delegation Contract (supervisor ↔ router)

The supervisor is a **caller** of `route_orchestrator`, not a replacement. The classifier table in `shared/orchestrator-interception.md` remains the single source of truth for pause-site routing.

### What the supervisor delegates

All 11 sites with verdict `orchestrator` in the classifier table:

`scope-challenge-mode`, `pass-2-ask`, `version-bump-major-vs-minor`, `agent-roster-selection`, `task-breakdown-granularity`, `qa-tier-selection`, `evaluator-iterate-vs-escalate`, `review-autofix-vs-defer`, `ship-readiness-gate`, `post-ship-docs-target`, `retro-friction-categorize`

For each: invoke the router script, parse the returned choice, log `route_delegation` row, act.

### What the supervisor escalates (hard-gate)

All 3 sites with verdict `user` in the classifier table:

`push-ack`, `secret-scan-allow`, `scope-unlock-for-drift`

For each: emit `escalation` row + `supervisor_stop` row, end turn with escalation block, return to lead.

### What the supervisor never does

- Reimplement the classifier table (it lives in `shared/orchestrator-interception.md`)
- Make hard-gate decisions itself (always escalate)
- Override router fallback behavior (`-fallback` suffix from parse failures still flows through to user, per existing contract)

## Kill Switch + Feature Flag Contract

| Env var                            | Default     | Effect                                                                                 |
| ---------------------------------- | ----------- | -------------------------------------------------------------------------------------- |
| `PLAN_W_TEAM_SUPERVISOR=1`         | unset (OFF) | Enables Pattern C in `03-execute.md`; without this, supervisor is never spawned        |
| `PLAN_W_TEAM_DISABLE_SUPERVISOR=1` | unset       | Force-OFF override; even if feature flag is on, wrapper exits 2 and lead falls through |

The wrapper script (`plan-w-team-supervisor-route.sh`) enforces both at invocation time:

```bash
[ "${PLAN_W_TEAM_DISABLE_SUPERVISOR:-}" = "1" ] && { echo "kill switch set" >&2; exit 2; }
[ "${PLAN_W_TEAM_SUPERVISOR:-}" = "1" ] || { echo "feature flag off" >&2; exit 2; }
```

Exit 2 from the wrapper signals "fall through to Pattern A/B" — `03-execute.md` Pattern C is wrapped in `if .../plan-w-team-supervisor-route.sh "$SLUG"; then ... fi`, so a non-zero exit is the documented fall-through path.

## Failure Modes

| Failure                                               | Supervisor behavior                                                                                                                                  |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fleet-query.sh` returns malformed JSON               | Warn to stderr, treat result as empty, fall back to `TaskList` for spawn decisions; log `route_delegation` with `router_choice: "fallback-tasklist"` |
| `route_orchestrator` script missing                   | Treat as `-fallback`: emit `escalation` row + return for user (do NOT silently retry)                                                                |
| `route_orchestrator` returns malformed decision block | Same as missing-script case (preserves existing `-fallback` contract)                                                                                |
| Action log path EACCES                                | Warn to stderr, continue dispatch; logging is observability, never a gate                                                                            |
| Builder agent crashes (hook writes `event=error`)     | Treat error event as completion for spawn-capacity accounting; mark task as failed in `TaskList`                                                     |
| Supervisor's own session compacts mid-dispatch        | The supervisor-actions log is the recovery anchor — Step 1 of any `--resume` invocation: read the log to reconstruct dispatched state                |
| Supervisor forgets summary block for one turn         | Next turn MUST emit it immediately; Step 5 review flags missing-summary streaks (T5 evaluator will too, once shipped)                                |

## Where This Runs

| Stage                                 | What happens                                                                                                   |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `03-execute.md` Pattern C             | Spawns supervisor agent when feature flag on (and wrapper exits 0); falls through to Pattern A/B when flag off |
| `07-retro.md` §8j-quater              | Reads supervisor-actions log; scores supervisor decision health 1-5; cleans up log on `RETRO_SUCCESS=1`        |
| `shared/orchestrator-interception.md` | Notes (in §Where This Runs) that supervisor is a caller of `route_orchestrator`, not a replacement             |
| `shared/state-artifacts.md`           | Registers `plan-w-team-supervisor-actions-$SLUG.jsonl` as mode `handoff`                                       |
| Future T5 `/goal` wrapper             | Evaluator reads transcript summary blocks each turn to judge progress                                          |

## Adding a New Event Type or Summary Field

When extending the supervisor (e.g. for T5 integration):

1. Add the new event type or field to the schema tables above with type + when-required notes.
2. Update the supervisor's system prompt (`.claude/agents/team/supervisor.md`) to emit it.
3. Update `07-retro.md` §8j-quater if the new field affects scoring.
4. Update the symmetry-check registry row if the on-disk path or pattern changes.
5. Add a test case in `plan-w-team-supervisor-route.test.sh` if it affects the wrapper.
6. If the change touches the **summary block schema**, document the version bump in this file (the block is a one-way contract once T5 ships).
