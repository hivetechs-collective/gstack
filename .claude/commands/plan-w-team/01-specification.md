# Step 1: Generate Specification

**Opus 4.7/4.8 tip**: Front-load the full task shape in the first draft — intent, constraints, acceptance criteria, Error & Rescue Map, and Shadow Paths. Progressive reveal wastes tokens on rework. See `shared/opus-4-7-practices.md` §1.

Create a **spec** (requirements document, persists in repo) at `docs/specs/<feature-name>.md`:

```markdown
# Feature: <name>

## Scope Inputs (from Step 0)

Captured from the Step 0 scope-challenge output. These travel with the spec so Step 5 review and Step 8 retro can verify the feature shipped against its declared inputs (and not against silently-shifted scope).

| Field                | Value                                                                                                                                                                                   |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scope_mode`         | EXPAND \| SELECTIVE EXPAND \| HOLD \| REDUCE — chosen at /plan-w-team invocation                                                                                                        |
| `door_labels`        | List each major design decision tagged in §0d, e.g. `auth-table-schema: one-way`, `email-template-copy: two-way`                                                                        |
| `taste_anchor`       | 2-3 in-repo good patterns + 1-2 anti-patterns from §0b, with file paths. The reviewer (Step 5) cites these when ranking subjective code quality.                                        |
| `dream_state_delta`  | One sentence: how this feature moves CURRENT toward 12-MONTH IDEAL. If empty, Step 0 should have killed the feature.                                                                    |
| `board_issue`        | `#<n>` from `scripts/board.sh add` (filled in after the Board Integration block below)                                                                                                  |
| `complexity_signals` | Files-to-change estimate, new-files-to-create estimate, estimated-task count. If any exceeded the §0c Context Budget Gate threshold, this field MUST also reference the split decision. |

## Existing-System Grounding Ledger (MANDATORY — GRD)

What this run verified about the EXISTING system before designing against it (built in
Step 0 §0a-pre; contract in `shared/grounding.md`). Every enumerated canonical doc is
listed (consulted or skipped-with-reason); every claim the Technical Design relies on
about existing behavior has a row with evidence. `ASSUMED` = shapes the design but
unverified at spec time — allowed here, forbidden by Step 5 review.

Sources consulted:

- README.md — read
- docs/architecture/overview.md — read
- docs/adr/0007-queueing.md — skipped: superseded per ADR-0012

| Claim about the existing system           | Evidence (file:line / doc §)    | Status    |
| ----------------------------------------- | ------------------------------- | --------- |
| Notifications fan out via NotificationBus | src/notify/bus.ts:41; README §3 | CONFIRMED |
| Rate limiting handled at the edge (CDN)   | (could not verify in repo)      | ASSUMED   |

Greenfield repos: replace the list + table with the explicit statement
"Greenfield — no existing documentation to consult." — never a silent blank.

## Overview

Brief description. Include dream state mapping (CURRENT must trace to Grounding Ledger rows):

