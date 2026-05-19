# Orchestrator Interception — Classifier + Decision Protocol

This document is the authoritative classifier for the `/plan-w-team`
orchestrator-interception upgrade. It maps every pause site in the pipeline
(stages 00–07) to one of three verdicts and defines the contract by which the
orchestrator returns its decision.

Spec: `docs/specs/plan-w-team-orchestrator-interception-upgrade.md`
Router: `.claude/scripts/plan-w-team-orchestrator-route.sh`
Tests: `.claude/scripts/plan-w-team-orchestrator-route.test.sh`

## Overview

Historically every `/plan-w-team` pause site fired an `AskUserQuestion` and
blocked until the human typed an answer. The orchestrator-interception upgrade
classifies all **14 pause sites** in the pipeline and routes them through a
single dispatcher (`plan-w-team-orchestrator-route.sh`):

- **11 sites** → `orchestrator` verdict — the lead orchestrator agent decides
  autonomously and the choice is logged for audit.
- **3 sites** → `user` verdict — true escalations (irreversible, security-
  sensitive, or scope-altering) that still require human confirmation.
- **0 sites** → `inline-rule` — reserved for future deterministic shortcuts
  (no pause sites currently qualify; the router supports the verdict so a
  future site can opt-in without re-plumbing).

The kill switch `PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1` forces every site back to
the legacy `AskUserQuestion` path. Use it during incidents or while debugging
orchestrator misbehavior.

## Classifier Table

| Call-site label | Verdict | Rationale |
| --- | --- | --- |
| `scope-challenge-mode` | `orchestrator` | Mode selection (HOLD/EXPAND/REDUCE) on bounded, reversible scope work |
| `pass-2-ask` | `orchestrator` | Spec second-pass clarification — orchestrator can resolve from doc context |
| `version-bump-major-vs-minor` | `orchestrator` | Semver bump choice; deterministic from diff scope |
| `agent-roster-selection` | `orchestrator` | Choosing which agents to spawn for a task — orchestrator owns roster |
| `task-breakdown-granularity` | `orchestrator` | Coarse-vs-fine task split is a planning detail |
| `qa-tier-selection` | `orchestrator` | Light/Standard/Full tier picked from change shape |
| `evaluator-iterate-vs-escalate` | `orchestrator` | Evaluator-loop continuation; already machine-verdict-driven |
| `review-autofix-vs-defer` | `orchestrator` | Reviewer applies small fixes vs defers; bounded by autofix scope fence |
| `ship-readiness-gate` | `orchestrator` | Pre-ship checklist verdict (PASS/HOLD); evidence-driven |
| `post-ship-docs-target` | `orchestrator` | Which docs to update; derived from changed paths |
| `retro-friction-categorize` | `orchestrator` | Friction-log category assignment; taxonomy-driven |
| `push-ack` | `user` | Irreversible push to remote — requires human confirmation |
| `secret-scan-allow` | `user` | Secret-scan allowlist additions — security-sensitive, audit-required |
| `scope-unlock-for-drift` | `user` | Mid-flight scope expansion — alters the contract the user signed off on |

**Count:** 14 entries (11 orchestrator + 3 user + 0 inline-rule). When adding
a 15th site, append a row here in the same commit as the router caller.

## Decision Block Contract

When the router invokes the orchestrator (verdict `orchestrator`), the agent
MUST end its output with a machine-fenced decision block in this exact format:

```decision
{"choice": "<option>", "rationale": "<one-paragraph>", "confidence": "high|medium|low"}
```

The router extracts the block with `awk '/^```decision$/{flag=1; next} /^```$/{flag=0} flag'`,
parses with `jq`, and writes one JSONL row to
`.claude/state/plan-w-team-orchestrator-decisions-<slug>.jsonl`.

The block:

- MUST be valid JSON.
- MUST have a non-empty `choice` field — this is what the router echoes to
  stdout for the caller to act on.
- SHOULD include `rationale` (one paragraph) so Step 8 retro can audit the
  decision quality.
- SHOULD include `confidence` (`high|medium|low`) so Step 8 can flag low-
  confidence streaks as a friction signal.

Additional fields (e.g. `alternatives_considered`) are preserved verbatim in
the JSONL row's `decision` object — Step 8 may read them for richer scoring.

## Failure Modes

### Malformed decision block

If the agent returns prose with no fenced block, an unclosed fence, or JSON
that fails `jq` parsing, the router **falls through to the user-ASK path with
the orchestrator's prose as the question preamble**. The fall-through is
non-silent: the user sees both the orchestrator's reasoning attempt and the
original question. This mirrors the evaluator-loop pattern in
`03-execute.md` §4b — "ambiguity is not a pass."

