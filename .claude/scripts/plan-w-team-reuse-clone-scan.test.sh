#!/usr/bin/env bash
# plan-w-team-reuse-clone-scan.test.sh — M3 opt-in clone-scan tests (bash 3.2)
# Exit 0 = all pass. Discovered by tests/skill/run.sh shell-integration phase.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/plan-w-team-reuse-clone-scan.sh"

# Scrub any inherited opt-in flag so default-OFF cases see a pristine env.
unset PLAN_W_TEAM_CLONE_SCAN

PASS=0
FAIL=0
check()    { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1 (exit $3)"; else FAIL=$((FAIL+1)); echo "  FAIL $1 (expected $2 got $3)"; fi; }
checkout() { case "$3" in *"$2"*) PASS=$((PASS+1)); echo "  ok   $1";; *) FAIL=$((FAIL+1)); echo "  FAIL $1 (missing '$2')";; esac; }

[ -f "$SCAN" ] || { echo "✗ scan not found: $SCAN" >&2; exit 1; }

# ── Case 1: disabled (default) → no-op exit 0 ────────────────────────────────
OUT=$( bash "$SCAN" 2>&1 ); RC=$?
check "disabled is no-op exit 0" 0 $RC
checkout "disabled output says disabled" "disabled" "$OUT"

# ── Case 2: explicitly disabled value → no-op exit 0 ─────────────────────────
OUT=$( PLAN_W_TEAM_CLONE_SCAN=0 bash "$SCAN" 2>&1 ); RC=$?
check "value 0 is no-op exit 0" 0 $RC

# ── Case 3: enabled but tool absent (restricted PATH) → graceful skip exit 0 ──
# Restrict PATH so neither jscpd nor npx resolve → exercises the no-hard-dependency path.
OUT=$( PATH=/usr/bin:/bin PLAN_W_TEAM_CLONE_SCAN=1 bash "$SCAN" 2>&1 ); RC=$?
check "enabled+tool-absent graceful skip exit 0" 0 $RC
checkout "tool-absent output degrades gracefully" "degrading gracefully" "$OUT"

# ── Case 4: opportunistic — if jscpd resolves, enabled run still exits 0 ──────
if command -v jscpd >/dev/null 2>&1; then
  OUT=$( PLAN_W_TEAM_CLONE_SCAN=1 bash "$SCAN" --paths "$HERE" --min-tokens 9999 2>&1 ); RC=$?
  check "enabled+tool-present advisory exit 0" 0 $RC
else
  echo "  skip jscpd not installed — tool-present case not exercised (expected; no hard dependency)"
fi

echo ""
echo "plan-w-team-reuse-clone-scan.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
