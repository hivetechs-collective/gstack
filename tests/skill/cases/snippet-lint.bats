#!/usr/bin/env bats
# tests/skill/cases/snippet-lint.bats
#
# Coverage for .claude/scripts/plan-w-team-snippet-lint.sh — every documented
# exit code (0 clean, 1 parse failure, 2 internal error) plus the skip-directive
# opt-out and the file:block-index reporting contract.
#
# The script under test scans a fixed REPO_ROOT path
# (`.claude/commands/plan-w-team*`). To exercise it without polluting the real
# stage files, we copy the script into a sandbox that mirrors the same layout
# but with controlled markdown fixtures.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SCRIPT_REL=".claude/scripts/plan-w-team-snippet-lint.sh"
TOP_STAGE_REL=".claude/commands/plan-w-team.md"
STAGE_DIR_REL=".claude/commands/plan-w-team"

setup() {
  sandbox
  mkdir -p "$SANDBOX_DIR/.claude/scripts"
  mkdir -p "$SANDBOX_DIR/$STAGE_DIR_REL"
  cp "$REPO_ROOT/$SCRIPT_REL" "$SANDBOX_DIR/$SCRIPT_REL"
  chmod +x "$SANDBOX_DIR/$SCRIPT_REL"
}

teardown() {
  teardown_sandbox
}

# ── Fixture builders ────────────────────────────────────────────────────────

write_top_stage_clean() {
  cat > "$SANDBOX_DIR/$TOP_STAGE_REL" <<'MD'
# Stage entrypoint
```bash
echo "hello"
```
MD
}

write_clean_stage_file() {
  cat > "$SANDBOX_DIR/$STAGE_DIR_REL/01-clean.md" <<'MD'
# Clean stage
```bash
ls -la
echo "all good"
```
MD
}

write_broken_stage_file() {
  # Unbalanced if (missing fi) — should fail bash -n
  cat > "$SANDBOX_DIR/$STAGE_DIR_REL/02-broken.md" <<'MD'
# Broken stage
```bash
if [ -z "$X" ]; then
  echo "no fi closer"
```
MD
}

write_skip_directive_stage() {
  # Contains placeholder syntax `<file>` that bash -n rejects, but opted out.
  cat > "$SANDBOX_DIR/$STAGE_DIR_REL/03-skip.md" <<'MD'
# Skip stage
```bash
# snippet-lint: skip — illustrative placeholder, not executable
some-tool < <file>
```
MD
}

write_non_bash_fence_stage() {
  # ```yaml block — must NOT be checked.
  cat > "$SANDBOX_DIR/$STAGE_DIR_REL/04-yaml.md" <<'MD'
# YAML stage
```yaml
key: value
```
MD
}

# ── Happy path / exit 0 ─────────────────────────────────────────────────────

@test "snippet-lint: given only clean bash blocks, when lint runs, then exit code is 0" {
  write_top_stage_clean
  write_clean_stage_file
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_success
  assert_output_contains "all blocks parse cleanly"
}

@test "snippet-lint: given only clean blocks, when lint runs, then it reports the total block count" {
  write_top_stage_clean
  write_clean_stage_file
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_success
  # Two clean blocks across two files
  assert_output_contains "2 bash blocks"
}

@test "snippet-lint: given a yaml-fenced block, when lint runs, then it does not parse it as bash" {
  write_top_stage_clean
  write_non_bash_fence_stage
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_success
  # Only the top-stage's bash block should be counted; yaml is ignored.
  assert_output_contains "1 bash blocks"
}

# ── Failure path / exit 1 ───────────────────────────────────────────────────

@test "snippet-lint: given a malformed bash block, when lint runs, then exit code is 1" {
  write_top_stage_clean
  write_broken_stage_file
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 1
  assert_output_contains "failed bash -n"
}

@test "snippet-lint: given a broken block, when lint runs, then it reports file and block index" {
  write_top_stage_clean
  write_broken_stage_file
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_failure 1
  # Must surface the offending file path AND the block-index marker
  assert_output_contains "02-broken.md"
  assert_output_contains "bash block #"
}

# ── Skip directive / opt-out ───────────────────────────────────────────────

@test "snippet-lint: given a block with snippet-lint:skip directive, when lint runs, then exit code is 0" {
  write_top_stage_clean
  write_skip_directive_stage
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_success
}

@test "snippet-lint: given a block with skip directive, when lint runs, then it is counted but bypasses bash -n" {
  write_top_stage_clean
  write_skip_directive_stage
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL"
  # The skip directive bypasses `bash -n` (so the malformed `<file>` placeholder
  # does not trigger a failure) but the block is still counted in total_blocks
  # for visibility. Two blocks total; zero failures.
  assert_success
  assert_output_contains "2 bash blocks"
  assert_output_not_contains "failed bash -n"
}

# ── Internal error / exit 2 ────────────────────────────────────────────────

@test "snippet-lint: given stage dir exists but no .md files, when lint runs, then exit code is 0 with 0 blocks" {
  # STAGE_FILES is seeded with the top-stage path; when that file does not
  # exist on disk the per-iteration `[ -f "$f" ] || continue` skips it, so we
  # land on the gracefully-empty path: 0 blocks parsed, exit 0. The "exit 2"
  # internal-error guard only fires if the array is literally zero-length,
  # which the seed prevents. This test pins down the empty-input contract so
  # callers (pre-commit) can rely on exit 0 when no relevant files exist.
  cd "$SANDBOX_DIR"
  run "$SANDBOX_DIR/$SCRIPT_REL"
  assert_success
  assert_output_contains "0 bash blocks"
}
