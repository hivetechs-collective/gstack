#!/usr/bin/env bats
# tests/skill/scenarios/worker-cascade-blocked.bats
#
# Scenario: pwt-goal.sh refuses to spawn when running inside a /plan-w-team
#           worker session (cascade prevention).
# Bug ref:  Bug B (cascade) — 2026-05-22. Worker 85420913's goal text contained
#           "Use /plan-w-team to..." (verbatim from pwt-goal.sh's template).
#           Its LLM read the goal, matched the manifest's trigger pattern, and
#           called pwt-goal.sh AGAIN, producing a recursive cascade. Worker
#           c00b9887 used --launch (not --worker-only), bypassing PWT-DS1.
#
# PWT-DS2 (cascade guard) refuses when PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 is in
# env AND either --worker-only or --launch is requested. Covers both paths.
#
# This scenario calls pwt-goal.sh directly (no shim/route-hook) because the
# failure mode lives in pwt-goal.sh's preflight, not in the hook contract.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

PWT_GOAL="$REPO_ROOT/.claude/scripts/pwt-goal.sh"

setup() {
  sandbox
  # Stub `claude` so any accidental spawn is caught (we should never see it).
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

@test "worker-cascade-blocked: inside worker (--worker-only) → exit 4" {
  PATH="$STUB_DIR:$PATH" \
  PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 \
    run "$PWT_GOAL" --worker-only "test request"
  [ "$status" -eq 4 ]
  [[ "$output" == *"Worker-cascade refused"* ]]
}

@test "worker-cascade-blocked: inside worker (--launch) → exit 4" {
  # Previously unguarded — PWT-DS1 only covered --worker-only
  PATH="$STUB_DIR:$PATH" \
  PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 \
    run "$PWT_GOAL" --launch "test request"
  [ "$status" -eq 4 ]
  [[ "$output" == *"Worker-cascade refused"* ]]
}

@test "worker-cascade-blocked: stderr cites the env signal" {
  PATH="$STUB_DIR:$PATH" \
  PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 \
    run "$PWT_GOAL" --worker-only "test"
  [[ "$output" == *"PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1"* ]]
}

@test "worker-cascade-blocked: stderr documents the OUT-OF-BAND operator escape hatch (C6)" {
  PATH="$STUB_DIR:$PATH" \
  PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 \
    run "$PWT_GOAL" --worker-only "test"
  # C6: in-worker the bypass is the out-of-band PLAN_W_TEAM_OPERATOR_FORCE_SPAWN,
  # NOT PLAN_W_TEAM_FORCE_SPAWN — a worker's own LLM could self-set the latter
  # straight from this stderr (the original cascade bug).
  [[ "$output" == *"PLAN_W_TEAM_OPERATOR_FORCE_SPAWN=1"* ]]
}

@test "worker-cascade-blocked: in-worker FORCE_SPAWN does NOT bypass (C6)" {
  PATH="$STUB_DIR:$PATH" \
  PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 \
  PLAN_W_TEAM_FORCE_SPAWN=1 \
    run "$PWT_GOAL" --launch "test request"
  # FORCE_SPAWN is self-authorizable by a worker → in-worker it must NOT bypass.
  [ "$status" -eq 4 ]
}

@test "worker-cascade-blocked: in-worker OPERATOR_FORCE_SPAWN bypasses (C6)" {
  PATH="$STUB_DIR:$PATH" \
  PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 \
  PLAN_W_TEAM_OPERATOR_FORCE_SPAWN=1 \
    run "$PWT_GOAL" --launch "test request"
  # The out-of-band operator signal IS allowed to bypass the cascade guard.
  [ "$status" -ne 4 ]
}

@test "worker-cascade-blocked: outside worker (no env var) → normal" {
  # Sanity: when PLAN_W_TEAM_DISABLE_PROMPT_ROUTE is unset, no cascade guard fires.
  # Use the non-launch mode so we just print the goal text without spawning.
  run "$PWT_GOAL" "test request"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/goal Use /plan-w-team to test request"* ]]
}

@test "worker-cascade-blocked: stub claude never invoked when guard fires" {
  PATH="$STUB_DIR:$PATH" \
  PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 \
    "$PWT_GOAL" --worker-only "test" >/dev/null 2>&1 || true
  # stub log should be empty — no spawn occurred
  [ ! -s "$STUB_LOG" ]
}
