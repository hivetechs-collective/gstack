#!/usr/bin/env bats
# tests/skill/scenarios/test-gap-analyzer-flags-untested-branch.bats
#
# Scenario: STE Extension — test-gap-analyzer agent exists, is Brain-tier
# (Opus 4.7), and Step 5 invokes it to surface untested branches/error
# paths/edge cases. Findings become queued retroactive-coverage tasks.
#
# Spec: docs/specs/ste-extension.md (AC2, AC3)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

AGENT_FILE="$REPO_ROOT/.claude/agents/research-planning/test-gap-analyzer.md"
REVIEW_STAGE_FILE="$COMMANDS_DIR/04-fix-first-review.md"

# ─── AC2: agent file exists with Brain-tier Opus 4.7 frontmatter ────────────

@test "test-gap-analyzer AC2: agent file exists at .claude/agents/research-planning/test-gap-analyzer.md" {
  [ -f "$AGENT_FILE" ]
}

@test "test-gap-analyzer AC2: agent frontmatter declares model: claude-opus-4-8" {
  run grep -E '^model: claude-opus-4-8' "$AGENT_FILE"
  assert_success
}

@test "test-gap-analyzer AC2: agent name is test-gap-analyzer" {
  run grep -E '^name: test-gap-analyzer' "$AGENT_FILE"
  assert_success
}

@test "test-gap-analyzer AC2: agent description mentions untested branches/error paths/edge cases" {
  run grep -E 'untested branches|error paths|edge cases' "$AGENT_FILE"
  assert_success
}

@test "test-gap-analyzer AC2: agent emits a structured report (severity field documented)" {
  run grep -E 'severity.*high|severity.*medium|severity.*low|severity:' "$AGENT_FILE"
  assert_success
}

@test "test-gap-analyzer AC2: agent is read-only — no Write tool, no Edit tool" {
  run grep -E 'Do NOT use Write/Edit|analysis only' "$AGENT_FILE"
  assert_success
}

# ─── AC3: Step 5 invokes test-gap-analyzer + queues retroactive tasks ───────

@test "test-gap-analyzer AC3: 04-fix-first-review.md has a Retroactive Test-Gap Analysis section" {
  run grep -nE 'Retroactive Test-Gap Analysis' "$REVIEW_STAGE_FILE"
  assert_success
}

@test "test-gap-analyzer AC3: Step 5 invokes test-gap-analyzer agent" {
  run grep -E 'test-gap-analyzer' "$REVIEW_STAGE_FILE"
  assert_success
}

@test "test-gap-analyzer AC3: findings become queued retroactive-coverage tasks" {
  run grep -E 'retroactive.coverage|retroactive: true' "$REVIEW_STAGE_FILE"
  assert_success
}

@test "test-gap-analyzer AC3: retroactive tasks assigned to unit-testing-specialist" {
  run grep -E 'unit-testing-specialist' "$REVIEW_STAGE_FILE"
  assert_success
}

@test "test-gap-analyzer AC3: tasks run BEFORE Step 8 retro (not blocking current ship)" {
  run grep -E 'before Step 8 retro|before retro|after Step 6 ship and before' "$REVIEW_STAGE_FILE"
  assert_success
}

# ─── Fixture-based sanity: the report shape the analyzer is documented to emit
#     is what the lead can mechanically parse. (No live LLM in this test.)

@test "test-gap-analyzer AC3: agent doc names the G<N> finding heading shape" {
  # The agent's documented output uses "### G<N> — ..." headings so the lead
  # can parse them mechanically.
  run grep -E '### G<N>|### G[0-9]+' "$AGENT_FILE"
  assert_success
}

@test "test-gap-analyzer AC3: agent doc names gap_type field (untested_error_path / untested_branch / untested_edge_case)" {
  run grep -E 'untested_error_path|untested_branch|untested_edge_case' "$AGENT_FILE"
  assert_success
}

@test "test-gap-analyzer AC3: kill switch PLAN_W_TEAM_DISABLE_TEST_GAP_ANALYZER documented" {
  run grep -E 'PLAN_W_TEAM_DISABLE_TEST_GAP_ANALYZER' "$REVIEW_STAGE_FILE"
  assert_success
}
