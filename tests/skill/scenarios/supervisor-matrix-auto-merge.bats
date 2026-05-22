#!/usr/bin/env bats
# tests/skill/scenarios/supervisor-matrix-auto-merge.bats
#
# Scenario: supervisor-protocol.md documents the AUTO-MERGE row of the
# decision matrix. When a worker reaches SUCCESS terminal state AND the
# associated PR is CI-green AND has no governance label, the supervisor
# (origin-chat LLM following the protocol) is authorized to auto-merge
# without surfacing to user.
#
# This scenario validates the INFRASTRUCTURE the supervisor relies on:
# matrix exists in the protocol doc, references the required PR-state
# inputs, and the AUTO-MERGE action is explicitly named. The LLM-driven
# decision itself is asserted by the protocol prose; what we pin here is
# the contract that prose references.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

PROTOCOL="$REPO_ROOT/.claude/commands/plan-w-team/shared/supervisor-protocol.md"

@test "supervisor-matrix-auto-merge: supervisor-protocol.md exists" {
  [ -f "$PROTOCOL" ]
}

@test "supervisor-matrix-auto-merge: protocol contains a Decision Matrix section" {
  grep -qE "(Decision Matrix|## Matrix)" "$PROTOCOL"
}

@test "supervisor-matrix-auto-merge: matrix names AUTO-MERGE action for green CI + no governance tag" {
  grep -qF "AUTO-MERGE" "$PROTOCOL"
}

@test "supervisor-matrix-auto-merge: matrix cites the gh pr list input source" {
  grep -qE "gh pr list|statusCheckRollup" "$PROTOCOL"
}

@test "supervisor-matrix-auto-merge: matrix references DO NOT MERGE label as surface trigger" {
  grep -qF "DO NOT MERGE" "$PROTOCOL"
}

@test "supervisor-matrix-auto-merge: matrix references governance-tags.md for surface lookup" {
  grep -qF "governance-tags.md" "$PROTOCOL"
}
