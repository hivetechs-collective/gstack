# Goal Conditions — `/plan-w-team` Self-Hosted Goal Evaluator

Authoritative reference for PWT-T5b: the deterministic Stop-hook evaluator that fires after every Claude turn while a `/plan-w-team` run is active and decides whether the pipeline reached a terminal state.

Spec: `docs/specs/pwt-t5b-goal-evaluator.md`
Evaluator hook: `.claude/hooks/plan-w-team-goal-evaluator.sh` (Stop event)
Helper: `.claude/scripts/plan-w-team-surface-status.sh` (emits status blocks the evaluator reads)
State file: `.claude/state/plan-w-team-goal-<SLUG>.json` (written by skill at top-of-pipeline, deleted at retro-complete). For autonomous bg workers it is **also seeded at spawn by `pwt-goal.sh --worker-only` (PWT-WT2)** so the anti-skip anchor is active from t=0 even if the worker never reaches the manifest's top-of-pipeline activation — closing the 2026-06-02 regression where a worktree-isolated worker (no state file anywhere → evaluator "No active goal → exit 0") stopped short of its DoD. The seed is keyed by `SLUG_GUESS` in the launching checkout's `.claude/state/`; `await-terminal.sh` resolves it main-then-worktree (see `shared/supervisor-protocol.md` Wait mechanism + `docs/specs/supervisor-wait-worktree-aware.md`).
Kill switch: `PLAN_W_TEAM_DISABLE_GOAL=1` — hook exits 0 without evaluation
Companion: `shared/supervisor-protocol.md` (supervisor's per-turn summary block — second evaluator sensor)
Anthropic docs (for context — we no longer use `/goal`): https://code.claude.com/docs/en/goal

## Quick-start: `pwt-goal` helper (for `/goal`-driven autonomous runs)

When you want to start an autonomous run that uses Anthropic's `/goal` command as the outer autonomy loop with `/plan-w-team` as the executor — the pattern you'd actually use for multi-hour or multi-day unattended runs — derive the `/goal` directive from natural language with:

```bash
.claude/scripts/pwt-goal.sh "ship payment API with stripe webhook handling"
```

The script prints a properly-formatted `/goal` command to stdout. Copy and paste it at the start of a fresh `claude` session, or use `--launch` to invoke `claude -p` directly:

```bash
.claude/scripts/pwt-goal.sh --launch "ship payment API with stripe webhook handling"
```

The derived `/goal` command embeds:

- Instruction to use `/plan-w-team` to accomplish the request
- Definition-of-done anchors (transcript markers Anthropic's Haiku evaluator looks for to decide SUCCESS)
- Hard-gate escalation triggers (push-ack, secret-scan-allow, scope-unlock-for-drift, low-confidence streak)
- **No wall-clock or turn caps by design** — the only stopping points are goal-success and hard-gate halts

Template variants for different work types (`--type feature` is default):

```bash
.claude/scripts/pwt-goal.sh --type refactor "extract auth middleware"
.claude/scripts/pwt-goal.sh --type bugfix "fix login redirect on safari"
.claude/scripts/pwt-goal.sh --type docs "update README architecture diagram"
```

Interactive mode prompts for additional DoD criteria beyond the defaults:

```bash
.claude/scripts/pwt-goal.sh -i "ship payment API"
# Enter additional done criteria, one per line. Empty line to finish:
# > stripe webhook signature verification has unit test
# > rate limiting middleware applied to /api/charges
# > <enter>
```

### Two evaluators, two purposes

When you start a session with `/goal` and the goal directive invokes `/plan-w-team`, **two Stop hooks fire after every Claude turn**:

1. **Anthropic's `/goal` Haiku evaluator** — judges your custom condition (with semantic understanding via Haiku)
2. **Our self-hosted goal evaluator** (PWT-T5b/c, this doc) — deterministically checks the 4 terminal anchors + feature-specific criteria injected by Step 1 §1.5

Both blocking = Claude continues. Either allowing alone is not enough; both must allow for Claude to stop. This is belt + braces: Anthropic's evaluator handles the freeform "is the user's intent satisfied" question; ours handles "did the structured pipeline reach its terminal state with all ACs verified."

For interactive sessions where you ask the agent to run `/plan-w-team` (no `/goal` outer loop), only our hook fires — same effect, no LLM tokens, deterministic anchor matching. See §Why self-hosted instead of Anthropic's /goal below.

## Why self-hosted instead of Anthropic's `/goal`

`/goal` is a user-typed slash command. When the agent (Claude) invokes `/plan-w-team` on the user's behalf via the Skill tool, the agent **cannot type `/goal`** to bootstrap the wrapper — slash commands are user-initiated. Net effect with the original T5 design: in agent-driven invocation (the user's actual usage pattern), `/goal` never opens and T5 does nothing.

PWT-T5b replaces the `/goal` wrapper with our own Stop hook that the skill activates by writing a state file. No slash command required. The hook reads the same status/summary blocks the original T5 designed and applies the same 4-state terminal condition — but as deterministic grep-pattern matching, not LLM evaluation. All 4 terminal anchors are concrete enough (exact JSON field values) that no Haiku judgment is needed.

Trade-off: we lose Haiku's flexibility to interpret novel conditions, but we gain:

- Zero tokens per turn (free)
- Faster (no LLM round-trip)
- Deterministic (no eval hallucination)
- Works in agent-driven `/plan-w-team` invocation

## Overview

The evaluator hook fires on every `Stop` event (Claude finishes a turn). It:

1. Returns immediately if `PLAN_W_TEAM_DISABLE_GOAL=1` (kill switch).
2. Returns immediately if no active goal state file exists (no `/plan-w-team` run in progress).
3. Returns immediately if `stop_hook_active=true` in hook input (block-cap protection).
4. Reads the transcript file path from hook input, tails recent lines.
5. Checks for each of the 3 directly-detected terminal-state anchors via grep (`API_HALT`, the 4th, arises only via parent-child propagation — see §Parent-Child Terminal Propagation).
6. If a terminal state is hit: persists `terminal_state` + `terminal_reason` to state file, exits 0 (let Claude stop).
7. If no terminal state: outputs `{"decision":"block","reason":"..."}` to keep Claude working.

The evaluator **has no semantic intelligence**. It only matches concrete patterns:

1. **`status` block** — emitted by `plan-w-team-surface-status.sh` at the end of every lead-driven stage (Steps 0/1/2/5/6/7/8).
2. **`summary` block** — emitted by the T4 supervisor at the end of every turn during Step 3-4 (see `shared/supervisor-protocol.md`).

Both blocks contain machine-readable JSON. The evaluator greps for specific anchors:

| Terminal state          | Anchor pattern (grep)                                                                                                                                                                                                                                   |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SUCCESS`               | `"stage":"retro-complete"` AND `"workflow_lock":"done"`                                                                                                                                                                                                 |
| `USER_ESCALATION_HALT`  | `"pending_escalations":[...]` containing `"push-ack"`, `"secret-scan-allow"`, or `"scope-unlock-for-drift"`                                                                                                                                             |
| `LOW_CONFIDENCE_STREAK` | `"low_confidence_routes":N` where N ≥ 3                                                                                                                                                                                                                 |
| `API_HALT`              | No direct transcript anchor — a derived state: a registered child worker idle ≥ `PWT_API_HALT_IDLE_S` (600s) whose last turn matches a transient-connection pattern. Arises only via parent-child propagation (see §Parent-Child Terminal Propagation). |

**No `TIME_OR_TURN_CAP` terminal state**: the only valid termination signals are goal-success (above), the hard-gate / low-confidence anchors, and `API_HALT` (a delegated child that died on a transient API error). The evaluator does not track turn count or wall-clock and will not auto-stop a run for taking too long. If the pipeline truly stalls without producing those signals, the user halts it manually (`/goal clear` or session interrupt).

### `post-ship-complete` SUCCESS precondition (A5, 1.33.0)

A full-lifecycle run must not reach `SUCCESS` having silently skipped documentation. Step 8
retro §8d checks for the Step-7 artifact `plan-w-team-postship-$SLUG.json` **before** the
`retro-complete` anchor is emitted:

- **Artifact present** → §8d reads it and scores doc hygiene (the real A4 reader). Proceed.
- **Artifact absent on a full run that added public surface** → `post-ship-complete` is NOT
  satisfied: §8d scores doc-hygiene `n/a (docs-skipped)` and surfaces the precondition note
  so the operator sees Step 7 did not run. Pairs with the §7f net-new-surface gate
  (`06-post-ship.md`) — together they ensure docs are not skipped on the path to SUCCESS.
- **`--ship-only` / `--retro` flows** that legitimately never run Step 7 are exempt (no
  public-surface diff to document); the score is `n/a` without a finding.

This is the artifact-exists precondition the brief (gap A5) requires: previously nothing
verified the post-ship artifact existed before SUCCESS, so a run could reach `retro-complete`
with zero docs and no failing signal.

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

Stop when ANY of (1)–(3) holds. When stopping, state which terminal state
was reached and quote the most recent transcript line that demonstrates it.

There is NO wall-clock or turn cap. The pipeline runs until one of (1)–(3)
fires. If neither fires, keep working — the absence of a terminal anchor
means the work is genuinely not done. User intervention (`/goal clear` or
session interrupt) is the manual escape hatch.
```

The condition is well under `/goal`'s 4000 char limit.

## Terminal-State Reference

| State                   | Transcript anchor                                                                                                                                                    | What it means                                                                                                          |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `SUCCESS`               | A status block with `stage: "retro-complete"` AND `workflow_lock: "done"` (emitted by `07-retro.md`)                                                                 | Pipeline ran end-to-end without escalation; ship gate passed                                                           |
| `USER_ESCALATION_HALT`  | Any status/summary block with non-empty `pending_escalations` containing one of the 3 hard-gate labels                                                               | A hard-gate was hit; user must respond before pipeline can proceed                                                     |
| `LOW_CONFIDENCE_STREAK` | Either: 3 consecutive supervisor summary blocks mentioning "low-confidence" in `goal_progress`, OR any status block with `low_confidence_routes >= 3`                | Supervisor's decisions are unreliable; do not let it continue dispatching                                              |
| `API_HALT`              | No transcript anchor — derived during parent-child propagation when a delegated child worker is idle ≥ 600s and its last turn matches a transient-connection pattern | A delegated child died on a transient API error; surface to the user rather than masking it under the parent's SUCCESS |

**Removed:** an earlier `TIME_OR_TURN_CAP` terminal state was deleted by design (2026-05-19). Wall-clock and turn-count termination conflated "the work is done" with "we've used our budget" — neither is a legitimate stopping signal for autonomous engineering work. The four states above (three directly-detected + `API_HALT` via propagation) are the only ways a `/plan-w-team` run reaches terminal.

### Evaluator State Machine

```mermaid
stateDiagram-v2
    direction LR
    [*] --> Active : goal state file written\n(top-of-pipeline)

    Active --> CheckAnchors : Stop hook fires\n(per Claude turn)

    state CheckAnchors <<choice>>
    CheckAnchors --> HasEscalation : pending_escalations\nnon-empty
    CheckAnchors --> HasLowConfStreak : low_confidence_routes >= 3\nOR 3 consecutive supervisor\nlow-confidence summaries
    CheckAnchors --> HasGenericSuccess : stage="retro-complete"\nAND workflow_lock="done"\nAND slug match
    CheckAnchors --> Active : none of the above\n(BLOCK stop, keep running)

    HasGenericSuccess --> CheckFeatureCriteria : feature_specific_done_criteria\npresent?

    state CheckFeatureCriteria <<choice>>
    CheckFeatureCriteria --> SUCCESS : array empty\n(generic anchors sufficient)
    CheckFeatureCriteria --> ANDCheck : array non-empty
    ANDCheck --> SUCCESS : every AC<N>.*PASS\npattern matched in transcript
    ANDCheck --> Active : at least one AC unmet\n(BLOCK with reason citing unmet)

    HasEscalation --> USER_ESCALATION_HALT
    HasLowConfStreak --> LOW_CONFIDENCE_STREAK

    SUCCESS --> [*] : terminal_state persisted\nlet Claude stop
    USER_ESCALATION_HALT --> [*] : terminal_state persisted\nlet Claude stop · surface to user
    LOW_CONFIDENCE_STREAK --> [*] : terminal_state persisted\nlet Claude stop · surface to user

    note right of ANDCheck
        Per-AC AND-check: marks each
        criterion met:true · met_at:<ts>
        the first turn its pattern fires.
        Unmet list -> hook reason.
    end note
```

**Reading the diagram:**

- The hook is **always active** while the goal state file exists; the kill switch (`PLAN_W_TEAM_DISABLE_GOAL=1`) removes the hook from the path entirely.
- The three directly-detected terminal states are **mutually exclusive per evaluation**; precedence — `USER_ESCALATION_HALT > LOW_CONFIDENCE_STREAK > API_HALT > SUCCESS` (the hook's canonical chain, `plan-w-team-goal-evaluator.sh` ~L532) — only matters for parent-child propagation (next section). `API_HALT` is never detected directly; it arises only when propagating a dead child's state.
- The `CheckFeatureCriteria` branch is what PWT-T5c adds on top of T5b: a non-empty `feature_specific_done_criteria` array forces an AND-check between generic anchors and every per-AC pattern before SUCCESS fires. With an empty array (or a missing field), behavior is identical to T5b — generic anchors alone fire SUCCESS.
- "BLOCK stop" means the hook exits with `"continue": true` so Claude can't terminate; "let Claude stop" means the hook exits with `"continue": false`. The hook is the only thing standing between the run and termination — wrong hook decision = wrong run lifetime.

### Parent-Child Terminal Propagation (2026-05-20)

When a `/plan-w-team` run delegates work to a worker via `pwt-goal.sh --launch` (or any other `claude --bg` spawn registered via `plan-w-team-register-spawn.sh`), the worker writes its retro-complete anchors to its OWN transcript and state files — never the parent's. Transcript-only anchor sniffing on the parent therefore stalls indefinitely (incident 2026-05-20: 13-min stall after worker shipped).

The evaluator (`.claude/hooks/plan-w-team-goal-evaluator.sh`) handles this by reading worker state files directly. For each active parent goal:

1. Look up the parent's spawned-children registry at `.claude/state/plan-w-team-spawned-children-<PARENT_SLUG>.jsonl`.
2. For each unique `slug` field in the registry, read the worker's `plan-w-team-goal-<WORKER_SLUG>.json`.
3. When every registered worker has a non-null `terminal_state`, propagate the worst-precedence state to the parent:

   ```text
   SUCCESS < API_HALT < LOW_CONFIDENCE_STREAK < USER_ESCALATION_HALT
   ```

   A halted worker halts the parent (must surface to user). A clean worker satisfies parent SUCCESS. Mixed signals win toward the more severe state.

**Fail-open contract**: missing worker state files mark the child non-terminal (parent keeps blocking — correct). Corrupt JSON state files are skipped with a stderr warn (the corrupt file does NOT pin the parent indefinitely). Self-referential rows (registry `slug` == parent `SLUG`) are skipped to prevent infinite hold-open. Registry absent → behavior is byte-identical to pre-fix (backward compatible).

This propagation is automatic — no code changes needed in stage files. As long as spawns are registered via `plan-w-team-register-spawn.sh` (already wired into `pwt-goal.sh --launch` and `plan-w-team-route-prompt.sh` per the self-cleanup work), the parent goal terminates cleanly when its workers do.

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

````

Stage labels in use:
- `scope-challenge` (after Step 0)
- `specification` (after Step 1)
- `task-breakdown` (after Step 2)
- `review` (after Step 5)
- `ship` (after Step 6)
- `post-ship` (after Step 7)
- `retro-complete` (after Step 8 — the SUCCESS anchor)

The supervisor's per-turn summary block (fenced as `summary` not `status`) is documented in `shared/supervisor-protocol.md` §Turn-End Summary Block Contract.

### Transcript-storage detection (escaped quotes) — 2026-05-25

The evaluator detects the three terminal signals by scanning the transcript
JSONL. Claude Code stores assistant/user/tool message content as
**JSON-encoded strings**, so a status block emitted as assistant text lands on
disk with escaped quotes — `\"stage\":\"retro-complete\"` — not raw quotes. The
original detector used `grep -F '"stage":"retro-complete"'`, which can never
match the escaped form, causing **false-negative** terminal detection that
trapped autonomous runs (cleanscale hard-gate escalation incident).

The hook now decodes each transcript entry with `jq` (`decode_transcript`) and
matches against the UNESCAPED text, OR'd with the raw transcript tail for
backward-compat. Recognized shapes:

- assistant `.message.content[].text` (escaped quotes)
- `tool_result.content` as a string OR a `[{type:text,text}]` array
- string-form user `.message.content`
- `tool_use.input` objects (flattened to compact JSON)
- fenced ` ```json ` blocks inside any of the above
- raw direct-write form (unescaped) — still matched via the raw corpus

Each decoded entry becomes ONE logical line (newlines collapsed), so a status
block's keys colocate — preserving the "same status block / ±5 lines of the
slug anchor" proximity defense against documentation text that merely quotes
the pattern strings.

**Debug env var**: set `PWT_GOAL_EVALUATOR_DEBUG=1` (or pass `--debug`) to make
the hook print, to stderr, which detector ran and what matched/didn't — the
diagnostic window for any future false-negative. stdout stays the pure
`{"decision":"block",...}` contract.

Regression coverage: `tests/skill/scenarios/goal-evaluator-escaped-quotes.bats`
(+ fixtures under `tests/skill/scenarios/fixtures/goal-evaluator-escaped-quotes/`).

## Feature-Specific Done Criteria (PWT-T5c)

The goal state file optionally carries a `feature_specific_done_criteria` array that extends the SUCCESS terminal condition. Generic anchors alone are insufficient when this array is non-empty — every criterion in it must ALSO appear in the transcript before SUCCESS fires.

### Schema

```jsonc
{
  // ... (existing T5b state fields above)
  "feature_specific_done_criteria": [
    {
      "pattern": "AC1.*PASS",
      "description": "Payment endpoint returns 200 with valid stripe token",
      "met": false,
      "met_at": null
    },
    {
      "pattern": "AC2.*PASS",
      "description": "Secret scan reports 0 findings",
      "met": false,
      "met_at": null
    }
  ]
}
````

| Field         | Type                   | Required | Purpose                                                                                                     |
| ------------- | ---------------------- | -------- | ----------------------------------------------------------------------------------------------------------- |
| `pattern`     | string (grep -E regex) | yes      | Pattern matched against transcript via `grep -E`. Default derivation: `AC<N>.*PASS` for AC entries in spec. |
| `description` | string                 | yes      | Human-readable text from the AC line. Used in block reason when criterion is unmet.                         |
| `met`         | boolean                | yes      | `false` initially. Hook flips to `true` on first match.                                                     |
| `met_at`      | ISO8601 string \| null | yes      | Set to current UTC timestamp when `met` flips. Preserved across subsequent invocations (first-match-wins).  |

### Derivation (Step 1 §1.5)

`01-specification.md` §1.5 reads the spec's `## Acceptance Criteria` section and extracts every `AC<N>:` line. For each, it derives a criterion with pattern `AC<N>.*PASS` and the original line's text (after the `AC<N>:` prefix) as description. Template placeholders (e.g., `[Subject] [verb]`) are skipped. The array is then injected into the goal state file via `jq`.

This is mechanical — no LLM judgment needed. The AC contract in the spec IS the source of truth, and Step 5 review / Step 6 ship already emit `AC<N>: PASS` verification lines that match the derived patterns.

### Evaluator semantics (AND-check)

When the generic SUCCESS anchors appear (`stage="retro-complete"` + `workflow_lock="done"` + slug match), the hook iterates the criteria array:

1. For each `met: false` criterion, run `echo "$RECENT" | grep -E "$pattern"`.
2. On match: persist `{met: true, met_at: <ts>}` atomically (`jq … > tmp && mv tmp`). First match wins — `met_at` is not overwritten on later matches.
3. On no-match: append `description` to the unmet-list.

If the unmet-list is empty: SUCCESS fires. If not: hook demotes terminal back to empty and blocks the stop with a reason citing the unmet criteria descriptions ("Generic SUCCESS anchors present but feature-specific criteria unmet: …").

### Backward compatibility

A goal state file without `feature_specific_done_criteria` (or with `feature_specific_done_criteria: []`) behaves identically to T5b — generic anchors alone fire SUCCESS. Existing T5b state files continue to work unchanged.

### Failure modes

- **Malformed regex** in a `pattern` → hook skips that criterion, continues with others. The criterion stays unmet forever (manual investigation needed).
- **Spec has no AC entries** → derivation injects empty array, evaluator falls back to T5b generic-only SUCCESS.
- **Criterion never matches** (real bug in pipeline or wrong pattern) → pipeline keeps running; eventually surfaces via `LOW_CONFIDENCE_STREAK` (supervisor noticing repeated failure) or via user interrupt. There is no time-based escape — the user is the final stop.

## Chain Continuation — `next_batch_spec` (2026-05-22)

Spec: `docs/specs/supervisor-protocol-autonomy.md`

The goal state file optionally carries a `next_batch_spec` object. When set on retro SUCCESS, the origin-chat supervisor (Decision Matrix `AUTO-MERGE → CHAIN` branch — see `shared/supervisor-protocol.md`) spawns the next worker in a chained mission without user intervention. The chain terminates when a worker's retro does not set `next_batch_spec` (or sets it to `null`).

### Schema

```jsonc
{
  // existing T5b/T5c fields above…
  "next_batch_spec": {
    "request": "Add SMS delivery tracking after invoice send",
    "type": "feature",
    "started_from_slug": "invoice-send-autonomous",
  },
}
```

| Field               | Type                                                                            | Required | Purpose                                                                                                                        |
| ------------------- | ------------------------------------------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `request`           | string                                                                          | yes      | Natural-language request passed verbatim to `pwt-goal.sh --worker-only`. MUST be non-empty.                                    |
| `type`              | string enum (`feature` \| `refactor` \| `bugfix` \| `docs`) — `feature` default | no       | Maps to `pwt-goal.sh --type`. Omit for `feature`.                                                                              |
| `started_from_slug` | string                                                                          | yes      | Slug of the parent `/plan-w-team` run that scheduled this chain. Auditable provenance back to the original `/goal` invocation. |

### When the Supervisor Reads It

1. Worker reaches retro SUCCESS — `terminal_state == "SUCCESS"` persists to the worker's `plan-w-team-goal-<SLUG>.json`.
2. Decision Matrix returns AUTO-MERGE for the worker's PR.
3. After `gh pr merge --auto` succeeds, the supervisor re-reads the state file and checks the `next_batch_spec` field.
4. **Present + non-null**: spawn next worker via `pwt-goal.sh --worker-only "<request>"` (with `--type <type>` if set).
5. **Absent / null / `{}`**: mission terminates. The supervisor emits a normal terminal block and returns control to the user.

### Cascade Guards (PWT-DS1 / PWT-DS2)

Chained spawns are subject to the same deterministic guards as any other `pwt-goal.sh --worker-only` call:

- **PWT-DS1** (process-level flag file): if `.claude/state/plan-w-team-hook-spawn-<sid>.flag` is fresh (≤60s), the spawn refuses with exit 3 (`PWT_DS1_DUPLICATE`). The supervisor SURFACES instead.
- **PWT-DS2** (env-cascade): the chained worker inherits `PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1`, so any `Use /plan-w-team to …` text in the worker's own goal cannot re-trigger the routing classifier. Subsequent `pwt-goal.sh` calls inside the worker exit 4 (`PWT_DS2_CASCADE`).
- **PWT-WF1** (workflow guard): every bg session `pwt-goal.sh` spawns (worker + supervisor) carries `CLAUDE_CODE_DISABLE_WORKFLOWS=1` in `LAUNCH_ENV`. Dynamic Workflows (`/workflows`, the `Workflow` tool) auto-run in headless/bg mode, and the literal token "workflow" — which /plan-w-team prose uses dozens of times — can otherwise trigger a nested workflow fan-out that bypasses gated dispatch and the RAM-budget gate. The guard makes headless `/goal` runs deterministically Agent()-tool-only. Env-var name verified in the CLI 2.1.156 binary string table. **Interactive sessions are NOT guarded** — there an operator may legitimately author a workflow (e.g. this very evaluation run).

These guards exist to prevent the failure modes that produced commits `c9cfcd5` (LLM-attention miss → double-spawn) and `553ab85` (worker self-replication). `next_batch_spec` chaining does not relax either guard.

### Schema Compatibility

`next_batch_spec` is OPTIONAL. A goal state file without the field, or with the field explicitly `null`, behaves identically to pre-2026-05-22 — the supervisor does not chain, the mission terminates on retro SUCCESS as before. This is a strict additive extension.

### Failure Modes

| Failure                                                  | Behavior                                                                                    |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `request` empty string or missing                        | Supervisor SURFACES with `MalformedChainSpec`; does NOT spawn                               |
| `type` is not a recognized enum value                    | `pwt-goal.sh` rejects at parse time (exit 1); supervisor SURFACES the rejection             |
| Chained spawn blocked by PWT-DS1                         | Supervisor SURFACES (`worker-cascade-blocked` reason)                                       |
| Chained spawn blocked by PWT-DS2                         | Same as above — surfaces the env-cascade refusal                                            |
| State file deleted between SUCCESS and supervisor's read | Supervisor SURFACES; treats as `next_batch_spec` absent (mission complete, but anomalously) |

### Audit Trail

Every chain walks back to the original `/goal` via `started_from_slug`. To trace a mission:

```bash
# Walk the chain backward from the most recently completed run
SLUG=current-worker-slug
while [ -f ".claude/state/plan-w-team-goal-${SLUG}.json" ]; do
  PARENT=$(jq -r '.next_batch_spec.started_from_slug // empty' ".claude/state/plan-w-team-goal-${SLUG}.json")
  echo "$SLUG"
  [ -z "$PARENT" ] && break
  SLUG="$PARENT"
done
```

The chain is at most as deep as the user's original mission; PWT-DS2 prevents arbitrary recursion.

## Kill Switch Contract

| Env var                          | Default               | Effect                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| -------------------------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PLAN_W_TEAM_DISABLE_GOAL=1`     | unset                 | Skip top-of-pipeline `/goal` open entirely; pipeline runs as today (lead-driven turn-by-turn polling)                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `PLAN_W_TEAM_DISABLE_ANTIPARK=1` | unset                 | Disable the PWT-ANTIPARK gate (§Anti-Park Gate below). The supervisor yield + empty-AC SUCCESS-withholding revert to pre-2026-06-07 behavior. Fail-open default: with the var unset, the gate is also a no-op whenever the run's slug-keyed `.claude/state/supervisor-progress-<slug>.json` is absent, foreign-slug, stale, or corrupt.                                                                                                                                                                                                                                |
| `PWT_ANTIPARK_MAX_AGE_S`         | `3600`                | Staleness threshold for the slug-keyed anti-park snapshot. A `supervisor-progress-<slug>.json` older than this (by its embedded `ts`, else file mtime) is IGNORED (fail-open) so a dead run's STALLED verdict cannot haunt a new run. Consumed by `__antipark_state` in `.claude/hooks/plan-w-team-goal-evaluator.sh`.                                                                                                                                                                                                                                                 |
| `PWT_GOAL_EVALUATOR_DEBUG=1`     | unset                 | Evaluator prints per-detector diagnostics to stderr (which signal ran, what matched). Also `--debug`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `PWT_AUTONOMY_PROFILE`           | `strict` (when unset) | Autonomy-constant profile for the supervisor loop (C6 pilot). `strict`/unset = byte-for-byte today (STALL_THRESHOLD 2, in-flight window 30 min, idle 300 s). `relaxed` loosens to STALL_THRESHOLD 4, in-flight 60 min, idle 900 s — for long-horizon Opus-4.8 runs that legitimately cook longer between landings. Explicit `STALL_THRESHOLD` / `PWT_INFLIGHT_MMIN` / `PLAN_W_TEAM_IDLE_THRESHOLD_S` always override the profile. Adds **NO** self-report grace tick — STALL-ALERT stays purely objective. Consumed by `.claude/scripts/supervisor-progress-check.sh`. |

The kill switch only affects the `/goal` invocation in the skill md. The `plan-w-team-surface-status.sh` helper is unaffected — it remains observability infrastructure (status blocks still appear in the transcript whether or not `/goal` is active).

## Anti-Park Gate (PWT-ANTIPARK, 2026-06-07)

Promotes `feedback_supervisor_progress_objective` from prose to an **enforced**
gate at the goal-evaluator's terminal/yield decision. Root cause + design:
`docs/operations/supervisor-no-park-rootcause-2026-06-07.md`; spec:
`docs/specs/supervisor-no-park.md`; supervisor rules:
`shared/self-regulation.md §Supervisor Self-Regulation`.

**The defect it closes:** the supervisor-yield paths
(`plan-w-team-goal-evaluator.sh` PWT-SUP-YIELD / PWT-SUP-YIELD-SID) let a
supervisor session stop with a live `BLOCK_REASON` (run not terminal, backlog
remains) on the unverified assumption that an await-loop will re-wake it. When the
supervisor parked after handling an issue, the yield silently permitted the stop —
the 2026-06-07 cleanscale "parked in recalibration, lost dev time" incident.

**Integration seam:** the evaluator reads the objective progress snapshot via a
small fail-open helper (`__antipark_state`, jq, never grep-on-JSON). The snapshot
is **slug-scoped** (2026-06-07 hermeticity fix): `supervisor-progress-check.sh`
writes `.claude/state/supervisor-progress-<slug>.json` when invoked with
`--slug "$SLUG"` (carrying a `slug` field), and the reader resolves ONLY the
current run's slug-keyed file. This closes a cross-run contamination bug — the
original global, non-slug-keyed `supervisor-progress.json` let a stale/foreign
run's snapshot (e.g. a dead run's `verdict:STALLED, backlog:9`) drive an unrelated
run's Stop decision. Three fail-open guards, any of which yields no signal:
(1) no slug-keyed file for the current run; (2) the snapshot's own `slug` field
differs from the current run (foreign-slug guard); (3) the snapshot is older than
`PWT_ANTIPARK_MAX_AGE_S` (default 3600s — stale guard, via the embedded `ts` or
file mtime). A snapshot from another run, or a dead run's old verdict, can never
drive this run's terminal/yield decision. Two decision points consult it:

| Gate                      | When it fires                                                                                                                       | Effect                                                                                                                                                                                              |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Yield gate**            | A supervisor session would yield (`BLOCK_REASON` set) AND the snapshot says `verdict=STALL-ALERT` with `backlogKnown=1 ∧ backlog>0` | The yield is BLOCKED (the hook emits `{"decision":"block",...}` citing ANTI-PARK) so the supervisor must re-dispatch the next unblocked item or escalate a genuine hard-gate — never silently park. |
| **Empty-AC SUCCESS gate** | Generic SUCCESS anchors present, `feature_specific_done_criteria` empty/missing, AND snapshot says `backlogKnown=1 ∧ backlog>0`     | SUCCESS is withheld (empty AC contract ≠ done while backlog remains).                                                                                                                               |

**Self-correcting:** the instant a dispatch moves an objective metric (commit, open
PR, AC-PASS) or touches an agent worktree, `supervisor-progress-check.sh` flips the
verdict to `PROGRESSING`/`IN-FLIGHT`/`BACKLOG-CLEAR` and the yield is permitted
again — so a supervisor that is legitimately waiting on cooking work is never
blocked; only a genuine park (flat ticks + backlog>0) is.

**Single-item-blocker partitioning** falls out for free: only the 3 registered
hard-gate sites produce `USER_ESCALATION_HALT`; a capability block (deploy token
missing) is not one of them, so it never halts the run — the anti-park gate keeps
the run building the rest of the backlog while that one item is parked-with-escalation.

**Fail-open + kill switch:** `PLAN_W_TEAM_DISABLE_ANTIPARK=1` disables both gates.
With the var unset, the gates are STILL no-ops whenever the snapshot is absent or
corrupt (an in-session `/plan-w-team` with no supervisor tick, or a fresh run). The
gate can only ADD a block where the run was about to silently park; it never
removes an existing block, never relaxes a terminal, and never weakens the C3
honesty-floor anti-spoof. Regression coverage:
`.claude/scripts/plan-w-team-antipark-gate.test.sh` (13 cases) +
`.claude/scripts/plan-w-team-antipark-hermeticity.test.sh` (slug-scope /
foreign-slug / stale-guard, proving the suite stays green even with a stray
`supervisor-progress.json` present in the real `.claude/state/`).

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

| Failure                                                | Behavior                                                                                                   |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| `/goal` command unavailable (older Claude Code)        | Top-of-pipeline section no-ops; pipeline runs as today                                                     |
| Condition string exceeds 4000 chars                    | Truncate to first 3900 + note truncation in skill comment                                                  |
| Helper crashes during stage execution                  | Stage echoes minimal inline status block as fallback; evaluator gets degraded signal                       |
| Supervisor doesn't emit summary blocks during Step 3-4 | Evaluator falls back to stage-end status blocks only (less granular but functional)                        |
| Network failure prevents Haiku evaluator from running  | `/goal` retries per Anthropic's internal logic; pipeline continues regardless                              |
| Evaluator returns "yes" prematurely (false success)    | User reviews final state; can `/goal clear` mid-pipeline if needed                                         |
| Evaluator never returns "yes" (stuck in "no")          | Pipeline keeps blocking stops. User intervention required (`/goal clear`); no automatic time-based escape. |

## Adding a New Terminal State

If future work needs a new terminal state (e.g., T6 adds a "compliance check failed" state):

1. Add a row to the Terminal-State Reference table above with the transcript anchor and meaning.
2. Update the condition template to include the new state as `(5)`.
3. Update `07-retro.md` §8j-quinquies scoring to handle the new terminal reason.
4. If the new state requires a new field in the status block, update the Status-Block Schema section AND `plan-w-team-surface-status.sh` to emit it.

The condition template is the single source of truth — never inline an alternate condition in the skill md or stage files.

## Where This Runs

| Stage                                    | What happens                                                                                        |
| ---------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `plan-w-team.md` top-of-pipeline section | Opens `/goal` with condition above (unless `PLAN_W_TEAM_DISABLE_GOAL=1`)                            |
| Lead stages 00, 01, 02, 04, 05, 06       | End of stage calls `plan-w-team-surface-status.sh` to emit status block                             |
| Step 3-4 (`03-execute.md`)               | Supervisor emits summary block per turn (no helper call here — supervisor protocol owns the signal) |
| Step 8 (`07-retro.md`)                   | Final stage call emits `stage="retro-complete"` status — the SUCCESS terminal anchor                |
| `07-retro.md` §8j-quinquies              | Reads `/goal` terminal state + turn count; scores evaluator health 1-5                              |

```

```

## Auto-Mode Compatibility (Claude Code 2.1.147+)

Claude Code 2.1.147 changed auto-mode behavior so that `AskUserQuestion` is NO
longer suppressed when a hook or skill explicitly relies on it. This validates
the design of `/plan-w-team`'s hard-gate halts (`push-ack`, `secret-scan-allow`,
`scope-unlock-for-drift`): even when a worker session runs with `auto` mode
enabled, hitting one of these pause sites correctly surfaces an `AskUserQuestion`
prompt back to the user instead of silently auto-approving. No code change
required on our side — this entry confirms behavior alignment.

## Background-Task DEAD-Worker Detection (Claude Code 2.1.145+)

Claude Code 2.1.145 added a `background_tasks` array to the Stop/SubagentStop
hook input. `plan-w-team-goal-evaluator.sh` reads it to detect dead spawned
workers: when a registered child's session_id is NOT in the active set AND the
child has no `terminal_state` written, the evaluator marks the child as
`LOW_CONFIDENCE_STREAK` with reason "DEAD — SID not in background_tasks".
Two-pass convergence: first pass writes child terminal, second pass allows stop.
Backward-compatible when the field is absent (older Claude Code).
Regression: `.claude/scripts/plan-w-team-goal-evaluator-dead-worker.test.sh` (8 cases).
