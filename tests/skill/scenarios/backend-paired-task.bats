#!/usr/bin/env bats
# tests/skill/scenarios/backend-paired-task.bats
#
# Scenario: STE Extension — non-UI scopes trigger paired N.a/N.b task
# decomposition. Verifies that 02-task-breakdown.md documents the paired
# pattern for [BACKEND, INFRASTRUCTURE, SCRIPTS, LIBRARY, API] code-adding
# tasks, mirroring the UI paired-task block.
#
# Spec: docs/specs/ste-extension.md (AC1, AC6, AC7)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

STAGE_FILE="$COMMANDS_DIR/02-task-breakdown.md"

# ─── AC1: non-UI paired-task block exists in 02-task-breakdown.md ───────────

@test "backend-paired-task AC1: 02-task-breakdown.md has a non-UI paired-task protocol section" {
  run grep -nE 'Paired Task Protocol \(non-UI scopes\)' "$STAGE_FILE"
  assert_success
}

@test "backend-paired-task AC1: non-UI block lists BACKEND, INFRASTRUCTURE, SCRIPTS, LIBRARY, API" {
  run grep -E 'BACKEND, INFRASTRUCTURE, SCRIPTS, LIBRARY, API' "$STAGE_FILE"
  assert_success
}

@test "backend-paired-task AC1: trigger expression conditions on mode == add" {
  # Trigger expression must condition on add-mode (not refactor/docs/config)
  run grep -E 'mode == "add"' "$STAGE_FILE"
  assert_success
}

@test "backend-paired-task AC1: refactor-only / docs-only / config-only stay single-task" {
  run grep -E 'refactor.*single-task|single-task.*refactor|mode == \"refactor\"' "$STAGE_FILE"
  assert_success
}

@test "backend-paired-task AC1: N.a assigned to unit-testing-specialist (default)" {
  # The non-UI paired-task table's N.a row defaults to unit-testing-specialist.
  # Extract lines between the non-UI block heading and the next ## heading,
  # then grep for unit-testing-specialist on a line that mentions N.a.
  local block
  block=$(awk '/^## Paired Task Protocol \(non-UI scopes\)/,/^## [^P]/' "$STAGE_FILE")
  echo "$block" | grep -E 'unit-testing-specialist'
  echo "$block" | grep -E '\bN\.a\b'
}

@test "backend-paired-task AC1: language-specific test specialist mentioned as alternative" {
  # The block should mention language-specific test specialists (python/rust/go test)
  run grep -E 'python-test-specialist|rust-test-specialist|go-test-specialist|language-specific test specialist' "$STAGE_FILE"
  assert_success
}

# ─── AC6: Hot-path overlay emits perf-testing-specialist slot ───────────────

@test "backend-paired-task AC6: 02-task-breakdown.md has a Hot-Path Overlay section" {
  run grep -nE 'Hot-Path Overlay' "$STAGE_FILE"
  assert_success
}

@test "backend-paired-task AC6: hot-path threshold cites >1000 LOC OR >50 commits in last 30 days" {
  run grep -E '>1000 LOC|>50 commits' "$STAGE_FILE"
  assert_success
}

@test "backend-paired-task AC6: hot-path emits optional perf-testing-specialist task slot (N.p)" {
  run grep -E 'perf-testing-specialist' "$STAGE_FILE"
  assert_success
  run grep -E '\bN\.p\b' "$STAGE_FILE"
  assert_success
}

# ─── AC7: TO2 mutation default-on for one-way doors ─────────────────────────

@test "backend-paired-task AC7: 02-task-breakdown.md documents TO2 mutation default-on for one-way-door PRs" {
  run grep -nE 'TO2 Mutation Default-On' "$STAGE_FILE"
  assert_success
}

@test "backend-paired-task AC7: mutation_required: true is set when door_type == one-way" {
  run grep -E 'mutation_required: true' "$STAGE_FILE"
  assert_success
}

@test "backend-paired-task AC7: documented mutation-survived >5% threshold" {
  run grep -E 'survival.*5%|>5%|5%.*survived|Mutation-survived' "$STAGE_FILE"
  assert_success
}
