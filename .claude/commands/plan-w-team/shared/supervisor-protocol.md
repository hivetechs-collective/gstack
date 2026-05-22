# Supervisor Protocol — Action Log, Transcript Surfacing, Delegation Contract

Authoritative reference for the PWT-T4 persistent supervisor agent (`.claude/agents/team/supervisor.md`). Companion to `shared/orchestrator-interception.md` (router classifier table) and `shared/fleet-manager.md` (T3 fleet artifact).

Spec: `docs/specs/pwt-t4-supervisor.md`
Agent: `.claude/agents/team/supervisor.md`
Wrapper: `.claude/scripts/plan-w-team-supervisor-route.sh`
Default: ON for parallel-builder runs (no env var needed)
Kill switch: `PLAN_W_TEAM_DISABLE_SUPERVISOR=1` (reverts to legacy lead-fanout)

## Overview

The supervisor is a persistent Brain-tier agent that owns Step 3-4 dispatch for one `/plan-w-team` run. It replaces the lead's ad-hoc batch fan-out with a single coherent dispatcher. It is:

- **Persistent** within one run (not ephemeral per pause site like PWT-T1/T2 orchestrators)
- **Subordinate** to the lead session that spawned it
- **A caller** of `route_orchestrator` for pause-site classification (NOT a replacement)
- **A user-escalator** only on 3 hard-gate sites (push-ack, secret-scan-allow, scope-unlock-for-drift)
- **An audit-logger** via supervisor-actions JSONL
- **A transcript-surfacer** via per-turn summary block (the contract T5 `/goal` evaluator will consume)

### Process Tree & Shared Artifacts

````mermaid
flowchart TB
    subgraph Parent["Parent session (lead)"]
        Lead[Lead agent<br/>Brain · Opus 4.7]
    end

    subgraph SupervisorRun["Supervisor (Step 3-4 only)"]
        Sup[Supervisor agent<br/>persistent · Brain · Opus 4.7]
        ActionLog[(supervisor-actions<br/>JSONL audit log)]
        Summary[/per-turn summary block<br/>fenced ```summary``` in transcript/]
    end

    subgraph Workers["Worker subagents (one per task)"]
        W1[builder<br/>Hands · Opus 4.6]
        W2[specialist-N<br/>Hands · pinned per agent def]
        Wn[...up to N parallel...]
    end

    subgraph SharedState[".claude/state/ (worktree-aware)"]
        Goal[(plan-w-team-goal-SLUG.json<br/>terminal_state · feature_specific_done_criteria)]
        Fleet[(plan-w-team-fleet-SLUG.jsonl<br/>spawn/complete events · T3 hook writer)]
        Intent[(plan-w-team-fleet-intent-SLUG.jsonl<br/>task_id ↔ agent_type sidecar)]
        Children[(plan-w-team-spawned-children-SLUG.jsonl<br/>registered claude --bg children)]
        Lock[(plan-w-team-workflow-SLUG.lock<br/>mkdir-atomic owner PID)]
    end

    subgraph Hooks["Always-on hooks"]
        Eval[plan-w-team-goal-evaluator.sh<br/>Stop hook · reads Goal + Children]
        Spawn[plan-w-team-register-spawn.sh<br/>writes Children on claude --bg]
        SubHook[SubagentStart/Stop hooks<br/>write Fleet]
    end

    Lead -->|spawns once for<br/>parallel-builder runs| Sup
    Sup -->|spawns N workers<br/>via Agent tool| Workers
    Sup -->|emits per turn| Summary
    Sup -->|appends events| ActionLog
    Sup -->|reads to decide<br/>next dispatch| Fleet
    Sup -.optional: route_orchestrator.-> Lead

    Workers -.SubagentStart/Stop.-> SubHook
    SubHook --> Fleet
    Sup -->|writes intent before<br/>each Agent() call| Intent

    Eval -.reads per turn.-> Goal
    Eval -.aggregates worker state.-> Children

    Lead -->|holds for run duration| Lock

    classDef parent fill:#e3f2fd,stroke:#1565c0;
    classDef sup fill:#fff3e0,stroke:#e65100;
    classDef worker fill:#e8f5e9,stroke:#2e7d32;
    classDef state fill:#f3e5f5,stroke:#6a1b9a;
    classDef hook fill:#fce4ec,stroke:#ad1457;
    class Lead parent;
    class Sup,ActionLog,Summary sup;
    class W1,W2,Wn worker;
    class Goal,Fleet,Intent,Children,Lock state;
    class Eval,Spawn,SubHook hook;
