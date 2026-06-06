#!/usr/bin/env bats
# tests/skill/scenarios/spec-fanout-optin.bats
# C1 pilot: Step-1 multi-angle spec fan-out (§1b-pre), OPT-IN / default-OFF.
# Regression guard: with PLAN_W_TEAM_SPEC_FANOUT unset, Step 1 is single-pass as
# before; the fan-out roster is the spec-authoring agents (NOT the diff-based gap
# analyzers); and it runs strictly before the AC freeze.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SPEC_STAGE="$COMMANDS_DIR/01-specification.md"
RETRO_STAGE="$COMMANDS_DIR/07-retro.md"
REGISTRY="$COMMANDS_DIR/shared/state-artifacts.md"

@test "spec-fanout: §1b-pre section exists in 01-specification.md" {
  run grep -nE '## §1b-pre\. Multi-Angle Spec Fan-Out' "$SPEC_STAGE"
  [ "$status" -eq 0 ]
}

@test "spec-fanout: gated on PLAN_W_TEAM_SPEC_FANOUT and default-OFF (!= 1)" {
  run grep -nE 'PLAN_W_TEAM_SPEC_FANOUT:-0.*!= .?1' "$SPEC_STAGE"
  [ "$status" -eq 0 ] || { echo "missing default-OFF !=1 guard"; return 1; }
}

@test "spec-fanout: §1b-pre runs BEFORE the AC freeze (frozen-contract chain)" {
  fanout_line=$(grep -nE '## §1b-pre\. Multi-Angle Spec Fan-Out' "$SPEC_STAGE" | head -1 | cut -d: -f1)
  freeze_line=$(grep -nE '## Acceptance Criteria Snapshot' "$SPEC_STAGE" | head -1 | cut -d: -f1)
  [ -n "$fanout_line" ] && [ -n "$freeze_line" ] || { echo "missing section(s)"; return 1; }
  [ "$fanout_line" -lt "$freeze_line" ] || { echo "fan-out ($fanout_line) not before freeze ($freeze_line)"; return 1; }
}

@test "spec-fanout: roster is the three spec-authoring reviewers" {
  for a in system-architect security-expert code-review-expert; do
    run grep -q "$a" "$SPEC_STAGE"
    [ "$status" -eq 0 ] || { echo "roster missing $a"; return 1; }
  done
}

@test "spec-fanout: does NOT use the diff-based gap analyzers (roster correction)" {
  # The §1b-pre block must not enlist security-gap-analyzer / test-gap-analyzer
  # as fan-out reviewers (they read a diff that does not exist at Step 1). Allow a
  # mention only inside an explicit NOT/exclusion clause — assert no subagent_type
  # assignment to them. Simplest robust check: the literal "subagent_type: security-gap"
  # / "test-gap" assignment must be absent from the section.
  sec=$(awk '/## §1b-pre/{f=1} /## Acceptance Criteria Snapshot/{f=0} f' "$SPEC_STAGE")
  echo "$sec" | grep -qE 'subagent_type:[[:space:]]*(security-gap-analyzer|test-gap-analyzer)' && { echo "diff-based analyzer wired as reviewer"; return 1; }
  return 0
}

@test "spec-fanout: uses the Agent tool, not the Workflow tool" {
  sec=$(awk '/## §1b-pre/{f=1} /## Acceptance Criteria Snapshot/{f=0} f' "$SPEC_STAGE")
  echo "$sec" | grep -q 'Workflow(' && { echo "must not invoke Workflow() in the pipeline"; return 1; }
  echo "$sec" | grep -qi 'Agent' || { echo "should reference the Agent tool"; return 1; }
  return 0
}

@test "spec-fanout: advisory artifact registered + read by retro §8j-nonies" {
  run grep -q 'plan-w-team-spec-fanout-' "$REGISTRY"
  [ "$status" -eq 0 ] || { echo "artifact not registered in state-artifacts.md"; return 1; }
  # §3.4: the fan-out catch-rate block was renamed 8j-octies → 8j-nonies to
  # resolve the duplicate-heading collision with the P1 bypass-rate block.
  run grep -qE '## 8j-nonies\. Spec Fan-Out Catch-Rate' "$RETRO_STAGE"
  [ "$status" -eq 0 ] || { echo "retro §8j-nonies reader missing"; return 1; }
}
