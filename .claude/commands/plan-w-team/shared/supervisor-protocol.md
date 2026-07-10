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
- **A transcript-surfacer** via per-turn summary block (the contract the shipped `/goal` evaluator consumes)

### Process Tree & Shared Artifacts

````mermaid
flowchart TB
    subgraph Parent["Parent session (lead)"]
        Lead[Lead agent<br/>Brain]
    end

    subgraph SupervisorRun["Supervisor (Step 3-4 only)"]
        Sup[Supervisor agent<br/>persistent · Brain]
        ActionLog[(supervisor-actions<br/>JSONL audit log)]
        Summary[/per-turn summary block<br/>fenced ```summary``` in transcript/]
    end

    subgraph Workers["Worker subagents (one per task)"]
        W1[builder<br/>Hands]
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

| Event              | When                                               | Required fields                                                          |
| ------------------ | -------------------------------------------------- | ------------------------------------------------------------------------ |
| `supervisor_start` | First action of the supervisor's invocation        | `ts`, `event`, `slug`, `supervisor_agent_id`                             |
| `spawn_decision`   | Before each `Agent()` builder spawn                | `ts`, `event`, `slug`, `task_id`, `agent_type`, `reason`                 |
| `route_delegation` | After each `route_orchestrator` call returns       | `ts`, `event`, `slug`, `call_site`, `router_choice`, `router_confidence` |
| `escalation`       | When supervisor hits a hard-gate site              | `ts`, `event`, `slug`, `call_site`, `reason`                             |
| `supervisor_stop`  | Final action before returning control to lead      | `ts`, `event`, `slug`, `reason`, `duration_s`                            |
| `worker_restart`   | After a bounded API_HALT reclaim respawns a worker | `ts`, `event`, `slug`, `dead_sid`, `new_sid`, `attempt`, `reason`        |

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
| `event`               | string enum                    | Required; one of the 6 event types above                                                                                      |
| `slug`                | string                         | Required; consuming /plan-w-team run's SLUG                                                                                   |
| `supervisor_agent_id` | string                         | Supervisor's own agent_id (from spawn context); appears on `supervisor_start` only, for join with fleet log                   |
| `task_id`             | string                         | Required on `spawn_decision`                                                                                                  |
| `agent_type`          | string                         | Required on `spawn_decision`; matches `subagent_type` parameter passed to `Agent()`                                           |
| `reason`              | string                         | Free-form one-sentence rationale; required on `spawn_decision`, `escalation`, `supervisor_stop`, `worker_restart`             |
| `call_site`           | string                         | Required on `route_delegation` and `escalation`; must match a label in `shared/orchestrator-interception.md` Classifier Table |
| `router_choice`       | string                         | Required on `route_delegation`; what the router returned                                                                      |
| `router_confidence`   | enum (`high`\|`medium`\|`low`) | Required on `route_delegation`; from router's decision block                                                                  |
| `duration_s`          | integer                        | Required on `supervisor_stop`; wall-clock seconds from `supervisor_start` to now                                              |

## Transcript-Surfacing Summary Block

Required at the **end of every turn** the supervisor emits. This is the contract the shipped `/goal` evaluator consumes — when Anthropic's `/goal` Haiku evaluator is active it cannot run tools, so it judges progress from what the supervisor surfaces in conversation; the self-hosted Stop-hook greps the same block deterministically.

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

