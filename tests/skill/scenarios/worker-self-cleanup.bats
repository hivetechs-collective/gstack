#!/usr/bin/env bats
# tests/skill/scenarios/worker-self-cleanup.bats
#
# Scenario: when a worker reaches retro-complete, the self-cleanup contract
#           fires — `claude stop <SID>` is called for every registered child
#           and the SUCCESS goal-state file is removed.
# Bug ref:  feedback_pwt_must_self_cleanup (memory) — skill supervisor MUST
#           stop spawned `claude --bg` children at retro; every run must
#           surface a completion summary.
#
# The integration we test:
#   .claude/scripts/plan-w-team-child-cleanup.sh <SLUG>
#     reads .claude/state/plan-w-team-spawned-children-<SLUG>.jsonl
#     for each row, invokes `claude stop <SID>`
#     emits a JSON summary on stdout
#
#   .claude/scripts/plan-w-team-cleanup-stale-goal-states.sh
#     for each plan-w-team-goal-*.json with terminal_state=SUCCESS, deletes it

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

CHILD_CLEANUP="$REPO_ROOT/.claude/scripts/plan-w-team-child-cleanup.sh"
STALE_CLEANUP="$REPO_ROOT/.claude/scripts/plan-w-team-cleanup-stale-goal-states.sh"

setup() {
  sandbox
  # Stage a stub `claude` that records every `stop <SID>` call.
  STUB_DIR="$SANDBOX_DIR/.stub-bin"
  STUB_LOG="$SANDBOX_DIR/claude-stop.log"
  : > "$STUB_LOG"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/claude" <<STUB_EOF
#!/usr/bin/env bash
# Stub: record stop SID; exit 0 (success — child was stopped).
if [ "\${1:-}" = "stop" ]; then
  echo "stop \${2:-}" >> "$STUB_LOG"
  exit 0
fi
exit 0
STUB_EOF
  chmod +x "$STUB_DIR/claude"
  export STUB_DIR STUB_LOG

  # Stage the spawned-children manifest under the sandbox's .claude/state/.
  SLUG="self-cleanup-fixture-$$"
  STATE_DIR="$SANDBOX_DIR/.claude/state"
  mkdir -p "$STATE_DIR"
  MANIFEST="$STATE_DIR/plan-w-team-spawned-children-${SLUG}.jsonl"
  cat > "$MANIFEST" <<JSONL_EOF
{"session_id":"aaaa1111","purpose":"builder","parent_slug":"${SLUG}","registered_at":"2026-05-21T00:00:00Z"}
{"session_id":"bbbb2222","purpose":"evaluator","parent_slug":"${SLUG}","registered_at":"2026-05-21T00:00:01Z"}
{"session_id":"cccc3333","purpose":"reviewer","parent_slug":"${SLUG}","registered_at":"2026-05-21T00:00:02Z"}
JSONL_EOF
  export SLUG MANIFEST STATE_DIR
}

teardown() { teardown_sandbox; }

@test "worker-self-cleanup: given a manifest with 3 registered children, when child-cleanup runs, then claude stop is called for each SID" {
  run env CLAUDE_PROJECT_DIR="$SANDBOX_DIR" PATH="$STUB_DIR:$PATH" \
      "$CHILD_CLEANUP" "$SLUG"
  assert_success
  # All three SIDs must appear in the stop log.
  for sid in aaaa1111 bbbb2222 cccc3333; do
    if ! grep -qF "stop $sid" "$STUB_LOG"; then
      printf 'expected stop %s in log, got:\n%s\n' "$sid" "$(cat "$STUB_LOG")" >&2
      return 1
    fi
  done
}

