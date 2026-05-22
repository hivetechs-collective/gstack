#!/usr/bin/env bats
# tests/skill/scenarios/supervisor-idle-progresses.bats
#
# Scenario: when the supervisor's POLLING LOOP detects >5 minutes of
# user-input silence AND all monitored workers are terminal SUCCESS AND
# open PRs are CI-green AND no one-way-door tags, the supervisor
# auto-progresses per the decision matrix instead of remaining blocked
# on user input.
#
# Validates: supervisor-protocol.md POLLING LOOP gains a CONTINUATION
# CHECK step that names the idle-detection signal (transcript_path
# mtime), the threshold (>5 min default), and the action (apply matrix).
# pwt-goal.sh --supervisor-goal flag exists for the supervisor to run
# under /goal with documented merge authority.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

PROTOCOL="$REPO_ROOT/.claude/commands/plan-w-team/shared/supervisor-protocol.md"
PWT_GOAL="$REPO_ROOT/.claude/scripts/pwt-goal.sh"

@test "idle-progresses: POLLING LOOP has a CONTINUATION CHECK step" {
  grep -qiE "CONTINUATION CHECK|continuation check|continuation_check" "$PROTOCOL"
}

@test "idle-progresses: continuation check names idle-detection signal" {
  awk '/CONTINUATION CHECK|continuation check/,/^## /' "$PROTOCOL" \
    | grep -qiE "transcript|mtime|idle"
}

@test "idle-progresses: continuation check names the 5-minute threshold" {
  awk '/CONTINUATION CHECK|continuation check/,/^## /' "$PROTOCOL" \
    | grep -qE "5.*min|five.minutes|>5"
}

@test "idle-progresses: continuation check references decision matrix" {
  awk '/CONTINUATION CHECK|continuation check/,/^## /' "$PROTOCOL" \
    | grep -qiE "matrix|auto-merge|auto.progress"
}

@test "idle-progresses: pwt-goal.sh implements --supervisor-goal flag" {
  grep -qE "(\-\-supervisor-goal|SUPERVISOR_GOAL)" "$PWT_GOAL"
}

@test "idle-progresses: --supervisor-goal mirrors goal-state to origin .claude/state" {
  awk '/\-\-supervisor-goal|SUPERVISOR_GOAL/,/^$/' "$PWT_GOAL" \
    | grep -qE "\.claude/state|origin"
}
