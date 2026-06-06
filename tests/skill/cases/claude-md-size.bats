#!/usr/bin/env bats
# tests/skill/cases/claude-md-size.bats
#
# Coverage for scripts/check-claude-md-size.sh — the regression guard that keeps
# the project CLAUDE.md under Claude Code's 40,000-character performance
# threshold. Because claude-pattern is the synced source-of-truth, an oversized
# CLAUDE.md propagates the "Large CLAUDE.md will impact performance" warning to
# every consumer repo.
#
# We pin every documented exit code (0 under-limit, 1 at/over-limit, 2
# file-not-found) using synthetic fixtures, plus a live anchor asserting the
# real repo CLAUDE.md is currently under the limit (this is the assertion that
# was RED before the size-reduction fix and GREEN after).

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SCRIPT_REL="scripts/check-claude-md-size.sh"

setup() {
  sandbox
  mkdir -p "$SANDBOX_DIR/scripts"
  cp "$REPO_ROOT/$SCRIPT_REL" "$SANDBOX_DIR/$SCRIPT_REL"
  chmod +x "$SANDBOX_DIR/$SCRIPT_REL"
}

teardown() {
  teardown_sandbox
}

# ── Helpers ─────────────────────────────────────────────────────────────────

# make_file <path> <num_chars> — write exactly <num_chars> bytes of 'x'.
make_file() {
  local path="$1" n="$2"
  # `head -c` is portable on macOS + Linux for byte-exact output.
  head -c "$n" /dev/zero | tr '\0' 'x' > "$path"
}

# ── Under limit / exit 0 ──────────────────────────────────────────────────────

@test "claude-md-size: given a 39999-char file, when checked, then exit 0" {
  make_file "$SANDBOX_DIR/CLAUDE.md" 39999
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_success
  assert_output_contains "under 40000 limit"
}

@test "claude-md-size: given an explicit path argument under limit, when checked, then exit 0" {
  make_file "$SANDBOX_DIR/custom.md" 100
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL" "$SANDBOX_DIR/custom.md"
  assert_success
}

# ── At / over limit / exit 1 ──────────────────────────────────────────────────

@test "claude-md-size: given a file exactly at the 40000 limit, when checked, then exit 1" {
  make_file "$SANDBOX_DIR/CLAUDE.md" 40000
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 1
  assert_output_contains "limit 40000"
}

@test "claude-md-size: given a 41295-char file (the pre-fix size), when checked, then exit 1" {
  make_file "$SANDBOX_DIR/CLAUDE.md" 41295
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 1
  assert_output_contains "over by 1295"
  assert_output_contains "impact performance"
}

@test "claude-md-size: given an over-limit file, when CLAUDE_MD_MAX_CHARS lowers the bound, then it still trips" {
  make_file "$SANDBOX_DIR/CLAUDE.md" 39000
  cd "$SANDBOX_DIR"
  CLAUDE_MD_MAX_CHARS=38000 run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 1
}

# ── File not found / exit 2 ───────────────────────────────────────────────────

@test "claude-md-size: given a missing file, when checked, then exit 2" {
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL" "$SANDBOX_DIR/does-not-exist.md"
  assert_failure 2
  assert_output_contains "file not found"
}

# ── Live regression anchor ────────────────────────────────────────────────────

@test "claude-md-size: the real repo CLAUDE.md is under the 40000-char limit" {
  # This is the regression: RED before the size-reduction fix, GREEN after.
  run "$REPO_ROOT/$SCRIPT_REL"
  assert_success
}
