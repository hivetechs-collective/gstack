#!/usr/bin/env bats
# tests/skill/scenarios/completion-summary-emits.bats
#
# Scenario: completion-summary writer (retro §8k) emits structured JSON + MD
#           with HOLISTIC_CHECK contract for spec-compliance.
#
# Spec: docs/specs/retro-completion-summary.md
# Holistic-check contract: docs/specs/reporting-holistic-check.md
#
# Each test seeds a synthetic worker transcript + AC snapshot in a sandbox,
# invokes the writer with $CLAUDE_TRANSCRIPT_PATH overriding discovery, and
# asserts on the emitted artifacts.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

WRITER="$REPO_ROOT/.claude/scripts/plan-w-team-completion-summary.sh"
SLUG="test-feat"

setup() {
  sandbox
  sandbox_git_init

  mkdir -p .claude/state docs/specs

  # Goal state — provides started_at for duration math.
  cat > ".claude/state/plan-w-team-goal-${SLUG}.json" <<EOF
{
  "slug": "${SLUG}",
  "started_at": "2026-05-22T00:00:00Z",
  "terminal_state": null
}
EOF
}

teardown() { teardown_sandbox; }

# ─── Helpers ─────────────────────────────────────────────────────────────────

seed_snapshot() {
  # $1 = newline-separated list of AC numbers (e.g. "1 2 3")
  local nums="$1"
  local snap=".claude/state/plan-w-team-ac-snapshot-${SLUG}.md"
  {
    echo "---"
    echo "slug: ${SLUG}"
    echo "spec_path: docs/specs/${SLUG}.md"
    echo "---"
    echo "## Acceptance Criteria"
    echo ""
    for n in $nums; do
      echo "- [ ] AC${n}: synthetic criterion ${n}"
    done
  } > "$snap"
}

seed_transcript() {
  # $1 = lines to put into a fake transcript .jsonl
  local body="$1"
  local tx="$SANDBOX_DIR/fake-transcript.jsonl"
  printf '%s\n' "$body" > "$tx"
  export CLAUDE_TRANSCRIPT_PATH="$tx"
}

# ─── AC1 happy path: every declared AC has a PASS verdict ────────────────────

@test "completion-summary AC1: all declared ACs PASS -> HOLISTIC_CHECK_PASS" {
  seed_snapshot "1 2 3"
  seed_transcript "AC1: PASS
AC2: PASS
AC3: PASS"

  run "$WRITER" "$SLUG"
  assert_success

  # JSON
  run jq -r '.ac_rollup.holistic_check' ".claude/state/plan-w-team-completion-${SLUG}.json"
  assert_success
  [ "$output" = "PASS" ]

  # MD anchor literal
  run grep -F "HOLISTIC_CHECK_PASS" ".claude/state/plan-w-team-completion-${SLUG}.md"
  assert_success
}

# ─── AC2: declared AC missing a verdict in the transcript ────────────────────

@test "completion-summary AC2: declared AC missing a verdict -> HOLISTIC_CHECK_FAIL with missing list" {
  seed_snapshot "1 2 3"
  seed_transcript "AC1: PASS
AC2: PASS"
  # AC3 has no verdict

  run "$WRITER" "$SLUG"
  assert_success

  run jq -r '.ac_rollup.holistic_check' ".claude/state/plan-w-team-completion-${SLUG}.json"
  assert_success
  [ "$output" = "FAIL" ]

  run jq -r '.ac_rollup.missing | join(",")' ".claude/state/plan-w-team-completion-${SLUG}.json"
  assert_success
  [ "$output" = "AC3" ]

  run grep -F "HOLISTIC_CHECK_FAIL" ".claude/state/plan-w-team-completion-${SLUG}.md"
  assert_success
}

# ─── AC3: spec declares no ACs (docs-only feature) ───────────────────────────

@test "completion-summary AC3: no declared ACs in spec -> HOLISTIC_CHECK_SKIPPED" {
  seed_snapshot ""  # empty list → no AC lines
  seed_transcript "(no verdicts emitted)"

  run "$WRITER" "$SLUG"
  assert_success

  run jq -r '.ac_rollup.holistic_check' ".claude/state/plan-w-team-completion-${SLUG}.json"
  assert_success
  [ "$output" = "SKIPPED" ]

  run grep -F "HOLISTIC_CHECK_SKIPPED" ".claude/state/plan-w-team-completion-${SLUG}.md"
  assert_success
}

