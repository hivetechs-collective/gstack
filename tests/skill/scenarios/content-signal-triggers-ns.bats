#!/usr/bin/env bats
# tests/skill/scenarios/content-signal-triggers-ns.bats
#
# Scenario: Access-Control Content-Signal Gate — a diff that mutates a
# privilege-bearing field (e.g. platformRole) in a normally-named file (no
# security-glob match) must trigger a paired N.s security-review task and map to
# A01 / API-security, via the CONTENT-SIGNAL layer (not filename glob).
#
# Spec: docs/specs/access-control-content-signal-gate.md (AC1)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

STAGE_FILE="$COMMANDS_DIR/02-task-breakdown.md"

# Extract the security-review paired-task section (same range the existing
# backend-paired-security-task.bats uses — the next section is "Hot-Path
# Overlay", which does not start with P).
sec_block() {
  awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE"
}

@test "content-signal-triggers-ns AC1: security-review section exists" {
  run grep -nE 'Paired Task Protocol \(security review\)' "$STAGE_FILE"
  assert_success
}

@test "content-signal-triggers-ns AC1: a second content-signal trigger layer exists" {
  sec_block | grep -E 'Content-signal layer|content-signal layer|CONTENT-SIGNAL'
}

@test "content-signal-triggers-ns AC1: content signal fires regardless of filename" {
  sec_block | grep -E 'regardless of filename'
}

@test "content-signal-triggers-ns AC1: privilege-field signal names platformRole (CS-1)" {
  sec_block | grep -E 'platformRole'
}

@test "content-signal-triggers-ns AC1: the four content signals CS-1..CS-4 are enumerated" {
  local block
  block=$(sec_block)
  echo "$block" | grep -E 'CS-1'
  echo "$block" | grep -E 'CS-2'
  echo "$block" | grep -E 'CS-3'
  echo "$block" | grep -E 'CS-4'
}

@test "content-signal-triggers-ns AC1: request-body spread into ORM update is a signal (CS-2)" {
  sec_block | grep -E 'req\.body|\{\.\.\.body\}|Object\.assign'
}

@test "content-signal-triggers-ns AC1: bypass/QA token gating is a signal (CS-3)" {
  sec_block | grep -E 'QA_SIM_TOKEN|_BYPASS_|bypass'
}

@test "content-signal-triggers-ns AC1: where-by-id without tenant predicate is a signal (CS-4)" {
  sec_block | grep -E 'tenant.*predicate|where/query-by-id|by-id'
}

@test "content-signal-triggers-ns AC1: content signal maps to A01 / API-security" {
  local block
  block=$(sec_block)
  echo "$block" | grep -E 'A01'
  echo "$block" | grep -E 'API1|API3|API5|API Security'
}

@test "content-signal-triggers-ns AC1: content signal still emits a paired N.s task" {
  sec_block | grep -E '\bN\.s\b'
}

@test "content-signal-triggers-ns AC1: a refactor with a content signal is NOT exempt from N.s" {
  # The single-task exceptions must carve out content-signal matches from the
  # refactor exemption (the exact bypass class the enhancement closes).
  local block
  block=$(sec_block)
  echo "$block" | grep -E 'refactor'
  echo "$block" | grep -E 'UNLESS the diff matches a content signal|overrides every mode-based exemption'
}

@test "content-signal-triggers-ns AC1: confirmed access-control finding is gating, not deferrable" {
  sec_block | grep -E 'gating, not deferrable|gating per|§5d-ter|§6c-ter'
}

@test "content-signal-triggers-ns AC1: review uses the access-control-invariants rubric" {
  sec_block | grep -E 'access-control-invariants\.md'
}
