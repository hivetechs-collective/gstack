#!/usr/bin/env bats
# tests/skill/cases/r2-sentinels.bats
#
# Regression suite for the seven R2 (round-2 meta-evaluation) defects we already
# paid to find in the /plan-w-team-followups review. Each test asserts the FIX
# is present at its committed location. Reintroducing a defect — by deleting,
# refactoring, or watering down a fix — must turn the corresponding sentinel red.
#
# These tests run against the REAL repo (no sandbox). The point is to guard
# committed source — sandboxing would defeat the intent. They are pure
# read-only greps, so there is no mutation risk.
#
# Naming: each test references its R2 ID (R2-1 through R2-7) so a failure
# instantly maps to the original defect documented in the followups retro.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

# ── R2-1: degraded-mode sentinel writes RETRO_STATE unconditionally ────────
# Defect: round 1 wrapped the degraded-mode write in `[ -f "$RETRO_STATE" ]`
# which silently no-op'd on the most common skip path (--ship-only / --retro).
# Fix: the `if [ ! -f "$BASELINE" ]` block now writes unconditionally; the
# inner `if [ -f "$RETRO_STATE" ]` only chooses jq vs `jq -n` for the merge,
# not whether to write at all.

@test "r2-sentinel: R2-1: given retro degraded-mode block, when scanned, then sentinel writes RETRO_STATE unconditionally" {
  local retro="$REPO_ROOT/.claude/commands/plan-w-team/07-retro.md"
  [ -f "$retro" ]
  # The fix has both jq forms (with-state and without-state) inside the
  # `if [ ! -f "$BASELINE" ]` branch — proves the write is unconditional.
  run grep -n 'jq -n .*untracked_hygiene' "$retro"
  assert_success
  run grep -n 'jq .*\.untracked_hygiene = {hygiene_skipped: true' "$retro"
  assert_success
  # And the sentinel comment naming the defect must remain in place.
  run grep -n 'sentinel exists for' "$retro"
  assert_success
}

# ── R2-2: workflow-lock cleanup trap chains existing EXIT trap ─────────────
# Defect: round 1 used `trap "rm -rf ..." EXIT` which would clobber any
# previously-installed EXIT trap. Fix: capture existing trap text via
# `trap -p EXIT | sed`, then chain `${EXISTING_TRAP:+...; }rm -rf ...`.

@test "r2-sentinel: R2-2: given workflow-lock cleanup trap, when added, then existing EXIT trap chains (no overwrite)" {
  local skill="$REPO_ROOT/.claude/commands/plan-w-team.md"
  [ -f "$skill" ]
  run grep -n 'EXISTING_TRAP=$(trap -p EXIT' "$skill"
  assert_success
  # The chain syntax: `${EXISTING_TRAP:+${EXISTING_TRAP}; }rm -rf ...`
  run grep -nF 'EXISTING_TRAP:+${EXISTING_TRAP}' "$skill"
  assert_success
}

# ── R2-3: secret-scan-allow.txt has both reader and writer registered ──────
# Defect: original registry entry for secret-scan-allow listed only a writer,
# making it look orphan-reader. Fix: registry now lists matching writer_grep
# AND reader_grep so symmetry-check passes.

@test "r2-sentinel: R2-3: given secret-scan-allow registry entry, when checked, then both reader and writer exist" {
  local registry="$REPO_ROOT/.claude/commands/plan-w-team/shared/state-artifacts.md"
  [ -f "$registry" ]
  # Entry must be present in registry
  run grep -n 'plan-w-team-secret-scan-allow' "$registry"
  assert_success
  # Both writer_grep and reader_grep columns must contain ALLOW_FILE token
  # (the row format puts both in backticks within the same line)
  local row
  row=$(grep 'plan-w-team-secret-scan-allow' "$registry" | head -1)
  # Count occurrences of ALLOW_FILE in the row — must be ≥2 (writer + reader)
  local count
  count=$(printf '%s\n' "$row" | grep -o 'ALLOW_FILE' | wc -l | tr -d ' ')
  [ "$count" -ge 2 ]
}

