#!/usr/bin/env bats
# tests/skill/scenarios/access-control-invariants-checklist.bats
#
# Scenario: shared/access-control-invariants.md exists and flags a where-by-id
# lacking a tenant/owner predicate (INV-1 / BOLA / CS-4), and the checklist is
# wired into the security reviewer + analyzer + N.s task.
#
# Spec: docs/specs/access-control-content-signal-gate.md (AC3)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

INV_FILE="$COMMANDS_DIR/shared/access-control-invariants.md"
REVIEW_STAGE="$COMMANDS_DIR/04-fix-first-review.md"
TASK_STAGE="$COMMANDS_DIR/02-task-breakdown.md"
EXPERT_AGENT="$REPO_ROOT/.claude/agents/research-planning/security-expert.md"
ANALYZER_AGENT="$REPO_ROOT/.claude/agents/research-planning/security-gap-analyzer.md"

# ─── file exists ─────────────────────────────────────────────────────────────

@test "access-control-invariants-checklist AC3: shared/access-control-invariants.md exists" {
  [ -f "$INV_FILE" ]
}

# ─── the five invariants are present ─────────────────────────────────────────

@test "access-control-invariants-checklist AC3: all five invariants INV-1..INV-5 are defined" {
  run grep -cE 'INV-[1-5]' "$INV_FILE"
  assert_success
  [ "$output" -ge 5 ]
}

@test "access-control-invariants-checklist AC3: INV-1 is object ownership / BOLA" {
  run grep -E 'INV-1.*(Object ownership|BOLA|IDOR)' "$INV_FILE"
  assert_success
}

@test "access-control-invariants-checklist AC3: INV-1 requires a tenant/owner predicate on where-by-id" {
  # The core AC3 assertion: a by-id query without a tenant/owner predicate is a violation.
  run grep -E 'tenant/owner predicate|tenant predicate' "$INV_FILE"
  assert_success
}

@test "access-control-invariants-checklist AC3: the IDOR failing pattern (where eq id, no tenant) is shown" {
  run grep -E 'where\(eq\(.*\.id' "$INV_FILE"
  assert_success
}

@test "access-control-invariants-checklist AC3: INV-3 mass-assignment / privilege-field guard is defined" {
  run grep -E 'INV-3.*(Mass-assignment|privilege-field|BOPLA)' "$INV_FILE"
  assert_success
}

@test "access-control-invariants-checklist AC3: INV-4 bypass/test-token scoping is defined" {
  run grep -E 'INV-4.*(bypass|test-token|Bypass)' "$INV_FILE"
  assert_success
}

@test "access-control-invariants-checklist AC3: the API Security Top 10 classes are mapped (API1/API3/API5)" {
  run grep -E 'API1' "$INV_FILE"; assert_success
  run grep -E 'API3' "$INV_FILE"; assert_success
  run grep -E 'API5' "$INV_FILE"; assert_success
}

@test "access-control-invariants-checklist AC3: the two real 2026-06-01 escapes are mapped to invariants" {
  run grep -E 'seed-platform-admin' "$INV_FILE"; assert_success
  run grep -E 'assignedTo' "$INV_FILE"; assert_success
}

# ─── wired into the reviewer / analyzer / N.s task ──────────────────────────

@test "access-control-invariants-checklist AC3: security-expert consumes the invariants checklist" {
  run grep -E 'access-control-invariants\.md' "$EXPERT_AGENT"
  assert_success
}

@test "access-control-invariants-checklist AC3: security-expert has a mandatory per-endpoint invariant checklist" {
  run grep -E 'MANDATORY for every data-mutating endpoint' "$EXPERT_AGENT"
  assert_success
}

@test "access-control-invariants-checklist AC3: security-gap-analyzer consumes the invariants checklist" {
  run grep -E 'access-control-invariants\.md' "$ANALYZER_AGENT"
  assert_success
}

@test "access-control-invariants-checklist AC3: analyzer can emit a missing_tenant_predicate gap_type (BOLA)" {
  run grep -E 'missing_tenant_predicate' "$ANALYZER_AGENT"
  assert_success
}

@test "access-control-invariants-checklist AC3: the §5b scan applies the invariants rubric" {
  run grep -E 'access-control-invariants\.md' "$REVIEW_STAGE"
  assert_success
}

@test "access-control-invariants-checklist AC3: the N.s review uses the invariants rubric" {
  run grep -E 'access-control-invariants\.md' "$TASK_STAGE"
  assert_success
}
