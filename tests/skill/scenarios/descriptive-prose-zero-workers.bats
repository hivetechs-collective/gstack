#!/usr/bin/env bats
# tests/skill/scenarios/descriptive-prose-zero-workers.bats
#
# Scenario: descriptive prose that contains the trigger substring (but is
#           clearly NOT an imperative request) must NOT spawn a worker.
# Bug ref:  Bug 1 (classifier) — a previous fix added the
#           imperative-vs-descriptive classifier to the route hook so that
#           messages quoting or describing /plan-w-team usage don't fire it.
#
# Two fixtures cover the two strongest descriptive signals:
#   (a) metaphrase: "the manifest says use /plan-w-team to ..." — METAPHRASES rule
#   (b) interrogative: "Should I use /plan-w-team to ...?" — rule 7

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"
load "$BATS_TEST_DIRNAME/../helpers/scenario_helper.bash"

setup() { scenario_sandbox; }
teardown() { scenario_teardown; }

@test "descriptive-prose-zero-workers: given a metaphrase prose mentioning the trigger, when shim runs hook, then 0 bg workers are spawned" {
  run_shim "The manifest says use /plan-w-team to ship features. I'm reading it to understand the contract."
  assert_success
  assert_simctx_bg_count 0
}

@test "descriptive-prose-zero-workers: given a metaphrase prose mentioning the trigger, when shim runs hook, then no sysmsg is delivered" {
  run_shim "The manifest says use /plan-w-team to ship features. I'm reading it to understand the contract."
  assert_success
  assert_simctx_no_marker
}

@test "descriptive-prose-zero-workers: given an interrogative trigger phrase, when shim runs hook, then 0 bg workers are spawned" {
  run_shim "Should I use /plan-w-team to add foo?"
  assert_success
  assert_simctx_bg_count 0
}

@test "descriptive-prose-zero-workers: given an interrogative trigger phrase, when shim runs hook, then no sysmsg is delivered" {
  run_shim "Should I use /plan-w-team to add foo?"
  assert_success
  assert_simctx_no_marker
}

@test "descriptive-prose-zero-workers: given a quoted/descriptive trigger phrase, when shim runs hook, then 0 bg workers are spawned" {
  # The substring is inside a quoted span — classifier rule 1 (is_inside_quote)
  # should suppress firing.
  run_shim 'The user said "use /plan-w-team to ship the API" but they were describing past behavior.'
  assert_success
  assert_simctx_bg_count 0
}
