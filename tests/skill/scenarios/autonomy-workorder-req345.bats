#!/usr/bin/env bats
# autonomy-workorder-req345.bats — doc-invariant checks for the 2026-05-29
# autonomy work order REQ-3 (effort escalation), REQ-4b (post-merge reclaim),
# REQ-5 (vendor/SSO OAuth guardrail). Spec:
# docs/specs/claude-pattern-DIRECTION-pwt-autonomy-2026-05-29.md

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SUPERVISOR="$COMMANDS_DIR/shared/supervisor-protocol.md"
SECRET="$COMMANDS_DIR/shared/secret-safety.md"
EXECUTE="$COMMANDS_DIR/03-execute.md"
REVIEW="$COMMANDS_DIR/04-fix-first-review.md"

# ── REQ-5: vendor/SSO console guardrail ──────────────────────────────────────
@test "REQ-5: secret-safety has the vendor/SSO console hard guardrail" {
  run grep -qE "Vendor / SSO Console Access" "$SECRET"; [ "$status" -eq 0 ]
  run grep -q "console.neon.tech" "$SECRET"; [ "$status" -eq 0 ]
  run grep -q "blocked-external" "$SECRET"; [ "$status" -eq 0 ]
}

@test "REQ-5: guardrail allows programmatic path, forbids interactive login" {
  run grep -qiE "API token from the secrets inventory|programmatic" "$SECRET"; [ "$status" -eq 0 ]
  run grep -qiE "NEVER navigate|never.*interactive login|must not try" "$SECRET"; [ "$status" -eq 0 ]
}

@test "REQ-5: 03-execute references the blocked-external gate" {
  run grep -q "blocked-external" "$EXECUTE"; [ "$status" -eq 0 ]
}

# ── REQ-3: autonomous effort escalation (NO workflows for bg) ─────────────────
@test "REQ-3: supervisor STALL-ALERT has an effort-escalation rung" {
  run grep -qE "Effort-escalation rung" "$SUPERVISOR"; [ "$status" -eq 0 ]
  run grep -qiE "ultrathink|/effort xhigh|elevate the reasoning budget" "$SUPERVISOR"; [ "$status" -eq 0 ]
}

@test "REQ-3: effort rung keeps PWT-WF1 (no bg workflows)" {
  run grep -q "CLAUDE_CODE_DISABLE_WORKFLOWS=1" "$SUPERVISOR"; [ "$status" -eq 0 ]
}

@test "REQ-3: 04-fix-first-review names the low-confidence/HARD trigger" {
  # format-tolerant: markdown backticks/bold sit between the words.
  run grep -qiE "low.{0,4}twice|HARD.{0,4}tagged" "$REVIEW"; [ "$status" -eq 0 ]
  run grep -qiE "ultrathink|/effort xhigh" "$REVIEW"; [ "$status" -eq 0 ]
}

# ── REQ-4b: post-merge reclaim in the AUTO-MERGE action ──────────────────────
@test "REQ-4b: AUTO-MERGE action reclaims the worktree after gh pr merge" {
  run grep -qE "plan-w-team-worktree-on-merge.sh" "$SUPERVISOR"; [ "$status" -eq 0 ]
  # the reclaim note must sit in the AUTO-MERGE action context (mentions admin-squash/remote)
  run grep -qiE "admin-squash on the remote|no local hook fires" "$SUPERVISOR"; [ "$status" -eq 0 ]
}
