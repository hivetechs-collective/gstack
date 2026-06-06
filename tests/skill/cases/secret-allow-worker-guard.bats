#!/usr/bin/env bats
# tests/skill/cases/secret-allow-worker-guard.bats
#
# Regression guard for audit C4 — the secret-scan-allow hard-gate must not be
# self-clearable by a bg /plan-w-team worker.
#
# 05-ship.md §6a-ter enforces the secret gate by FILE PRESENCE
# (plan-w-team-secret-scan-allow-<slug> → scanner runs with --allow). Nothing
# stopped a bg worker's own LLM from Writing that file to suppress a real secret
# finding with no human review. block-protected-paths.sh (registered PreToolUse
# Write+Edit) now refuses such a write when the in-worker marker
# PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 is set, while leaving interactive
# (human-operator) writes untouched.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

HOOK="$HOOKS_DIR/block-protected-paths.sh"
ALLOW_JSON='{"tool_input":{"file_path":"/repo/.claude/state/plan-w-team-secret-scan-allow-myslug"}}'
GOAL_JSON='{"tool_input":{"file_path":"/repo/.claude/state/plan-w-team-goal-myslug.json"}}'

@test "C4: in-worker write to the secret-scan-allow file is BLOCKED" {
  run env PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 bash -c "printf '%s' '$ALLOW_JSON' | '$HOOK'"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"decision": "block"'* ]]
  [[ "$output" == *"PWT-C4"* ]]
}

@test "C4: interactive (no in-worker marker) write to the allow-file is ALLOWED" {
  run env -u PLAN_W_TEAM_DISABLE_PROMPT_ROUTE bash -c "printf '%s' '$ALLOW_JSON' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "C4: in-worker write to an unrelated state file is ALLOWED (guard is scoped)" {
  run env PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 bash -c "printf '%s' '$GOAL_JSON' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "C4: an in-worker MultiEdit to the allow-file is BLOCKED (round-2 §4 — no MultiEdit bypass)" {
  json=$(jq -nc --arg fp "/repo/.claude/state/plan-w-team-secret-scan-allow-myslug" \
    '{tool_input:{file_path:$fp,edits:[{old_string:"a",new_string:"b"}]}}')
  run env PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 bash -c "printf '%s' '$json' | '$HOOK'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PWT-C4"* ]]
}