# ─── AC4: transcript discovery falls through ─────────────────────────────────

@test "completion-summary AC4: transcript discovery fails -> HOLISTIC_CHECK_UNKNOWN" {
  seed_snapshot "1 2"
  # Force discovery to fail by:
  #   1. Clearing the explicit override
  #   2. Pointing CLAUDE_PROJECT_DIR at a non-existent path
  #   3. Pointing HOME at the sandbox so ~/.claude/projects scan finds nothing
  unset CLAUDE_TRANSCRIPT_PATH || true
  export CLAUDE_PROJECT_DIR="$SANDBOX_DIR/no-such-dir"
  export HOME="$SANDBOX_DIR/fake-home"

  run "$WRITER" "$SLUG"
  assert_success

  run jq -r '.ac_rollup.holistic_check' ".claude/state/plan-w-team-completion-${SLUG}.json"
  assert_success
  [ "$output" = "UNKNOWN" ]

  run grep -F "HOLISTIC_CHECK_UNKNOWN" ".claude/state/plan-w-team-completion-${SLUG}.md"
  assert_success
}

# ─── AC5: missing SLUG argument is a caller-bug exit 2 ───────────────────────

@test "completion-summary AC5: missing SLUG arg -> exit 2 with usage" {
  run "$WRITER"
  assert_failure 2
}

# ─── AC6: idempotency — re-running overwrites prior output ───────────────────

@test "completion-summary AC6: second run with different transcript overwrites prior summary" {
  seed_snapshot "1"
  seed_transcript "AC1: PASS"
  run "$WRITER" "$SLUG"
  assert_success
  run jq -r '.ac_rollup.holistic_check' ".claude/state/plan-w-team-completion-${SLUG}.json"
  [ "$output" = "PASS" ]

  # Now seed a transcript with AC1 FAILing and re-run
  seed_transcript "AC1: FAIL"
  run "$WRITER" "$SLUG"
  assert_success
  run jq -r '.ac_rollup.holistic_check' ".claude/state/plan-w-team-completion-${SLUG}.json"
  [ "$output" = "PASS" ]  # FAIL is still in the declared set, so PASS holds (all ACs verdicted)
  run jq -r '.ac_rollup.failed | join(",")' ".claude/state/plan-w-team-completion-${SLUG}.json"
  [ "$output" = "AC1" ]
}

# ─── AC7: emitted JSON is valid and contains required top-level keys ─────────

@test "completion-summary AC7: JSON is parseable and has required schema keys" {
  seed_snapshot "1"
  seed_transcript "AC1: PASS"
  run "$WRITER" "$SLUG"
  assert_success

  local f=".claude/state/plan-w-team-completion-${SLUG}.json"
  run jq -e '.slug and .generated_at and .writer_version and .ac_rollup and .git and .tests and .ship' "$f"
  assert_success
}

# ─── AC8: MD includes ## Spec Compliance Check section ───────────────────────

@test "completion-summary AC8: MD always includes Spec Compliance Check section" {
  seed_snapshot "1 2"
  seed_transcript "AC1: PASS
AC2: PASS"
  run "$WRITER" "$SLUG"
  assert_success

  run grep -E '^## Spec Compliance Check' ".claude/state/plan-w-team-completion-${SLUG}.md"
  assert_success
}

# ─── AC9: writer exits 0 even on internal failure paths (R10 safety) ─────────

@test "completion-summary AC9: writer returns 0 on missing snapshot (safety)" {
  # No snapshot, no transcript — should still exit 0 with a degraded summary.
  unset CLAUDE_TRANSCRIPT_PATH || true
  export CLAUDE_PROJECT_DIR="$SANDBOX_DIR/no-such-dir"

  run "$WRITER" "$SLUG"
  assert_success

  [ -f ".claude/state/plan-w-team-completion-${SLUG}.json" ]
  [ -f ".claude/state/plan-w-team-completion-${SLUG}.md" ]
}
