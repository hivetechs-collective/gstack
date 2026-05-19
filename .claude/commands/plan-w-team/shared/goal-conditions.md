# Goal Conditions — `/goal` Wrapper Contract

Authoritative reference for PWT-T5: the `/goal` wrapper that opens at the top of every `/plan-w-team` invocation and decides each turn whether the pipeline is complete.

Spec: `docs/specs/pwt-t5-goal-wrapper.md`
Helper: `.claude/scripts/plan-w-team-surface-status.sh`
Kill switch: `PLAN_W_TEAM_DISABLE_GOAL=1` — skip `/goal` open entirely
Companion: `shared/supervisor-protocol.md` (supervisor's per-turn summary block — the second evaluator sensor)
Anthropic docs: https://code.claude.com/docs/en/goal

## Overview

`/goal` (Claude Code 2.1.139+, released 2026-05-12) is a wrapper around a session-scoped prompt-based Stop hook. After every turn, a small fast model (Haiku by default) reads the conversation transcript and returns yes/no plus a short reason. "Yes" → the goal clears and control returns to the user. "No" → Claude continues to the next turn with the reason injected as guidance.

`/plan-w-team` opens `/goal` at the top of its skill invocation with a precise terminal condition. The pipeline then runs Step 0 → Step 8 as usual; the evaluator polls the transcript after every turn. The user can walk away — `/goal` decides when the run is done.

The evaluator **cannot call tools**. Its only sensor is the conversation transcript. Two surfacing mechanisms exist:

1. **`status` block** — emitted by `plan-w-team-surface-status.sh` at the end of every lead-driven stage (Steps 0/1/2/5/6/7/8).
2. **`summary` block** — emitted by the T4 supervisor at the end of every turn during Step 3-4 (see `shared/supervisor-protocol.md`).

Both blocks contain machine-readable JSON the evaluator parses.

## The Condition (copy-paste template)

When `/plan-w-team` opens `/goal`, it uses this condition verbatim (with `<SLUG>` substituted):

```
/goal /plan-w-team SLUG=<SLUG> reaches a terminal state. Terminal states:

(1) SUCCESS: The transcript contains a `status` or `summary` block with
    `workflow_lock: "done"` AND `stage: "retro-complete"`. Ship-readiness
    gate verdict PASS may appear earlier in a stage="ship" status block —
    use that as a corroborating signal but the retro-complete marker is
    the authoritative success anchor.

(2) USER_ESCALATION_HALT: The transcript contains a `status` or `summary`
    block with a non-empty `pending_escalations` array referencing any of
    `push-ack`, `secret-scan-allow`, or `scope-unlock-for-drift`. This is
    a hard-gate awaiting user response — pipeline cannot proceed
    autonomously past these sites.

(3) LOW_CONFIDENCE_STREAK: The transcript contains 3 consecutive supervisor
    `summary` blocks where `goal_progress` mentions "low-confidence" OR
    any status block reports `low_confidence_routes >= 3`. This signals
    the supervisor is confused and should not continue dispatching.

(4) TIME_OR_TURN_CAP: 12 wall-clock hours have elapsed OR 200 turns have
    run, whichever comes first.

Stop when ANY of (1)–(4) holds. When stopping, state which terminal state
was reached and quote the most recent transcript line that demonstrates it.
```

The condition is ~990 characters — well under `/goal`'s 4000 char limit.

## Terminal-State Reference

| State                   | Transcript anchor                                                                                                                                     | What it means                                                             |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `SUCCESS`               | A status block with `stage: "retro-complete"` AND `workflow_lock: "done"` (emitted by `07-retro.md`)                                                  | Pipeline ran end-to-end without escalation; ship gate passed              |
| `USER_ESCALATION_HALT`  | Any status/summary block with non-empty `pending_escalations` containing one of the 3 hard-gate labels                                                | A hard-gate was hit; user must respond before pipeline can proceed        |
| `LOW_CONFIDENCE_STREAK` | Either: 3 consecutive supervisor summary blocks mentioning "low-confidence" in `goal_progress`, OR any status block with `low_confidence_routes >= 3` | Supervisor's decisions are unreliable; do not let it continue dispatching |
| `TIME_OR_TURN_CAP`      | Wall-clock or turn-count limit (evaluator tracks both internally)                                                                                     | Run took too long; surface state to user for manual review                |

The 3 hard-gate labels referenced in `USER_ESCALATION_HALT` are:

- `push-ack` (Step 6 — irreversible push)
- `secret-scan-allow` (Step 6 — security allowlist modification)
- `scope-unlock-for-drift` (Step 2/3 — mid-flight scope expansion)

These are defined in `shared/orchestrator-interception.md` Classifier Table as the 3 `user`-verdict sites.

## Status-Block Schema

Emitted by `plan-w-team-surface-status.sh` at the end of every lead-driven stage:

````
```status
{"slug":"<SLUG>",
 "stage":"<stage-label>",
 "ts":"<ISO8601 UTC>",
 "workflow_lock":"active|done|missing",
 "ship_readiness_gate":"PASS|FAIL|pending|n/a",
 "fleet":{"spawned":N,"completed":N,"failed":N,"running":N,"max_concurrent":N},
 "pending_escalations":[...],
 "low_confidence_routes":N}
````

```

Stage labels in use:
- `scope-challenge` (after Step 0)
- `specification` (after Step 1)
- `task-breakdown` (after Step 2)
- `review` (after Step 5)
- `ship` (after Step 6)
- `post-ship` (after Step 7)
- `retro-complete` (after Step 8 — the SUCCESS anchor)

The supervisor's per-turn summary block (fenced as `summary` not `status`) is documented in `shared/supervisor-protocol.md` §Turn-End Summary Block Contract.

## Kill Switch Contract

| Env var | Default | Effect |
| --- | --- | --- |
| `PLAN_W_TEAM_DISABLE_GOAL=1` | unset | Skip top-of-pipeline `/goal` open entirely; pipeline runs as today (lead-driven turn-by-turn polling) |

The kill switch only affects the `/goal` invocation in the skill md. The `plan-w-team-surface-status.sh` helper is unaffected — it remains observability infrastructure (status blocks still appear in the transcript whether or not `/goal` is active).

## /goal Unavailability Fallback

If the running Claude Code version does not have `/goal` (pre-2.1.139), the top-of-pipeline section in `plan-w-team.md` detects this and is a no-op. The pipeline runs unchanged. The helper's status blocks still surface, but no evaluator polls them.

Detection pattern (in the skill md):

```

If /goal command is not available in this Claude Code version, skip the
top-of-pipeline /goal open and proceed directly to Pre-Flight. The
pipeline runs as today — Steps 0–8 in sequence, lead-driven. The
surface-status helper still emits transcript blocks; they're observability
without an evaluator consumer.

```

## Failure Modes

| Failure | Behavior |
| --- | --- |
| `/goal` command unavailable (older Claude Code) | Top-of-pipeline section no-ops; pipeline runs as today |
| Condition string exceeds 4000 chars | Truncate to first 3900 + note truncation in skill comment |
| Helper crashes during stage execution | Stage echoes minimal inline status block as fallback; evaluator gets degraded signal |
| Supervisor doesn't emit summary blocks during Step 3-4 | Evaluator falls back to stage-end status blocks only (less granular but functional) |
| Network failure prevents Haiku evaluator from running | `/goal` retries per Anthropic's internal logic; pipeline continues regardless |
| Evaluator returns "yes" prematurely (false success) | User reviews final state; can `/goal clear` mid-pipeline if needed |
| Evaluator never returns "yes" (stuck in "no") | TIME_OR_TURN_CAP terminal state fires after 12h or 200 turns |

## Adding a New Terminal State

If future work needs a new terminal state (e.g., T6 adds a "compliance check failed" state):

1. Add a row to the Terminal-State Reference table above with the transcript anchor and meaning.
2. Update the condition template to include the new state as `(5)`.
3. Update `07-retro.md` §8j-quinquies scoring to handle the new terminal reason.
4. If the new state requires a new field in the status block, update the Status-Block Schema section AND `plan-w-team-surface-status.sh` to emit it.

The condition template is the single source of truth — never inline an alternate condition in the skill md or stage files.

## Where This Runs

| Stage | What happens |
| --- | --- |
| `plan-w-team.md` top-of-pipeline section | Opens `/goal` with condition above (unless `PLAN_W_TEAM_DISABLE_GOAL=1`) |
| Lead stages 00, 01, 02, 04, 05, 06 | End of stage calls `plan-w-team-surface-status.sh` to emit status block |
| Step 3-4 (`03-execute.md`) | Supervisor emits summary block per turn (no helper call here — supervisor protocol owns the signal) |
| Step 8 (`07-retro.md`) | Final stage call emits `stage="retro-complete"` status — the SUCCESS terminal anchor |
| `07-retro.md` §8j-quinquies | Reads `/goal` terminal state + turn count; scores evaluator health 1-5 |
```
