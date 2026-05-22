#!/usr/bin/env bats
# tests/skill/cases/secret-doc-sync.bats
#
# Coverage for .claude/scripts/secret-doc-sync.sh — every documented exit code
# (0 sync OK, 1 drift, 2 parse error, 3 missing file, 4 missing markers) plus
# the happy path. Each test sandboxes both the scanner and the doc so we never
# touch the real repo files.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

# Build a minimal sandbox layout that mirrors the real repo enough for the
# script to resolve REPO_ROOT correctly. Layout:
#   $SANDBOX_DIR/.claude/scripts/secret-doc-sync.sh   (copy of real script)
#   $SANDBOX_DIR/.claude/scripts/secret-scan.sh       (test fixture — varies)
#   $SANDBOX_DIR/.claude/commands/plan-w-team/shared/secret-safety.md (fixture)
#
# REPO_ROOT inside the script resolves to two levels above its own location, so
# placing the script at .claude/scripts/ inside SANDBOX_DIR is sufficient.
SCRIPT_REL=".claude/scripts/secret-doc-sync.sh"
SCANNER_REL=".claude/scripts/secret-scan.sh"
DOC_REL=".claude/commands/plan-w-team/shared/secret-safety.md"

setup() {
  sandbox
  mkdir -p "$SANDBOX_DIR/.claude/scripts"
  mkdir -p "$SANDBOX_DIR/.claude/commands/plan-w-team/shared"
  cp "$REPO_ROOT/$SCRIPT_REL" "$SANDBOX_DIR/$SCRIPT_REL"
  chmod +x "$SANDBOX_DIR/$SCRIPT_REL"
}

teardown() {
  teardown_sandbox
}

# ── Fixture builders ────────────────────────────────────────────────────────

# Write a minimal scanner with a 2-pattern PATTERNS array.
write_scanner_2patterns() {
  cat > "$SANDBOX_DIR/$SCANNER_REL" <<'SH'
#!/usr/bin/env bash
PATTERNS=(
  'aws|AKIA[A-Z0-9]{16}|Revoke at AWS IAM console'
  'github|gh[pousr]_[a-zA-Z0-9_]{36,}|Revoke at github.com/settings/tokens'
)
SH
}

# Write a doc with markers wrapping a placeholder table that will be replaced.
write_doc_with_markers() {
  cat > "$SANDBOX_DIR/$DOC_REL" <<'MD'
# Secret Safety

Some prose before the table.

<!-- BEGIN AUTO-GENERATED: secret-patterns -->

| Name | Pattern (shape) | Remediation |
| ---- | --------------- | ----------- |
| `old` | `OLD` | placeholder |

<!-- END AUTO-GENERATED: secret-patterns -->

Some prose after the table.
MD
}

# ── Happy path ──────────────────────────────────────────────────────────────

@test "secret-doc-sync: given valid scanner and doc with markers, when sync runs, then exit code is 0" {
  write_scanner_2patterns
  write_doc_with_markers
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_success
  assert_output_contains "synced"
  assert_output_contains "2 patterns"
}

@test "secret-doc-sync: given scanner has 2 patterns, when sync runs, then doc shows 2 data rows" {
  write_scanner_2patterns
  write_doc_with_markers
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_success
  # Count data rows: lines starting with "| `" (backtick-wrapped name column)
  data_rows=$(grep -c '^| `' "$SANDBOX_DIR/$DOC_REL")
  [ "$data_rows" -eq 2 ]
}

@test "secret-doc-sync: given sync just ran, when --check runs, then exit code is 0" {
  write_scanner_2patterns
  write_doc_with_markers
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_success
  run "$SANDBOX_DIR/$SCRIPT_REL" --check
  assert_success
}