````

**Reading the diagram:**

- The **lead** spawns the supervisor exactly once for parallel-builder runs. Lead-implements-directly and single-builder strategies skip the supervisor entirely (the lead drives workers/tasks itself).
- The **supervisor** is the only spawner of workers during Step 3-4. Worker `SubagentStart`/`SubagentStop` hooks write fleet events automatically; the supervisor writes the intent sidecar BEFORE each `Agent()` call so the fleet log can be joined to task IDs.
- The **goal evaluator** (Stop hook) reads both the parent's goal state file AND the spawned-children registry — workers that ship their own retro-complete state propagate up to the parent (see `Parent-Child Terminal Propagation` below).
- `.claude/state/` paths are **worktree-aware**: `surface-status.sh` and `goal-evaluator.sh` check `$PWD/.claude/state/` first before falling back to `$CLAUDE_PROJECT_DIR/.claude/state/`. This makes background-session worktrees (`claude --bg`) safe by default.

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

### If the supervisor ever spawns a `claude --bg` child

The supervisor's normal dispatch model is `Agent()` calls into the same session (subagents share the lead's conversation). It does **not** spawn new top-level sessions today. If a future extension ever does (e.g., to fan out across repos), every such spawn MUST register the child for retro-time cleanup:

```bash
.claude/scripts/plan-w-team-register-spawn.sh "$CHILD_SID" "supervisor-spawn" "$SLUG" "$PARENT_SID" "supervisor"
```

The registry is read by `07-retro.md §8j-sexies` which runs `claude stop` on each entry. Without this call, a supervisor-spawned child becomes an orphan when the parent run ends — the exact defect class the 2026-05-20 cleanup work was meant to close. See `docs/specs/plan-w-team-self-cleanup.md` and the artifact entry in `shared/state-artifacts.md`.

## Kill Switch Contract

| Env var                            | Default | Effect                                                                  |
| ---------------------------------- | ------- | ----------------------------------------------------------------------- |
| `PLAN_W_TEAM_DISABLE_SUPERVISOR=1` | unset   | Kill switch — wrapper exits 2, lead falls through to legacy Pattern A/B |

Supervisor is the default dispatcher for parallel-builder runs — no opt-in env var required. The wrapper script (`plan-w-team-supervisor-route.sh`) enforces only the kill switch:

```bash
[ "${PLAN_W_TEAM_DISABLE_SUPERVISOR:-}" = "1" ] && { echo "kill switch set" >&2; exit 2; }
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

| Stage                                 | What happens                                                                                                         |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `03-execute.md` Pattern C             | Spawns supervisor agent BY DEFAULT for parallel-builder runs; falls through to Pattern A/B only when kill switch set |
| `07-retro.md` §8j-quater              | Reads supervisor-actions log; scores supervisor decision health 1-5; cleans up log on `RETRO_SUCCESS=1`              |
| `shared/orchestrator-interception.md` | Notes (in §Where This Runs) that supervisor is a caller of `route_orchestrator`, not a replacement                   |
| `shared/state-artifacts.md`           | Registers `plan-w-team-supervisor-actions-$SLUG.jsonl` as mode `handoff`                                             |
| Future T5 `/goal` wrapper             | Evaluator reads transcript summary blocks each turn to judge progress                                                |

## Parent-Child Terminal Propagation (2026-05-20)

The persistent supervisor described above owns Step 3-4 dispatch within ONE `/plan-w-team` run. A separate but related case: when a parent `/goal` session delegates an entire `/plan-w-team` run to a worker via `pwt-goal.sh --launch` (which spawns `claude --bg`), the parent must learn when the worker reaches terminal.

The goal-evaluator hook (`.claude/hooks/plan-w-team-goal-evaluator.sh`) handles this automatically by reading worker `goal-<SLUG>.json` state files directly — not by sniffing transcript anchors that only ever appear in the worker's own session. See `shared/goal-conditions.md` §Parent-Child Terminal Propagation for the precedence rules and fail-open contract.

For supervisors that ever spawn additional `claude --bg` children (rare — supervisors normally spawn agents via the `Agent` tool, not new sessions): such a spawn MUST be registered via `.claude/scripts/plan-w-team-register-spawn.sh` so the propagation works. Without registration, the parent's goal evaluator has no record of the child and will continue to wait on transcript anchors that never arrive in its own session.

## Origin-Chat Supervisor — systemMessage as Load-Bearing Signal (2026-05-21)

The **persistent supervisor** described above is for parallel-builder runs (Step 3-4 dispatch). A different, simpler supervisor mode runs for every natural-language `/plan-w-team` trigger: the **origin-chat supervisor**, where the user's current chat session takes the supervisor role for a single bg worker spawned by the UserPromptSubmit route hook. The full inlined protocol lives in the skill manifest's "Step 3c — Act as live supervisor" block; this section documents only what makes the handoff between hook and origin chat actually work in 2.1.148+.

**Load-bearing signal: `systemMessage` (not `additionalContext`)**

The Claude Code harness silently drops the `additionalContext` field from UserPromptSubmit hook output. Verified 2026-05-21 in v2.1.148: 0 of 20 expected `additionalContext` deliveries arrived in the captured session JSONL near the user-prompt turn. Only `systemMessage` reaches the assistant — delivered as a `hook_system_message` attachment. Therefore the marker the manifest Step 3a check scans for MUST be a substring of the systemMessage content the hook emits, NOT a marker buried in additionalContext.

The current marker the route hook emits in its `systemMessage`:

```
🚀 /plan-w-team origin-chat supervisor active
   worker: <SID>
   pattern: <trigger>
   ...