# ── R2-4: per-SLUG mkdir lock (not global) — different SLUGs do not race ───
# Defect: round 1 used a global `plan-w-team-workflow.lock` directory; two
# legitimate parallel features collided. Fix: `WORKFLOW_LOCK_DIR=
# .claude/state/plan-w-team-workflow-${SLUG}.lock` — per-SLUG keying lets
# different features run concurrently while still preventing same-SLUG races.

@test "r2-sentinel: R2-4: given workflow lock path, when defined, then it is per-SLUG (not global)" {
  local skill="$REPO_ROOT/.claude/commands/plan-w-team.md"
  [ -f "$skill" ]
  run grep -nF 'WORKFLOW_LOCK_DIR=".claude/state/plan-w-team-workflow-${SLUG}.lock"' "$skill"
  assert_success
}

@test "r2-sentinel: R2-4: given two mkdir attempts on same path, when raced, then second fails" {
  # Behavioral assertion: mkdir is atomic on POSIX, so the same-path race
  # produces success+failure (not double-success). Direct sandbox test.
  sandbox
  mkdir "$SANDBOX_DIR/race-lock"
  run mkdir "$SANDBOX_DIR/race-lock"
  assert_failure
  teardown_sandbox
}

# ── R2-5: BlockShip arrow flow in mermaid diagram is correct ───────────────
# Defect: a prior diagram had `BlockShip --> Pass2` directly, skipping the
# Resolve gate. Fix: `BlockShip --> Resolve` and `Resolve -->|No| BlockShip`
# (loop) and `Resolve -->|Yes| Pass2` — ship cannot proceed until resolved.

@test "r2-sentinel: R2-5: given two-pass review mermaid, when grepped, then BlockShip arrow flow is correct" {
  local doc="$REPO_ROOT/.claude/commands/plan-w-team/04-fix-first-review.md"
  [ -f "$doc" ]
  # All three required arrows must be present in the diagram body.
  run grep -nF 'Findings1 -->|Yes| BlockShip' "$doc"
  assert_success
  run grep -nF 'BlockShip --> Resolve' "$doc"
  assert_success
  run grep -nF 'Resolve -->|No| BlockShip' "$doc"
  assert_success
  run grep -nF 'Resolve -->|Yes| Pass2' "$doc"
  assert_success
}

# ── R2-6: spec_sha mismatch branch is present in mermaid ───────────────────
# Defect: original diagram had no spec-drift detection arrow at all — the
# fix-first review would proceed even if the AC snapshot SHA differed from
# the live spec SHA. Fix: `Integrity{Spec SHA<br/>matches snapshot?}` with
# `Integrity -->|No| AskDrift[ASK: spec drift]` branch.

@test "r2-sentinel: R2-6: given fix-first review mermaid, when grepped, then spec SHA mismatch branch is present" {
  local doc="$REPO_ROOT/.claude/commands/plan-w-team/04-fix-first-review.md"
  [ -f "$doc" ]
  # The Integrity gate node — note the <br/> embedded in the label
  run grep -nF 'Integrity{Spec SHA<br/>matches snapshot?}' "$doc"
  assert_success
  # The "No" branch must route to AskDrift (not silently fall through)
  run grep -nF 'Integrity -->|No| AskDrift' "$doc"
  assert_success
  # AskDrift node label must mention "spec drift" so reviewers see why
  run grep -nF 'AskDrift[ASK: spec drift]' "$doc"
  assert_success
}

# ── R2-7: --resume documents SLUG re-acquire of workflow lock ──────────────
# Defect: round 1 docs said "--resume continues" without specifying that the
# lock must be re-acquired with the same SLUG; ambiguity allowed silent state
# overwrites. Fix: explicit "Resume contract" paragraph in plan-w-team.md.

@test "r2-sentinel: R2-7: given --resume flow, when documented, then SLUG re-acquire is described" {
  local skill="$REPO_ROOT/.claude/commands/plan-w-team.md"
  [ -f "$skill" ]
  run grep -nF 'Resume contract' "$skill"
  assert_success
  # The contract must mention all three: --resume, SLUG, and re-acquire
  local block
  block=$(awk '/Resume contract/,/^$/' "$skill")
  [[ "$block" == *"--resume"* ]]
  [[ "$block" == *"SLUG"* ]]
  [[ "$block" == *"re-acquire"* ]]
}
