#!/usr/bin/env bats
# tests/skill/scenarios/next-batch-spec-chains.bats
#
# Scenario: a worker's goal-state JSON may carry an optional
# `next_batch_spec` field. When the supervisor observes terminal SUCCESS
# and that field is present, it spawns the next worker via
# pwt-goal.sh --worker-only with the spec's request text. Chains terminate
# when the field is null or absent.
#
# Validates: schema documented in shared/goal-conditions.md, supervisor
# protocol references the chain action, and a synthetic goal-state JSON
# with next_batch_spec is parseable by jq.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

GOAL_CONDITIONS="$REPO_ROOT/.claude/commands/plan-w-team/shared/goal-conditions.md"
PROTOCOL="$REPO_ROOT/.claude/commands/plan-w-team/shared/supervisor-protocol.md"

setup() {
  sandbox
  GOAL_FILE="$SANDBOX_DIR/plan-w-team-goal-test.json"
  cat > "$GOAL_FILE" <<JSON
{
  "slug": "test-chain-parent",
  "started_at": "2026-05-22T16:00:00Z",
  "terminal_state": "SUCCESS",
  "next_batch_spec": {
    "request": "implement batch 2 marketing pages",
    "type": "feature",
    "started_from_slug": "test-chain-parent"
  }
}
JSON
}

teardown() { teardown_sandbox; }

@test "next-batch-spec-chains: goal-conditions.md documents next_batch_spec schema" {
  grep -qF "next_batch_spec" "$GOAL_CONDITIONS"
}

@test "next-batch-spec-chains: schema spec mentions required 'request' field" {
  awk '/next_batch_spec/,/^## /' "$GOAL_CONDITIONS" | grep -qE "request"
}

@test "next-batch-spec-chains: schema spec mentions optional 'type' field" {
  awk '/next_batch_spec/,/^## /' "$GOAL_CONDITIONS" | grep -qE "type"
}

@test "next-batch-spec-chains: schema spec mentions 'started_from_slug' for audit" {
  awk '/next_batch_spec/,/^## /' "$GOAL_CONDITIONS" | grep -qE "started_from_slug"
}

@test "next-batch-spec-chains: protocol matrix references chain action" {
  grep -qE "next_batch_spec|chain" "$PROTOCOL"
}

@test "next-batch-spec-chains: synthetic goal-state JSON with next_batch_spec is parseable" {
  next_request=$(jq -r '.next_batch_spec.request' "$GOAL_FILE")
  [ "$next_request" = "implement batch 2 marketing pages" ]
}

@test "next-batch-spec-chains: chain terminator (null next_batch_spec) is parseable" {
  cat > "$GOAL_FILE" <<JSON
{"slug":"terminator","terminal_state":"SUCCESS","next_batch_spec":null}
JSON
  next=$(jq -r '.next_batch_spec // "TERMINATED"' "$GOAL_FILE")
  [ "$next" = "TERMINATED" ]
}
