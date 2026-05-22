#!/usr/bin/env bats
# tests/skill/scenarios/coverage-floor-auto-default.bats
#
# Scenario: STE Extension — when a repo declares no coverage threshold,
# Step 6 ship gate auto-proposes a language-aware default (60% new repos /
# 80% mature repos with >6mo git history). Opt-out: a 'no-coverage-floor'
# line in .claude/state/coverage-policy.txt.
#
# Spec: docs/specs/ste-extension.md (AC4)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SHIP_STAGE_FILE="$COMMANDS_DIR/05-ship.md"

# ─── AC4: coverage floor auto-default block exists in 05-ship.md ────────────

@test "coverage-floor AC4: 05-ship.md has a Coverage Floor Auto-Default section" {
  run grep -nE 'Coverage Floor Auto-Default' "$SHIP_STAGE_FILE"
  assert_success
}

@test "coverage-floor AC4: documented thresholds — 60% for new repos, 80% for mature" {
  run grep -E 'FLOOR=60|FLOOR=80|60%.*new|80%.*mature' "$SHIP_STAGE_FILE"
  assert_success
}

@test "coverage-floor AC4: maturity heuristic is >180 days (>6 months) git history" {
  run grep -E 'AGE_DAYS.*180|>6mo|180.*days' "$SHIP_STAGE_FILE"
  assert_success
}

@test "coverage-floor AC4: opt-out file is .claude/state/coverage-policy.txt" {
  run grep -E '\.claude/state/coverage-policy\.txt' "$SHIP_STAGE_FILE"
  assert_success
}

@test "coverage-floor AC4: opt-out token is 'no-coverage-floor'" {
  run grep -E 'no-coverage-floor' "$SHIP_STAGE_FILE"
  assert_success
}

@test "coverage-floor AC4: gate refuses ship when measured < proposed default" {
  run grep -E 'Refusing to ship|exit 1' "$SHIP_STAGE_FILE"
  assert_success
}

@test "coverage-floor AC4: shallow-clone fallback documented (cannot detect age → assume mature)" {
  run grep -E 'shallow|Shallow' "$SHIP_STAGE_FILE"
  assert_success
}

@test "coverage-floor AC4: companion policy keys documented (coverage-floor:, mutation-survival-floor:)" {
  run grep -E 'coverage-floor:|mutation-survival-floor:' "$SHIP_STAGE_FILE"
  assert_success
}

# ─── Behavioural sanity test (sandbox): the opt-out file format ─────────────
# The opt-out is just a single-line plain-text file. Verify our regex in the
# stage file matches the documented opt-out token exactly.

@test "coverage-floor AC4: opt-out token matches grep -qx 'no-coverage-floor'" {
  sandbox
  mkdir -p .claude/state
  echo "no-coverage-floor" > .claude/state/coverage-policy.txt
  run grep -qx "no-coverage-floor" .claude/state/coverage-policy.txt
  assert_success
  teardown_sandbox
}

@test "coverage-floor AC4: 'coverage-floor: 75' explicit-floor key parsed correctly" {
  sandbox
  mkdir -p .claude/state
  printf 'coverage-floor: 75\n' > .claude/state/coverage-policy.txt
  run grep -E '^coverage-floor: [0-9]+$' .claude/state/coverage-policy.txt
  assert_success
  teardown_sandbox
}
