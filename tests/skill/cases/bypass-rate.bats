#!/usr/bin/env bats
# tests/skill/cases/bypass-rate.bats
#
# Coverage for the P1 retro accountability signal
# (.claude/scripts/plan-w-team-bypass-rate.sh). Turns the previously-fictional
# "retros MAY count the stage-file-bypass marker" into a deterministic,
# tested count → 1-5 score.
#
# Audit: P1 (docs/operations/pwt-principles-enforcement-audit-2026-06-02.md).

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SCRIPT="$SCRIPTS_DIR/plan-w-team-bypass-rate.sh"

setup() { SD="$(mktemp -d "${BATS_TMPDIR:-/tmp}/bypass-XXXXXX")"; }
teardown() { rm -rf "$SD"; }

@test "missing bypass log → count 0, score 5 (no error)" {
  run "$SCRIPT" --slug t --state-dir "$SD"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.count')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.score')" -eq 5 ]
}

@test "two markers → count 2, score 3" {
  printf '⚠ stage-file-bypass: skipping 02-task-breakdown — already loaded\n⚠ stage-file-bypass: skipping 05-ship — doc-only\n' \
    > "$SD/plan-w-team-bypass-t.log"
  run "$SCRIPT" --slug t --state-dir "$SD"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.count')" -eq 2 ]
  [ "$(echo "$output" | jq -r '.score')" -eq 3 ]
}

@test "empty bypass log → count 0, score 5" {
  : > "$SD/plan-w-team-bypass-t.log"
  run "$SCRIPT" --slug t --state-dir "$SD"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.count')" -eq 0 ]
  [ "$(echo "$output" | jq -r '.score')" -eq 5 ]
}

@test "many markers floor the score at 1" {
  for i in 1 2 3 4 5 6; do printf '⚠ stage-file-bypass: skip %s\n' "$i"; done > "$SD/plan-w-team-bypass-t.log"
  run "$SCRIPT" --slug t --state-dir "$SD"
  [ "$(echo "$output" | jq -r '.count')" -eq 6 ]
  [ "$(echo "$output" | jq -r '.score')" -eq 1 ]
}
