#!/usr/bin/env bats
# tests/skill/cases/builder-self-regulation.bats
#
# Drift-lock for the P7 fix: the WTF-likelihood self-regulation discipline must
# travel with the builder agent definition (not only via a stage-file pointer a
# spawn prompt might omit), and its hard-cap numbers must match the canonical
# shared/self-regulation.md so the two cannot drift apart.
#
# Audit: P7 (docs/operations/pwt-principles-enforcement-audit-2026-06-02.md).

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

BUILDER="$REPO_ROOT/.claude/agents/team/builder.md"
SELFREG="$COMMANDS_DIR/shared/self-regulation.md"

@test "builder.md inlines a Self-Regulation section" {
  run grep -qi "Self-Regulation" "$BUILDER"
  [ "$status" -eq 0 ]
}

@test "builder.md states the 20% STOP threshold and 50-fix hard cap" {
  grep -q "20%" "$BUILDER"
  grep -q "50" "$BUILDER"
}

@test "builder.md points at the canonical self-regulation.md" {
  grep -q "shared/self-regulation.md" "$BUILDER"
}

@test "the 20% / 50 caps in builder.md match shared/self-regulation.md (no drift)" {
  # self-regulation.md is the source of truth for both numbers.
  grep -q "20%" "$SELFREG"
  grep -q "50 fixes" "$SELFREG"
}
