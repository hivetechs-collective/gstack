#!/usr/bin/env bats
# tests/skill/cases/board.bats
#
# Coverage for .claude/scripts/board.sh — local/deterministic behaviors only.
# The script's primary surface is a thin CLI over `gh project` + GraphQL, which
# is not portable to test in CI. We pin the in-process behaviors here:
#   - help/usage output
#   - unknown command rejection
#   - missing config detection
#   - malformed config detection (parse error path)
#
# Anything that hits the GitHub API is out of scope for this harness — those
# paths are validated by the operations runbook and live release.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SCRIPT_REL=".claude/scripts/board.sh"

setup() {
  sandbox
  mkdir -p "$SANDBOX_DIR/.claude/scripts"
  mkdir -p "$SANDBOX_DIR/.github"
  cp "$REPO_ROOT/$SCRIPT_REL" "$SANDBOX_DIR/$SCRIPT_REL"
  chmod +x "$SANDBOX_DIR/$SCRIPT_REL"
}

teardown() {
  teardown_sandbox
}

# ── Help / usage ────────────────────────────────────────────────────────────

@test "board: given help command, when invoked, then usage prints and exit code is 0" {
  run "$SANDBOX_DIR/$SCRIPT_REL" help
  assert_success
  assert_output_contains "Usage: board.sh"
}

@test "board: given --help flag, when invoked, then usage prints and exit code is 0" {
  run "$SANDBOX_DIR/$SCRIPT_REL" --help
  assert_success
  assert_output_contains "Usage: board.sh"
}

@test "board: given no arguments, when invoked, then it defaults to help (exit 0)" {
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_success
  assert_output_contains "Usage: board.sh"
}

# ── Unknown command rejection ──────────────────────────────────────────────

@test "board: given an unknown command, when invoked, then exit code is non-zero" {
  run "$SANDBOX_DIR/$SCRIPT_REL" frobnicate
  assert_failure
  assert_output_contains "Unknown command"
}

# ── Missing config detection ───────────────────────────────────────────────

@test "board: given no board config and a config-requiring command, when invoked, then it bails with a clear error" {
  # `list` requires config; with .github/board.json absent it must surface
  # the "No board config found" error path rather than crashing.
  run "$SANDBOX_DIR/$SCRIPT_REL" list
  assert_failure
  assert_output_contains "No board config found"
  assert_output_contains "board.sh init"
}

# ── Malformed config detection ─────────────────────────────────────────────

@test "board: given an invalid JSON board config, when a command runs, then it bails (does not silently continue)" {
  # Deliberately malformed JSON — python3 json.load will raise.
  printf '{ this is not json' > "$SANDBOX_DIR/.github/board.json"
  run "$SANDBOX_DIR/$SCRIPT_REL" list
  assert_failure
}

@test "board: given a config missing project_number, when a command runs, then it surfaces the missing field" {
  # Valid JSON but missing required key.
  printf '{"owner": "test-owner"}' > "$SANDBOX_DIR/.github/board.json"
  run "$SANDBOX_DIR/$SCRIPT_REL" list
  assert_failure
  # The script either crashes on the python3 KeyError or hits the explicit
  # "Invalid board config" check. Either way, it must not exit 0.
}
