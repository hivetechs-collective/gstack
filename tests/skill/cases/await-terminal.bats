#!/usr/bin/env bats
# tests/skill/cases/await-terminal.bats
#
# Coverage for plan-w-team-await-terminal.sh — the event-driven supervisor wait
# (principle #2; replaces active polling on a guessed cadence). Pins: terminal
# detection via goal-state, heartbeat re-arm (NOT a cap), worker-gone debounce
# against the flaky `claude agents --json`, and that a present worker is never
# falsely reaped.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SCRIPT="$SCRIPTS_DIR/plan-w-team-await-terminal.sh"

setup() {
  SD="$(mktemp -d "${BATS_TMPDIR:-/tmp}/await-XXXXXX")"
}
teardown() { rm -rf "$SD"; }

@test "terminal_state present → exit 0 reporting the terminal state (instant wake)" {
  printf '{"slug":"t","terminal_state":"SUCCESS","terminal_reason":"retro-complete"}\n' > "$SD/plan-w-team-goal-t.json"
  run "$SCRIPT" --slug t --state-dir "$SD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"terminal=SUCCESS"* ]]
}

@test "USER_ESCALATION_HALT (sad path) is detected too" {
  printf '{"slug":"t","terminal_state":"USER_ESCALATION_HALT","terminal_reason":"push-ack"}\n' > "$SD/plan-w-team-goal-t.json"
  run "$SCRIPT" --slug t --state-dir "$SD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"terminal=USER_ESCALATION_HALT"* ]]
}

@test "no terminal + heartbeat → exit 3 re-arm (NOT a halt)" {
  printf '{"slug":"t","terminal_state":null}\n' > "$SD/plan-w-team-goal-t.json"
  run "$SCRIPT" --slug t --state-dir "$SD" --interval 1 --heartbeat 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"rearm"* ]]
}

@test "worker-gone is debounced and then reported (flaky-listing safe)" {
  printf '{"slug":"t","terminal_state":null}\n' > "$SD/plan-w-team-goal-t.json"
  # Valid non-empty listing that does NOT contain the watched sid → after
  # GONE_CONFIRM consecutive absences, report WORKER_GONE. Heartbeat high so the
  # gone path wins. CLAUDE_AGENTS_RAW is honored by claude-agents-extended.sh.
  run env CLAUDE_AGENTS_RAW='[{"sessionId":"other999-aaaa","kind":"background","status":"busy"}]' \
    PWT_AWAIT_GONE_CONFIRM=2 \
    "$SCRIPT" --slug t --worker-sid "missing12" --state-dir "$SD" --interval 1 --heartbeat 600
  [ "$status" -eq 0 ]
  [[ "$output" == *"WORKER_GONE"* ]]
}

@test "a worker still present in the listing is NOT reaped (heartbeat fires instead)" {
  printf '{"slug":"t","terminal_state":null}\n' > "$SD/plan-w-team-goal-t.json"
  run env CLAUDE_AGENTS_RAW='[{"sessionId":"present1-bbbb","kind":"background","status":"busy"}]' \
    PWT_AWAIT_GONE_CONFIRM=2 \
    "$SCRIPT" --slug t --worker-sid "present1" --state-dir "$SD" --interval 1 --heartbeat 2
  [ "$status" -eq 3 ]
  [[ "$output" == *"rearm"* ]]
  [[ "$output" != *"WORKER_GONE"* ]]
}

@test "§3.1: a flaky/empty base agents list does NOT report a false WORKER_GONE (--bg-only)" {
  # The round-2 audit's BROKEN finding: a flaky base `claude agents --json` ([])
  # masked by live subagents would falsely report a live worker gone. With
  # --bg-only the liveness check ignores subagents, so a flaky-empty base
  # degrades to [] → fails the length>0 guard → rearm, never WORKER_GONE.
  printf '{"slug":"t","terminal_state":null}\n' > "$SD/plan-w-team-goal-t.json"
  run env CLAUDE_AGENTS_RAW='[]' PWT_AWAIT_GONE_CONFIRM=1 \
    "$SCRIPT" --slug t --worker-sid "workr123" --state-dir "$SD" --interval 1 --heartbeat 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"rearm"* ]]
  [[ "$output" != *"WORKER_GONE"* ]]
}

