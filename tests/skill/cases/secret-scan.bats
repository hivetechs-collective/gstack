#!/usr/bin/env bats
# tests/skill/cases/secret-scan.bats
#
# Coverage for .claude/scripts/secret-scan.sh — every documented exit code
# (0 clean, 1 secret found, 2 bad args), the placeholder-suppression contract,
# the allow-file behavior, and the redaction guarantee (no full-length tokens
# in output). Tests use the real script (no fork) but sandbox the input files.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SCANNER="$REPO_ROOT/.claude/scripts/secret-scan.sh"

setup() {
  sandbox
}

teardown() {
  teardown_sandbox
}

# ── Argument validation / exit 2 ───────────────────────────────────────────

@test "secret-scan: given no mode flag, when scan runs, then exit code is 2" {
  run "$SCANNER"
  assert_failure 2
}

@test "secret-scan: given unknown flag, when scan runs, then exit code is 2" {
  run "$SCANNER" --bogus
  assert_failure 2
  assert_output_contains "Unknown argument"
}

@test "secret-scan: given --paths with no files, when scan runs, then exit code is 2" {
  run "$SCANNER" --paths
  assert_failure 2
}

@test "secret-scan: given --diff with no range, when scan runs, then exit code is 2" {
  run "$SCANNER" --diff
  assert_failure 2
}

@test "secret-scan: given --allow with missing file, when scan runs, then exit code is 2" {
  printf 'safe content\n' > "$SANDBOX_DIR/clean.txt"
  run "$SCANNER" --allow "$SANDBOX_DIR/no-such-allow.txt" --paths "$SANDBOX_DIR/clean.txt"
  assert_failure 2
  assert_output_contains "not found"
}

# ── Clean path / exit 0 ────────────────────────────────────────────────────

@test "secret-scan: given a file with no secrets, when --paths scan runs, then exit code is 0" {
  printf 'this file has no secrets\nfoo=bar\n' > "$SANDBOX_DIR/clean.txt"
  run "$SCANNER" --paths "$SANDBOX_DIR/clean.txt"
  assert_success
}

@test "secret-scan: given an empty file, when --paths scan runs, then exit code is 0" {
  : > "$SANDBOX_DIR/empty.txt"
  run "$SCANNER" --paths "$SANDBOX_DIR/empty.txt"
  assert_success
}

# ── Live secret detection / exit 1 ─────────────────────────────────────────

@test "secret-scan: given AWS access key in file, when --paths scan runs, then exit code is 1" {
  printf 'AWS_KEY=AKIAIOSFODNN7EXAMPLE\n' > "$SANDBOX_DIR/leak.txt"
  run "$SCANNER" --paths "$SANDBOX_DIR/leak.txt"
  assert_failure 1
  assert_output_contains "LIVE SECRET"
  assert_output_contains "aws"
}

@test "secret-scan: given GitHub token in file, when --paths scan runs, then exit code is 1" {
  # ghp_ prefix + 36 chars
  printf 'token=ghp_abcdefghijklmnopqrstuvwxyz0123456789\n' > "$SANDBOX_DIR/gh.txt"
  run "$SCANNER" --paths "$SANDBOX_DIR/gh.txt"
  assert_failure 1
  assert_output_contains "github-token"
}

@test "secret-scan: given matched token in output, when scan runs, then full token is redacted" {
  # The full token must NOT appear in scanner output. Only first 6 + last 4.
  local full="ghp_abcdefghijklmnopqrstuvwxyz0123456789"
  printf 'token=%s\n' "$full" > "$SANDBOX_DIR/gh.txt"
  run "$SCANNER" --paths "$SANDBOX_DIR/gh.txt"
  assert_failure 1
  assert_output_not_contains "$full"
  # Redacted form: first 6 + "..." + last 4
  assert_output_contains "ghp_ab"
  assert_output_contains "6789"
}

# ── Placeholder suppression ────────────────────────────────────────────────

@test "secret-scan: given pattern-shape with YOUR_ marker, when scan runs, then exit code is 0" {
  # AKIA-shape but contains placeholder marker → suppressed
  printf 'AWS_KEY=AKIAIOSYOUR_KEY1234X\n' > "$SANDBOX_DIR/example.env"
  run "$SCANNER" --paths "$SANDBOX_DIR/example.env"
  assert_success
}

@test "secret-scan: given pattern-shape with REDACTED marker, when scan runs, then exit code is 0" {
  printf 'token=ghp_REDACTED_abcdefghijklmnopqrstuv1234\n' > "$SANDBOX_DIR/redacted.txt"
  run "$SCANNER" --paths "$SANDBOX_DIR/redacted.txt"
  assert_success
}

# ── Allow-file behavior ────────────────────────────────────────────────────

@test "secret-scan: given allow-file matching the finding, when scan runs, then exit code is 0" {
  printf 'AWS_KEY=AKIAIOSFODNN7EXAMPLE\n' > "$SANDBOX_DIR/leak.txt"
  printf '%s:1:aws\n' "$SANDBOX_DIR/leak.txt" > "$SANDBOX_DIR/allow.txt"
  run "$SCANNER" --allow "$SANDBOX_DIR/allow.txt" --paths "$SANDBOX_DIR/leak.txt"
  assert_success
}

@test "secret-scan: given allow-file with comments and blanks, when scan runs, then they are ignored" {
  printf 'AWS_KEY=AKIAIOSFODNN7EXAMPLE\n' > "$SANDBOX_DIR/leak.txt"
  cat > "$SANDBOX_DIR/allow.txt" <<EOF
# this is a comment
   # indented comment

$SANDBOX_DIR/leak.txt:1:aws
EOF
  run "$SCANNER" --allow "$SANDBOX_DIR/allow.txt" --paths "$SANDBOX_DIR/leak.txt"
  assert_success
}

# ── JSON output format ─────────────────────────────────────────────────────

@test "secret-scan: given --json with a secret, when scan runs, then output is valid JSON per finding" {
  printf 'AWS_KEY=AKIAIOSFODNN7EXAMPLE\n' > "$SANDBOX_DIR/leak.txt"
  run "$SCANNER" --json --paths "$SANDBOX_DIR/leak.txt"
  assert_failure 1
  if command -v jq >/dev/null 2>&1; then
    # Each finding is a single JSON object on its own line.
    echo "$output" | jq -e '.pattern == "aws"' >/dev/null
  else
    assert_output_contains '"pattern":"aws"'
  fi
}

# ── Self-skip: the scanner must not flag its own pattern catalog ──────────

@test "secret-scan: given the scanner file itself, when scan runs, then exit code is 0 (self-skip)" {
  run "$SCANNER" --paths "$SCANNER"
  assert_success
}

# ── Binary file handling ───────────────────────────────────────────────────

@test "secret-scan: given a binary file, when --paths scan runs, then it is skipped (exit 0)" {
  # Create a small binary blob
  printf '\x00\x01\x02AKIAIOSFODNN7EXAMPLE\x00' > "$SANDBOX_DIR/binary.bin"
  run "$SCANNER" --paths "$SANDBOX_DIR/binary.bin"
  assert_success
}
