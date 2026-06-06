#!/usr/bin/env bats
# tests/skill/scenarios/owasp-api-top10-content-signals.bats
#
# Scenario: shared/owasp-top10-mapping.md carries the API Security Top 10 (2023)
# categories + a content-signal trigger table; shared/access-control-invariants.md
# and shared/secure-by-default.md exist and are wired into Steps 1/3/5/6.
#
# Spec: docs/specs/access-control-content-signal-gate.md (AC4)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

MAP_FILE="$COMMANDS_DIR/shared/owasp-top10-mapping.md"
INV_FILE="$COMMANDS_DIR/shared/access-control-invariants.md"
SBD_FILE="$COMMANDS_DIR/shared/secure-by-default.md"
SPEC_STAGE="$COMMANDS_DIR/01-specification.md"
EXEC_STAGE="$COMMANDS_DIR/03-execute.md"
REVIEW_STAGE="$COMMANDS_DIR/04-fix-first-review.md"
SHIP_STAGE="$COMMANDS_DIR/05-ship.md"
BUILDER_AGENT="$REPO_ROOT/.claude/agents/team/builder.md"

# ─── owasp map: API Security Top 10 ─────────────────────────────────────────

@test "owasp-api-top10-content-signals AC4: map lists the API Security Top 10 (2023)" {
  run grep -E 'API Security Top 10' "$MAP_FILE"
  assert_success
}

@test "owasp-api-top10-content-signals AC4: API1 BOLA listed" {
  run grep -E 'API1.*(BOLA|Broken Object Level)' "$MAP_FILE"
  assert_success
}

@test "owasp-api-top10-content-signals AC4: API3 BOPLA / mass-assignment listed" {
  run grep -E 'API3.*(BOPLA|Property Level|mass-assignment)' "$MAP_FILE"
  assert_success
}

@test "owasp-api-top10-content-signals AC4: API5 BFLA listed" {
  run grep -E 'API5.*(BFLA|Function Level)' "$MAP_FILE"
  assert_success
}

# ─── owasp map: Content-Signal Triggers table ───────────────────────────────

@test "owasp-api-top10-content-signals AC4: map has a Content-Signal Triggers section" {
  run grep -E 'Content-Signal Triggers' "$MAP_FILE"
  assert_success
}

@test "owasp-api-top10-content-signals AC4: all four content signals CS-1..CS-4 are tabulated" {
  run grep -cE 'CS-[1-4]' "$MAP_FILE"
  assert_success
  [ "$output" -ge 4 ]
}

@test "owasp-api-top10-content-signals AC4: content-signal table names the privilege-field tokens" {
  run grep -E 'platformRole' "$MAP_FILE"
  assert_success
}

@test "owasp-api-top10-content-signals AC4: content-signal table names the bypass token" {
  run grep -E 'QA_SIM_TOKEN|_BYPASS_' "$MAP_FILE"
  assert_success
}

@test "owasp-api-top10-content-signals AC4: the A01 row still roots the access-control categories" {
  run grep -E 'A01.*Broken Access Control' "$MAP_FILE"
  assert_success
}

# ─── new shared docs exist ──────────────────────────────────────────────────

@test "owasp-api-top10-content-signals AC4: shared/access-control-invariants.md exists" {
  [ -f "$INV_FILE" ]
}

@test "owasp-api-top10-content-signals AC4: shared/secure-by-default.md exists" {
  [ -f "$SBD_FILE" ]
}

@test "owasp-api-top10-content-signals AC4: secure-by-default.md codifies assertQaScoped + .strict()/.pick()" {
  run grep -E 'assertQaScoped' "$SBD_FILE"; assert_success
  run grep -E '\.strict\(\)' "$SBD_FILE"; assert_success
  run grep -E '\.pick\(\)' "$SBD_FILE"; assert_success
}

# ─── wired into Step 1 (spec) ───────────────────────────────────────────────

@test "owasp-api-top10-content-signals AC4: Step 1 has a Threat Model & Access-Control Surface block" {
  run grep -E 'Threat Model & Access-Control Surface' "$SPEC_STAGE"
  assert_success
}

@test "owasp-api-top10-content-signals AC4: Step 1 §1c trigger keys on content signals" {
  run grep -E '§1c\. Access-Control Threat-Model Trigger' "$SPEC_STAGE"
  assert_success
}

# ─── wired into Step 3 (execute + builder) ──────────────────────────────────

@test "owasp-api-top10-content-signals AC4: Step 3 builder prompt references secure-by-default.md" {
  run grep -E 'secure-by-default\.md' "$EXEC_STAGE"
  assert_success
}

@test "owasp-api-top10-content-signals AC4: builder agent references secure-by-default.md" {
  run grep -E 'secure-by-default\.md' "$BUILDER_AGENT"
  assert_success
}

# ─── wired into Step 5 (review) ─────────────────────────────────────────────

@test "owasp-api-top10-content-signals AC4: Step 5 references access-control-invariants.md" {
  run grep -E 'access-control-invariants\.md' "$REVIEW_STAGE"
  assert_success
}

# ─── wired into Step 6 (ship) ───────────────────────────────────────────────

@test "owasp-api-top10-content-signals AC4: Step 6 has the §6c-ter access-control gate" {
  run grep -E '6c-ter\. Access-Control Finding Gate' "$SHIP_STAGE"
  assert_success
}

# ─── map's consumed-by stays truthful ───────────────────────────────────────

@test "owasp-api-top10-content-signals AC4: map consumed-by cites §6c-ter and §5b" {
  run grep -E '§6c-ter' "$MAP_FILE"; assert_success
  run grep -E '§5b' "$MAP_FILE"; assert_success
}
