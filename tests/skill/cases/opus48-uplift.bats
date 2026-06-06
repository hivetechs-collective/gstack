#!/usr/bin/env bats
# tests/skill/cases/opus48-uplift.bats
#
# Invariants for the Opus 4.8 + Claude Code v2.1.154 uplift (/plan-w-team 1.5.0).
# Spec: docs/specs/opus48-v2154-uplift.md
#
# Pure assertions against the committed skill/agent/doc files — no sandbox,
# no network. REPO_ROOT is exported by the helper.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

AGENTS="$REPO_ROOT/.claude/agents"
MANIFEST="$REPO_ROOT/.claude/commands/plan-w-team.md"
PRACTICES="$REPO_ROOT/.claude/commands/plan-w-team/shared/opus-4-7-practices.md"
CLAUDEMD="$REPO_ROOT/CLAUDE.md"
VERSION_FILE="$REPO_ROOT/.claude/commands/plan-w-team/VERSION"
CHANGELOG="$REPO_ROOT/.claude/commands/plan-w-team/CHANGELOG.md"
REPORT="$REPO_ROOT/docs/operations/version-uplift-reports/2026-05-28-2.1.154.md"

# ── AC1: Brain-tier agents pin claude-opus-4-8 ──────────────────────────────
@test "AC1: Brain-tier agents pin claude-opus-4-8" {
  for f in team/evaluator team/validator team/supervisor team/silent-failure-hunter \
           research-planning/test-gap-analyzer research-planning/security-gap-analyzer \
           research-planning/system-architect; do
    run grep -qx "model: claude-opus-4-8" "$AGENTS/$f.md"
    [ "$status" -eq 0 ] || { echo "FAIL: $f not pinned to claude-opus-4-8"; return 1; }
  done
}

# ── AC2: Hands-tier agents pin claude-opus-4-7, no stray 4-6 ─────────────────
@test "AC2: Hands-tier agents pin claude-opus-4-7 and no pipeline agent keeps 4-6" {
  for f in team/builder implementation/react-typescript-specialist \
           implementation/rust-backend-specialist; do
    run grep -qx "model: claude-opus-4-7" "$AGENTS/$f.md"
    [ "$status" -eq 0 ] || { echo "FAIL: $f not pinned to claude-opus-4-7"; return 1; }
  done
  # No team/ agent frontmatter still on 4-6 (research-planning/claude-sdk-expert/docs
  # carry illustrative SDK model IDs that are intentionally out of scope — see spec).
  run grep -rl "^model: claude-opus-4-6" "$AGENTS/team"
  [ "$status" -ne 0 ]
}

# ── AC3: Manifest Model Strategy reflects 4.8 Brain / 4.7 Hands ──────────────
@test "AC3: manifest Model Strategy references Opus 4.8 and 4.7 rollover" {
  run grep -q "claude-opus-4-8" "$MANIFEST"
  [ "$status" -eq 0 ]
  run grep -q "Dynamic Workflows" "$MANIFEST"
  [ "$status" -eq 0 ]
}

# ── AC4: CLAUDE.md Models table + compat rows + xhigh correction ─────────────
@test "AC4: CLAUDE.md adds Opus 4.8 and 2.1.154 compat row" {
  run grep -q "Opus 4.8" "$CLAUDEMD"
  [ "$status" -eq 0 ]
  run grep -q "2.1.154" "$CLAUDEMD"
  [ "$status" -eq 0 ]
  # stale xhigh "API-only / not reachable on Max" claim must be gone
  run grep -q "not reachable on the Max subscription" "$CLAUDEMD"
  [ "$status" -ne 0 ]
}

# ── AC5: hook-event table = 20 events incl MessageDisplay ────────────────────
@test "AC5: CLAUDE.md hook-event table lists 20 events incl MessageDisplay" {
  run grep -q "Supported Hook Events (20 total)" "$CLAUDEMD"
  [ "$status" -eq 0 ]
  run grep -q "MessageDisplay" "$CLAUDEMD"
  [ "$status" -eq 0 ]
  run grep -q "reloadSkills" "$CLAUDEMD"
  [ "$status" -eq 0 ]
}

# ── AC6: opus practices updated for 4.8 + xhigh reachable ────────────────────
@test "AC6: opus-4-7-practices updated for Opus 4.8" {
  run grep -q "Opus 4.8" "$PRACTICES"
  [ "$status" -eq 0 ]
  run grep -q "xhigh" "$PRACTICES"
  [ "$status" -eq 0 ]
}

# ── AC7: Dynamic Workflows positioning note present ──────────────────────────
@test "AC7: manifest has /workflows vs plan-w-team positioning" {
  run grep -q "/workflows" "$MANIFEST"
  [ "$status" -eq 0 ]
}

