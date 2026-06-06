#!/usr/bin/env bats
# tests/skill/scenarios/access-control-finding-gates-ship.bats
#
# Scenario: a bypass-token endpoint that updates an existing user without an
# isQaUser/scope guard produces a confirmed high-severity finding that is GATING
# (blocks ship), not retroactive. Verifies the producer (04 §5b + §5d-ter + §5h
# frontmatter key) and the consumer (05 §6c-ter fail-closed gate).
#
# Spec: docs/specs/access-control-content-signal-gate.md (AC2)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SHIP_STAGE="$COMMANDS_DIR/05-ship.md"
REVIEW_STAGE="$COMMANDS_DIR/04-fix-first-review.md"

ship_gate_block() { awk '/^## 6c-ter/,/^## 6d\. /' "$SHIP_STAGE"; }
gating_rule_block() { awk '/^### 5d-ter/,/^## 5d\. /' "$REVIEW_STAGE"; }
scan_block() { awk '/^### Access-Control Content-Signal Scan/,/^## 5c\. /' "$REVIEW_STAGE"; }

# ─── Consumer: 05-ship.md §6c-ter Access-Control Finding Gate ────────────────

@test "access-control-finding-gates-ship AC2: §6c-ter Access-Control Finding Gate exists" {
  run grep -nE '^## 6c-ter\. Access-Control Finding Gate' "$SHIP_STAGE"
  assert_success
}

@test "access-control-finding-gates-ship AC2: §6c-ter is ENFORCING" {
  ship_gate_block | grep -E 'ENFORCING'
}

@test "access-control-finding-gates-ship AC2: §6c-ter reads the access_control_high_unresolved key" {
  ship_gate_block | grep -E 'access_control_high_unresolved'
}

@test "access-control-finding-gates-ship AC2: §6c-ter fails closed with exit 1" {
  ship_gate_block | grep -E 'exit 1'
}

@test "access-control-finding-gates-ship AC2: §6c-ter uses the canonical ship-gate prefix" {
  ship_gate_block | grep -E '✗ Ship gate 6c-ter:'
}

@test "access-control-finding-gates-ship AC2: a deferral does NOT clear the gate" {
  ship_gate_block | grep -E 'DEFERRED.*does NOT clear|GATING, not deferrable|No ship-side override'
}

@test "access-control-finding-gates-ship AC2: §6c-ter appears AFTER §6c-bis in 05-ship.md" {
  local bis_line ter_line
  bis_line=$(grep -n '^## 6c-bis' "$SHIP_STAGE" | head -1 | cut -d: -f1)
  ter_line=$(grep -n '^## 6c-ter' "$SHIP_STAGE" | head -1 | cut -d: -f1)
  [ -n "$bis_line" ]
  [ -n "$ter_line" ]
  [ "$ter_line" -gt "$bis_line" ]
}

@test "access-control-finding-gates-ship AC2: the new exit-1 is registered in the §6-0a trap inventory" {
  run grep -E 'access-control finding gate' "$SHIP_STAGE"
  assert_success
}

# ─── Producer: 04 §5b scan writes the gating finding ────────────────────────

@test "access-control-finding-gates-ship AC2: §5b Access-Control Content-Signal Scan is a CRITICAL pass" {
  run grep -nE '^### Access-Control Content-Signal Scan \(CRITICAL' "$REVIEW_STAGE"
  assert_success
}

@test "access-control-finding-gates-ship AC2: bypass-token scoping (INV-4) is checked in the scan" {
  local block
  block=$(scan_block)
  echo "$block" | grep -E 'INV-4|bypass.*token'
  echo "$block" | grep -E 'isQaUser|assertQaScoped|QA-scoped'
}

@test "access-control-finding-gates-ship AC2: the scan sets access_control_high_unresolved" {
  scan_block | grep -E 'access_control_high_unresolved'
}

# ─── Producer: 04 §5d-ter gating-not-retroactive rule ───────────────────────

@test "access-control-finding-gates-ship AC2: §5d-ter declares findings gating, not retroactive" {
  run grep -nE '^### 5d-ter\. Confirmed Access-Control Findings Are Gating' "$REVIEW_STAGE"
  assert_success
}

@test "access-control-finding-gates-ship AC2: §5d-ter blocks the retroactive N.t queue for these findings" {
  local block
  block=$(gating_rule_block)
  echo "$block" | grep -E 'MUST NOT enter'
  echo "$block" | grep -E 'retroactive'
}

@test "access-control-finding-gates-ship AC2: §5d-ter names the API access-control classes" {
  local block
  block=$(gating_rule_block)
  echo "$block" | grep -E 'A01'
  echo "$block" | grep -E 'API1|BOLA'
  echo "$block" | grep -E 'API3|BOPLA'
  echo "$block" | grep -E 'API5|BFLA'
}

@test "access-control-finding-gates-ship AC2: §5d-ter gates all high-sev archetypes incl. INV-1 IDOR (jobs.ts must gate)" {
  # Regression lock: gating must NOT be scoped to INV-3/INV-4 only — the jobs.ts
  # FIN-15 cross-tenant IDOR (INV-1 / API1 BOLA) is a motivating bug and must gate,
  # not defer. Severity is the gate; the three archetypes must all appear.
  local block
  block=$(gating_rule_block)
  echo "$block" | grep -E 'INV-1'
  echo "$block" | grep -E 'INV-3'
  echo "$block" | grep -E 'INV-4'
  echo "$block" | grep -E 'IDOR|cross-tenant'
}

@test "access-control-finding-gates-ship AC2: §5d-ter makes severity (not invariant id) the gate" {
  gating_rule_block | grep -E 'Severity is the gate|severity, not the invariant'
}

@test "access-control-finding-gates-ship AC2: §6c-ter gate fails closed on a non-numeric count" {
  local block
  block=$(ship_gate_block)
  echo "$block" | grep -E 'unparseable|failing closed|fail closed'
  echo "$block" | grep -E '\[!0-9\]'
}

# ─── §5h persists the gating contract ────────────────────────────────────────

@test "access-control-finding-gates-ship AC2: §5h frontmatter carries access_control_high_unresolved" {
  run grep -nE '^access_control_high_unresolved:' "$REVIEW_STAGE"
  assert_success
}

@test "access-control-finding-gates-ship AC2: §5h marks the access-control key non-deferrable" {
  # The 'what goes in the file' guidance must state a DEFERRED access-control
  # finding still counts toward the gating key.
  run grep -E 'still counts|still.*count toward this number|non-deferrable' "$REVIEW_STAGE"
  assert_success
}
