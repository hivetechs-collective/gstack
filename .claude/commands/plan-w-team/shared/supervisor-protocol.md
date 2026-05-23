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

| Worker terminal       | PR CI | DO-NOT-MERGE label OR governance surface? | PR draft? | Action                                                                                             |
| --------------------- | ----- | ----------------------------------------- | --------- | -------------------------------------------------------------------------------------------------- |
| SUCCESS               | green | no                                        | no        | **AUTO-MERGE** (`gh pr merge --auto --squash <PR>`) + chain `next_batch_spec` if set on goal state |
| SUCCESS               | green | yes                                       | no        | **SURFACE** to user — one-way door requires explicit consent                                       |
| SUCCESS               | red   | any                                       | no        | **SPAWN FIX-WORKER** via `pwt-goal.sh --worker-only` with goal "fix CI on PR #N: <failing checks>" |
| SUCCESS               | any   | any                                       | yes       | **LEAVE** — user intentionally drafted the PR                                                      |
| USER_ESCALATION_HALT  | any   | any                                       | any       | **SURFACE** — hard-gate already fired upstream                                                     |
| LOW_CONFIDENCE_STREAK | any   | any                                       | any       | **SURFACE** — supervisor decisions are unreliable                                                  |
| DEAD                  | any   | any                                       | any       | **SURFACE** — worker died unexpectedly                                                             |
| no terminal yet       | any   | any                                       | any       | **POLL** — continue waiting                                                                        |

### Actions, in detail

- **AUTO-MERGE**: emit a status block citing the matrix row and PR number, then invoke `gh pr merge --auto --squash <PR>`. The `--auto` flag is important — GitHub waits for any required checks even if the supervisor's snapshot showed green moments earlier. Log the merge as a per-turn surface line: `✅ auto-merged PR #N (reversible, CI-green, no governance tag)`.
- **CHAIN**: after AUTO-MERGE succeeds AND `next_batch_spec` is non-null, spawn the next worker via `pwt-goal.sh --worker-only "<request>"` (with `--type` if specified). PWT-DS1 / PWT-DS2 deterministic guards still apply — if a fresh hook flag is present or the env-cascade signal is set, the spawn refuses and the supervisor SURFACES instead.
- **SPAWN FIX-WORKER**: spawn a focused worker whose goal is the CI failure, NOT a re-run of the original mission. The fix-worker's goal directive references the failing checks verbatim. The supervisor returns to POLL on the fix-worker; on its SUCCESS the matrix consults again on the original PR.
- **SURFACE**: emit a `⚠ HALT` block citing the matrix row + reason, stop polling, return control to the user. The supervisor does NOT exit — it waits for user input then resumes its loop.
- **LEAVE**: emit a one-line acknowledgment (`PR #N left as draft per user`) and continue polling other workers; the draft PR is not the supervisor's concern.
- **POLL**: continue the normal polling cadence (no surface).

### Hard Rules (revised 2026-05-22)

These supersede the previous "NEVER push to remote" wording. The origin-chat supervisor must follow these unconditionally:

