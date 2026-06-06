#!/usr/bin/env bats
# tests/skill/cases/plugin-integration.bats
#
# Regression coverage for the silent-failure-hunter integration into Step 5
# §5b-pre domain-specialist fan-out table. Asserts:
#   1. The vendored agent definition exists with correct frontmatter.
#   2. Step 5 §5b-pre table contains the silent-failure-hunter row.
#   3. The decision-matrix spec exists.
#
# See docs/specs/plugin-integration-evaluation.md for the evaluation context.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

@test "silent-failure-hunter agent definition exists and is well-formed" {
  local agent_file="$REPO_ROOT/.claude/agents/team/silent-failure-hunter.md"
  [ -f "$agent_file" ]

  run grep -E '^name: silent-failure-hunter$' "$agent_file"
  [ "$status" -eq 0 ]

  run grep -E '^model: claude-opus-4-8$' "$agent_file"
  [ "$status" -eq 0 ]

  run grep -E '^description:' "$agent_file"
  [ "$status" -eq 0 ]
}

@test "silent-failure-hunter is wired into Step 5 §5b-pre domain-specialist table" {
  local stage_file="$REPO_ROOT/.claude/commands/plan-w-team/04-fix-first-review.md"
  [ -f "$stage_file" ]

  run grep -F 'silent-failure-hunter' "$stage_file"
  [ "$status" -eq 0 ]

  run grep -F 'Diff contains new' "$stage_file"
  [ "$status" -eq 0 ]
}

@test "plugin-integration-evaluation spec exists with all three plugin verdicts" {
  local spec="$REPO_ROOT/docs/specs/plugin-integration-evaluation.md"
  [ -f "$spec" ]

  run grep -F 'pr-review-toolkit' "$spec"
  [ "$status" -eq 0 ]

  run grep -F 'code-review' "$spec"
  [ "$status" -eq 0 ]

  run grep -F 'commit-commands' "$spec"
  [ "$status" -eq 0 ]

  run grep -E '\| INTEGRATE +\|' "$spec"
  [ "$status" -eq 0 ]

  run grep -E '\| REJECT +\|' "$spec"
  [ "$status" -eq 0 ]
}