@test "worker-self-cleanup: given a manifest with 3 registered children, when child-cleanup runs, then JSON summary reports registered=3 stopped=3" {
  run env CLAUDE_PROJECT_DIR="$SANDBOX_DIR" PATH="$STUB_DIR:$PATH" \
      "$CHILD_CLEANUP" "$SLUG"
  assert_success
  local registered stopped
  registered=$(jq -r '.registered' <<<"$output")
  stopped=$(jq -r '.stopped' <<<"$output")
  if [ "$registered" != "3" ]; then
    printf 'expected registered=3, got %s\n--- output ---\n%s\n' "$registered" "$output" >&2; return 1
  fi
  if [ "$stopped" != "3" ]; then
    printf 'expected stopped=3, got %s\n--- output ---\n%s\n' "$stopped" "$output" >&2; return 1
  fi
}

@test "worker-self-cleanup: given no manifest, when child-cleanup runs, then it reports skipped=true without error" {
  run env CLAUDE_PROJECT_DIR="$SANDBOX_DIR" PATH="$STUB_DIR:$PATH" \
      "$CHILD_CLEANUP" "nonexistent-slug-xyz"
  assert_success
  local skipped reason
  skipped=$(jq -r '.skipped' <<<"$output")
  reason=$(jq -r '.reason' <<<"$output")
  if [ "$skipped" != "true" ]; then
    printf 'expected skipped=true, got %s\n' "$skipped" >&2; return 1
  fi
  if [ "$reason" != "no registry" ]; then
    printf 'expected reason=no registry, got %s\n' "$reason" >&2; return 1
  fi
}

@test "worker-self-cleanup: given PLAN_W_TEAM_DISABLE_CHILD_CLEANUP=1, when child-cleanup runs, then it skips the loop" {
  run env CLAUDE_PROJECT_DIR="$SANDBOX_DIR" PATH="$STUB_DIR:$PATH" \
      PLAN_W_TEAM_DISABLE_CHILD_CLEANUP=1 "$CHILD_CLEANUP" "$SLUG"
  assert_success
  local skipped
  skipped=$(jq -r '.skipped' <<<"$output")
  if [ "$skipped" != "true" ]; then
    printf 'expected skipped=true under kill switch, got %s\n' "$skipped" >&2; return 1
  fi
  # And the stub must NOT have been invoked.
  if [ -s "$STUB_LOG" ]; then
    printf 'expected no stop calls under kill switch, got:\n%s\n' "$(cat "$STUB_LOG")" >&2; return 1
  fi
}

@test "worker-self-cleanup: given a SUCCESS goal-state file, when cleanup-stale-goal-states runs, then the file is removed" {
  # Stage a SUCCESS terminal-state file plus a non-SUCCESS sibling that must
  # be preserved.
  cat > "$STATE_DIR/plan-w-team-goal-self-cleanup-success-$$.json" <<EOF
{"slug":"self-cleanup-success-$$","terminal_state":"SUCCESS","terminal_reason":"retro-complete"}
EOF
  cat > "$STATE_DIR/plan-w-team-goal-self-cleanup-halt-$$.json" <<EOF
{"slug":"self-cleanup-halt-$$","terminal_state":"USER_ESCALATION_HALT","terminal_reason":"push-ack"}
EOF
  cat > "$STATE_DIR/plan-w-team-goal-self-cleanup-active-$$.json" <<EOF
{"slug":"self-cleanup-active-$$","terminal_state":null,"terminal_reason":null}
EOF

  run env STATE_DIR="$STATE_DIR" "$STALE_CLEANUP"
  assert_success
  # SUCCESS file must be gone
  if [ -f "$STATE_DIR/plan-w-team-goal-self-cleanup-success-$$.json" ]; then
    printf 'SUCCESS state file should have been removed\n' >&2; return 1
  fi
  # USER_ESCALATION_HALT file must be preserved
  if [ ! -f "$STATE_DIR/plan-w-team-goal-self-cleanup-halt-$$.json" ]; then
    printf 'USER_ESCALATION_HALT state file was unexpectedly removed\n' >&2; return 1
  fi
  # Active file must be preserved
  if [ ! -f "$STATE_DIR/plan-w-team-goal-self-cleanup-active-$$.json" ]; then
    printf 'Active (null terminal) state file was unexpectedly removed\n' >&2; return 1
  fi
}