# ── Worktree-aware resolution (PWT-WT1 collision fix; spec: supervisor-wait-worktree-aware.md) ──

@test "AC1/AC4: worktree-isolated terminal (main absent → worktree-present SUCCESS) wakes instantly, NOT on heartbeat" {
  # No --state-dir, no main goal-state. The worktree-isolated worker wrote SUCCESS
  # inside .claude/worktrees/<wt>/.claude/state/. High heartbeat so a heartbeat
  # re-arm would lose; instant terminal detection must win on the first tick.
  # No --worker-sid → detection is purely file-based ("worker idle at terminal").
  mkdir -p "$SD/.claude/worktrees/wt/.claude/state"
  printf '{"slug":"t","terminal_state":"SUCCESS","terminal_reason":"retro-complete in worktree"}\n' \
    > "$SD/.claude/worktrees/wt/.claude/state/plan-w-team-goal-t.json"
  run env PWT_PROJECT_ROOT_OVERRIDE="$SD" \
    "$SCRIPT" --slug t --interval 1 --heartbeat 600
  [ "$status" -eq 0 ]
  [[ "$output" == *"terminal=SUCCESS"* ]]
  [[ "$output" != *"rearm"* ]]
}

@test "AC2: main-present goal-state takes precedence over a worktree copy" {
  # Both exist; main carries SUCCESS, worktree copy is still null. The main path
  # must win (precedence), so SUCCESS is reported from main.
  mkdir -p "$SD/.claude/state" "$SD/.claude/worktrees/wt/.claude/state"
  printf '{"slug":"t","terminal_state":"SUCCESS","terminal_reason":"from-main"}\n' \
    > "$SD/.claude/state/plan-w-team-goal-t.json"
  printf '{"slug":"t","terminal_state":null}\n' \
    > "$SD/.claude/worktrees/wt/.claude/state/plan-w-team-goal-t.json"
  run env PWT_PROJECT_ROOT_OVERRIDE="$SD" \
    "$SCRIPT" --slug t --interval 1 --heartbeat 600
  [ "$status" -eq 0 ]
  [[ "$output" == *"terminal=SUCCESS"* ]]
  [[ "$output" == *"from-main"* ]]
}

@test "AC2: explicit --state-dir wins over both main and worktree copies" {
  # --state-dir carries SUCCESS; main (override) is null and a worktree copy is null.
  # The explicit override must take precedence and report SUCCESS.
  OD="$(mktemp -d "${BATS_TMPDIR:-/tmp}/await-override-XXXXXX")"
  printf '{"slug":"t","terminal_state":"SUCCESS","terminal_reason":"from-override"}\n' \
    > "$OD/plan-w-team-goal-t.json"
  mkdir -p "$SD/.claude/state" "$SD/.claude/worktrees/wt/.claude/state"
  printf '{"slug":"t","terminal_state":null}\n' > "$SD/.claude/state/plan-w-team-goal-t.json"
  printf '{"slug":"t","terminal_state":null}\n' > "$SD/.claude/worktrees/wt/.claude/state/plan-w-team-goal-t.json"
  run env PWT_PROJECT_ROOT_OVERRIDE="$SD" \
    "$SCRIPT" --slug t --state-dir "$OD" --interval 1 --heartbeat 600
  rm -rf "$OD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"terminal=SUCCESS"* ]]
  [[ "$output" == *"from-override"* ]]
}

@test "shadow: no goal-state anywhere → heartbeat re-arm, no crash" {
  # main absent, no worktree copy → resolver defaults to the (non-existent) main
  # path; the wait must not crash and must heartbeat re-arm (exit 3).
  mkdir -p "$SD/.claude/state"
  run env PWT_PROJECT_ROOT_OVERRIDE="$SD" \
    "$SCRIPT" --slug t --interval 1 --heartbeat 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"rearm"* ]]
}
