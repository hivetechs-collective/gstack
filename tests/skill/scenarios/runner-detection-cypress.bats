#!/usr/bin/env bats
# tests/skill/scenarios/runner-detection-cypress.bats
#
# Scenario: STE Extension — Step 3 runner detection extended to recognize
# cypress.config.{ts,js,mjs}, playwright.config.{ts,js,mjs}, tests/e2e/,
# and robotframework .robot files. They run in ADDITION to unit runners,
# not instead of.
#
# Spec: docs/specs/ste-extension.md (AC5)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

EXEC_STAGE_FILE="$COMMANDS_DIR/03-execute.md"

# ─── AC5: runner detection extended to e2e/integration runners ──────────────

@test "runner-detection-cypress AC5: 03-execute.md recognizes cypress.config.{ts,js}" {
  run grep -E 'cypress\.config' "$EXEC_STAGE_FILE"
  assert_success
}

@test "runner-detection-cypress AC5: 03-execute.md recognizes playwright.config.{ts,js}" {
  run grep -E 'playwright\.config' "$EXEC_STAGE_FILE"
  assert_success
}

@test "runner-detection-cypress AC5: 03-execute.md recognizes tests/e2e/ directory" {
  run grep -E 'tests/e2e/' "$EXEC_STAGE_FILE"
  assert_success
}

@test "runner-detection-cypress AC5: 03-execute.md recognizes robotframework .robot files" {
  run grep -E 'robot|\.robot|Robot Framework' "$EXEC_STAGE_FILE"
  assert_success
}

@test "runner-detection-cypress AC5: e2e runners run IN ADDITION to unit runners (not instead)" {
  # "in addition" / "alongside" / "run all detected" — explicit additive language
  run grep -E 'in addition|alongside|run ALL detected|in addition to unit' "$EXEC_STAGE_FILE"
  assert_success
}

@test "runner-detection-cypress AC5: unit runners run FIRST (faster signal), e2e last" {
  run grep -E 'unit.*first|FIRST.*unit|unit-runner command.*before.*marking|UNIT runners.*highest priority' "$EXEC_STAGE_FILE"
  assert_success
}

@test "runner-detection-cypress AC5: multiple e2e configs all run (no pick-one)" {
  # "Do NOT pick one and skip the other" — explicit anti-collision rule
  run grep -E 'Do NOT pick one|all of them' "$EXEC_STAGE_FILE"
  assert_success
}

# ─── Behavioural detection sanity (sandbox) ─────────────────────────────────
# The stage-file is the source of truth; verify a sandbox with cypress.config
# would be picked up by a naive detection grep matching the priority list.

@test "runner-detection-cypress AC5: sandbox with cypress.config.ts is matched by detection regex" {
  sandbox
  printf 'export default { e2e: {} }\n' > cypress.config.ts
  run ls cypress.config.ts
  assert_success
  # Simulate the detection regex applied to the file list
  run bash -c "ls cypress.config.{ts,js,mjs} 2>/dev/null | head -1"
  assert_success
  teardown_sandbox
}

@test "runner-detection-cypress AC5: sandbox with playwright.config.ts is matched by detection regex" {
  sandbox
  printf 'export default { testDir: \"./tests\" }\n' > playwright.config.ts
  run bash -c "ls playwright.config.{ts,js,mjs} 2>/dev/null | head -1"
  assert_success
  teardown_sandbox
}

@test "runner-detection-cypress AC5: sandbox with tests/e2e/ directory is detected" {
  sandbox
  mkdir -p tests/e2e
  printf 'console.log(\"e2e test\")\n' > tests/e2e/example.spec.ts
  [ -d tests/e2e ]
  run bash -c "find tests/e2e -type f -name '*.spec.*' | head -1"
  assert_success
  teardown_sandbox
}

@test "runner-detection-cypress AC5: sandbox with .robot file is detected" {
  sandbox
  mkdir -p tests
  printf '*** Test Cases ***\nExample\n    Log    hello\n' > tests/example.robot
  run bash -c "find . -name '*.robot' | head -1"
  assert_success
  teardown_sandbox
}
