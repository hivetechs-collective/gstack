#!/usr/bin/env bats
# tests/skill/scenarios/security-gap-analyzer-flags-missing-injection-tests.bats
#
# Scenario: Security Review Extension — security-gap-analyzer agent definition
# exists and is structurally complete. Verifies the agent doc declares the
# gap_type taxonomy including the SQL/injection-fuzz signal, attributes
# findings to OWASP categories, and is referenced by Step 5 §5d-bis.
#
# Spec: docs/specs/security-review-extension.md (AC2, AC3)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

AGENT_FILE="$REPO_ROOT/.claude/agents/research-planning/security-gap-analyzer.md"
REVIEW_STAGE="$COMMANDS_DIR/04-fix-first-review.md"

# ─── AC2: Agent file exists with required frontmatter ───────────────────────

@test "security-gap-analyzer AC2: agent file exists at the canonical path" {
  [ -f "$AGENT_FILE" ]
}

@test "security-gap-analyzer AC2: agent pinned to model: claude-opus-4-8 (Brain-tier)" {
  run grep -E '^model: claude-opus-4-8' "$AGENT_FILE"
  assert_success
}

@test "security-gap-analyzer AC2: agent category is research-planning" {
  run grep -E '^category: research-planning' "$AGENT_FILE"
  assert_success
}

@test "security-gap-analyzer AC2: agent is read-only (no Write/Edit allowed)" {
  run grep -E 'Do NOT use Write/Edit' "$AGENT_FILE"
  assert_success
}

# ─── AC2: gap_type taxonomy covers the directive's named categories ─────────

@test "security-gap-analyzer AC2: gap_type taxonomy includes missing_input_validation_test" {
  run grep -E 'missing_input_validation_test' "$AGENT_FILE"
  assert_success
}

@test "security-gap-analyzer AC2: gap_type taxonomy includes missing_auth_boundary_test" {
  run grep -E 'missing_auth_boundary_test' "$AGENT_FILE"
  assert_success
}

@test "security-gap-analyzer AC2: gap_type taxonomy includes missing_injection_fuzz" {
  run grep -E 'missing_injection_fuzz' "$AGENT_FILE"
  assert_success
}

@test "security-gap-analyzer AC2: gap_type taxonomy includes missing_ssrf_coverage" {
  run grep -E 'missing_ssrf_coverage' "$AGENT_FILE"
  assert_success
}

@test "security-gap-analyzer AC2: gap_type taxonomy includes missing_xss_coverage" {
  run grep -E 'missing_xss_coverage' "$AGENT_FILE"
  assert_success
}

@test "security-gap-analyzer AC2: gap_type taxonomy includes missing_deserialization_test" {
  run grep -E 'missing_deserialization_test' "$AGENT_FILE"
  assert_success
}

# ─── AC2: OWASP category attribution in report shape ────────────────────────

@test "security-gap-analyzer AC2: agent emits owasp_category field in findings" {
  run grep -E 'owasp_category' "$AGENT_FILE"
  assert_success
}

@test "security-gap-analyzer AC2: agent references shared/owasp-top10-mapping.md" {
  run grep -E 'owasp-top10-mapping\.md' "$AGENT_FILE"
  assert_success
}

# ─── AC2: severity calibration documented ───────────────────────────────────

@test "security-gap-analyzer AC2: severity values are high|medium|low" {
  # Severity calibration section names all three levels (may be on separate lines).
  run grep -c -E '^\- \*\*(high|medium|low)\*\*:' "$AGENT_FILE"
  assert_success
  [ "$output" -ge 3 ]
}

# ─── AC3: Step 5 §5d-bis invokes the analyzer ───────────────────────────────

@test "security-gap-analyzer AC3: 04-fix-first-review.md has §5d-bis Retroactive Security-Gap Analysis" {
  run grep -nE '5d-bis.*Retroactive Security-Gap Analysis' "$REVIEW_STAGE"
  assert_success
}

@test "security-gap-analyzer AC3: §5d-bis invokes security-gap-analyzer agent" {
  local block
  block=$(awk '/^## 5d-bis/,/^## 5d\. /' "$REVIEW_STAGE")
  echo "$block" | grep -E 'security-gap-analyzer'
}

@test "security-gap-analyzer AC3: §5d-bis queues N.t retroactive-security-coverage tasks assigned to security-expert" {
  local block
  block=$(awk '/^## 5d-bis/,/^## 5d\. /' "$REVIEW_STAGE")
  echo "$block" | grep -E 'security-expert'
  echo "$block" | grep -E 'retroactive-security-coverage|retroactive: true|origin.*security-gap-analyzer'
}

@test "security-gap-analyzer AC3: §5d-bis documents kill switch PLAN_W_TEAM_DISABLE_SECURITY_GAP_ANALYZER" {
  local block
  block=$(awk '/^## 5d-bis/,/^## 5d\. /' "$REVIEW_STAGE")
  echo "$block" | grep -E 'PLAN_W_TEAM_DISABLE_SECURITY_GAP_ANALYZER'
}

@test "security-gap-analyzer AC3: §5d-bis runs AFTER §5c-bis (test-gap analysis order preserved)" {
  # The Retroactive Security-Gap Analysis block must appear AFTER the
  # Retroactive Test-Gap Analysis block in the stage file (security runs after tests).
  local test_line sec_line
  test_line=$(grep -n '5c-bis.*Retroactive Test-Gap Analysis' "$REVIEW_STAGE" | head -1 | cut -d: -f1)
  sec_line=$(grep -n '5d-bis.*Retroactive Security-Gap Analysis' "$REVIEW_STAGE" | head -1 | cut -d: -f1)
  [ -n "$test_line" ]
  [ -n "$sec_line" ]
  [ "$sec_line" -gt "$test_line" ]
}