- **NEVER merge irreversible PRs.** Irreversible = one-way door. The closed list lives in `shared/governance-tags.md`. The supervisor MUST run the diff-path comparison against that list before merging, even on PRs with no DO-NOT-MERGE label.
- **NEVER push to remote.** The worker pushes; the supervisor only merges existing remote PRs. (`gh pr merge` operates on remote state — it does not push from the supervisor's working tree.)
- **NEVER edit code, configs, or specs.** Implementation belongs to the worker.
- **NEVER spawn more than one chain-worker per AUTO-MERGE.** `next_batch_spec` is consumed exactly once; the new worker carries no `next_batch_spec` of its own unless its own retro sets one (PWT-DS2 also enforces this via env-cascade).
- **Auto-merge reversible code/test PRs within the same mission** per the Decision Matrix. Reversibility is established by (a) no DO-NOT-MERGE label, (b) no `shared/governance-tags.md` surface match, (c) CI green.
- **NEVER `gh pr merge --admin` on a repo with GitHub Actions required checks** unless the deterministic merge-gate (`.claude/scripts/supervisor-merge-gate.sh`) returned `recommended_action=ADMIN_MERGE` for the PR. `--admin` bypasses required checks; on repos where GitHub Actions IS the required check, this skips CI. Use `--auto` instead and let GitHub wait for checks. The gate's `ci_mode` field is the authoritative input for this rule. See §CI-Aware Action Hierarchy below.

### CI-Aware Action Hierarchy (2026-05-22 — supersedes the simpler matrix above)

The Decision Matrix above tells the supervisor WHEN to act (worker terminal + PR state). The hierarchy below tells the supervisor HOW to act (which `gh pr merge` flag, or whether to surface). It is implemented by `.claude/scripts/supervisor-merge-gate.sh` — the supervisor MUST invoke the script before any merge action and use its `recommended_action` field rather than re-deriving the decision from raw inputs.

**Originating evidence**: cleanscale incident 2026-05-22 — supervisor used `gh pr merge --admin --squash $PR` to clear a DO-NOT-MERGE-labeled PR. On cleanscale (local-Makefile-only CI), this was functionally equivalent to `--auto`. On a typical SaaS repo with GitHub Actions required checks, this would have bypassed CI without operator consent. The hierarchy makes the supervisor's choice deterministic and CI-aware.

Spec: `docs/specs/supervisor-merge-enforcement.md`. Script: `.claude/scripts/supervisor-merge-gate.sh`.

| Row | `governance_surfaces_matched` | `has_do_not_merge_label` | `ci_mode`        | `recommended_action` | Rationale                                                                                          |
| --- | ----------------------------- | ------------------------ | ---------------- | -------------------- | -------------------------------------------------------------------------------------------------- |
| 1   | non-empty                     | (any)                    | (any)            | `SURFACE_TO_USER`    | One-way door — explicit human consent always required.                                             |
| 2   | empty                         | `true`                   | `local-makefile` | `ADMIN_MERGE`        | Supervisor-reviewer pattern: worker added the label as precaution; supervisor IS the human review. |
| 3   | empty                         | `true`                   | `github-actions` | `SURFACE_TO_USER`    | Real CI required-checks need a real human to authorize bypass. NEVER `--admin` here.               |
| 4   | empty                         | `true`                   | `none`           | `SURFACE_TO_USER`    | Conservative — unknown CI posture defaults to user.                                                |
| 5   | empty                         | `false`                  | `github-actions` | `AUTO_MERGE`         | `gh pr merge --auto --squash` — GitHub waits for required checks.                                  |
| 6   | empty                         | `false`                  | `local-makefile` | `ADMIN_MERGE`        | `gh pr merge --admin --squash` — no `--auto` target exists; local CI passed pre-push.              |
| 7   | empty                         | `false`                  | `none`           | `ADMIN_MERGE`        | `gh pr merge --admin --squash` — no CI to wait on.                                                 |

**`ci_mode` detection** (script-level heuristic, NOT a `gh api` round-trip):

- `github-actions`: any `.github/workflows/*.y*ml` defines a `pull_request:` trigger.
- `local-makefile`: `Makefile` at repo root has a `test` / `test-skill` / `check` / `lint` target AND no qualifying workflow exists.
- `none`: neither holds.

**How the supervisor uses the gate**:

```bash
GATE=$(.claude/scripts/supervisor-merge-gate.sh "$PR_NUMBER")
ACTION=$(echo "$GATE" | jq -r '.recommended_action')
case "$ACTION" in
  AUTO_MERGE)         gh pr merge --auto  --squash "$PR_NUMBER" ;;
  ADMIN_MERGE)        gh pr merge --admin --squash "$PR_NUMBER" ;;
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

The origin-chat supervisor's polling loop has two responsibilities per tick: (1) standard worker observation, (2) CONTINUATION CHECK (added 2026-05-22).

### Standard Tick

1. `claude agents --json` — confirm worker SID still listed; if absent for ≥2 ticks, treat as DEAD per matrix.
2. `claude logs <SID> --tail 200` — scan for stage transitions and pause-site emissions.
3. `.claude/state/plan-w-team-goal-<SLUG>.json` — read `terminal_state`; on non-null, consult Decision Matrix.
4. `.claude/state/pwt-completion-summary-<SID>.md` — surface if ship/retro stages wrote one this tick.

**Auto-terminate of origin mirror (2026-05-22)**: The origin chat's mirror goal-state file (`.claude/state/plan-w-team-goal-<SLUG>.json`, written by `pwt-goal.sh --supervisor-goal`) **auto-terminates on worker retro** — no manual `jq` intervention needed. Mechanism: `pwt-goal.sh --supervisor-goal` registers the mirror in the spawned-children registry as `type=supervisor_mirror`; on worker retro, `07-retro §8j-sexies → child-cleanup.sh` patches the mirror to SUCCESS. If the worker dies without retro, the goal-evaluator hook's DEAD-detection branch patches the mirror to LOW_CONFIDENCE_STREAK. See `docs/specs/supervisor-mirror-lifecycle.md`.

Cadence: ~30–60s. Use `Bash + sleep` or `ScheduleWakeup` (preferred for runs >5 min).

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

## Adding a New Event Type or Summary Field

When extending the supervisor (e.g. for T5 integration):

1. Add the new event type or field to the schema tables above with type + when-required notes.
2. Update the supervisor's system prompt (`.claude/agents/team/supervisor.md`) to emit it.
3. Update `07-retro.md` §8j-quater if the new field affects scoring.
4. Update the symmetry-check registry row if the on-disk path or pattern changes.
5. Add a test case in `plan-w-team-supervisor-route.test.sh` if it affects the wrapper.
6. If the change touches the **summary block schema**, document the version bump in this file (the block is a one-way contract once T5 ships).
