# Step 1: Generate Specification

**Opus 4.7 tip**: Front-load the full task shape in the first draft — intent, constraints, acceptance criteria, Error & Rescue Map, and Shadow Paths. Progressive reveal wastes tokens on rework. See `shared/opus-4-7-practices.md` §1.

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

## Overview

Brief description. Include dream state mapping:

- CURRENT: [what exists]
- THIS PLAN: [what we're building]
- 12-MONTH IDEAL: [where this leads]

## Requirements

- [ ] Requirement 1
- [ ] Requirement 2

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

## §1b-pre. Multi-Angle Spec Fan-Out (OPT-IN — default OFF)

When `PLAN_W_TEAM_SPEC_FANOUT=1`, run a parallel multi-angle critique of the
just-authored draft spec **before the AC freeze below**. This catches missing
requirements, weak/untestable acceptance criteria, untraced shadow paths, and
security boundaries while the spec is still mutable. **Default OFF**: when the
var is unset (or `!= 1`), Step 1 is single-pass exactly as before — author the
spec, then freeze. This is a pilot; it stays default-OFF until the §8j-octies
retro signal shows it earns its keep.

Hard ordering rule: the fan-out MUST complete and its findings MUST be folded
into the spec **strictly before** the freeze below, so the SHA256 snapshot
digests the post-fan-out spec and the frozen contract is preserved.

Roster — three same-session **Agent**-tool reviewers (Brain-tier, spec-authoring
capable; NOT the diff-based gap analyzers, which read a diff that does not exist
at Step 1):

| Reviewer (subagent_type) | Angle                                                            |
| ------------------------ | ---------------------------------------------------------------- |
| `system-architect`       | Architecture fit, missing requirements, boundary/shadow paths    |
| `security-expert`        | Security/abuse boundaries, one-way-door surfaces                 |
| `code-review-expert`     | Testability — are the acceptance criteria observable/verifiable? |

```bash
# Opt-in gate — default OFF preserves today's single-pass Step 1 exactly.
if [ "${PLAN_W_TEAM_SPEC_FANOUT:-0}" != "1" ]; then
  echo "[§1b-pre] spec fan-out disabled (set PLAN_W_TEAM_SPEC_FANOUT=1 to enable)"
else
  SLUG="<feature-slug>"
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

## §1c. Access-Control Threat-Model Trigger (security-relevant features)

The `### Threat Model & Access-Control Surface` block in the Technical Design (above) is **MANDATORY** — not skippable — when ANY of these hold. The trigger keys on the same content signals the diff-time gate uses (`shared/owasp-top10-mapping.md` §Content-Signal Triggers), so the surface is _declared_ at spec time and _checked_ at review time:

- The feature reads, writes, mints, or validates an auth/session token, API key, **bypass/QA/service token**, or other credential.
- The feature writes any **privilege-bearing field** (`role`, `platformRole`, `tenantId`/`orgId`, `isQaUser`, `ownerId`, `isAdmin`, `permissions`, `passwordHash`, `balance`, `*Cents`).
- The feature spreads a request body / untrusted input into an ORM `update`/`insert`/`save` (mass-assignment surface).
- The feature performs a `where … by id` / single-record lookup or mutation that may need a tenant/owner predicate.
- The feature adds or gates a handler behind a bypass / QA / debug / service token.

Skip the block ONLY for features touching none of the above (pure docs, pure UI-copy, isolated compute with no auth/tenant/credential surface) — write "N/A — no security surface" so the omission is deliberate, not forgotten. When the block is required and the author leaves it empty, Step 5 review treats the missing block as an ASK item (mirroring the AC-snapshot tamper-detection pattern).

Any security/access-control acceptance criteria belong **inside** the AC block below, so they are captured by the SHA256 freeze. Designing the invariants in here is the point: a confirmed high-severity broken-access-control finding against this declared surface is **GATING at Step 6 ship** (`05-ship.md` §6c-ter) — it blocks the push and is NOT retroactive (`04-fix-first-review.md` §5d-ter).

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

The derivation is MECHANICAL: every `AC<N>:` entry in the spec's Acceptance Criteria section becomes one criterion with pattern `AC<N>.*PASS`. The pattern matches the verification lines that Step 5 review and Step 6 ship already emit per AC.

```bash
SLUG="<feature-slug>"
SPEC="docs/specs/${SLUG}.md"
GOAL_FILE=".claude/state/plan-w-team-goal-${SLUG}.json"

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
        CRITERIA_JSON=$(echo "$CRITERIA_JSON" | jq --arg p "AC${n}.*PASS" --arg d "$desc" \
            '. + [{pattern: $p, description: $d, met: false, met_at: null}]')
    done < <(awk '/^## Acceptance Criteria/,/^## [^A]/' "$SPEC" | grep -E '^\s*-?\s*\[?\s*\]?\s*AC[0-9]+:')

    CRITERIA_COUNT=$(echo "$CRITERIA_JSON" | jq 'length')
    if [ "$CRITERIA_COUNT" -gt 0 ]; then
        jq --argjson c "$CRITERIA_JSON" '.feature_specific_done_criteria = $c' \
            "$GOAL_FILE" > "$GOAL_FILE.tmp" && mv "$GOAL_FILE.tmp" "$GOAL_FILE"
        echo "[§1.5] injected $CRITERIA_COUNT feature-specific done criteria into goal state"
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
