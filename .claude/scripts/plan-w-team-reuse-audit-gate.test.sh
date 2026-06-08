#!/usr/bin/env bash
# plan-w-team-reuse-audit-gate.test.sh — H1 gate regression tests (bash 3.2)
#
# Exit 0 = all pass; 1 = a failure. Run directly: bash <this file>.
# Discovered by tests/skill/run.sh's shell-integration phase.

set -u

# Resolve the gate script relative to THIS test file (worktree-safe — do not
# rely on ambient CWD; see feedback_test_worktree_cwd_fragility).
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/plan-w-team-reuse-audit-gate.sh"

# Scrub the kill switch so default-behavior cases see a pristine env
# (worker sessions may export PLAN_W_TEAM_DISABLE_*; see project_pwt_worker_disable_env_leak).
unset PLAN_W_TEAM_DISABLE_REUSE_AUDIT

PASS=0
FAIL=0
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

check() {
  # check <description> <expected_exit> <actual_exit>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "  ok   $1 (exit $3)"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $1 (expected $2, got $3)"
  fi
}

[ -f "$GATE" ] || { echo "✗ gate script not found: $GATE" >&2; exit 1; }

# ── Case 1: audit section with verdicts → pass (0) ───────────────────────────
cat > "$TMPD/with-verdicts.md" <<'EOF'
# Feature: x
## Existing-Code Survey / Reuse Audit
| candidate | verdict |
| --------- | ------- |
| foo()     | REUSE   |
| bar()     | BUILD-NEW |
## Requirements
- nothing here
EOF
bash "$GATE" --spec "$TMPD/with-verdicts.md" >/dev/null 2>&1
check "audit with verdicts passes" 0 $?

# ── Case 2: heading present but blank body → fail (1) ─────────────────────────
cat > "$TMPD/blank.md" <<'EOF'
# Feature: x
## Reuse Audit

## Requirements
- something
EOF
bash "$GATE" --spec "$TMPD/blank.md" >/dev/null 2>&1
check "blank audit section fails" 1 $?

# ── Case 3: no audit section at all → fail (1) ────────────────────────────────
cat > "$TMPD/none.md" <<'EOF'
# Feature: x
## Overview
nothing about reuse here
## Requirements
- something
EOF
bash "$GATE" --spec "$TMPD/none.md" >/dev/null 2>&1
check "missing audit section fails" 1 $?

# ── Case 4: explicit "nothing overlaps" statement → pass (0) ──────────────────
cat > "$TMPD/empty-ok.md" <<'EOF'
# Feature: x
## Existing-Code Survey / Reuse Audit
Surveyed the codebase; nothing overlaps this feature.
## Requirements
- something
EOF
bash "$GATE" --spec "$TMPD/empty-ok.md" >/dev/null 2>&1
check "explicit nothing-overlaps statement passes" 0 $?

# ── Case 5: kill switch on a no-audit spec → pass (0) ─────────────────────────
PLAN_W_TEAM_DISABLE_REUSE_AUDIT=1 bash "$GATE" --spec "$TMPD/none.md" >/dev/null 2>&1
check "kill switch bypasses gate" 0 $?

# ── Case 6: missing spec file → exit 2 ───────────────────────────────────────
bash "$GATE" --spec "$TMPD/does-not-exist.md" >/dev/null 2>&1
check "missing spec file exits 2" 2 $?

# ── Case 7: --slug derivation (file absent) → exit 2 ─────────────────────────
bash "$GATE" --slug "definitely-not-a-real-slug-xyz" >/dev/null 2>&1
check "slug-derived missing spec exits 2" 2 $?

echo ""
echo "plan-w-team-reuse-audit-gate.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