```

The manifest Step 3a guard greps for the prefix `/plan-w-team origin-chat supervisor active`. If present → skip the manifest's own spawn (worker already exists); if absent → call `pwt-goal.sh --worker-only`. The full inlined Step 3c supervisor protocol is in the manifest because additionalContext (which previously carried the protocol body) is dropped.

**Why this is documented as load-bearing**: the systemMessage marker is the only inter-process signal between the route hook and the assistant turn. If a future Claude Code release changes how systemMessage attachments are delivered, the origin-chat-supervisor handoff breaks silently. See `tests/skill/scenarios/imperative-nl-one-worker.bats` for the regression that catches this.

**PWT-DS1 and PWT-DS2 are deterministic backstops, not replacements:**

- **PWT-DS1** (process-level, mid-2026-05): even if the assistant ignores the systemMessage marker and calls `pwt-goal.sh --worker-only` anyway, the script checks `.claude/state/plan-w-team-hook-spawn-<sid>.flag` (written by the hook on successful spawn). A flag mtime-within-60s for the current parent SID → refuse spawn, exit 3 (PWT_DS1_DUPLICATE label, code returns 3). The flag-file is registered in `shared/state-artifacts.md`.
- **PWT-DS2** (env-propagated, cascade guard): `pwt-goal.sh --worker-only` sets `PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1` in the spawned worker's environment. Any subsequent `pwt-goal.sh` invocation (worker-only OR launch) inside that env refuses to spawn (exit 4 `PWT_DS2_CASCADE`). Escape hatch: `PLAN_W_TEAM_FORCE_SPAWN=1` for legitimate nested runs.

**Defense-in-depth ordering** (first→last):

1. **LLM attention** (systemMessage marker scan) — fastest path; correct in ~99% of cases.
2. **PWT-DS1** flag file — process-level deterministic; catches LLM-attention misses (the case that produced commit `c9cfcd5`).
3. **PWT-DS2** env signal — catches the cascade pattern where a worker's goal text re-triggers the routing classifier (the case that produced commit `553ab85`).

This layering is intentional: the visual marker is the cheapest and most ergonomic; the flag-file is a backstop that requires no assistant cooperation; the env signal stops self-replication from inside the worker.

## Adding a New Event Type or Summary Field

When extending the supervisor (e.g. for T5 integration):

1. Add the new event type or field to the schema tables above with type + when-required notes.
2. Update the supervisor's system prompt (`.claude/agents/team/supervisor.md`) to emit it.
3. Update `07-retro.md` §8j-quater if the new field affects scoring.
4. Update the symmetry-check registry row if the on-disk path or pattern changes.
5. Add a test case in `plan-w-team-supervisor-route.test.sh` if it affects the wrapper.
6. If the change touches the **summary block schema**, document the version bump in this file (the block is a one-way contract once T5 ships).