# ── AC8: uplift CHANGELOG entries present + VERSION >= 1.6.0 ─────────────────
# (Asserts the uplift's own history, not the latest version — robust to bumps.)
@test "AC8: CHANGELOG has the 1.5.0 + 1.6.0 uplift entries and VERSION >= 1.6.0" {
  run grep -q "## \[1.6.0\]" "$CHANGELOG"
  [ "$status" -eq 0 ]
  run grep -q "## \[1.5.0\]" "$CHANGELOG"
  [ "$status" -eq 0 ]
  # VERSION must be at least 1.6.0 (the uplift baseline); later bumps are fine.
  v=$(cat "$VERSION_FILE")
  run bash -c "printf '%s\n%s\n' '1.6.0' '$v' | sort -V | head -1"
  [ "$output" = "1.6.0" ]
}

# ── AC10: version-uplift report exists ───────────────────────────────────────
@test "AC10: version-uplift report for 2.1.154 exists" {
  [ -f "$REPORT" ]
  run grep -q "Opus 4.8" "$REPORT"
  [ "$status" -eq 0 ]
}

# ── 1.6.0 deep-audit follow-through invariants ───────────────────────────────
STATUSLINE="$REPO_ROOT/.claude/statusline.sh"
PWTGOAL="$REPO_ROOT/.claude/scripts/pwt-goal.sh"
REVIEW="$REPO_ROOT/.claude/commands/plan-w-team/04-fix-first-review.md"
GOALCOND="$REPO_ROOT/.claude/commands/plan-w-team/shared/goal-conditions.md"
CLEANUP_TEST="$REPO_ROOT/.claude/scripts/pwt-claims-cleanup.test.sh"

# ── AC11: statusline renders the six effort levels (ultra/xhigh/max + base) ──
@test "AC11: statusline maps effort levels incl ultracode + reads CLAUDE_EFFORT" {
  run grep -q 'effort_display="ultracode"' "$STATUSLINE"
  [ "$status" -eq 0 ] || { echo "missing ultra->ultracode mapping"; return 1; }
  run grep -q 'xhigh + workflows' "$STATUSLINE"
  [ "$status" -eq 0 ]
  run grep -q 'CLAUDE_EFFORT' "$STATUSLINE"
  [ "$status" -eq 0 ]
  # reads the precise stdin signal first
  run grep -q '.effort.level' "$STATUSLINE"
  [ "$status" -eq 0 ]
}

# ── AC12: pwt-goal.sh threads --fallback-model into both bg spawn sites ──────
@test "AC12: pwt-goal.sh adds --fallback-model to worker + supervisor spawns" {
  run grep -q 'PWT_FALLBACK_MODEL' "$PWTGOAL"
  [ "$status" -eq 0 ]
  # at least two --fallback-model spawn invocations (worker + supervisor)
  n=$(grep -c -- '--fallback-model' "$PWTGOAL")
  [ "$n" -ge 2 ] || { echo "expected >=2 --fallback-model spawn sites, got $n"; return 1; }
  run grep -q 'claude-opus-4-7' "$PWTGOAL"
  [ "$status" -eq 0 ]
}

# ── AC13: reviewer-tier accuracy corrected (no stale Hands/4-6 labels) ───────
@test "AC13: review stage labels reviewers Brain-tier, no stale opus-4-6" {
  run grep -q "Reviewers are \*\*Brain-tier\*\*" "$REVIEW"
  [ "$status" -eq 0 ] || { echo "reviewers not labeled Brain-tier"; return 1; }
  # the false Hands-tier claude-opus-4-6 reviewer label must be gone
  run grep -q "Hands-tier\*\* (\`claude-opus-4-6\`" "$REVIEW"
  [ "$status" -ne 0 ]
  run grep -q "builder\` agent, Opus 4.6" "$REVIEW"
  [ "$status" -ne 0 ]
}

# ── AC14: auto-mode change re-attributed 2.1.146 -> 2.1.147 ──────────────────
@test "AC14: goal-conditions auto-mode attributed to 2.1.147" {
  run grep -q "Auto-Mode Compatibility (Claude Code 2.1.147" "$GOALCOND"
  [ "$status" -eq 0 ]
}

# ── AC15: flaky cleanup test is hermetic (pins empty projects dir) ───────────
@test "AC15: pwt-claims-cleanup.test pins CLAUDE_PROJECTS_DIR for hermetic run" {
  run grep -q 'export CLAUDE_PROJECTS_DIR=' "$CLEANUP_TEST"
  [ "$status" -eq 0 ]
}
