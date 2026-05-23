#!/usr/bin/env bats
# tests/skill/scenarios/owasp-coverage-map-lookup.bats
#
# Scenario: Security Review Extension — shared/owasp-top10-mapping.md exists
# and is a deterministic lookup: given a file pattern, the doc returns
# the OWASP category + the required tier set. Verifies all 10 categories
# (A01-A10) are listed with file-pattern globs, default agent, and tier set.
#
# Spec: docs/specs/security-review-extension.md (AC6)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

MAP_FILE="$COMMANDS_DIR/shared/owasp-top10-mapping.md"

# ─── AC6: file exists ──────────────────────────────────────────────────────

@test "owasp-coverage-map-lookup AC6: shared/owasp-top10-mapping.md exists at the canonical path" {
  [ -f "$MAP_FILE" ]
}

# ─── AC6: All 10 OWASP Top 10 (2021) categories present ────────────────────

@test "owasp-coverage-map-lookup AC6: A01 Broken Access Control listed" {
  run grep -E 'A01.*Broken Access Control' "$MAP_FILE"
  assert_success
}

@test "owasp-coverage-map-lookup AC6: A02 Cryptographic Failures listed" {
  run grep -E 'A02.*Cryptographic Failures' "$MAP_FILE"
  assert_success
}

@test "owasp-coverage-map-lookup AC6: A03 Injection listed" {
  run grep -E 'A03.*Injection' "$MAP_FILE"
  assert_success
}

@test "owasp-coverage-map-lookup AC6: A04 Insecure Design listed" {
  run grep -E 'A04.*Insecure Design' "$MAP_FILE"
  assert_success
}

@test "owasp-coverage-map-lookup AC6: A05 Security Misconfiguration listed" {
  run grep -E 'A05.*Security Misconfiguration' "$MAP_FILE"
  assert_success
}

@test "owasp-coverage-map-lookup AC6: A06 Vulnerable and Outdated Components listed" {
  run grep -E 'A06.*Vulnerable and Outdated Components' "$MAP_FILE"
  assert_success
}

@test "owasp-coverage-map-lookup AC6: A07 Identification and Authentication Failures listed" {
  run grep -E 'A07.*Identification and Authentication Failures' "$MAP_FILE"
  assert_success
}

@test "owasp-coverage-map-lookup AC6: A08 Software and Data Integrity Failures listed" {
  run grep -E 'A08.*Software and Data Integrity Failures' "$MAP_FILE"
  assert_success
}

@test "owasp-coverage-map-lookup AC6: A09 Security Logging and Monitoring Failures listed" {
  run grep -E 'A09.*Security Logging and Monitoring Failures' "$MAP_FILE"
  assert_success
}

@test "owasp-coverage-map-lookup AC6: A10 Server-Side Request Forgery listed" {
  run grep -E 'A10.*Server-Side Request Forgery' "$MAP_FILE"
  assert_success
}

# ─── AC6: Default agent is security-expert across all categories ───────────

@test "owasp-coverage-map-lookup AC6: security-expert is the default agent" {
  # security-expert should appear ≥ 9 times (one per category with a glob;
  # A04 is review-only but still attributes to security-expert)
  run grep -c 'security-expert' "$MAP_FILE"
  assert_success
  [ "$output" -ge 9 ]
}

# ─── AC6: File-pattern globs are present for grep-able patterns ────────────

@test "owasp-coverage-map-lookup AC6: A07 globs include **/auth/** and **/login*" {
  local block
  block=$(awk '/A07/,/A08/' "$MAP_FILE")
  echo "$block" | grep -E '\*\*/auth/|\*\*/login'
}

@test "owasp-coverage-map-lookup AC6: A03 globs include **/sql* and **/sanitize*" {
  local block
  block=$(awk '/A03/,/A04/' "$MAP_FILE")
  echo "$block" | grep -E '\*\*/sql|\*\*/sanitize'
}

@test "owasp-coverage-map-lookup AC6: A10 SSRF globs include **/fetch* and **/proxy*" {
  local block
  block=$(awk '/A10/,/$/' "$MAP_FILE")
  echo "$block" | grep -E '\*\*/fetch|\*\*/proxy'
}

@test "owasp-coverage-map-lookup AC6: A06 manifest globs include package.json and Cargo.toml" {
  local block
  block=$(awk '/A06/,/A07/' "$MAP_FILE")
  echo "$block" | grep -E 'package\.json'
  echo "$block" | grep -E 'Cargo\.toml'
}

@test "owasp-coverage-map-lookup AC6: A02 crypto globs include **/crypto* and **/hash*" {
  local block
  block=$(awk '/A02/,/A03/' "$MAP_FILE")
  echo "$block" | grep -E '\*\*/crypto'
  echo "$block" | grep -E '\*\*/hash'
}

# ─── AC6: Tier sets per category are specified ─────────────────────────────

@test "owasp-coverage-map-lookup AC6: A06 tier set is T3 (dependency audit)" {
  local block
  block=$(awk '/A06/,/A07/' "$MAP_FILE")
  echo "$block" | grep -E 'T3'
}

@test "owasp-coverage-map-lookup AC6: A07 tier set is T1 + T2 + T4" {
  local block
  block=$(awk '/A07/,/A08/' "$MAP_FILE")
  echo "$block" | grep -E 'T1 \+ T2 \+ T4|T1\+T2\+T4|T1.*T2.*T4'
}

# ─── AC6: Union rule for multi-category files documented ───────────────────

@test "owasp-coverage-map-lookup AC6: union rule for multi-category files documented" {
  run grep -E 'union|Union' "$MAP_FILE"
  assert_success
}

# ─── AC6: Forward and retroactive use documented ───────────────────────────

@test "owasp-coverage-map-lookup AC6: Step 2 forward usage documented" {
  run grep -E 'Step 2|forward scoping' "$MAP_FILE"
  assert_success
}

@test "owasp-coverage-map-lookup AC6: Step 5 retroactive usage documented" {
  run grep -E 'Step 5|retroactive' "$MAP_FILE"
  assert_success
}

# ─── AC6: Helper for "given a pattern, return category" lookup intent ──────

@test "owasp-coverage-map-lookup AC6: doc describes lookup intent for given file pattern" {
  run grep -E 'lookup|matched|matches' "$MAP_FILE"
  assert_success
}
