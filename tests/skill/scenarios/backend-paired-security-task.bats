#!/usr/bin/env bats
# tests/skill/scenarios/backend-paired-security-task.bats
#
# Scenario: Security Review Extension — code-adding tasks on security-relevant
# surfaces trigger paired N.s security-review task emission. Verifies that
# 02-task-breakdown.md documents the paired security pattern for
# [BACKEND, INFRASTRUCTURE, SCRIPTS, LIBRARY, API] tasks that ADD new code on
# auth/secret/injection/SSRF/XSS surfaces, mirroring the STE N.a/N.b paired-task
# block.
#
# Spec: docs/specs/security-review-extension.md (AC1)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

STAGE_FILE="$COMMANDS_DIR/02-task-breakdown.md"

# ─── AC1: Paired Task Protocol (security review) block exists ───────────────

@test "backend-paired-security-task AC1: 02-task-breakdown.md has a Paired Task Protocol (security review) section" {
  run grep -nE 'Paired Task Protocol \(security review\)' "$STAGE_FILE"
  assert_success
}

@test "backend-paired-security-task AC1: security block lists BACKEND, INFRASTRUCTURE, SCRIPTS, LIBRARY, API" {
  # The trigger expression names the same scope set the STE block uses
  local block
  block=$(awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E 'BACKEND, INFRASTRUCTURE, SCRIPTS, LIBRARY, API'
}

@test "backend-paired-security-task AC1: trigger expression conditions on mode == add" {
  local block
  block=$(awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E 'mode == "add"'
}

@test "backend-paired-security-task AC1: refactor-only and docs-only stay single-task (no N.s)" {
  local block
  block=$(awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E 'refactor|Refactor'
  echo "$block" | grep -E 'docs-only|docs|Documentation'
}

@test "backend-paired-security-task AC1: N.s task assigned to security-expert" {
  local block
  block=$(awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E 'security-expert'
  echo "$block" | grep -E '\bN\.s\b'
}

@test "backend-paired-security-task AC1: N.s blocked by N.b (review runs against implementation)" {
  local block
  block=$(awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E 'blockedBy.*N\.b|N\.s.*blocked.*N\.b|N\.b.*blocks?.*N\.s'
}

# ─── AC1: Security-relevant surface globs are documented ─────────────────────

@test "backend-paired-security-task AC1: auth/login/session surfaces (A07) referenced in trigger globs" {
  local block
  block=$(awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E '\*\*/auth/|\*\*/login|\*\*/session'
}

@test "backend-paired-security-task AC1: injection / SQL / sanitize / validate surfaces (A03) referenced" {
  local block
  block=$(awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E '\*\*/sql|\*\*/validate|\*\*/sanitize'
}

@test "backend-paired-security-task AC1: crypto / hash / cipher surfaces (A02) referenced" {
  local block
  block=$(awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E '\*\*/crypto|\*\*/hash|\*\*/cipher'
}

@test "backend-paired-security-task AC1: SSRF surfaces (A10) referenced" {
  local block
  block=$(awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E '\*\*/fetch|\*\*/proxy|\*\*/url|SSRF'
}

@test "backend-paired-security-task AC1: deserialization surfaces (A08) referenced" {
  local block
  block=$(awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E '\*\*/deserialize|\*\*/parse|\*\*/marshal'
}

@test "backend-paired-security-task AC1: trigger references governance-tags.md / owasp-top10-mapping.md" {
  local block
  block=$(awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E 'governance-tags\.md|owasp-top10-mapping\.md'
}

# ─── AC1: Config touching secrets is special-cased (A05) ─────────────────────

@test "backend-paired-security-task AC1: config touching .env / secret wiring still gets N.s" {
  local block
  block=$(awk '/^## Paired Task Protocol \(security review\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E '\.env|secret wiring|credentials|A05'
}
