#!/usr/bin/env bats
# tests/skill/cases/block-gh-actions-build.bats
#
# Coverage for the P9b enforcement hook (block-gh-actions-build.sh). The
# No-GitHub-Actions-for-build/CI/deploy rule self-labeled "ENFORCING" but nothing
# blocked a workflow write — §6b-bis only echo'd. This hook makes it real.
#
# Audit: P9b (docs/operations/pwt-principles-enforcement-audit-2026-06-02.md).

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

HOOK="$HOOKS_DIR/block-gh-actions-build.sh"

setup() { TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ghguard-XXXXXX")"; }
teardown() { rm -rf "$TMP"; }

BUILD_WF=$'on:\n  push:\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm ci && npm test\n'
OBS_WF=$'on:\n  workflow_run:\njobs:\n  notify:\n    steps:\n      - run: echo alert\n'

# write_input <file_path> <content> [key]   (key defaults to "content")
write_input() {
  local key="${3:-content}"
  jq -nc --arg fp "$1" --arg c "$2" --arg k "$key" '{tool_input:({file_path:$fp} + {($k):$c})}' > "$TMP/in.json"
}

@test "P9b: a build/CI workflow under .github/workflows is BLOCKED" {
  write_input ".github/workflows/build.yml" "$BUILD_WF"
  run bash -c "'$HOOK' < '$TMP/in.json'"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"decision": "block"'* ]]
  [[ "$output" == *"PWT-P9b"* ]]
}

@test "P9b: an observer workflow (ci-alert*) is ALLOWED" {
  write_input ".github/workflows/ci-alert.yml" "$OBS_WF"
  run bash -c "'$HOOK' < '$TMP/in.json'"
  [ "$status" -eq 0 ]
}

@test "P9b: a non-workflow file is ALLOWED even if its text mentions jobs/run" {
  write_input "src/app.ts" "$BUILD_WF"
  run bash -c "'$HOOK' < '$TMP/in.json'"
  [ "$status" -eq 0 ]
}

@test "P9b: a workflow with no jobs/run steps is ALLOWED" {
  write_input ".github/workflows/docs.yml" "name: docs only"
  run bash -c "'$HOOK' < '$TMP/in.json'"
  [ "$status" -eq 0 ]
}

@test "P9b: an Edit (new_string) adding a build step is BLOCKED" {
  write_input ".github/workflows/build.yml" "$BUILD_WF" "new_string"
  run bash -c "'$HOOK' < '$TMP/in.json'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PWT-P9b"* ]]
}

@test "P9b: kill switch PLAN_W_TEAM_DISABLE_GH_ACTIONS_GUARD=1 disables the block" {
  write_input ".github/workflows/build.yml" "$BUILD_WF"
  run bash -c "PLAN_W_TEAM_DISABLE_GH_ACTIONS_GUARD=1 '$HOOK' < '$TMP/in.json'"
  [ "$status" -eq 0 ]
}

@test "P9b: a MultiEdit introducing a build workflow is BLOCKED (round-2 §4 — edits[] parse)" {
  jq -nc --arg fp ".github/workflows/build.yml" --arg ns "$BUILD_WF" \
    '{tool_input:{file_path:$fp,edits:[{old_string:"",new_string:$ns}]}}' > "$TMP/in.json"
  run bash -c "'$HOOK' < '$TMP/in.json'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PWT-P9b"* ]]
}

@test "round-2 §4: a MultiEdit matcher is registered for both security hooks (no bypass)" {
  run python3 -c "
import json,sys
d=json.load(open('$REPO_ROOT/.claude/settings.json'))
pt=d.get('hooks',{}).get('PreToolUse',[])
cmds=' '.join(h.get('command','') for m in pt if m.get('matcher')=='MultiEdit' for h in m.get('hooks',[]))
sys.exit(0 if ('block-protected-paths' in cmds and 'block-gh-actions-build' in cmds) else 1)"
  [ "$status" -eq 0 ]
}
