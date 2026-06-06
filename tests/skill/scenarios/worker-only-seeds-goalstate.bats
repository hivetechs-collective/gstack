#!/usr/bin/env bats
# tests/skill/scenarios/worker-only-seeds-goalstate.bats
#
# Scenario (PWT-WT2): pwt-goal.sh --worker-only deterministically SEEDS the
# goal-state file at spawn, so the self-hosted goal-evaluator's anti-skip anchor
# is active for the worktree-isolated bg worker — independent of whether the
# worker's LLM ever runs the manifest's PWT-T5b activation block.
#
# Bug ref: the 1.28.0 build-artifact worker c68e27ac pushed to origin then went
# idle BEFORE its consumer-sync DoD because NO goal-state file existed anywhere
# (the worker never ran PWT-T5b), so the evaluator saw "No active goal → exit 0"
# and nothing blocked the premature stop. See docs/specs/supervisor-wait-worktree-aware.md.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

PWT_GOAL="$REPO_ROOT/.claude/scripts/pwt-goal.sh"

setup() {
  sandbox
  # PROJECT_ROOT (= sandbox) must have a .claude/state dir, as a real checkout does.
  mkdir -p "$SANDBOX_DIR/.claude/state"
  # Stub `claude` so the --bg spawn emits a parseable SID without launching anything.
  STUB_DIR="$SANDBOX_DIR/.stub-bin"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/claude" <<'STUB_EOF'
#!/usr/bin/env bash
echo "backgrounded · deadbeef"
STUB_EOF
  chmod +x "$STUB_DIR/claude"
  export STUB_DIR
}

teardown() { teardown_sandbox; }

@test "AC3: pwt-goal.sh --worker-only seeds plan-w-team-goal-<SLUG>.json (terminal_state null) at spawn" {
  run env PATH="$STUB_DIR:$PATH" PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX_DIR" \
      PLAN_W_TEAM_DISABLE_RAM_GATE=1 PLAN_W_TEAM_DISABLE_DISK_GATE=1 \
      PLAN_W_TEAM_DISABLE_FAIR_SHARE=1 PLAN_W_TEAM_DISABLE_WORKTREE_CAP=1 \
      "$PWT_GOAL" --worker-only "ship the widget with tests"
  [ "$status" -eq 0 ]
  [[ "$output" == *"worker_sid=deadbeef"* ]]

  # Exactly one seeded goal-state file must exist in the launching checkout.
  shopt -s nullglob
  local seeds=( "$SANDBOX_DIR"/.claude/state/plan-w-team-goal-*.json )
  shopt -u nullglob
  [ "${#seeds[@]}" -eq 1 ]

  local seed="${seeds[0]}"
  # Anchor must be present-but-not-terminal so the evaluator BLOCKS premature stop.
  [ "$(jq -r '.terminal_state' "$seed")" = "null" ]
  [ "$(jq -r '.worker_sid' "$seed")" = "deadbeef" ]
  # feature_specific_done_criteria must be an (empty) array the worker's §1.5 fills.
  [ "$(jq -r '.feature_specific_done_criteria | type' "$seed")" = "array" ]
}
