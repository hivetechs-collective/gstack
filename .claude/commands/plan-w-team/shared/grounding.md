# Existing-System Grounding — Read the Repo Before Planning It (GRD)

> **The failure mode this closes**: in an EXISTING repo, a `/plan-w-team` run (especially
> a context-blind bg worker spawned by the route hook) starts planning without first
> reading the repo's documentation or understanding its current architecture. Wrong
> assumptions about "what exists today" get written into the spec's CURRENT state and
> Technical Design, every downstream stage inherits them (builders build on them, the
> Step-5 verifier filter even _trusts_ them — "intended behavior documented in the spec"
> is a drop-reason for findings), and the run ships something that fights the codebase
> it lives in. Grounding was previously advisory prose ("read the relevant code");
> this contract makes it a **deterministic two-phase gate** with an adversarial
> re-check, per the enforcement-audit philosophy: detection must not be LLM-only.

## The contract in one paragraph

Before the Step-0 premise challenge, the lead **enumerates and reads the repo's
canonical docs** and records what it learned as an **Existing-System Grounding Ledger**
in the spec (Step 1). The Step-1 AC freeze **refuses** to proceed without a compliant
ledger (`plan-w-team-grounding-gate.sh --check`, ENFORCING). At Step 5, the review
**adversarially re-verifies** the ledger: the deterministic gate re-runs against the
live repo (`--phase review` — zero `ASSUMED` rows may survive), and the reviewer
semantically spot-checks the claims against the actual code/docs. A **REFUTED claim
the diff's design depends on is a Pass-1 CRITICAL** — it blocks ship through the
existing `all_critical_resolved` machinery. No new pause site, no new state artifact.

## Phase A — Enumerate + read (Step 0, before the premise challenge)

```bash
.claude/scripts/plan-w-team-grounding-gate.sh --enumerate
```

The enumerator lists the repo's canonical entry-point docs (deterministic, sorted,
capped at `PWT_GROUNDING_MAX` (default 30) with a LOUD truncation warning): root
`README*` / `CLAUDE.md` / `AGENTS.md` / `CONTRIBUTING*` / `ARCHITECTURE*` / `DESIGN*` /
`GOVERNANCE*`, top-level `docs/*.md`, and `docs/{architecture,adr,decisions}/*.md`.

**Honest limits of the deterministic floor** (do not overclaim what the gate proves):
coverage is checked against the **capped** list — docs beyond `PWT_GROUNDING_MAX`
need no disposition (the stderr warning is the only signal; raise the cap in doc-heavy
repos). The gate verifies section _shape_, doc-path _coverage_, and status _tokens_ —
it cannot verify that reading actually happened or that citations are truthful. That
semantic layer is exactly what Step 5 §5a-ter's adversarial re-verification exists for,
and a wholesale skipped-every-doc ledger or a suspiciously-thin one is itself a review
flag there.

The lead MUST dispose of **every** enumerated doc one of two ways:

1. **Read it** (Read tool) and mine it for claims relevant to the feature; or
2. **Skip it with a written reason** (`docs/marketing-plan.md — skipped: not technical`).

Entry points are the floor, not the ceiling: follow references from them into
feature-relevant deep docs (runbooks, sibling specs, module READMEs) as needed.
The Step-0 `CURRENT` state and taste calibration MUST derive from what was read —
not from what the model assumes a repo like this probably contains.

## Phase B — Ledger in the spec (Step 1, gated at freeze)

The spec carries a mandatory section (template in `01-specification.md`):

```markdown
## Existing-System Grounding Ledger (MANDATORY — GRD)

Sources consulted:

- README.md — read
- docs/architecture/overview.md — read
- docs/adr/0007-queueing.md — skipped: superseded per ADR-0012

| Claim about the existing system           | Evidence (file:line / doc §)    | Status    |
| ----------------------------------------- | ------------------------------- | --------- |
| Notifications fan out via NotificationBus | src/notify/bus.ts:41; README §3 | CONFIRMED |
| Jobs table has no tenant column           | db/schema.sql:88                | CONFIRMED |
| Rate limiting handled at the edge (CDN)   | (could not verify in repo)      | ASSUMED   |
```

Row rules:

- **CONFIRMED** — the lead actually opened the cited evidence and it supports the claim.
- **ASSUMED** — the claim shapes the design but could not be verified at spec time.
  Allowed at Step 1 (flagged honestly beats laundered), **forbidden by Step 5**.
- Every claim the Technical Design _relies on_ about existing behavior belongs here —
  module boundaries, conventions, invariants, "X already handles Y". If the spec's
  `CURRENT:` line says it, a ledger row must back it.
- Greenfield repos (enumerator finds nothing) write the explicit statement
  `Greenfield — no existing documentation to consult.` — never a silent blank.
  A greenfield claim does NOT exempt coverage when docs exist (the gate fails it).

**ENFORCING**: `plan-w-team-grounding-gate.sh --check --spec "$SPEC"` runs as a Step-1
freeze pre-condition beside the H1 reuse-audit gate. It fails the freeze when the
section is missing/blank, when any enumerated doc path is absent from the section, or
when there is neither a claim table row nor the canonical greenfield statement. Claim
rows are counted **row-anchored** (a table row whose status cell is CONFIRMED/ASSUMED —
prose mentions of the tokens are ignored), and the greenfield waiver requires the
canonical phrase "no existing documentation" (a bare "greenfield" mention, or its
negation, does not qualify).

