#!/usr/bin/env bats
# tests/skill/cases/symmetry-check.bats
#
# Coverage for .claude/scripts/plan-w-team-symmetry-check.sh — every documented
# exit code (0 OK, 1 orphan, 2 stale, 3 environment, 4 orphan reader).
#
# The script accepts --registry <path> so we can point it at a sandbox-controlled
# fixture without touching the real registry. The SCOPE/EXCLUDES it scans are
# hardcoded, so we run it from $SANDBOX_DIR with a sandboxed code tree mirrored
# under .claude/commands/plan-w-team/ and .claude/scripts/.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SCRIPT_REL=".claude/scripts/plan-w-team-symmetry-check.sh"

setup() {
  sandbox
  mkdir -p "$SANDBOX_DIR/.claude/scripts"
  mkdir -p "$SANDBOX_DIR/.claude/commands/plan-w-team/shared"
  mkdir -p "$SANDBOX_DIR/.claude/hooks"
  cp "$REPO_ROOT/$SCRIPT_REL" "$SANDBOX_DIR/$SCRIPT_REL"
  chmod +x "$SANDBOX_DIR/$SCRIPT_REL"
  cd "$SANDBOX_DIR"
}

teardown() {
  teardown_sandbox
}

# ── Fixture builders ────────────────────────────────────────────────────────

# Minimal valid registry with one enforcing entry. Header rows match the format
# the parser expects.
write_registry_one_enforcing() {
  local writer_grep="$1" reader_grep="$2"
  cat > "$SANDBOX_DIR/.claude/commands/plan-w-team/shared/state-artifacts.md" <<MD
# State Artifacts Registry

| pattern | writer_grep | reader_grep | mode | purpose |
| ------- | ----------- | ----------- | ---- | ------- |
| \`.claude/state/plan-w-team-test-\$SLUG.txt\` | \`$writer_grep\` | \`$reader_grep\` | enforcing | Test fixture |
MD
}

write_registry_one_audit_trail() {
  cat > "$SANDBOX_DIR/.claude/commands/plan-w-team/shared/state-artifacts.md" <<'MD'
# State Artifacts Registry

| pattern | writer_grep | reader_grep | mode | purpose |
| ------- | ----------- | ----------- | ---- | ------- |
| `.claude/state/plan-w-team-test-$SLUG.txt` | `WRITER_TOKEN` | `-` | audit-trail | Audit only |
MD
}

# Drop a code file containing a writer/reader token so the symmetry check
# can find it via ripgrep.
write_writer_in_code() {
  local token="$1"
  printf 'echo "%s"\n' "$token" > "$SANDBOX_DIR/.claude/commands/plan-w-team/00-stage.md"
}

write_reader_in_code() {
  local token="$1"
  printf 'echo "%s"\n' "$token" >> "$SANDBOX_DIR/.claude/commands/plan-w-team/00-stage.md"
}

# Drop a stage file that references an undeclared .claude/state path.
# Must end in non-dash characters so the bidirectional pass does not skip
# it as a wildcard-mention (`*-` heuristic).
write_orphan_reader_in_code() {
  printf 'echo ".claude/state/plan-w-team-undeclared.json"\n' \
    > "$SANDBOX_DIR/.claude/commands/plan-w-team/99-orphan.md"
}

# ── Exit 0: all entries OK ──────────────────────────────────────────────────

@test "symmetry-check: given writer and reader both present, when check runs, then exit code is 0" {
  write_registry_one_enforcing 'WRITER_TOKEN' 'READER_TOKEN'
  write_writer_in_code 'WRITER_TOKEN'
  write_reader_in_code 'READER_TOKEN'
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_success
  assert_output_contains "ok:       1"
}

@test "symmetry-check: given audit-trail entry with writer present, when check runs, then exit code is 0" {
  write_registry_one_audit_trail
  write_writer_in_code 'WRITER_TOKEN'
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_success
  assert_output_contains "audit-trail"
}

# ── Exit 1: orphan (registry entry has no reader in code) ──────────────────

@test "symmetry-check: given enforcing entry with no reader, when check runs, then exit code is 1" {
  write_registry_one_enforcing 'WRITER_TOKEN' 'READER_TOKEN'
  write_writer_in_code 'WRITER_TOKEN'
  # Reader deliberately not added.
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 1
  assert_output_contains "orphans"
}

# ── Exit 2: stale (registry entry has no writer in code) ───────────────────

@test "symmetry-check: given registry entry with no writer in code, when check runs, then exit code is 2" {
  write_registry_one_enforcing 'WRITER_TOKEN' 'READER_TOKEN'
  # Neither writer nor reader added — stale check fires first (exit 2).
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 2
  assert_output_contains "stale"
}

# ── Exit 3: environment errors ─────────────────────────────────────────────

@test "symmetry-check: given registry file missing, when check runs, then exit code is 3" {
  # Don't write a registry. Even with --registry flag pointing at it.
  run "$SANDBOX_DIR/$SCRIPT_REL" --registry .claude/commands/plan-w-team/shared/state-artifacts.md
  assert_failure 3
  assert_output_contains "registry not found"
}

@test "symmetry-check: given unknown CLI arg, when check runs, then exit code is 3" {
  write_registry_one_enforcing 'WRITER_TOKEN' 'READER_TOKEN'
  run "$SANDBOX_DIR/$SCRIPT_REL" --bogus-flag
  assert_failure 3
  assert_output_contains "Unknown arg"
}

# ── Exit 4: orphan reader (code references unregistered .claude/state path) ─

@test "symmetry-check: given code references undeclared .claude/state path, when check runs, then exit code is 4" {
  write_registry_one_enforcing 'WRITER_TOKEN' 'READER_TOKEN'
  write_writer_in_code 'WRITER_TOKEN'
  write_reader_in_code 'READER_TOKEN'
  write_orphan_reader_in_code
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 4
  assert_output_contains "orphan readers"
  assert_output_contains "plan-w-team-undeclared"
}

# ── --json output mode ─────────────────────────────────────────────────────

@test "symmetry-check: given --json flag with all-OK fixture, when check runs, then output is valid JSON" {
  write_registry_one_enforcing 'WRITER_TOKEN' 'READER_TOKEN'
  write_writer_in_code 'WRITER_TOKEN'
  write_reader_in_code 'READER_TOKEN'
  run "$SANDBOX_DIR/$SCRIPT_REL" --json
  assert_success
  # Validate JSON via jq if available; otherwise grep-validate the structural keys.
  if command -v jq >/dev/null 2>&1; then
    echo "$output" | jq -e '.total == 1 and .ok == 1' >/dev/null
  else
    assert_output_contains '"total":'
    assert_output_contains '"ok":'
  fi
}