@test "secret-doc-sync: given sync runs twice, when --check runs, then doc is byte-identical (idempotent)" {
  write_scanner_2patterns
  write_doc_with_markers
  run "$SANDBOX_DIR/$SCRIPT_REL"; assert_success
  first_hash=$(md5 -q "$SANDBOX_DIR/$DOC_REL" 2>/dev/null || md5sum "$SANDBOX_DIR/$DOC_REL" | awk '{print $1}')
  run "$SANDBOX_DIR/$SCRIPT_REL"; assert_success
  second_hash=$(md5 -q "$SANDBOX_DIR/$DOC_REL" 2>/dev/null || md5sum "$SANDBOX_DIR/$DOC_REL" | awk '{print $1}')
  [ "$first_hash" = "$second_hash" ]
}

# ── Drift detection (exit 1) ────────────────────────────────────────────────

@test "secret-doc-sync: given pattern added to scanner, when --check runs, then exit code is 1" {
  write_scanner_2patterns
  write_doc_with_markers
  run "$SANDBOX_DIR/$SCRIPT_REL"; assert_success

  # Now add a third pattern to the scanner — doc is no longer in sync.
  cat > "$SANDBOX_DIR/$SCANNER_REL" <<'SH'
#!/usr/bin/env bash
PATTERNS=(
  'aws|AKIA[A-Z0-9]{16}|Revoke at AWS IAM console'
  'github|gh[pousr]_[a-zA-Z0-9_]{36,}|Revoke at github.com/settings/tokens'
  'stripe|sk_live_[a-zA-Z0-9]{20,}|Roll at dashboard.stripe.com/apikeys'
)
SH

  run "$SANDBOX_DIR/$SCRIPT_REL" --check
  assert_failure 1
  assert_output_contains "out of sync"
}

# ── Parse errors (exit 2) ───────────────────────────────────────────────────

@test "secret-doc-sync: given empty PATTERNS array, when sync runs, then exit code is 2" {
  cat > "$SANDBOX_DIR/$SCANNER_REL" <<'SH'
#!/usr/bin/env bash
PATTERNS=(
)
SH
  write_doc_with_markers
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 2
  assert_output_contains "PATTERNS"
}

@test "secret-doc-sync: given malformed entry with 2 fields not 3, when sync runs, then exit code is 2" {
  cat > "$SANDBOX_DIR/$SCANNER_REL" <<'SH'
#!/usr/bin/env bash
PATTERNS=(
  'aws|AKIA[A-Z0-9]{16}'
)
SH
  write_doc_with_markers
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 2
  assert_output_contains "malformed"
}

# ── Missing files (exit 3) ──────────────────────────────────────────────────

@test "secret-doc-sync: given scanner file missing, when sync runs, then exit code is 3" {
  write_doc_with_markers
  # No scanner written — should bail with exit 3.
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 3
  assert_output_contains "scanner not found"
}

@test "secret-doc-sync: given doc file missing, when sync runs, then exit code is 3" {
  write_scanner_2patterns
  # No doc written.
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 3
  assert_output_contains "doc not found"
}

@test "secret-doc-sync: given unknown CLI arg, when sync runs, then exit code is 3" {
  write_scanner_2patterns
  write_doc_with_markers
  run "$SANDBOX_DIR/$SCRIPT_REL" --bogus-flag
  assert_failure 3
  assert_output_contains "Unknown arg"
}

# ── Missing markers (exit 4) ────────────────────────────────────────────────

@test "secret-doc-sync: given doc with no BEGIN marker, when sync runs, then exit code is 4" {
  write_scanner_2patterns
  cat > "$SANDBOX_DIR/$DOC_REL" <<'MD'
# Secret Safety
No markers here.
<!-- END AUTO-GENERATED: secret-patterns -->
MD
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 4
  assert_output_contains "BEGIN"
}

@test "secret-doc-sync: given doc with no END marker, when sync runs, then exit code is 4" {
  write_scanner_2patterns
  cat > "$SANDBOX_DIR/$DOC_REL" <<'MD'
# Secret Safety
<!-- BEGIN AUTO-GENERATED: secret-patterns -->
No closer.
MD
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 4
  assert_output_contains "END"
}