## Phase C — Adversarial re-verification (Step 5, the second check)

Two layers, mirroring the access-control scan's floor+judgment split:

1. **Deterministic floor** — re-run the gate against the LIVE repo:
   `plan-w-team-grounding-gate.sh --check --spec "$SPEC" --phase review`.
   Catches: section deleted/decayed mid-run, docs added since Step 1 (e.g. by a
   concurrent run) that were never consulted, and any surviving `ASSUMED` row.
2. **Semantic verification (reviewer judgment)** — the Pass-1 reviewer (or the
   fan-out's reviewers, when §5b-pre triggers) re-reads the ledger rows against the
   actual repo: does the cited evidence really say that? Verify **all rows when ≤10**;
   otherwise prioritize every row the diff's design depends on. Verdict per row:
   `VERIFIED` / `REFUTED` (+ one-line citation). A **REFUTED row the diff depends on
   is Pass-1 CRITICAL** (blocks ship via `all_critical_resolved`); fixing it means
   correcting the spec (re-run the Step-1 freeze per the AC-snapshot rules) and
   re-validating the affected design/tasks — not editing the ledger to match the code.
   Resolving an honest `ASSUMED` row (verify → flip to `CONFIRMED` + citation) is a
   REQUIRED edit, not drift: after flipping, re-run the Step-1 snapshot as for a
   tightened-AC edit so later §5a integrity passes don't flag it.

**Verifier-filter interplay (IMPORTANT)**: Step 5's synthesis filter drops findings
whose behavior is "documented in the spec". That drop-reason is only valid when the
documenting spec claim traces to a CONFIRMED/VERIFIED ledger row — an _ungrounded_
spec claim cannot launder a finding.

## Integration points

| Stage  | Duty                                                              | Enforcement                                 |
| ------ | ----------------------------------------------------------------- | ------------------------------------------- |
| Step 0 | §0a-pre: enumerate + read/skip every canonical doc before premise | gate at Step-1 freeze (coverage check)      |
| Step 1 | Ledger section in spec; freeze pre-condition                      | `plan-w-team-grounding-gate.sh` (exit 1)    |
| Step 5 | §5a-ter: deterministic re-check + semantic re-verification        | gate `--phase review` + Pass-1 CRITICAL row |
| Retro  | REFUTED-at-review count is a spec-quality signal (note in §8i)    | advisory                                    |

## Sibling floor — Step-2 path-existence gate (G2 follow-on)

The same deterministic-floor philosophy ("detection must not be LLM-only") applies to
Step 2's task-breakdown path annotations, not just the spec's existing-system claims.
The `files_touched` `(create)`/`(modify)` annotations and `creates_types` locations are
LLM-guessed; left unchecked, a `(create)` target that already exists — or a `(modify)`
target that does not exist — passes into the ENFORCING scope-lock and the builder
prompts. `plan-w-team-path-existence-gate.sh` (`.claude/scripts/`) validates every
annotation against the working tree at scope-lock time — intra-breakdown-aware (a
`(modify)` of a file a sibling task `(create)`s is not flagged) — with the same exit-code
contract and ack escape hatch as the import-coupling analyzer. It is wired as a second
ENFORCING pre-condition in `02-task-breakdown.md`'s Scope Lock Artifact, writes
`.claude/state/plan-w-team-path-existence-$SLUG.json` (registered in
`shared/state-artifacts.md`), and **shares this gate's kill switch** —
`PLAN_W_TEAM_DISABLE_GROUNDING=1` disables it too. See `02-task-breakdown.md`
§Path-Existence Check for the full contract.

Kill switch: `PLAN_W_TEAM_DISABLE_GROUNDING=1` (consistent with the
`PLAN_W_TEAM_DISABLE_*` family) — for trivial/docs-only runs where the ceremony
exceeds the risk. It disables both the spec grounding gate AND the Step-2
path-existence floor above. This switch is documented HERE for operator use and deliberately
not echoed in gate failure messages (C6 precedent — a blocked autonomous worker is
not handed its own escape hatch). When the gate runs disabled it prints a grep-able
notice line; note the family-wide residual that a worker env exporting
`PLAN_W_TEAM_DISABLE_*` silently weakens gates in unattended runs (tracked in the
recursive-followups ledger).

## Why this shape

- **Spec-resident ledger, no new state artifact** — the spec already travels to
  builders, reviewers, and `--resume`; keeping evidence there avoids a new
  `state-artifacts.md` registration and another writer↔reader pair to keep symmetric.
- **Two-phase same-script** — declare-then-reverify with one deterministic tool is the
  proven §6c-ter pattern (scanner runs at Step 5 AND ship; a count that contradicts a
  live signal fails closed).
- **ASSUMED is allowed early, fatal late** — honesty at spec time beats forced fake
  certainty; the review-phase zero-ASSUMED rule guarantees assumptions can't reach ship.