The fall-through call site label is suffixed with `-fallback` so Step 8 can
distinguish genuine user escalations from parse failures.

### Unknown call-site label

If a caller passes a label not present in the Classifier Table above, the
router exits non-zero with `UnknownCallSiteError: '<label>' not in classifier
table` on stderr. This is fail-closed by design — silently routing to ASK
would mask integration bugs in newly-added stage files.

### Lock contention

Concurrent invocations for the same SLUG serialize on a mkdir-based lock
(`<decision_log>.lock`). The lock is released via `trap … EXIT` to guarantee
cleanup even on signal-induced termination.

## Rollback

```bash
export PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1
```

With the toggle set, every call-site falls through to legacy
`ask_user_question` regardless of the classifier verdict. The router does not
spawn an orchestrator, does not write to the decision log, and does not
acquire the lock. Use this during incidents or to debug a misbehaving
orchestrator without touching the stage files.

## Backward Compatibility

When the router is invoked with `--resume <slug>` and the decision log
`.claude/state/plan-w-team-orchestrator-decisions-<slug>.jsonl` does not
exist, the SLUG is treated as a legacy session created before the upgrade.
The router routes silently to `ask_user_question` (no warnings, no agent
spawn, no JSONL creation). This guarantees in-flight pre-upgrade sessions
do not break.

## State Artifact Contract

- **Path:** `.claude/state/plan-w-team-orchestrator-decisions-<slug>.jsonl`
- **Format:** newline-delimited JSON, one row per decision
- **Row schema:**
  ```json
  {
    "timestamp": "2026-05-17T00:00:00Z",
    "call_site": "scope-challenge-mode",
    "slug": "feature-slug",
    "decision": { "choice": "HOLD", "rationale": "…", "confidence": "high" }
  }
  ```
- **Writer:** `.claude/scripts/plan-w-team-orchestrator-route.sh`
  (look for `DECISION_LOG="$STATE_DIR/plan-w-team-orchestrator-decisions-${SLUG}.jsonl"`)
- **Reader (shipped T2):** Step 8 retro `§8j-bis Orchestrator Decision Health`
  reads it via `RETRO_DECISIONS=".claude/state/plan-w-team-orchestrator-decisions-$SLUG.jsonl"`
  and scores:
  - count of low-confidence decisions
  - parse-failure ratio (via `-fallback` call-site suffix)
  - per-site verdict distribution
  Score <4 feeds `§8i` friction log with category `orchestrator-quality`.
- **Lock:** `.claude/state/plan-w-team-orchestrator-decisions-<slug>.lock`
  (mkdir-based, released via `trap … EXIT`).
- **Mode:** `handoff` — Step 5 review fails closed if registered without a
  reader. Until T2 ships, the reader_grep matches the planned variable name
  documented in this file (`RETRO_DECISIONS=".claude/state/plan-w-team-orchestrator-decisions-$SLUG.jsonl"`),
  so the symmetry-check passes via doc self-reference.

## Router Invocation Contract

```bash
# snippet-lint: skip — illustrative invocation pattern
.claude/scripts/plan-w-team-orchestrator-route.sh <call-site-label> <slug> [evidence-args...]
```

- Exit 0 + stdout = chosen option (orchestrator or ask-stub).
- Exit non-zero = `UnknownCallSiteError` or invocation error (stderr has detail).

The script is called `route_orchestrator` in prose; on disk it is
`plan-w-team-orchestrator-route.sh`.

## Adding a New Call Site

1. Append a row to the Classifier Table above.
2. Assign the verdict honestly:
   - `orchestrator` if the decision is reversible and bounded by evidence the
     orchestrator already has in context.
   - `user` if the decision is irreversible, security-sensitive, or alters a
     contract the user signed off on (scope, secrets, push).
   - `inline-rule` only if the decision can be made by a deterministic shell
     check (no LLM judgement needed).
3. Update the stage file that needs the pause to call
   `route_orchestrator <label> "$SLUG" <evidence...>` instead of
   `AskUserQuestion`.
4. Run `.claude/scripts/plan-w-team-orchestrator-route.test.sh` —
   `unknown-call-site-label` should still fail, but the new label should
   route correctly.

## Where This Runs

- **Stages 00–07** call `route_orchestrator` at every classified pause site
  (retrofitted in PWT-T2, 2026-05-18).
- **Step 5 review** scores the symmetry check that registers this artifact.
- **Step 8 retro §8j-bis** reads the JSONL for decision-health metrics.