- **Machine-readable** for the `/goal` evaluator (jq can extract fields)
- **Human-readable** in the conversation transcript (it's pretty-printable)
- **Greppable** for retro analysis (`grep -A1 '```summary'`)
- **Stable** — the schema is a shipped one-way contract; field additions are safe, renames are not

### Why each turn

The `/goal` evaluator fires after every supervisor turn. If the summary block is missing, the evaluator must treat that turn as non-progress. The supervisor's job is to make every turn observable.

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
| Supervisor forgets summary block for one turn         | Next turn MUST emit it immediately; Step 5 review flags missing-summary streaks (the `/goal` evaluator flags them too)                               |

## Where This Runs

| Stage                                 | What happens                                                                                                         |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `03-execute.md` Pattern C             | Spawns supervisor agent BY DEFAULT for parallel-builder runs; falls through to Pattern A/B only when kill switch set |
| `07-retro.md` §8j-quater              | Reads supervisor-actions log; scores supervisor decision health 1-5; cleans up log on `RETRO_SUCCESS=1`              |
| `shared/orchestrator-interception.md` | Notes (in §Where This Runs) that supervisor is a caller of `route_orchestrator`, not a replacement                   |
| `shared/state-artifacts.md`           | Registers `plan-w-team-supervisor-actions-$SLUG.jsonl` as mode `handoff`                                             |
| `/goal` evaluator (shipped)           | Evaluator reads transcript summary blocks each turn to judge progress                                                |

## Parent-Child Terminal Propagation (2026-05-20)

The persistent supervisor described above owns Step 3-4 dispatch within ONE `/plan-w-team` run. A separate but related case: when a parent `/goal` session delegates an entire `/plan-w-team` run to a worker via `pwt-goal.sh --launch` (which spawns `claude --bg`), the parent must learn when the worker reaches terminal.

The goal-evaluator hook (`.claude/hooks/plan-w-team-goal-evaluator.sh`) handles this automatically by reading worker `goal-<SLUG>.json` state files directly — not by sniffing transcript anchors that only ever appear in the worker's own session. See `shared/goal-conditions.md` §Parent-Child Terminal Propagation for the precedence rules and fail-open contract.

For supervisors that ever spawn additional `claude --bg` children (rare — supervisors normally spawn agents via the `Agent` tool, not new sessions): such a spawn MUST be registered via `.claude/scripts/plan-w-team-register-spawn.sh` so the propagation works. Without registration, the parent's goal evaluator has no record of the child and will continue to wait on transcript anchors that never arrive in its own session.

## Post-Ship Off-Brief Drift — Auto Stand-Down (PWT-TERM, 2026-06-25)

A run can finish its lifecycle — ship to origin (a deterministic PASS ship-verdict at
`.claude/state/plan-w-team-ship-verdict-<slug>.json`, HEAD pushed) — yet keep the session
alive and drift into **new, unrequested work** if the goal never resolves SUCCESS. This is the
runaway-after-ship failure: worker `3ce4f51f` shipped 1.45.0 and then ran 48 min / 131k tokens
into a non-existent backlog (zero commits) before the origin-chat supervisor stopped it by hand.

**Rule (codifying what the supervisor did by hand):** once a run has demonstrably shipped
(PASS ship-verdict present OR HEAD pushed past the ship gate) and the only remaining activity
is NOT one of this run's spec ACs / queued tasks, the supervisor **stands the worker down and
surfaces it as a completion (SUCCESS), not an error**. "We already shipped" is an objective
signal that must dominate a missing/fragile `stage=retro-complete` + `workflow_lock=done`
transcript marker. The supervisor must NOT dispatch new off-brief work after ship.

**Deterministic enforcement:** the stand-down is enforced by the goal-evaluator, not left to
the supervisor's judgment. Its **PWT-TERM2 runaway guard** resolves SUCCESS the moment a PASS
ship-verdict (whose `ts` is at/after the goal's `started_at`) exists for the slug, even if the
paired marker was never emitted — and **PWT-TERM1** has retro authoritatively write
`terminal_state=SUCCESS` (`terminal_state_source=retro`, honored by the worker-mode spoof-guard
only when corroborated by that same PASS ship-verdict). Both unblock the Stop hook so the
session terminates instead of inventing work. The feature-AC AND-check and the PWT-ANTIPARK
empty-AC backlog check still run first, so a genuinely incomplete multi-AC run (or a multi-epic
program with unmet backlog) is never falsely stood down — only a run that truly shipped its
contract terminates. See `shared/goal-conditions.md` and the goal-evaluator hook for the
precedence and fail-open contract.

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

- **PWT-DS1** (process-level, mid-2026-05): even if the assistant ignores the systemMessage marker and calls `pwt-goal.sh --worker-only` anyway, the script checks `.claude/state/plan-w-team-hook-spawn-<sid>.flag` (written by the hook on successful spawn). A flag fresh within the `PWT_DOUBLE_SPAWN_WINDOW_MIN` window (default 3 minutes, mtime-based) for the current parent SID → refuse spawn, exit 3 (PWT_DS1_DUPLICATE label, code returns 3). The flag-file is registered in `shared/state-artifacts.md`.
- **PWT-DS2** (env-propagated, cascade guard): `pwt-goal.sh --worker-only` sets `PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1` in the spawned worker's environment. Any subsequent `pwt-goal.sh` invocation (worker-only OR launch) inside that env refuses to spawn (exit 4 `PWT_DS2_CASCADE`). Escape hatch: `PLAN_W_TEAM_FORCE_SPAWN=1` for legitimate nested runs.

**Defense-in-depth ordering** (first→last):

1. **LLM attention** (systemMessage marker scan) — fastest path; correct in ~99% of cases.
2. **PWT-DS1** flag file — process-level deterministic; catches LLM-attention misses (the case that produced commit `c9cfcd5`).
3. **PWT-DS2** env signal — catches the cascade pattern where a worker's goal text re-triggers the routing classifier (the case that produced commit `553ab85`).

This layering is intentional: the visual marker is the cheapest and most ergonomic; the flag-file is a backstop that requires no assistant cooperation; the env signal stops self-replication from inside the worker.

**Known limitation**: the UserPromptSubmit route hook does NOT fire on mid-work interrupts (a prompt submitted while the assistant is mid-turn) — a natural-language `/plan-w-team` trigger arriving that way needs manual routing, after the standard double-spawn check.

## Decision Matrix — Origin-Chat Supervisor Continuation (2026-05-22)

Spec: `docs/specs/supervisor-protocol-autonomy.md`

The origin-chat supervisor (Step 3c in the skill manifest) previously surfaced to the user on every worker terminal state, even when the outcome was reversible and CI was green. In multi-PR missions this blocks the user on input for every continuation. The Decision Matrix below tells the supervisor when it MAY auto-progress without user intervention vs. when it MUST surface.

The matrix is consulted in two places:

1. **On every observed worker terminal state** (the existing trigger).
2. **On every CONTINUATION CHECK tick** (idle-detection — see §POLLING LOOP below).

### Inputs

| Input              | Source                                                                                                |
| ------------------ | ----------------------------------------------------------------------------------------------------- |
| Worker terminal    | `claude agents --json` + `plan-w-team-goal-<SLUG>.json` `terminal_state`                              |
| PR CI status       | `gh pr list --state open --json number,statusCheckRollup,labels,isDraft --search 'head:<branch>'`     |
| DO-NOT-MERGE label | The PR's labels array (literal label `DO NOT MERGE`)                                                  |
| Governance surface | Diff path-glob match against `shared/governance-tags.md` (origin-chat supervisor runs the comparison) |
| Draft flag         | The PR's `isDraft` boolean                                                                            |

### Matrix

| Worker terminal       | PR CI | DO-NOT-MERGE label OR governance surface? | PR draft? | Action                                                                                                                                       |
| --------------------- | ----- | ----------------------------------------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| SUCCESS               | green | no                                        | no        | **AUTO-MERGE** (`gh pr merge --auto --squash --delete-branch <PR>`) + chain `next_batch_spec` if set on goal state                           |
| SUCCESS               | green | yes                                       | no        | **SURFACE** to user — one-way door requires explicit consent                                                                                 |
| SUCCESS               | red   | any                                       | no        | **SPAWN FIX-WORKER** via `pwt-goal.sh --worker-only` with goal "fix CI on PR #N: <failing checks>"                                           |
| SUCCESS               | any   | any                                       | yes       | **LEAVE** — user intentionally drafted the PR                                                                                                |
| USER_ESCALATION_HALT  | any   | any                                       | any       | **SURFACE** — hard-gate already fired upstream                                                                                               |
| LOW_CONFIDENCE_STREAK | any   | any                                       | any       | **SURFACE** — supervisor decisions are unreliable                                                                                            |
| DEAD                  | any   | any                                       | any       | **SURFACE** — worker died unexpectedly                                                                                                       |
| API_HALT              | any   | any                                       | any       | **RESTART (bounded N≤2)** — respawn continuation worker via `pwt-goal.sh --worker-only`; on budget exhaustion fall through to DEAD → SURFACE |
| no terminal yet       | any   | any                                       | any       | **POLL** — continue waiting                                                                                                                  |

### Actions, in detail

- **AUTO-MERGE**: emit a status block citing the matrix row and PR number, then invoke `gh pr merge --auto --squash --delete-branch <PR>`. The `--auto` flag is important — GitHub waits for any required checks even if the supervisor's snapshot showed green moments earlier. `--delete-branch` removes the merged remote branch so it does not linger (belt-and-suspenders with the helper's own remote-delete below). Log the merge as a per-turn surface line: `✅ auto-merged PR #N (reversible, CI-green, no governance tag)`. **Then reclaim the merged worktree immediately (REQ-4b)** — `gh pr merge` is an **admin-squash on the remote**, so NO local hook fires and the inline §6h ship-block never runs for a remote squash (or for a worker that wedged before ship). Right after the merge confirms, call `.claude/scripts/plan-w-team-worktree-on-merge.sh "<worktree>" "<branch>" "<slug>"` so the worktree is reclaimed now, not left for the nightly GC timer. **The helper now ALSO fast-forwards the primary checkout to `origin/<default>` and deletes the local+remote feature branch — do not skip it even on a remote admin-squash.** It enforces its own safety invariants (containment, uncommitted/in-use checks, idempotency, ff-only — never force-resets a primary with real local commits) and safe-skips rather than failing, so calling it unconditionally on the merged branch is safe.
- **CHAIN**: after AUTO-MERGE succeeds AND `next_batch_spec` is non-null, spawn the next worker via `pwt-goal.sh --worker-only "<request>"` (with `--type` if specified). PWT-DS1 / PWT-DS2 deterministic guards still apply — if a fresh hook flag is present or the env-cascade signal is set, the spawn refuses and the supervisor SURFACES instead.
- **SPAWN FIX-WORKER**: spawn a focused worker whose goal is the CI failure, NOT a re-run of the original mission. The fix-worker's goal directive references the failing checks verbatim. The supervisor returns to POLL on the fix-worker; on its SUCCESS the matrix consults again on the original PR.
- **RESTART (API_HALT — bounded reclaim)**: a worker wedged on a transient API/socket error is detected by the goal-evaluator (`plan-w-team-goal-evaluator.sh` classifies `API_HALT` when the child transcript is idle ≥ `PWT_API_HALT_IDLE_S` AND its last meaningful turn matches a transient-connection pattern from `pwt-transient-errors.sh`). On observing `API_HALT`: (1) read the restart-attempt count for this SID; (2) cap at `PWT_API_HALT_MAX_RESTARTS` (default 2); (3) optionally try `claude --resume <sid>` once as a cheap first attempt (a connection-dead session usually re-wedges, so don't rely on it); (4) respawn a continuation worker via `pwt-goal.sh --worker-only` seeded from the halted worker's last goal state; (5) log a `worker_restart` row to the supervisor-actions JSONL (`dead_sid`, `new_sid`, `attempt`); (6) PWT-DS1 (hook-spawn flag) and PWT-DS2 (env-cascade) anti-double-spawn backstops still apply — a refusal means SURFACE instead. On budget exhaustion, stop restarting and fall through to **DEAD → SURFACE**. A healthy worker is never restarted: the goal-evaluator's idle-mtime gate makes an actively-writing worker immune to API_HALT classification.
- **SURFACE**: emit a `⚠ HALT` block citing the matrix row + reason, stop polling, return control to the user. The supervisor does NOT exit — it waits for user input then resumes its loop.
- **LEAVE**: emit a one-line acknowledgment (`PR #N left as draft per user`) and continue polling other workers; the draft PR is not the supervisor's concern.
- **POLL**: continue the normal polling cadence (no surface).

### Hard Rules (revised 2026-05-22)

These supersede the previous "NEVER push to remote" wording. The origin-chat supervisor must follow these unconditionally:

- **NEVER merge irreversible PRs.** Irreversible = one-way door. The closed list lives in `shared/governance-tags.md`. The supervisor MUST run the diff-path comparison against that list before merging, even on PRs with no DO-NOT-MERGE label.
- **NEVER push to remote.** The worker pushes; the supervisor only merges existing remote PRs. (`gh pr merge` operates on remote state — it does not push from the supervisor's working tree.)
- **NEVER edit code, configs, or specs.** Implementation belongs to the worker.
- **INVARIANT: PWT mutates branches only inside `.claude/worktrees/<name>/` worktrees.** The primary checkout must remain on the default branch at all times. If it is found elsewhere with no unique commits, restore it to the default (see `pwt-goal.sh` `--launch` preflight `__assert_primary_on_default` and `plan-w-team-worktree-on-merge.sh` `__resync_primary_checkout`). Never force-move a primary that carries real local commits — warn and leave it.
- **NEVER spawn more than one chain-worker per AUTO-MERGE.** `next_batch_spec` is consumed exactly once; the new worker carries no `next_batch_spec` of its own unless its own retro sets one (PWT-DS2 also enforces this via env-cascade).
- **Auto-merge reversible code/test PRs within the same mission** per the Decision Matrix. Reversibility is established by (a) no DO-NOT-MERGE label, (b) no `shared/governance-tags.md` surface match, (c) CI green.
- **NEVER `gh pr merge --admin` on a repo with GitHub Actions required checks** unless the deterministic merge-gate (`.claude/scripts/supervisor-merge-gate.sh`) returned `recommended_action=ADMIN_MERGE` for the PR. `--admin` bypasses required checks; on repos where GitHub Actions IS the required check, this skips CI. Use `--auto` instead and let GitHub wait for checks. The gate's `ci_mode` field is the authoritative input for this rule. See §CI-Aware Action Hierarchy below.

### CI-Aware Action Hierarchy (2026-05-22 — supersedes the simpler matrix above)

The Decision Matrix above tells the supervisor WHEN to act (worker terminal + PR state). The hierarchy below tells the supervisor HOW to act (which `gh pr merge` flag, or whether to surface). It is implemented by `.claude/scripts/supervisor-merge-gate.sh` — the supervisor MUST invoke the script before any merge action and use its `recommended_action` field rather than re-deriving the decision from raw inputs.

**Originating evidence**: cleanscale incident 2026-05-22 — supervisor used `gh pr merge --admin --squash $PR` to clear a DO-NOT-MERGE-labeled PR. On cleanscale (local-Makefile-only CI), this was functionally equivalent to `--auto`. On a typical SaaS repo with GitHub Actions required checks, this would have bypassed CI without operator consent. The hierarchy makes the supervisor's choice deterministic and CI-aware.

Spec: `docs/specs/supervisor-merge-enforcement.md`. Script: `.claude/scripts/supervisor-merge-gate.sh`.

| Row | `governance_surfaces_matched` | `has_do_not_merge_label` | `ci_mode`        | `recommended_action` | Rationale                                                                                             |
| --- | ----------------------------- | ------------------------ | ---------------- | -------------------- | ----------------------------------------------------------------------------------------------------- |
| 1   | non-empty                     | (any)                    | (any)            | `SURFACE_TO_USER`    | One-way door — explicit human consent always required.                                                |
| 2   | empty                         | `true`                   | `local-makefile` | `ADMIN_MERGE`        | Supervisor-reviewer pattern: worker added the label as precaution; supervisor IS the human review.    |
| 3   | empty                         | `true`                   | `github-actions` | `SURFACE_TO_USER`    | Real CI required-checks need a real human to authorize bypass. NEVER `--admin` here.                  |
| 4   | empty                         | `true`                   | `none`           | `SURFACE_TO_USER`    | Conservative — unknown CI posture defaults to user.                                                   |
| 5   | empty                         | `false`                  | `github-actions` | `AUTO_MERGE`         | `gh pr merge --auto --squash --delete-branch` — GitHub waits for required checks.                     |
| 6   | empty                         | `false`                  | `local-makefile` | `ADMIN_MERGE`        | `gh pr merge --admin --squash --delete-branch` — no `--auto` target exists; local CI passed pre-push. |
| 7   | empty                         | `false`                  | `none`           | `ADMIN_MERGE`        | `gh pr merge --admin --squash --delete-branch` — no CI to wait on.                                    |

**`ci_mode` detection** (script-level heuristic, NOT a `gh api` round-trip):

- `github-actions`: any `.github/workflows/*.y*ml` defines a `pull_request:` trigger.
- `local-makefile`: `Makefile` at repo root has a `test` / `test-skill` / `check` / `lint` target AND no qualifying workflow exists.
- `none`: neither holds.

**How the supervisor uses the gate**:

```bash
GATE=$(.claude/scripts/supervisor-merge-gate.sh "$PR_NUMBER")
ACTION=$(echo "$GATE" | jq -r '.recommended_action')
case "$ACTION" in
  AUTO_MERGE)         gh pr merge --auto  --squash --delete-branch "$PR_NUMBER" ;;
  ADMIN_MERGE)        gh pr merge --admin --squash --delete-branch "$PR_NUMBER" ;;
  SURFACE_TO_USER)    # emit ⚠ HALT block citing $(echo "$GATE" | jq -r '.rationale')
                      ;;
esac
```

The gate fails-closed: on any `gh` or parse error, `recommended_action=SURFACE_TO_USER` with a `rationale` describing the failure. The supervisor never has to interpret "the gate script failed" — it reads `recommended_action` and acts.

**Why the matrix is doc + script, not just script**: prose in this file is the source of truth for human reviewers and retros; the script encodes the same hierarchy mechanically. If the two ever drift, the prose wins (and the script is updated to match in a follow-up). The regression scenario at `tests/skill/scenarios/supervisor-merge-gate-governance.bats` covers the rows the script must implement.

### `next_batch_spec` Chaining

Schema lives in `shared/goal-conditions.md` §Chain Continuation. On every AUTO-MERGE action, the supervisor re-reads the just-merged worker's `plan-w-team-goal-<SLUG>.json` to check for `next_batch_spec`. When present:

1. Parse `request` (required), `type` (default `feature`), `started_from_slug` (audit).
2. Spawn via `pwt-goal.sh --worker-only "<request>"` (with `--type <type>` if non-default).
3. The new worker writes its OWN goal state file with a fresh slug derived from `request`.
4. Chain terminates when a worker's retro does NOT set `next_batch_spec` (or sets it to `null`).

A chain is auditable: every worker's `started_from_slug` walks back to the original `/goal` invocation.

## POLLING LOOP

The origin-chat supervisor's polling loop has three responsibilities per tick, in order: (0) PROGRESS CHECK (added 2026-05-25), (1) standard worker observation, (2) CONTINUATION CHECK (added 2026-05-22).

> **Standing hygiene duty (1.32.0):** at pre-flight AND on each supervisor wake, run
> `.claude/scripts/plan-w-team-hygiene-sweep.sh` (dry-run by default; `--execute` to
> reclaim) and **surface its one-line summary** in the per-wake transcript block —
> `hygiene-sweep: df_free_gb=… worktrees=… wt_reaped=… companions_reaped=… orphan_dirs=… mode=… action=…`.
> It composes the worktree GC (now reaping `SAFE-PRUNE-PUSHED` for the push-not-merge
> lifecycle), the companion GC (orphan watchers + leaked build daemons), and the disk
> gate, so cruft from prior runs is swept before it blocks a spawn (the 2026-05-29
> 67-worktree → ENOSPC failure this prevents). See
> [`docs/operations/worktree-lifecycle.md`](../../../docs/operations/worktree-lifecycle.md) §Push-not-merge hardening.

### Step 0: Progress Check (anti-stall + anti-drift) — runs FIRST, every tick

> **Durable rule:** A monitoring-only tick is a **FAILURE while the backlog is > 0.** Progress is measured **objectively** (real metrics moved), never self-reported. Watching the worker and writing `"goal_progress": "progressing"` is NOT progress if nothing landed. "Memory pressure", a "perceived ceiling", or an `AT_CAPACITY` RAM verdict do **not** license indefinite idling — if they block progress for `STALL_THRESHOLD` ticks, that is a STALL to escalate, not a state to sit in.

Before anything else, run the mechanical self-check:

```bash
.claude/scripts/supervisor-progress-check.sh --slug "$SLUG"
# --slug "$SLUG" is REQUIRED (2026-06-07 hermeticity fix): it writes the snapshot to
# the run's own .claude/state/supervisor-progress-<slug>.json (carrying a slug field),
# which the goal-evaluator anti-park reader scopes to. WITHOUT --slug the writer falls
# back to the legacy global supervisor-progress.json and the slug-keyed reader ignores
# it (fail-open) — so the anti-park gate goes inert. Always pass the run's SLUG.
# The script resolves its own stall threshold from PWT_AUTONOMY_PROFILE / STALL_THRESHOLD
# (strict/unset = 2, relaxed = 4); do NOT pass `--threshold "${STALL_THRESHOLD:-2}"` here
# — that hardcodes 2 and would make PWT_AUTONOMY_PROFILE=relaxed inert. Pass --threshold
# only to force a specific value (e.g. tests). It also auto-detects the run's AC snapshot
# under .claude/state/ for the backlog anchor; pass --spec / --transcript explicitly if
# the run stores them elsewhere.
```

It snapshots objective, user-verifiable metrics (branch commit count, AC-PASS
count from the run's spec roll-up, open-PR count), diffs them against the prior
tick in the run's slug-keyed `.claude/state/supervisor-progress-<slug>.json`, and
emits a verdict:

| Verdict                       | Meaning                                           | Supervisor action                                                                                             |
| ----------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `PROGRESSING`                 | a metric moved                                    | continue normal tick                                                                                          |
| `IN-FLIGHT`                   | an `agent-*` worktree touched < 30 min ago        | continue; work is cooking                                                                                     |
| `BACKLOG-CLEAR`               | all known ACs pass                                | continue toward ship/retro                                                                                    |
| `STALLED` / `STALLED-UNKNOWN` | no movement (streak < threshold, or no AC source) | continue but on notice                                                                                        |
| `🔴 STALL-ALERT` (exit 2)     | `STALL_THRESHOLD` flat ticks, backlog > 0         | **MUST act this tick: spawn the next backlog item OR escalate a hard-gate to the user. Idling is forbidden.** |

**Anti-drift anchor:** the run's own backlog is the locked target list — the
Step-1 spec ACs still failing + Step-2 tasks not yet done. On `STALL-ALERT` the
supervisor pulls its next item **only** from there; it never improvises
off-target work to manufacture motion.

**Enforced at the Stop decision, not just advised here (PWT-ANTIPARK, 2026-06-07).**
This Step-0 check used to be a rule the supervisor was trusted to run each tick — a
supervisor that simply _stopped_ (rather than running another tick) bypassed it and
silently parked (the 2026-06-07 cleanscale incident: false-green caught + reverted,
then parked in "recalibration" with 5/6 epics unbuilt). The slug-keyed snapshot
`supervisor-progress-<slug>.json` this script writes is now ALSO read by the
goal-evaluator Stop hook (scoped to the current run's slug only — see the
hermeticity note in `shared/goal-conditions.md §Anti-Park Gate`): a supervisor
yield while `verdict=STALL-ALERT ∧ backlog>0` is **blocked**,
forcing re-dispatch/escalation instead of a silent park. So "monitoring-only tick =
failure while backlog>0" is now a gate, not only prose. See
`shared/goal-conditions.md §Anti-Park Gate`, `shared/self-regulation.md §Supervisor
Self-Regulation`, and `docs/operations/supervisor-no-park-rootcause-2026-06-07.md`.
Kill switch `PLAN_W_TEAM_DISABLE_ANTIPARK=1` (fail-open). This does NOT replace the
supervisor running this check each tick — running it is what keeps the snapshot
fresh so the enforced gate has an accurate signal.

**Effort-escalation rung (REQ-3 — autonomous "go deeper when stuck").** On
`STALL-ALERT` (or a `LOW_CONFIDENCE_STREAK`), before re-attempting the next backlog
item, **elevate the reasoning budget for the recovery turn** — interleaved-thinking
/ `ultrathink` / `/effort xhigh` — rather than retrying at default effort.
(Pin caveat, skill 1.52.3: `/effort xhigh` raises YOUR turn only — pinned team
subagents (builder, builder-opus, evaluator, validator, silent-failure-hunter)
keep `effort: high`; `ultrathink` in a re-spawn prompt deepens thinking within
that pin. The effective per-task escalation for a re-spawn is the model bump —
hard-lane re-dispatch per 04-fix-first REQ-3.) Trade
tokens for depth in place. This is the bg-autonomous equivalent of "an operator
invokes a workflow when stuck": the same recovery instinct, expressed as effort
because **`CLAUDE_CODE_DISABLE_WORKFLOWS=1` stays for bg (PWT-WF1)** — a bg worker
must NOT spawn nested workflows that bypass the RAM gate. Workflows remain an
operator/interactive lever; effort escalation is the autonomous one.

This **complements** the CONTINUATION CHECK below (which keys on user-input
silence). Step 0 keys on objective work-progress — a supervisor can be inside
the idle window yet still failing because nothing is landing; Step 0 catches that.

### Standard Tick

1. `claude agents --json` — confirm worker SID still listed; if absent for ≥2 ticks, treat as DEAD per matrix.
2. `.claude/scripts/pwt-status.sh <SLUG>` — the **canonical run manifest** rollup (structured; no ANSI log-grep). Reports the live stage, strategy, builder roster (spawned/running/completed), and task list — from a main-checkout-relative file the worker updates each stage, so this works even though the worker runs in a worktree. **Surface a one-line stage summary to the user whenever the stage advanced since the last tick** (e.g. `▸ <slug>: stage 3-execute → 5-ship, 3 builders (2 done, 1 running)`). This is the origin-chat surfacing of mid-run progress — the founder sees the stage without reading the worker transcript. Fall back to `claude logs <SID> --tail 200` only if the manifest is absent (older worker / pre-manifest run).
3. `.claude/state/plan-w-team-goal-<SLUG>.json` — read `terminal_state`; on non-null, consult Decision Matrix.
4. `.claude/state/pwt-completion-summary-<SID>.md` — surface if ship/retro stages wrote one this tick.
5. **Fix-Now Audit** — scan the tick's worker log + persisted review findings for any defect or flaky test logged as merely **"noted"** (or a flaky "fixed" by loosen/retry/`.skip`/timeout-widen). See Fix-Now Audit below.

### Fix-Now Audit (ENFORCING — every check-in)

The supervisor verifies at **every** check-in that the worker is honoring the
fix-immediately rule (`04-fix-first-review.md` §5-0, memory
`feedback_fix_defects_and_flaky_immediately`):

- **No defect/flaky logged as merely "noted".** A real defect (failed test, type/lint
  error, broken assertion) or a flaky test recorded as "noted" with no completed
  fix→retest→verify-GREEN is a violation. The supervisor **pushes it back to fix-now**
  before the worker proceeds — either by surfacing a corrective instruction to the worker
  (`SendMessage`/log) or, if the worker has the local-CI path, directing it through
  fix→deploy→retest→GREEN. It does NOT let the run advance with the item merely noted.
- **No masked flaky.** A flaky "fixed" by loosening an assertion, adding a retry,
  `.skip`/`xfail`, or widening a timeout did not remove the non-determinism — the
  supervisor rejects it and requires a real repair (mock/stub/pin/isolate, 100/100).
- **No GH-Actions build/deploy drift.** A new `.github/workflows/*.yml` build/deploy path
  (non-exempt per `shared/no-github-actions.md`) is a defect — push it back to fix-now.

This is a verification responsibility, not a fix responsibility: the supervisor never
edits code itself (see Hard Rules), it directs the worker to fix now and blocks
advancement until the item is GREEN, not "noted".

**Auto-terminate of origin mirror (2026-05-22)**: The origin chat's mirror goal-state file (`.claude/state/plan-w-team-goal-<SLUG>.json`, written by `pwt-goal.sh --supervisor-goal`) **auto-terminates on worker retro** — no manual `jq` intervention needed. Mechanism: `pwt-goal.sh --supervisor-goal` registers the mirror in the spawned-children registry as `type=supervisor_mirror`; on worker retro, `07-retro §8j-sexies → child-cleanup.sh` patches the mirror to SUCCESS. If the worker dies without retro, the goal-evaluator hook's DEAD-detection branch patches the mirror to LOW_CONFIDENCE_STREAK. See `docs/specs/supervisor-mirror-lifecycle.md`.

### Wait mechanism — EVENT-DRIVEN by default (do not guess a poll interval)

When the supervisor is **waiting on a worker to reach terminal/halt** (the common
case between progress ticks), prefer an **event-driven wait** over active polling.
Active polling guesses a 30–60s cadence: if the worker finishes 2s after a tick,
~58s of dev time is lost before the supervisor notices, and every unchanged tick
burns a supervisor turn. Instead, launch a background watcher that blocks until
the state flips and wakes the supervisor THE INSTANT it does:

```bash
# Mark THIS session as a supervisor so the goal-evaluator lets it YIELD (sleep)
# instead of dragging it back to busy-poll every turn (PWT-SUP-YIELD). The worker
# never sets this — pwt-goal forces it to 0 — so worker blocking is unchanged.
export PLAN_W_TEAM_SUPERVISOR_SESSION=1
# run_in_background: true — the harness re-invokes the supervisor when this exits.
.claude/scripts/plan-w-team-await-terminal.sh --slug "$SLUG" --worker-sid "$WORKER_SID"
```

Without `PLAN_W_TEAM_SUPERVISOR_SESSION=1`, the goal-evaluator Stop hook (which fires in EVERY session that sees the worker's goal-state, including this supervisor) blocks the supervisor's stop each turn — so even with the await-loop running, the supervisor is pulled back to poll rather than truly sleeping (observed 2026-06-02). The flag tells the evaluator "this session supervises, it doesn't own a pipeline → let it yield"; it then sleeps until the await-loop exits (terminal/halt) or its heartbeat re-arms it to run the Step-0 progress check.

It watches the goal-state `terminal_state` (which the evaluator writes for ALL
terminal/halt states — SUCCESS, USER_ESCALATION_HALT, LOW_CONFIDENCE_STREAK,
API_HALT, so the **sad path wakes too, not just the happy path**) and the worker's
liveness (debounced against flaky `claude agents --json`). Exit codes: `0` =
terminal/halt reached (read `terminal_state` and emit the TERMINAL/⚠HALT block);
`3` = heartbeat re-arm (re-run the Step-0 progress check, then re-launch the wait —
this is a heartbeat, **NOT** a wall-clock cap; principle #3 forbids turn/time caps
on the work); `4` = duplicate watcher (1.54.0 singleton — another watcher already
owns this slug+worker-sid wait: DEFER to it, do **NOT** re-launch; re-launching
loops straight back to exit 4). Tune via `PWT_AWAIT_INTERVAL_S` /
`PWT_AWAIT_HEARTBEAT_S`.

**Worktree-aware goal-state resolution (PWT-WT2).** PWT-WT1 spawns `--worker-only`
workers with `claude --bg --worktree`, so the worker runs inside
`.claude/worktrees/<slug>/` and its goal-state may live there, not in the main
checkout. `await-terminal.sh` resolves the goal-state **each tick** in precedence:
(1) explicit `--state-dir`; (2) main `<root>/.claude/state/plan-w-team-goal-<SLUG>.json`;
(3) worktree fallback `<root>/.claude/worktrees/*/.claude/state/plan-w-team-goal-<SLUG>.json`.
So the supervisor passes only `--slug "$SLUG"` (the `SLUG_GUESS` under which
`pwt-goal.sh --worker-only` seeds the file) and need NOT hand-read worktree state;
pass `--state-dir <dir>` only to pin a known location. Because `pwt-goal.sh`
**seeds** `plan-w-team-goal-<SLUG>.json` at spawn (the anti-skip anchor — see
`shared/goal-conditions.md`), the PRIMARY `terminal_state` trigger is active from
t=0 even when the worker idles at terminal without exiting; `WORKER_GONE` + heartbeat
remain as belt-and-braces backstops. This is what closed the 2026-06-02 regression
where the supervisor only ever woke on the 30-min heartbeat (the worktree-isolated
worker's file was invisible to a main-only watcher). Spec:
`docs/specs/supervisor-wait-worktree-aware.md`.

**Fallbacks** (when the event-driven wait is unavailable — e.g. a cross-session
gap the bg process can't span): active poll at ~30–60s via `Bash + sleep`, or
`ScheduleWakeup` (for idle gaps >5 min, to stay within the prompt-cache window).
The Step-0 Progress Check and CONTINUATION CHECK still run on each wake regardless
of which wait mechanism delivered it.

### CONTINUATION CHECK (idle-detection)

After the standard tick, additionally check:

1. **User-input silence ≥ `PLAN_W_TEAM_IDLE_THRESHOLD_S` seconds** (default `300`). Measured by the transcript file's mtime:

   ```bash
   IDLE_S=$(($(date +%s) - $(stat -f %m "$CLAUDE_TRANSCRIPT_PATH" 2>/dev/null || echo "$(date +%s)")))
   ```

   (macOS `stat -f %m`; Linux `stat -c %Y`. When the transcript path is unavailable, skip CONTINUATION CHECK silently — `IdleCheckUnavailable` rescue.)

2. **All registered workers terminal SUCCESS** — aggregate via `.claude/state/plan-w-team-spawned-children-<SLUG>.jsonl`. Every registered child's `plan-w-team-goal-<CHILD_SLUG>.json` must have `terminal_state == "SUCCESS"`.

3. **All open PRs from this mission CI-green** — `gh pr list --state open --json number,statusCheckRollup --search 'head:<branch-prefix>'`. Every rollup must be `SUCCESS`.

4. **No PR carries a `DO NOT MERGE` label** — `gh pr list --state open --json labels --search 'head:<branch-prefix>'`. Every PR's labels array must lack the literal `DO NOT MERGE` label.

When ALL four conditions hold, the supervisor proceeds per the Decision Matrix on each PR as if the worker had just signaled terminal. The user does not need to type "continue" — the idle window is the consent signal.

**Threshold override**: `PLAN_W_TEAM_IDLE_THRESHOLD_S=86400` effectively disables CONTINUATION CHECK (no realistic mission is idle for a day). Set to `0` to disable the silence requirement entirely (auto-progress on every tick where workers + PRs are clean — aggressive; only use when explicitly authorized).

**Why mtime, not transcript-tail scan**: parsing the transcript for "last user turn" is fragile across Claude Code versions. `stat` on the transcript file is the single deterministic signal Claude Code commits to maintaining (the file is rewritten on each user turn).

**Failure mode**: `stat` failure (transcript path absent, EACCES) → `IdleCheckUnavailable` → CONTINUATION CHECK skipped that tick; standard polling continues. The supervisor does not surface or block on this.

### CAPACITY CHECK (RAM-aware spawn gating)

When CONTINUATION CHECK is about to authorize a new batch (or when the supervisor itself is the entity considering a `pwt-goal.sh` invocation for the next batch), it MUST consult `.claude/scripts/ram-budget.sh` BEFORE spawning. This is the same gate `pwt-goal.sh` applies at its own entry point (PWT-RAM1), surfaced one layer up so the supervisor can hold and re-poll rather than discovering the refusal mid-spawn.

```bash
RAM_JSON=$(.claude/scripts/ram-budget.sh 2>/dev/null)
RAM_ACTION=$(printf '%s' "$RAM_JSON" \
    | grep -oE '"recommended_action": *"[^"]*"' \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/')

case "$RAM_ACTION" in
    SPAWN_OK|"")    # SPAWN_OK or fail-open (null) → proceed
        ;;
    AT_CAPACITY|REDUCE_PARALLEL)
        # Surface AT_CAPACITY to the transcript; hold the batch decision
        # until either (a) a peer terminates and frees RAM, or (b) the
        # operator manually overrides via PLAN_W_TEAM_DISABLE_RAM_GATE=1.
        # DO NOT spawn. DO NOT silently retry. Continue polling so the
        # user sees why no new batch is starting.
        ;;
esac
```

**Hard rules** (mirror the existing supervisor "never does" list in §Delegation Contract):

- The supervisor does NOT bypass the gate. If the gate refuses, the supervisor surfaces a status block citing the verdict and waits.
- The supervisor does NOT modify `PLAN_W_TEAM_DISABLE_RAM_GATE` — that override is reserved for the operator.
- The supervisor does NOT escalate AT_CAPACITY as a hard-gate halt. It is a transient backpressure signal, not a failure. The next CAPACITY CHECK tick may clear it (a peer session terminates, free memory recovers).

**Surface format**: when CAPACITY CHECK refuses to authorize a batch, the supervisor's per-turn summary block records `ram_gate: AT_CAPACITY` (or `REDUCE_PARALLEL`) alongside the standard summary fields. Retro reads these counts to compute the "stalled-on-RAM" duration as a quality signal.

**Why this lives in the supervisor and not only in pwt-goal.sh**: `pwt-goal.sh` is the last-line process-level guard, but it refuses with exit 5. By the time exit 5 fires, the supervisor has already committed to the spawn intent — wasting an LLM turn on a refused operation. Putting the check in the POLLING LOOP defers the spawn decision until budget exists, which is the user's stated optimization: _maximize parallel without exceeding RAM_.

See `shared/ram-budget.md` for the capacity model, defaults, override env, and tuning guidance.

### FAIR SHARE CHECK (cross-repo allocation)

CAPACITY CHECK ensures the host has RAM for another worker. FAIR SHARE CHECK ensures that RAM is divided fairly across repos with demand. Without it, a single repo running parallel /plan-w-team workers can monopolize machine capacity and starve other repos — the 2026-05-22 cleanscale incident that motivated PWT-RAM2.

**When it runs**: immediately after CAPACITY CHECK reports SPAWN_OK, and before the supervisor authorizes any new `pwt-goal.sh` invocation. If CAPACITY CHECK refused, FAIR SHARE is moot (no spawn is happening either way).

**The registry**: `~/.claude/state/pwt-ram-claims.jsonl` (override via `PWT_RAM_CLAIMS_REGISTRY`). One JSONL line per active worker:

```json
{
  "repo": "<name>",
  "sid": "<8hex>",
  "started_at": "<iso8601>",
  "estimated_gb": 1.8,
  "priority": "normal"
}
```

The registry is cross-repo and machine-wide — every `pwt-goal.sh --launch` and `--worker-only` invocation on this machine appends a row regardless of which repo the worker belongs to.

**Lifecycle**:

- **Add**: `pwt-goal.sh` appends a row after `claude --bg` returns a parsed SID.
- **Remove**: `plan-w-team-child-cleanup.sh` calls `pwt-ram-claim.sh remove <sid>` after `claude stop` (idempotent — no-op if the row wasn't there).
- **Sweep**: the supervisor calls `pwt-ram-claim.sh sweep` at the start of FAIR SHARE CHECK so claims for workers whose transcript mtime is older than `PWT_FAIR_SHARE_IDLE_THRESHOLD` (default 300s = 5min) are dropped. This recovers capacity when a worker died without running the cleanup hook (crash, kill, OOM).

**The check**:

```bash
.claude/scripts/pwt-ram-claim.sh sweep
FS_JSON=$(.claude/scripts/pwt-fair-share.sh 2>/dev/null)
FS_RECO=$(printf '%s' "$FS_JSON" \
    | grep -oE '"recommendation": *"[^"]*"' \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/')

case "$FS_RECO" in
    SPAWN_OK|"")             # proceed
        ;;
    AT_FAIR_SHARE)
        # All repos are at exact share; spawning would push this repo over,
        # but no specific peer is underserved. Hold for backpressure or yield
        # if priority=background.
        ;;
    YIELD_TO_OTHER_REPO)
        # Another repo is below its share. Hold this batch; the peer is
        # likely about to spawn and the registry will rebalance.
        ;;
esac
```

**Allocation math**: `fair_share_per_repo = max(1, machine_capacity / n_active_repos)`, where `n_active_repos` counts repos in the registry plus the asker (if not already present) — so a new repo never gets 0 share just because everyone else got there first. `machine_capacity = remaining_capacity_from_ram_budget + currently_claimed_workers` (total slots, not just free slots).

**Priority signals** (`PWT_RUN_PRIORITY` env, propagated to the worker via the claim row):

- `critical` — bypasses fair-share entirely; only `NO_CAPACITY` (which CAPACITY CHECK already caught) can block. Use sparingly: every critical bypass directly degrades fairness for peers.
- `normal` (default) — subject to fair-share. Refused on `YIELD_TO_OTHER_REPO` and `AT_FAIR_SHARE`.
- `background` — yields first under ANY contention (`n_total_active >= machine_capacity`). Use for background catch-up batches that should never compete with foreground work.

**Hard rules** (mirror CAPACITY CHECK):

- The supervisor does NOT bypass the fair-share gate. Refusals surface a status block citing the verdict and wait.
- The supervisor does NOT modify `PLAN_W_TEAM_DISABLE_FAIR_SHARE` — that override is reserved for the operator.
- The supervisor does NOT escalate `YIELD_TO_OTHER_REPO` as a hard-gate halt. It is reactive backpressure; the next tick may clear it (the underserved peer spawned, dropped a claim, or terminated).

**Surface format**: when FAIR SHARE CHECK refuses, the supervisor's per-turn summary records `fair_share: YIELD_TO_OTHER_REPO` (or `AT_FAIR_SHARE`) alongside the standard fields. Retro reads these to compute time spent yielding to peers — a healthy run should have `fair_share` deferrals < 10% of total ticks.

**Failure mode**: registry missing or unreadable → fair-share script emits `recommendation: null` (fail-open advisory); supervisor proceeds as if SPAWN_OK. The gate is advisory, not load-bearing for correctness.

See `docs/specs/pwt-cross-repo-fair-share.md` for the full design and AC catalog.

### CAPACITY & CONFLICT ANALYSIS (per-batch file-overlap)

CAPACITY CHECK gates on machine RAM. FAIR SHARE CHECK gates on cross-repo fairness. Neither catches the third dimension: **inter-task file overlap within a single repo's spawn batch**. A repo with capacity for 4 parallel workers and 4 pending tasks can still produce merge-conflict churn if 3 of the 4 tasks all touch `shared/supervisor-protocol.md`. CAPACITY & CONFLICT ANALYSIS gates on that.

**When it runs**: immediately after FAIR SHARE CHECK has reported SPAWN_OK and the supervisor has ≥2 queued tasks ready to spawn in the next batch. For a single queued task, this step is a no-op (no peer to conflict with).

**The check**:

```bash
.claude/scripts/pwt-conflict-detector.sh "$QUEUED_DIRECTIVE_1" "$QUEUED_DIRECTIVE_2" ... > "$CD_OUT"

LARGEST_PARALLEL_SAFE_GROUP=$(grep -oE '"parallel_safe_groups": *\[[^]]*\]' "$CD_OUT" \
    | head -1 \
    | grep -oE '\[[^]]*\]' \
    | tail -n +2 \
    | awk -F',' '{print NF}' \
    | sort -rn \
    | head -1)
# LARGEST_PARALLEL_SAFE_GROUP is the size of the biggest set of tasks that can run
# in parallel without file-overlap conflicts. Tasks within the same group must
# be serial; tasks across different groups are parallel-safe.

RAM_CAPACITY=$(printf '%s' "$RAM_JSON" \
    | grep -oE '"capacity_for_new_sessions": *[0-9]+' \
    | sed -E 's/.*: *//')
FAIR_SHARE_HEADROOM=$(( MY_REPO_ALLOWED_MAX - MY_REPO_CURRENT ))

# Compose the three gates into a single batch-size recommendation.
RECOMMENDED_BATCH=$LARGEST_PARALLEL_SAFE_GROUP
[ "$RAM_CAPACITY"        -lt "$RECOMMENDED_BATCH" ] && RECOMMENDED_BATCH=$RAM_CAPACITY
[ "$FAIR_SHARE_HEADROOM" -lt "$RECOMMENDED_BATCH" ] && RECOMMENDED_BATCH=$FAIR_SHARE_HEADROOM
[ "$RECOMMENDED_BATCH"   -lt 1 ] && RECOMMENDED_BATCH=1
```

**Composition rule**: `recommended_batch = min(largest_parallel_safe_group, ram_capacity, fair_share_headroom)`. The smallest of the three caps wins. The supervisor authorizes that many spawns this tick; the remaining queued tasks wait for the next batch.

**Why three gates and not one**: each gate measures an orthogonal property:

- `ram-budget.sh` ↔ machine-wide memory ceiling (process-level)
- `pwt-fair-share.sh` ↔ cross-repo fairness (claims-registry-level)
- `pwt-conflict-detector.sh` ↔ intra-repo file-overlap (directive-level)

A worker can be RAM-safe, fair-share-safe, AND still race another worker on `shared/supervisor-protocol.md`. The detector is the only gate that reads the actual task content.

**Hard rules** (mirror CAPACITY CHECK and FAIR SHARE CHECK):

- The supervisor does NOT bypass conflict-detector verdicts; serialized groups stay serial within a batch.
- The supervisor does NOT modify the detector's grouping output to force more parallelism. If the largest parallel-safe group is smaller than RAM allows, the limiting factor is conflict-detector; that's the honest signal.

**Surface format**: when CAPACITY & CONFLICT ANALYSIS bounds the batch, the supervisor's per-turn summary block records `conflict_groups: <N>` (count of distinct parallel-safe groups) and `recommended_batch: <K>`. If conflict is the binding constraint (smaller than `ram_capacity` and `fair_share_headroom`), additionally log `parallelism_bound_by: conflict-detector` so retro can identify how often file-overlap is the throughput bottleneck. A healthy run touching unrelated files should rarely show this; a run editing shared infrastructure is expected to.

**Failure mode**: detector script missing, unreadable, or returns `parallel_safe_groups: []` for nonempty input → treat as fail-open advisory; supervisor falls back to `recommended_batch = min(ram_capacity, fair_share_headroom)` and logs `conflict_detector: unavailable` once per batch decision.

**Unknown-scope handling**: tasks whose directive mentions no recognized path patterns appear in `tasks_with_unknown_scope`. They are treated as parallel-safe (own group) but flagged so the supervisor can surface `unknown_scope_tasks: <N>` to retro — high counts suggest directives need stricter file-touch listings.

See `docs/specs/task-conflict-detector.md` for the full design, algorithm, and AC catalog.

## Adding a New Event Type or Summary Field

When extending the supervisor (e.g. for T5 integration):

1. Add the new event type or field to the schema tables above with type + when-required notes.
2. Update the supervisor's system prompt (`.claude/agents/team/supervisor.md`) to emit it.
3. Update `07-retro.md` §8j-quater if the new field affects scoring.
4. Update the symmetry-check registry row if the on-disk path or pattern changes.
5. Add a test case in `plan-w-team-supervisor-route.test.sh` if it affects the wrapper.
6. If the change touches the **summary block schema**, document the version bump in this file (the block is a shipped one-way contract).

## Optional: Live-Supervision Dashboard Artifact (Hook 4 — OFF by default)

The origin-chat supervisor MAY maintain a self-contained HTML dashboard that re-renders
as the worker progresses — the one "updates while you watch" use that fits the `--bg`
model. **Best-effort, OFF by default, never blocks supervision** (the renderer is
fail-open and the re-render is fire-and-forget).

```bash
# snippet-lint: skip — illustrative; assemble ONE JSON from the live artifacts, then render.
# data shape: {slug, terminal_state, progress:{tasks_done,tasks_total}, stages:[…], fleet:[…]}
.claude/scripts/plan-w-team-render-artifact.sh --kind dashboard \
  --data ".claude/state/dashboard-${SLUG}.json" \
  --out  ".claude/state/dashboard-${SLUG}.html" || true
```

The supervisor assembles the JSON from `plan-w-team-goal-<SLUG>.json`,
`plan-w-team-stage-events-<SLUG>.jsonl`, `plan-w-team-fleet-<SLUG>.jsonl`, and
`supervisor-progress-<SLUG>.json` (all read-only). See
`docs/operations/plan-w-team-visual-artifacts.md`.
