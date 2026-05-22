#!/usr/bin/env bats
# tests/skill/scenarios/supervisor-matrix-blocks-on-one-way-door.bats
#
# Scenario: when a PR carries the literal label "DO NOT MERGE" OR touches
# any surface listed in shared/governance-tags.md (security allowlist,
# billing, schema migrations, infrastructure config, secrets), the
# supervisor MUST surface to user instead of auto-merging — even when CI
# is green.
#
# Validates the infrastructure: governance-tags.md exists and enumerates
# the required one-way-door surfaces; the protocol matrix references the
# SURFACE action for both label and surface-match cases.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

PROTOCOL="$REPO_ROOT/.claude/commands/plan-w-team/shared/supervisor-protocol.md"
GOVERNANCE="$REPO_ROOT/.claude/commands/plan-w-team/shared/governance-tags.md"
SHIP="$REPO_ROOT/.claude/commands/plan-w-team/05-ship.md"

@test "blocks-on-one-way-door: governance-tags.md exists" {
  [ -f "$GOVERNANCE" ]
}

@test "blocks-on-one-way-door: governance-tags lists security allowlist surface" {
  grep -qiE "secret-scan-allow|security.allowlist|secret.allowlist" "$GOVERNANCE"
}

@test "blocks-on-one-way-door: governance-tags lists billing/money surface" {
  grep -qiE "billing|money|payment|stripe|paddle" "$GOVERNANCE"
}

@test "blocks-on-one-way-door: governance-tags lists schema migration surface" {
  grep -qiE "schema.migration|migration|database schema" "$GOVERNANCE"
}

@test "blocks-on-one-way-door: governance-tags lists infrastructure config surface" {
  grep -qiE "infrastructure|wrangler|terraform|cloudformation|infra" "$GOVERNANCE"
}

@test "blocks-on-one-way-door: governance-tags lists secret-handling surface" {
  grep -qiE "secret|credential|api.key|token" "$GOVERNANCE"
}

@test "blocks-on-one-way-door: protocol matrix names SURFACE action for governance-tagged PRs" {
  grep -qF "SURFACE" "$PROTOCOL"
}

@test "blocks-on-one-way-door: 05-ship.md constrains DO NOT MERGE label to one-way-door surfaces" {
  grep -qE "(DO NOT MERGE|do-not-merge|do.not.merge)" "$SHIP"
  grep -qF "governance-tags.md" "$SHIP"
}
