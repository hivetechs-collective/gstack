#!/usr/bin/env bats
# tests/skill/cases/stop-hook-block-cap.bats
#
# Regression guard for PWT-P3 / C1 — the "no wall-clock or turn caps" principle.
#
# Claude Code defaults the consecutive-Stop-hook block cap to 8. The /plan-w-team
# goal-evaluator blocks the Stop hook every turn until terminal, so a full run
# blocks far more than 8 times. Without a raised cap, a bg worker is silently
# force-stopped mid-pipeline after ~8 evaluator blocks — defeating P3 and P12 for
# the canonical autonomous (--launch / --worker-only) path.
#
# Two enforcement points, both pinned here:
#   1. .claude/settings.json env raises the cap repo-wide (interactive + synced
#      consumers; settings.json is rsync'd wholesale by sync-to-project.sh).
#   2. pwt-goal.sh propagates the cap into LAUNCH_ENV so the spawned bg worker
#      inherits it (a --bg/headless session never sources ~/.zshrc).
#
# See docs/operations/pwt-principles-enforcement-audit-2026-06-02.md (P3/C1).

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

@test "settings.json env sets CLAUDE_CODE_STOP_HOOK_BLOCK_CAP" {
  run jq -er '.env.CLAUDE_CODE_STOP_HOOK_BLOCK_CAP' "$REPO_ROOT/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "block cap is well above the default of 8 (>= 100)" {
  cap="$(jq -r '.env.CLAUDE_CODE_STOP_HOOK_BLOCK_CAP' "$REPO_ROOT/.claude/settings.json")"
  # numeric and comfortably above the default-8 ceiling a full run would hit
  [[ "$cap" =~ ^[0-9]+$ ]]
  [ "$cap" -ge 100 ]
}

@test "pwt-goal.sh propagates the block cap into LAUNCH_ENV (covers --launch and --worker-only)" {
  run grep -n 'LAUNCH_ENV=.*CLAUDE_CODE_STOP_HOOK_BLOCK_CAP' "$SCRIPTS_DIR/pwt-goal.sh"
  [ "$status" -eq 0 ]
}