- CURRENT: [what exists]
- THIS PLAN: [what we're building]
- 12-MONTH IDEAL: [where this leads]

## Requirements

- [ ] Requirement 1
- [ ] Requirement 2

## Existing-Code Survey / Reuse Audit (MANDATORY — H1)

Before freezing the spec, survey the codebase (Grep/Explore) for existing implementations that overlap this feature — functions, helpers, utilities, modules, types, constants, enums. List each candidate with a **REUSE / EXTEND / BUILD-NEW** verdict and a one-line rationale. This is the written counterpart to the Step-0 premise question "can we achieve 80% of the value from what exists?" — it puts the reuse-vs-build decision on paper instead of leaving it implicit.

| Candidate existing implementation | Location (path:line / grep) | Overlap | Verdict (REUSE/EXTEND/BUILD-NEW) | Rationale                  |
| --------------------------------- | --------------------------- | ------- | -------------------------------- | -------------------------- |
| `formatCurrency()`                | `src/util/money.ts:12`      | exact   | REUSE                            | import the existing helper |

**Empty is allowed ONLY with an explicit statement** — e.g. "Surveyed the codebase; nothing overlaps this feature." — never silently blank. Any cross-feature / recent-commit overlaps surfaced by the Step-0 overlap scan (`00-scope-challenge.md` §0f) MUST be folded in here.

**Enforced**: the Step-1 freeze gate (`plan-w-team-reuse-audit-gate.sh`, run as a pre-condition before the AC Snapshot below) refuses to freeze the spec when this section is missing or blank-without-statement. See `shared/reuse-first.md` for the reuse-first rule this section operationalizes. Kill switch: `PLAN_W_TEAM_DISABLE_REUSE_AUDIT=1`.

## UI Tier Profile & Test Plan (UI features only)

Populate this block when `ui_scope_flag == true` from §0e. Skip entirely for non-UI features — the rest of the spec template is unchanged.

| Field                   | Value                                                                                                                                                             |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `qa_profile`            | `light` / `standard` / `full` — read from `.claude/qa-profile.json`. May be overridden per-feature via `qa_profile_override` front-matter (bump only, not lower). |
| `tiers_enforced`        | Expanded from the profile per `shared/qa-tiers.md` (e.g., Tier-Standard → T1 + T2 + T3).                                                                          |
| `locator_strategy`      | `data-testid` primary; hierarchy fallback order per `shared/locator-hierarchy.md`. Any CSS locator requires written justification in the test file.               |
| `page_object_required`  | `true` for any feature touching ≥1 interactive element. Inline `page.locator(...)` in specs is a Pass 1 CRITICAL violation.                                       |
| `data_testid_shape`     | `<feature>-<element>-<action>` kebab-case, e.g., `login-submit-button`. Enforced by `eslint-rules/require-data-testid.js`.                                        |
| `smoke_spec_path`       | `{{TEST_DIR}}/<feature>.smoke.spec.ts` — T1 equivalence, runs on every commit.                                                                                    |
| `regression_spec_paths` | Per-tier paths for T3/T4/T5 as applicable to the chosen profile.                                                                                                  |

Link the relevant sections of `shared/qa-tiers.md` and `shared/locator-hierarchy.md` inline rather than restating their rules. Duplication causes drift; the shared files are canonical.

### Waived Tiers (if any)

If the feature explicitly waives a tier that the profile would otherwise enforce (e.g., skipping T2 stability for a pure-documentation UI change), list it here with justification. Step 6 Tier Evidence Ledger reads this block — a tier marked ❌ without a corresponding waiver blocks the push.

## Technical Design

Architecture decisions, data flow, key interfaces.

### Architecture Diagram (MANDATORY)

Include at least one of: architecture diagram, data flow diagram, or sequence diagram.
Use Mermaid syntax for inline rendering. Diagrams are not optional — visual thinking
catches problems that text descriptions miss.

### Error & Rescue Map

| Method/Operation   | What Can Go Wrong   | Exception/Error Type     |
| ------------------ | ------------------- | ------------------------ |
| createUser()       | Duplicate email     | DuplicateEmailError      |
| sendNotification() | Service unavailable | NotificationTimeoutError |

| Error Type               | Rescued? | Recovery Action       | User Sees                |
| ------------------------ | -------- | --------------------- | ------------------------ |
| DuplicateEmailError      | Yes      | Suggest login instead | "Account already exists" |
| NotificationTimeoutError | Yes      | Queue for retry       | Nothing (async)          |

RULE: Catch-all exception handlers (`catch(e)`, `rescue StandardError`) are a smell.
Every error condition must have a named type.

### Shadow Path Analysis

For each data flow node, trace three shadow inputs:

1. **nil/undefined input** — What happens when upstream returns nothing?
2. **Empty/zero-length input** — What happens with `[]`, `""`, `0`?
3. **Upstream error** — What happens when the previous step failed?

### Context Boundary Check

For each data flow that crosses a context boundary, verify the consumer can actually access the data:

| Boundary                        | Example                             | Common Trap                                         |
| ------------------------------- | ----------------------------------- | --------------------------------------------------- |
| Agent context → shell hook      | Evaluator report → session-end hook | Shell hooks can't call TaskList/TaskGet             |
| Shell hook → agent context      | Hook output → Claude conversation   | Hooks communicate via stdout/stderr, not tool calls |
| Main process → background agent | Lead state → worktree builder       | Worktrees fork from a point-in-time snapshot        |
| Session N → Session N+1         | Task metadata → resumed session     | Task tools persist; TodoWrite does not              |

If data must cross a boundary, define the **bridge mechanism** (state file, git commit, environment variable) in the Technical Design.

### Threat Model & Access-Control Surface (security-relevant features)

REQUIRED when the feature hits any access-control content signal — see §1c for the trigger. Design the invariants in here so the diff-time gate (Step 5 §5b, Step 6 §6c-ter) has a declared surface to check against. Skip only for features with no auth/tenant/credential/privilege surface (note "N/A — no security surface").

| Trust Boundary                 | Token / Credential In Play | Blast Radius If It Leaks                 | Privilege-Bearing Fields Written |
| ------------------------------ | -------------------------- | ---------------------------------------- | -------------------------------- |
| _e.g._ public HTTP → API       | session JWT                | one tenant's data                        | none                             |
| _e.g._ QA harness → seed route | `QA_SIM_TOKEN` (bypass)    | every account if it can touch real users | `passwordHash`, `platformRole`   |

Then state, per data-mutating endpoint, which of the five invariants in `shared/access-control-invariants.md` are in play (INV-1 object ownership / INV-2 role authz / INV-3 mass-assignment / INV-4 bypass-token scoping / INV-5 tenant isolation), and the deny-by-default authorization rule for each. A bypass/QA/service-token endpoint MUST state how it proves the target is QA-scoped (the `assertQaScoped` pattern). These declarations become the Step 5 review rubric and the Step 6 gate's expectations.

### Decision Labels

Tag each design decision:

- Two-way door (reversible, move fast)
- One-way door (irreversible, scrutinize in review)

### Interaction State Coverage Matrix (for UI features)

| Feature/Component | LOADING  | EMPTY          | ERROR           | SUCCESS | PARTIAL    |
| ----------------- | -------- | -------------- | --------------- | ------- | ---------- |
| User list         | Skeleton | "No users yet" | Retry button    | Table   | Pagination |
| Search            | Spinner  | "No results"   | "Search failed" | Results | Filtering  |

Every cell must be designed, not just SUCCESS.

## Files to Create/Modify

- `path/to/file.ts` - Description of changes
- `path/to/new-file.ts` - New file purpose

## Acceptance Criteria Contract

Testable success criteria the evaluator agent checks in the iteration loop (Step 4b). See `shared/sprint-contracts.md` for the full template, rubric calibration, and examples.

**Required depth by feature type**: New features = Functional + Quality Rubrics. Bug fixes = Functional only ("bug no longer reproduces"). Refactors = Quality Rubrics only. Config/docs-only = skip contract entirely.

**Tuning evaluator iteration depth** (`max_eval_iterations`): The evaluator loop (Step 4b) runs at most `spec.max_eval_iterations` iterations before emitting ESCALATE. Default is `3` — suitable for most features. Override only when the feature has clear justification: set higher (e.g., `5`) for high-ambiguity research features where early iterations are expected to refine the criteria themselves; set to `0` to skip the evaluator entirely, though **prefer omitting the AC contract** (per the rule above) for docs-only or config-only changes. When overriding, declare the field in spec frontmatter and justify it in the Overview section.

### Functional Criteria

Testable assertions the evaluator can verify without subjective judgment. Each must use the `AC` prefix for trigger detection:

- [ ] AC1: [Subject] [verb] [expected outcome]
- [ ] AC2: [Subject] [verb] [expected outcome]

### Quality Rubrics

Gradable criteria on a 1-5 scale. Include anchor descriptions for consistent scoring:

| Criterion        | 1 (Poor)            | 3 (Adequate)        | 5 (Excellent)       |
| ---------------- | ------------------- | ------------------- | ------------------- |
| [Criterion name] | [What 1 looks like] | [What 3 looks like] | [What 5 looks like] |

### Playwright Test Plan

(Skip for non-web projects. See `shared/browser-qa.md` for Playwright MCP usage.)

1. Navigate to [URL]
2. [Action] -> verify [expected result]

**Scope**: Criteria are feature-level, not task-level. The evaluator checks the holistic feature output after all tasks are merged.

## Test Plan

Structured test plan that downstream validation can consume directly:

### Unit Tests

- [ ] Test case 1 — expected behavior, edge cases
- [ ] Test case 2

### Integration Tests

- [ ] Test case 1

### Edge Cases from Shadow Path Analysis

- [ ] nil input to X produces Y
- [ ] Empty array to Z produces W

## Temporal Stress Test

Evaluate the plan across implementation phases:

- **Hour 1 (foundations)**: What decisions must be made now that are costly to reverse later?
- **Hours 2-3 (core logic)**: What integration points need to be defined before parallel work begins?
- **Hours 4-5 (integration)**: What assumptions from earlier phases might break during assembly?
- **Hour 6+ (polish/tests)**: What was deferred that could become a blocker?

## Deferred Items

Everything deferred MUST be written down with enough context for someone else to pick it up.

| Item          | Why Deferred     | Context Needed to Resume            | Priority |
| ------------- | ---------------- | ----------------------------------- | -------- |
| Rate limiting | Not in MVP scope | See API design section, needs Redis | P2       |
```

The spec persists for resumption. A **plan** (implementation approach) is ephemeral and per-builder — each builder designs their own plan in plan approval mode.

Use `/fork` before trying a risky decomposition strategy. Fork the session, try one approach, and if it doesn't work, return to the fork point and try another.

## Board Integration (Auto)

After writing the spec, create a GitHub Issue on the project board. Issues (not drafts) enable full PR linking, comment history, and auto-close on merge. Fire-and-forget — failures must NOT block the workflow.

```bash
# Create Issue with spec summary in body — capture the issue number for later stages
BOARD_ISSUE=$(scripts/board.sh add "<feature-name>" \
  --priority P1 \
  --area <area> \
  --type feature \
  --size <S|M|L|XL> \
  --body "**Spec:** docs/specs/<feature-name>.md

## Overview
<1-2 sentence summary from spec>

## Acceptance Criteria
<paste AC list from spec>

## Task Checklist
_Updated after task breakdown (Step 2)_" || true)

# Move to Todo
scripts/board.sh move "<feature-name>" "Todo" || true
```

**Store the issue number** (e.g., `#42`) — subsequent stages use it for comments and PR linking. Add it to the spec file header:

```markdown
# Feature: <name>

<!-- Board: #42 -->
```

Choose `--area` based on the primary app affected (api, web, admin, website, mobile, db, shared, infra, docs).
Choose `--priority` based on urgency: P0=blocking, P1=current sprint, P2=next sprint, P3=backlog.
Choose `--size` based on estimated effort: S (<2h), M (2-8h), L (8-24h), XL (24h+).
If the card already exists (from a previous `/board add` or backlog grooming), skip creation and just verify status.

**Cognitive frameworks used here**: Make the change easy, then make the easy change (Beck), Boring technology (McKinley), Strangler fig pattern (Fowler). Read `shared/cognitive-frameworks.md` for full reference.

## §1b-pre. Multi-Angle Spec Fan-Out (AUTO — right-sized, default-on for non-trivial specs)

Run a parallel multi-angle critique of the just-authored draft spec **before the
AC freeze below**. This catches missing requirements, weak/untestable acceptance
criteria, untraced shadow paths, and security boundaries while the spec is still
mutable — the cheapest point in the whole lifecycle to fix them.

**AUTO mode (the default, operator decision 2026-07-02):** the fan-out fires
automatically when the draft spec is **non-trivial** — ≥3 requirement checkboxes
OR any one-way-door decision — and auto-skips (single-pass, exactly the old
behavior) on trivial specs, where 3 Brain-tier reviewers cannot earn their cost.
No env var, no per-run action, identical behavior on attended and bg runs.
Overrides: `PLAN_W_TEAM_SPEC_FANOUT=0` → hard OFF (operator opt-out, forwarded
to bg workers by `pwt-goal.sh` when set); `PLAN_W_TEAM_SPEC_FANOUT=1` → force ON
even for trivial specs. The §8j-nonies retro signal keeps scoring every fired
run — if `findings_folded ≈ 0` across ~5 auto-fired runs, that is the evidence
to restore default-off (reverse this section + the §8j-nonies advice text).

Hard ordering rule: the fan-out MUST complete and its findings MUST be folded
into the spec **strictly before** the freeze below, so the SHA256 snapshot
digests the post-fan-out spec and the frozen contract is preserved.

Roster — three same-session **Agent**-tool reviewers (Brain-tier, spec-authoring
capable; NOT the diff-based gap analyzers, which read a diff that does not exist
at Step 1):

| Reviewer (subagent_type) | Angle                                                                                                                                        |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `system-architect`       | Architecture fit, missing requirements, boundary/shadow paths                                                                                |
| `security-expert`        | Security/abuse boundaries, one-way-door surfaces                                                                                             |
| `code-review-expert`     | Testability — are the acceptance criteria observable/verifiable?                                                                             |
| `fable-spec-consult`     | **Fable tier — GUARD-GATED, see §1b-bis below.** Whole-design critique: top risks, missed alternatives, spec holes, production failure modes |

```bash
# Tri-state gate: unset → AUTO (fire on non-trivial specs); 0 → hard OFF; 1 → force ON.
SLUG="<feature-slug>"
SPEC="docs/specs/${SLUG}.md"
RUN_FANOUT=0
case "${PLAN_W_TEAM_SPEC_FANOUT:-auto}" in
  0) echo "[§1b-pre] spec fan-out OFF (PLAN_W_TEAM_SPEC_FANOUT=0 — operator opt-out)" ;;
  1) RUN_FANOUT=1; echo "[§1b-pre] spec fan-out FORCED on (PLAN_W_TEAM_SPEC_FANOUT=1)" ;;
  *)
    # AUTO: non-trivial = ≥3 requirement checkboxes OR a one-way-door decision.
    REQ_COUNT=$(awk '/^## Requirements/{f=1;next} /^## /{f=0} f' "$SPEC" | grep -cE '^[[:space:]]*-[[:space:]]*\[' || true)
    if [ "${REQ_COUNT:-0}" -ge 3 ] || grep -qi 'one-way' "$SPEC"; then
      RUN_FANOUT=1
      echo "[§1b-pre] auto-fired: non-trivial spec (${REQ_COUNT} requirements; one-way check applied)"
    else
      echo "[§1b-pre] auto-skip: trivial spec (${REQ_COUNT} requirements, no one-way door) — single-pass"
    fi
    ;;
esac
if [ "$RUN_FANOUT" = "1" ]; then
  FANOUT=".claude/state/plan-w-team-spec-fanout-${SLUG}.json"
  # Lead spawns the three reviewers via the Agent tool with run_in_background:true
  # (subagent_type: system-architect, security-expert, code-review-expert — via
  # the Agent tool, NOT the dynamic-workflow tool, NOT the diff-based
  # security-gap-analyzer/test-gap-analyzer), collects findings,
  # FOLDS them into the draft spec, then writes the advisory record:
  #   {"reviewers":[...],"verdicts":[...],"findings_folded":N,"findings_deferred":M}
  # The fold-in happens HERE, before the freeze, so the contract chain stays intact.
  echo "[§1b-pre] fan-out complete; findings folded; advisory record → $FANOUT"
fi
```

## §1b-bis. Fable Spec Consult (Model Tiering v3 — GUARD-GATED)

A fourth reviewer, `fable-spec-consult`, runs on the **Fable tier** — the strongest
model available. It is the last high-leverage read before the AC freeze, which is the
cheapest point in the lifecycle to fix a design.

It rides §1b-pre deliberately rather than carrying its own machinery: the trigger is
§1b-pre's **existing non-triviality classifier** (`RUN_FANOUT`, above — ≥3 requirement
checkboxes OR a one-way door), and it inherits §1b-pre's hard ordering rule verbatim —
the consult MUST complete and its findings MUST be folded in **strictly before the
freeze** below, so the SHA256 snapshot digests the post-consult spec and Step-5 tamper
detection stays clean. There is no separate classifier and no separate artifact.

Fable is a bounded, deliberate spend, never a lane. Every spawn goes through the guard:

```bash
# Only exit 0 authorizes the spawn. ANY other exit — including 127, which is what a
# consumer repo that synced the agent but not the guard will produce — means SKIP:
# continue with the three Opus reviewers and do NOT spawn Fable. A skip is never a
# run failure, and the guard records the reason either way.
if [ "$RUN_FANOUT" = "1" ] \
   && .claude/scripts/plan-w-team-fable-guard.sh \
        --slug "$SLUG" --kind consult --nontrivial true >/dev/null 2>&1; then
  # Spawn ONE fable-spec-consult reviewer via the Agent tool alongside the other
  # three. Give it the draft spec path and a findings path to write to as it goes
  # (a lane that goes idle without delivering otherwise leaves no evidence).
  # It is READ-ONLY: it advises; the Opus lead folds findings in and authors the spec.
  echo "[§1b-bis] Fable spec consult ALLOWED — spawning read-only consultant"
else
  echo "[§1b-bis] Fable spec consult skipped — continuing on the Opus reviewers"
fi
```

Overrides (all consumed by the guard, none re-implemented here):

| Var                                   | Effect                                                                      |
| ------------------------------------- | --------------------------------------------------------------------------- |
| `PLAN_W_TEAM_DISABLE_FABLE=1`         | Subsystem kill — consult AND escalation. Highest precedence.                |
| `PLAN_W_TEAM_DISABLE_FABLE_CONSULT=1` | Disables this consult only. Beats FORCE.                                    |
| `PLAN_W_TEAM_FORCE_FABLE_CONSULT=1`   | Forces the consult on a trivial spec. Never bypasses the budget or the cap. |
| `PLAN_W_TEAM_FABLE_BUDGET_MAX_PCT`    | Weekly Fable-bucket ceiling, default 80.                                    |

**Honest limit**: the guard is invoked by this prose, so it binds a lead that reads the
stage file. It is deterministic _once invoked_, not a chokepoint — a `PreToolUse` binding
is the structural fix and is tracked as a deferred item on the v3 spec.

## §1c. Access-Control Threat-Model Trigger (security-relevant features)

The `### Threat Model & Access-Control Surface` block in the Technical Design (above) is **MANDATORY** — not skippable — when ANY of these hold. The trigger keys on the same content signals the diff-time gate uses (`shared/owasp-top10-mapping.md` §Content-Signal Triggers), so the surface is _declared_ at spec time and _checked_ at review time:

- The feature reads, writes, mints, or validates an auth/session token, API key, **bypass/QA/service token**, or other credential.
- The feature writes any **privilege-bearing field** (`role`, `platformRole`, `tenantId`/`orgId`, `isQaUser`, `ownerId`, `isAdmin`, `permissions`, `passwordHash`, `balance`, `*Cents`).
- The feature spreads a request body / untrusted input into an ORM `update`/`insert`/`save` (mass-assignment surface).
- The feature performs a `where … by id` / single-record lookup or mutation that may need a tenant/owner predicate.
- The feature adds or gates a handler behind a bypass / QA / debug / service token.

Skip the block ONLY for features touching none of the above (pure docs, pure UI-copy, isolated compute with no auth/tenant/credential surface) — write "N/A — no security surface" so the omission is deliberate, not forgotten. When the block is required and the author leaves it empty, Step 5 review treats the missing block as an ASK item (mirroring the AC-snapshot tamper-detection pattern).

Any security/access-control acceptance criteria belong **inside** the AC block below, so they are captured by the SHA256 freeze. Designing the invariants in here is the point: a confirmed high-severity broken-access-control finding against this declared surface is **GATING at Step 6 ship** (`05-ship.md` §6c-ter) — it blocks the push and is NOT retroactive (`04-fix-first-review.md` §5d-ter).

**Secret-handling documentation duty (C1, 1.33.0).** The first trigger above — a feature that reads/writes/mints a credential — also raises a _documentation_ obligation, not just a threat-model one. When the feature introduces a **new secret-bearing env var** (a var whose name matches the secret-bearing heuristic: `*_TOKEN`, `*_KEY`, `*_SECRET`, `*_PASSWORD`, `*_API_KEY`, `*_CREDENTIAL*`, or a provider-prefixed var like `STRIPE_*` / `CLOUDFLARE_*` / `AWS_*`), the spec MUST record that a secret-handling deliverable is owed at ship: an `.env.example` row (placeholder value) **plus** a provisioning / rotation / never-commit note in the runbook or config reference. Note it here as a checklist item (e.g. "C1 deliverable: `FOO_API_TOKEN` → `.env.example` + DEPLOY_RUNBOOK rotation note"). This is enforced at post-ship — `06-post-ship.md §7f` refuses to mark Step 7 complete when this signal fired but no secret-handling doc is present in the diff. The full duty (including the C2 infra-glob analog) lives in `shared/secret-safety.md §Secret-Handling Documentation Duty`. `docs/specs/` does NOT satisfy it — the deliverable is operational documentation.

## Reuse-Audit Freeze Pre-Condition (ENFORCING — H1)

Before snapshotting (freezing) the Acceptance Criteria below, the `## Existing-Code Survey / Reuse Audit` section (above) MUST be present and non-blank. This mirrors the Step-2 scope-lock coupling-ack pre-condition (`02-task-breakdown.md` §Scope Lock Artifact) — the freeze refuses to proceed otherwise, making the reuse-vs-build decision a conscious, audited gate rather than a step the lead can forget.

```bash
SLUG="<feature-slug>"
SPEC="docs/specs/${SLUG}.md"
if ! .claude/scripts/plan-w-team-reuse-audit-gate.sh --spec "$SPEC"; then
  echo "✗ Step-1 freeze refused: Reuse Audit section missing/blank in $SPEC"
  echo "  Fill in the 'Existing-Code Survey / Reuse Audit' section with"
  echo "  REUSE/EXTEND/BUILD-NEW verdicts (or an explicit 'nothing overlaps'"
  echo "  statement)."
  # NOTE: no bypass coaching in the failure message (C6 precedent — do not hand
  # a blocked autonomous worker its own escape hatch; the kill switch is
  # documented in shared/reuse-first.md for OPERATOR use).
  exit 1
fi
```

The gate exits `0` (pass / kill switch), `1` (section missing or blank — refuse freeze), or `2` (spec file not found — author the spec first). Kill switch `PLAN_W_TEAM_DISABLE_REUSE_AUDIT=1` is consistent with the `PLAN_W_TEAM_DISABLE_*` family and lets a docs-only / trivial run bypass the gate. See `shared/reuse-first.md` for the underlying rule.

## Grounding Freeze Pre-Condition (ENFORCING — GRD)

Beside the reuse gate above, the freeze also refuses to proceed unless the spec carries a
compliant `## Existing-System Grounding Ledger` section (built in Step 0 §0a-pre; contract
in `shared/grounding.md`). This is the deterministic half of the existing-repo drift fix:
a spec that never read the repo's canonical docs cannot freeze.

```bash
SLUG="<feature-slug>"
SPEC="docs/specs/${SLUG}.md"
if ! .claude/scripts/plan-w-team-grounding-gate.sh --check --spec "$SPEC"; then
  echo "✗ Step-1 freeze refused: Grounding Ledger missing/blank/uncovered in $SPEC"
  echo "  Consult (or skip-with-reason) every doc from --enumerate, and add"
  echo "  CONFIRMED/ASSUMED claim table rows (or the explicit greenfield statement)."
  # NOTE: no bypass coaching in the failure message (C6 precedent — do not hand
  # a blocked autonomous worker its own escape hatch; the kill switch is
  # documented in shared/grounding.md for OPERATOR use).
  exit 1
fi
```

Exit codes mirror the reuse gate: `0` pass / kill switch, `1` refuse freeze (section
missing, blank, an enumerated doc path absent from the section, or no claim table rows
and no greenfield statement), `2` spec not found. The gate checks doc-path PRESENCE —
the read-vs-skipped disposition wording is the lead's duty and is verified semantically
at Step 5. Claim rows are counted **row-anchored** (a markdown table row whose status
cell is `CONFIRMED`/`ASSUMED`); prose mentions of those words are ignored, so keeping
this template's guidance sentences in the spec is safe. Step 5 §5a-ter re-runs this gate
with `--phase review` (zero `ASSUMED` rows may survive) and adversarially re-verifies the
rows — see `04-fix-first-review.md`.

## Acceptance Criteria Snapshot (MANDATORY — integrity gate)

At the end of Step 1, snapshot the Acceptance Criteria section of the spec with a SHA256 digest. The evaluator (Step 4b) reads this snapshot — NOT the live spec — so a mid-flight spec edit cannot silently loosen the contract.

```bash
SLUG="<feature-slug>"   # same slug used for baseline/scope-lock
SPEC="docs/specs/${SLUG}.md"
SNAPSHOT=".claude/state/plan-w-team-ac-snapshot-${SLUG}.md"

mkdir -p .claude/state

# Extract the Acceptance Criteria block (from the heading to the next top-level heading)
awk '/^## Acceptance Criteria/{flag=1; print; next} /^## /{flag=0} flag' "$SPEC" \
  > "${SNAPSHOT}.body"

# Compute SHA256 of the spec file itself (detects any edit to the file after snapshot)
SPEC_SHA=$(shasum -a 256 "$SPEC" | awk '{print $1}')
AC_SHA=$(shasum -a 256 "${SNAPSHOT}.body" | awk '{print $1}')

{
  echo "---"
  echo "slug: ${SLUG}"
  echo "spec_path: ${SPEC}"
  echo "snapshot_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "spec_sha256: ${SPEC_SHA}"
  echo "ac_sha256: ${AC_SHA}"
  echo "---"
  cat "${SNAPSHOT}.body"
} > "$SNAPSHOT"

rm -f "${SNAPSHOT}.body"
```

**What the snapshot enforces**:

- **Evaluator input is frozen**: Step 4b reads `$SNAPSHOT`, not `$SPEC`. A builder cannot edit the spec mid-iteration to make failing criteria "pass".
- **Tamper detection**: Step 5 review re-computes the spec SHA256 and compares against `spec_sha256` in the snapshot frontmatter. Mismatch = scope drift — flag as ASK item for the user.
- **Audit trail**: The snapshot is preserved for retro (Step 8). A feature that shipped with `ac_sha256=X` and a post-ship spec with `ac_sha256=Y` means the AC was retroactively rewritten — caught at retro.

If a legitimate mid-flight AC change is needed, re-run Step 1 to refresh the snapshot and note the reason in the spec's "Changelog" section. Do not edit the snapshot file directly — it has no authority if hand-edited.

## §1.5. Derive Feature-Specific Done Criteria (PWT-T5c)

After the AC snapshot, derive feature-specific grep patterns from the spec's Acceptance Criteria entries and inject them into the goal state file. This makes the `/goal` evaluator's SUCCESS condition require BOTH the generic terminal anchors AND every feature-specific criterion to appear in the transcript before allowing stop.

The derivation is MECHANICAL: every `AC<N>:` entry in the spec's Acceptance Criteria section becomes one criterion with pattern `AC<N>:[[:space:]]*PASS`. The pattern matches the `AC<N>: PASS — <evidence>` verification lines that Step 5 review and Step 6 ship emit per AC (this emission format is a CONTRACT — see the AC Verification Line Contract in `04-fix-first-review.md`/`05-ship.md`).

> **1.54.0 pattern tightening.** The previous pattern `AC<N>.*PASS` let the greedy `.*`
> span unrelated transcript content — field evidence 2026-07-09 (helm): AC9 flipped
> `met: true` while the lead explicitly reported it "deliberately not performed". The
> anchored form requires the literal verification line. Deliberately NOT end-anchored
> (`PASS` not `PASS([[:space:]]|$)`) so `AC3: PASSED` still matches — a too-tight
> pattern that never matches re-arms the 2026-06-22 blocked-stop runaway class, which
> is the worse failure.

```bash
SLUG="<feature-slug>"   # MUST be the directive's pre-seeded slug when one is named (see PWT-T5b SLUG adoption)
SPEC="docs/specs/${SLUG}.md"
GOAL_FILE=".claude/state/plan-w-team-goal-${SLUG}.json"

# ── MAIN-checkout resolution, hoisted (recursive-followup row 1, 2026-07-31) ──
# Under a `--worker-only` run cwd is a WORKTREE, and pwt-goal.sh's worktree seed
# arm is race-gated — so the worktree copy of the goal-state frequently does NOT
# exist and ONLY the main copy does. The cwd-relative GOAL_FILE above then misses,
# and this whole block used to print "state file missing — skipping": the run's
# entire AC contract silently un-enforced, on exactly the autonomous path the
# anti-skip anchor exists to protect. Resolve MAIN first and fall back to it.
# (Same resolution as the goal-evaluator's third source and the dual-write below.)
if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    MAIN_ROOT="$PWT_PROJECT_ROOT_OVERRIDE"
else
    CDIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    case "$CDIR" in
        "") MAIN_ROOT="" ;;
        /*) MAIN_ROOT=$(dirname "$CDIR") ;;
        *)  MAIN_ROOT=$(cd "$(dirname "$CDIR")" 2>/dev/null && pwd || echo "") ;;
    esac
fi
if [ ! -f "$GOAL_FILE" ] && [ -n "$MAIN_ROOT" ] \
   && [ -f "$MAIN_ROOT/.claude/state/plan-w-team-goal-${SLUG}.json" ]; then
    GOAL_FILE="$MAIN_ROOT/.claude/state/plan-w-team-goal-${SLUG}.json"
    echo "[§1.5] worktree goal-state absent — resolved MAIN copy: $GOAL_FILE"
fi

# Skip if /goal disabled or state file absent (top-of-pipeline activation skipped)
if [ "${PLAN_W_TEAM_DISABLE_GOAL:-}" = "1" ] || [ ! -f "$GOAL_FILE" ]; then
    echo "[§1.5] /goal disabled or state file missing — skipping criteria derivation"
else
    CRITERIA_JSON='[]'
    while IFS= read -r line; do
        n=$(echo "$line" | grep -oE 'AC[0-9]+' | head -1 | grep -oE '[0-9]+')
        [ -z "$n" ] && continue
        desc=$(echo "$line" | sed -E "s/.*AC${n}:[[:space:]]*//" | head -c 200)
        [[ "$desc" == *"[Subject]"* ]] && continue
        CRITERIA_JSON=$(echo "$CRITERIA_JSON" | jq --arg p "AC${n}:[[:space:]]*PASS" --arg d "$desc" \
            '. + [{pattern: $p, description: $d, met: false, met_at: null}]')
    done < <(awk '/^## Acceptance Criteria/,/^## [^A]/' "$SPEC" | grep -E '^\s*-?\s*\[?\s*\]?\s*AC[0-9]+:')

    CRITERIA_COUNT=$(echo "$CRITERIA_JSON" | jq 'length')

    # ── Canonical row-shape self-check (1.56.0, DEFECT B) ──────────────────
    # This writer must emit ONLY canonical {pattern,description,met,met_at}
    # objects with a NON-EMPTY pattern. The exact mechanism, verified against
    # `.claude/hooks/plan-w-team-goal-evaluator.sh:515`:
    #     PATTERN=$(echo "$NEW_CRITERIA" | jq -r ".[$i].pattern")
    # On a bare-STRING row, jq's `.pattern` errors and yields EMPTY, so the
    # next step greps with `grep -E ""` — an empty regex matches EVERY line —
    # silently marking the row MET. The write-back `.[$i].met = true` also
    # errors on a string, collapsing NEW_CRITERIA to "", so nothing persists
    # and the run resolves SUCCESS having checked NOTHING.
    #
    # The evaluator now fails CLOSED (non-object row → UNMET, empty pattern →
    # UNMET, never `grep -E ""`), so a bad row BLOCKS loudly instead of passing
    # silently. This check is the writer-side half: catch it here and fall back
    # to generic anchors, rather than emitting a contract that wedges the run.
    SHAPE_OK=$(echo "$CRITERIA_JSON" | jq '[.[] | (type == "object")
        and has("pattern") and has("description") and has("met") and has("met_at")
        and (.pattern | type == "string") and (.pattern | length > 0)] | all')
    if [ "$CRITERIA_COUNT" -gt 0 ] && [ "$SHAPE_OK" != "true" ]; then
        echo "[§1.5] ABORT: derived criteria are not canonical {pattern,description,met,met_at} objects with a non-empty pattern — refusing to inject (see goal-evaluator.sh:515 / DEFECT B)"
        CRITERIA_COUNT=0
    fi

    if [ "$CRITERIA_COUNT" -gt 0 ]; then
        # ── UNION merge, not replace (1.56.0) ──────────────────────────────
        # pwt-goal.sh seeds DONE<k> rows from the request's explicit done-when
        # clauses at spawn time (PWT-T2 §2b). The old `= $c` REPLACED the array,
        # so this step silently deleted every seeded row the moment Step 1 ran —
        # the user's own stated done criteria, gone before any work started.
        # Union + unique_by(.pattern) keeps both families and is idempotent
        # across re-runs of §1.5.
        jq --argjson c "$CRITERIA_JSON" \
            '.feature_specific_done_criteria = ((.feature_specific_done_criteria // []) + $c | unique_by(.pattern))' \
            "$GOAL_FILE" > "$GOAL_FILE.tmp" && mv "$GOAL_FILE.tmp" "$GOAL_FILE"
        echo "[§1.5] merged $CRITERIA_COUNT feature-specific done criteria into goal state (union with any seeded DONE<k> rows)"

        # ── Dual-write to the MAIN checkout (1.54.0) ────────────────────────────
        # Under a worker-only run, cwd is a WORKTREE: the bare-relative GOAL_FILE
        # above patches only the worktree-local copy, and the main-repo seeded copy
        # (read by the evaluator, await-terminal watcher, and Run-State Router)
        # stranded at terminal_state:null forever (field evidence 2026-07-09, 3 runs).
        # Mirror pwt-goal.sh's dual-seed: apply the same injection to the main copy
        # when it is a DIFFERENT file. MAIN_ROOT is resolved once, hoisted above —
        # do NOT re-derive it here (one resolution, one behavior).
        MAIN_GOAL_FILE="${MAIN_ROOT}/.claude/state/plan-w-team-goal-${SLUG}.json"
        if [ -n "$MAIN_ROOT" ] && [ -f "$MAIN_GOAL_FILE" ] \
           && [ "$MAIN_GOAL_FILE" != "$(cd "$(dirname "$GOAL_FILE")" 2>/dev/null && pwd)/$(basename "$GOAL_FILE")" ]; then
            # Union here too: this file is the OTHER half of pwt-goal.sh's
            # dual-seed pair and carries the same seeded DONE<k> rows.
            jq --argjson c "$CRITERIA_JSON" \
                '.feature_specific_done_criteria = ((.feature_specific_done_criteria // []) + $c | unique_by(.pattern))' \
                "$MAIN_GOAL_FILE" > "$MAIN_GOAL_FILE.tmp" && mv "$MAIN_GOAL_FILE.tmp" "$MAIN_GOAL_FILE"
            echo "[§1.5] dual-wrote criteria to main-checkout goal state (merged by union)"
        fi
    else
        echo "[§1.5] no AC entries found in spec — goal evaluator uses generic anchors only (T5b behavior)"
    fi
fi
```

**What this enforces**: The `/goal` evaluator's SUCCESS terminal state now requires both generic anchors (`stage="retro-complete"` + `workflow_lock="done"` + `slug` match) AND every `feature_specific_done_criteria` pattern present in the transcript. Each criterion is marked `met: true` + `met_at: <ts>` the first turn its pattern is found. If generic anchors arrive but some criteria are unmet, the hook blocks the stop with a reason citing the specific unmet criteria descriptions — keeping the pipeline running until every AC is verified in transcript.

**Backward compatibility**: If the spec has no AC entries (e.g., docs-only feature) or `PLAN_W_TEAM_DISABLE_GOAL=1`, the criteria array stays empty and the evaluator behaves identically to T5b (generic anchors alone are SUCCESS).

**Schema reference**: `shared/goal-conditions.md` documents the `feature_specific_done_criteria` array field and the AND-check semantics.

## End-of-Stage Status Block (PWT-T5)

At the end of this stage, emit a status block for the `/goal` evaluator. This is a one-line invocation; the helper handles all field population (workflow lock, supervisor log, fleet log, escalations).

```bash
.claude/scripts/plan-w-team-surface-status.sh "$SLUG" "specification"
```

The stage label `specification` is the second argument — see `shared/goal-conditions.md` §Status-Block Schema for the full label list. `/goal` evaluator reads the emitted block to judge whether the pipeline terminal condition is met.

Skip this block entirely when `PLAN_W_TEAM_DISABLE_GOAL=1` (kill switch) — the helper itself is observability and remains safe to call, but invocation here is optional in that mode.

## Optional: Visual Approach-Comparison Artifact (Hook 2 — OFF by default)

When the design phase produces **N candidate approaches** and a human will choose between
them, the lead MAY render them side-by-side as a self-contained HTML page (each option's
tradeoffs under it) — the judge-panel made reviewable. This is an **attended decision aid**,
additive and OFF by default; it introduces no lifecycle gate and never blocks the spec.

```bash
# snippet-lint: skip — illustrative; lead authors the options JSON, then renders.
# data shape: {"title":"…","options":[{"name":"…","pros":[…],"cons":[…],"notes":"…"}]}
.claude/scripts/plan-w-team-render-artifact.sh --kind comparison \
  --data ".claude/state/approaches-${SLUG}.json" \
  --out  ".claude/state/approaches-${SLUG}.html"
```

The renderer is self-contained (zero external requests) and fail-open. See
`docs/operations/plan-w-team-visual-artifacts.md`.
