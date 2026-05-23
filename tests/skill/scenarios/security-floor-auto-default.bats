#!/usr/bin/env bats
# tests/skill/scenarios/security-floor-auto-default.bats
#
# Scenario: Security Review Extension — Step 6 ship gate (§6c-bis) proposes
# a baseline security tier set (T1+T3+T4) when no .claude/state/security-policy.txt
# is declared. Verifies the auto-default block in 05-ship.md documents the
# baseline, the LOC>5k overlay (→ +T2), the user-facing overlay (→ +TO1),
# and the documented opt-out paths.
#
# Spec: docs/specs/security-review-extension.md (AC4)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

SHIP_STAGE="$COMMANDS_DIR/05-ship.md"

# ─── AC4: §6c-bis Security Tier Gate exists in 05-ship.md ───────────────────

@test "security-floor-auto-default AC4: 05-ship.md has §6c-bis Security Tier Gate section" {
  run grep -nE '6c-bis.*Security Tier Gate' "$SHIP_STAGE"
  assert_success
}

@test "security-floor-auto-default AC4: §6c-bis references .claude/state/security-policy.txt" {
  local block
  block=$(awk '/^## 6c-bis/,/^## 6d\. /' "$SHIP_STAGE")
  echo "$block" | grep -E '\.claude/state/security-policy\.txt'
}

# ─── AC4: Baseline T1+T3+T4 is the always-on default ───────────────────────

@test "security-floor-auto-default AC4: SecBaseline default tier set is T1+T3+T4" {
  local block
  block=$(awk '/^## 6c-bis/,/^## 6d\. /' "$SHIP_STAGE")
  echo "$block" | grep -E 'T1,T3,T4|T1\+T3\+T4|SecBaseline'
}

# ─── AC4: LOC > 5k overlay adds T2 ──────────────────────────────────────────

@test "security-floor-auto-default AC4: LOC >5k auto-overlay adds T2 SAST" {
  local block
  block=$(awk '/^## 6c-bis/,/^## 6d\. /' "$SHIP_STAGE")
  echo "$block" | grep -E '5000|5k LOC|LOC.*>.*5'
  echo "$block" | grep -E '\+T2|T2|SecStandard'
}

# ─── AC4: User-facing surface overlay adds TO1 ──────────────────────────────

@test "security-floor-auto-default AC4: user-facing endpoint detection adds TO1 ZAP overlay" {
  local block
  block=$(awk '/^## 6c-bis/,/^## 6d\. /' "$SHIP_STAGE")
  echo "$block" | grep -E 'routes|api|pages/api|app/api'
  echo "$block" | grep -E 'TO1|user_facing|SecHardened'
}

# ─── AC4: Opt-out paths documented ──────────────────────────────────────────

@test "security-floor-auto-default AC4: opt-out via no-security-floor line is documented" {
  local block
  block=$(awk '/^## 6c-bis/,/^## 6d\. /' "$SHIP_STAGE")
  echo "$block" | grep -E 'no-security-floor'
}

@test "security-floor-auto-default AC4: explicit override via 'security-tiers:' line is documented" {
  local block
  block=$(awk '/^## 6c-bis/,/^## 6d\. /' "$SHIP_STAGE")
  echo "$block" | grep -E "security-tiers: T1,T3,T4|security-tiers:"
}

@test "security-floor-auto-default AC4: TO1 / TO2 opt-in flags (enable-to1 / enable-to2) documented" {
  local block
  block=$(awk '/^## 6c-bis/,/^## 6d\. /' "$SHIP_STAGE")
  echo "$block" | grep -E 'enable-to1'
  echo "$block" | grep -E 'enable-to2'
}

# ─── AC4: §6c-bis runs AFTER §6c (coverage gate) ────────────────────────────

@test "security-floor-auto-default AC4: §6c-bis appears AFTER §6c coverage floor in 05-ship.md" {
  local coverage_line security_line
  coverage_line=$(grep -n 'Coverage Floor Auto-Default' "$SHIP_STAGE" | head -1 | cut -d: -f1)
  security_line=$(grep -n '6c-bis.*Security Tier Gate' "$SHIP_STAGE" | head -1 | cut -d: -f1)
  [ -n "$coverage_line" ]
  [ -n "$security_line" ]
  [ "$security_line" -gt "$coverage_line" ]
}

# ─── AC4: References shared/security-tiers.md and shared/owasp-top10-mapping.md ───

@test "security-floor-auto-default AC4: §6c-bis references shared/security-tiers.md" {
  local block
  block=$(awk '/^## 6c-bis/,/^## 6d\. /' "$SHIP_STAGE")
  echo "$block" | grep -E 'security-tiers\.md'
}

@test "security-floor-auto-default AC4: §6c-bis references shared/owasp-top10-mapping.md" {
  local block
  block=$(awk '/^## 6c-bis/,/^## 6d\. /' "$SHIP_STAGE")
  echo "$block" | grep -E 'owasp-top10-mapping\.md'
}

# ─── AC5: shared/security-tiers.md exists ──────────────────────────────────

@test "security-floor-auto-default AC5: shared/security-tiers.md exists and defines T1-T5 + TO1 + TO2" {
  local tiers_file="$COMMANDS_DIR/shared/security-tiers.md"
  [ -f "$tiers_file" ]
  run grep -E '^\| \*\*T1\*\*' "$tiers_file"
  assert_success
  run grep -E '^\| \*\*T2\*\*' "$tiers_file"
  assert_success
  run grep -E '^\| \*\*T3\*\*' "$tiers_file"
  assert_success
  run grep -E '^\| \*\*T4\*\*' "$tiers_file"
  assert_success
  run grep -E '^\| \*\*T5\*\*' "$tiers_file"
  assert_success
  run grep -E '^\| \*\*TO1\*\*' "$tiers_file"
  assert_success
  run grep -E '^\| \*\*TO2\*\*' "$tiers_file"
  assert_success
}

@test "security-floor-auto-default AC5: security-tiers.md mentions secret-scan.sh as T4 mechanism" {
  local tiers_file="$COMMANDS_DIR/shared/security-tiers.md"
  run grep -E 'secret-scan\.sh' "$tiers_file"
  assert_success
}
