# Step 1: Generate Specification

Create a **spec** (requirements document, persists in repo) at `docs/specs/<feature-name>.md`:

```markdown
# Feature: <name>

## Overview

Brief description. Include dream state mapping:

- CURRENT: [what exists]
- THIS PLAN: [what we're building]
- 12-MONTH IDEAL: [where this leads]

## Requirements

- [ ] Requirement 1
- [ ] Requirement 2

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
