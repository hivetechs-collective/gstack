#!/usr/bin/env bats
# tests/skill/scenarios/goal-cap-aborts-spawn.bats
#
# Scenario: pwt-goal.sh --worker-only refuses to spawn when the derived /goal
#           directive exceeds Anthropic's 4000-char runtime cap.
# Bug ref:  Bug 3 — without the cap-enforcement, an oversize directive would
#           be passed to `claude --bg`, /goal would silently reject it
#           ("Goal condition is limited to 4000 characters"), and the worker
#           would idle indefinitely instead of running the pipeline.
#
# This scenario runs pwt-goal.sh directly with an oversize request and asserts
# the cap fires with exit 2 BEFORE any `claude --bg` spawn happens. We don't
# go through the shim/route-hook for this scenario because the failure mode
# lives in pwt-goal.sh's preflight, not in the hook's stdin/stdout contract.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

PWT_GOAL="$REPO_ROOT/.claude/scripts/pwt-goal.sh"

setup() {
  sandbox
  # Stage a stub `claude` so any accidental spawn is caught (we should never
  # see it invoked — the cap should fire first).
  STUB_DIR="$SANDBOX_DIR/.stub-bin"
  STUB_LOG="$SANDBOX_DIR/stub.log"
  : > "$STUB_LOG"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/claude" <<STUB_EOF
#!/usr/bin/env bash
echo "argv: \$*" >> "$STUB_LOG"
echo "backgrounded · deadbeef"
STUB_EOF
  chmod +x "$STUB_DIR/claude"
  export STUB_DIR STUB_LOG
}

teardown() { teardown_sandbox; }

@test "goal-cap-aborts-spawn: given a request whose derived /goal exceeds 4000 chars, when pwt-goal.sh --worker-only runs, then exit code is 2" {
  # Build an oversize request: 4500 chars of repetition + minimal verb.
  local big
  big="Use /plan-w-team to do something verbose: "
  local i
  for i in $(seq 1 100); do
    big+="lorem ipsum dolor sit amet consectetur adipiscing elit chunk ${i}. "
  done
  # Sanity: confirm request alone is ~5000+ chars so the derived directive
  # (request + skeleton overhead) easily exceeds the 4000 cap.
  if [ "${#big}" -lt 4500 ]; then
    skip "fixture builder produced ${#big} chars, expected >=4500"
  fi

  # Overflow-to-disk (2026-05-22) would otherwise intercept this case before
  # the cap fires. We're explicitly testing the cap, so disable overflow with
  # a sky-high threshold.
  run env PATH="$STUB_DIR:$PATH" PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX_DIR" \
      PLAN_W_TEAM_OVERFLOW_THRESHOLD=10000000 \
      "$PWT_GOAL" --worker-only "$big"
  assert_failure 2
}

@test "goal-cap-aborts-spawn: given a request whose derived /goal exceeds 4000 chars, when pwt-goal.sh --worker-only runs, then stderr names the cap and exceedance" {
  local big
  big="Use /plan-w-team to do something: "
  local i
  for i in $(seq 1 100); do
    big+="lorem ipsum dolor sit amet consectetur adipiscing elit chunk ${i}. "
  done

  # Overflow-to-disk (2026-05-22) would otherwise intercept this case before
  # the cap fires. We're explicitly testing the cap, so disable overflow with
  # a sky-high threshold.
  run env PATH="$STUB_DIR:$PATH" PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX_DIR" \
      PLAN_W_TEAM_OVERFLOW_THRESHOLD=10000000 \
      "$PWT_GOAL" --worker-only "$big"
  assert_failure 2
  assert_output_contains "4000-char runtime cap"
}

@test "goal-cap-aborts-spawn: given a request whose derived /goal exceeds 4000 chars, when pwt-goal.sh --worker-only runs, then no claude --bg invocation occurs" {
  local big
  big="Use /plan-w-team to do something verbose: "
  local i
  for i in $(seq 1 100); do
    big+="lorem ipsum dolor sit amet consectetur adipiscing elit chunk ${i}. "
  done

  # Overflow-to-disk (2026-05-22) would otherwise intercept this case before
  # the cap fires. We're explicitly testing the cap, so disable overflow with
  # a sky-high threshold.
  run env PATH="$STUB_DIR:$PATH" PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX_DIR" \
      PLAN_W_TEAM_OVERFLOW_THRESHOLD=10000000 \
      "$PWT_GOAL" --worker-only "$big"
  assert_failure 2
  # Stub log must be empty — claude was never invoked.
  if [ -s "$STUB_LOG" ]; then
    printf 'expected no claude invocations, got:\n%s\n' "$(cat "$STUB_LOG")" >&2
    return 1
  fi
}

@test "goal-cap-aborts-spawn: given PLAN_W_TEAM_GOAL_MAX raises the cap, when pwt-goal.sh --worker-only runs, then override is honored" {
  # Same oversize fixture, but with a higher cap → no cap failure, spawn
  # proceeds. We don't run the real spawn (stubbed); we just observe that
  # the cap diagnostic is NOT emitted, confirming the env override path
  # works as documented in pwt-goal.sh.
  local big
  big="Use /plan-w-team to do something verbose: "
  local i
  for i in $(seq 1 100); do
    big+="lorem ipsum dolor sit amet consectetur adipiscing elit chunk ${i}. "
  done

  # PWT_PROJECT_ROOT_OVERRIDE pins pwt-goal.sh's registration helper to the
  # sandbox so the cap-override path doesn't pollute the real repo's
  # pwt-launches.jsonl / spawned-children manifests during test runs.
  mkdir -p "$SANDBOX_DIR/.claude/state"
  run env PATH="$STUB_DIR:$PATH" \
      PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX_DIR" \
      PLAN_W_TEAM_GOAL_MAX=20000 "$PWT_GOAL" --worker-only "$big"
  # When cap is raised, the script proceeds past preflight. The stub will be
  # called; output should NOT carry the cap diagnostic.
  if printf '%s' "$output" | grep -qF "exceeds Anthropic's"; then
    printf 'cap diagnostic appeared even with PLAN_W_TEAM_GOAL_MAX=20000 override\n--- output ---\n%s\n' "$output" >&2
    return 1
  fi
}
