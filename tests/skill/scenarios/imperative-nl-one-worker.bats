#!/usr/bin/env bats
# tests/skill/scenarios/imperative-nl-one-worker.bats
#
# Scenario: imperative natural-language /plan-w-team trigger spawns
#           EXACTLY one bg worker.
# Bug ref:  4f83172 (Step 3a guard was checking dropped additionalContext;
#                    fix was to switch the marker check to systemMessage,
#                    eliminating double-spawn when both hook + skill manifest
#                    fired their own pwt-goal.sh launchers.)
#
# Verifies that the route hook fires once on a clean imperative trigger,
# spawns one (and only one) bg worker, delivers the supervisor-protocol
# systemMessage to the assistant, and drops additionalContext per the
# 2026-05-21 harness audit.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"
load "$BATS_TEST_DIRNAME/../helpers/scenario_helper.bash"

setup() {
  scenario_sandbox
  USER_PROMPT='Use /plan-w-team to add a thing.'
}

teardown() { scenario_teardown; }

@test "imperative-nl-one-worker: given an imperative trigger, when shim runs hook, then exactly 1 bg worker is spawned" {
  run_shim "$USER_PROMPT"
  assert_success
  assert_simctx_bg_count 1
}

@test "imperative-nl-one-worker: given an imperative trigger, when shim runs hook, then supervisor marker is delivered to assistant" {
  run_shim "$USER_PROMPT"
  assert_success
  assert_simctx_marker "/plan-w-team origin-chat supervisor active"
}

@test "imperative-nl-one-worker: given an imperative trigger, when shim runs hook, then additionalContext is dropped (harness contract)" {
  run_shim "$USER_PROMPT"
  assert_success
  assert_simctx_addctx_dropped true
}

@test "imperative-nl-one-worker: given an imperative trigger, when shim runs hook, then worker bg argv contains the /goal directive prefix" {
  run_shim "$USER_PROMPT"
  assert_success
  assert_simctx_bg_argv_contains 0 "/goal"
}

@test "imperative-nl-one-worker: given an imperative trigger, when shim runs hook, then hook exits 0 (non-blocking)" {
  run_shim "$USER_PROMPT"
  assert_success
  assert_simctx_hook_exit 0
}
