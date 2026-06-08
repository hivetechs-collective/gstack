#!/usr/bin/env bash
# plan-w-team-reuse-overlap-scan.test.sh — M2 overlap-scan regression tests (bash 3.2)
# Exit 0 = all pass. Discovered by tests/skill/run.sh shell-integration phase.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/plan-w-team-reuse-overlap-scan.sh"

PASS=0
FAIL=0
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

check() { # <desc> <expected_exit> <actual_exit>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1 (exit $3)";
  else FAIL=$((FAIL+1)); echo "  FAIL $1 (expected $2 got $3)"; fi
}
checkout() { # <desc> <needle> <haystack>
  case "$3" in *"$2"*) PASS=$((PASS+1)); echo "  ok   $1";; *) FAIL=$((FAIL+1)); echo "  FAIL $1 (missing '$2')";; esac
}

[ -f "$SCAN" ] || { echo "✗ scan not found: $SCAN" >&2; exit 1; }

# Build a throwaway git repo with a known commit + spec.
REPO="$TMPD/repo"
mkdir -p "$REPO/docs/specs"
( cd "$REPO"
  git init -q
  git config user.email t@t.t; git config user.name t
  echo "# alerting" > docs/specs/alerting-system.md
  git add -A && git commit -q -m "feat(alerting): add notification engine"
) >/dev/null 2>&1

# ── Case 1: no terms/paths → fail-open exit 0 + 'no overlap signal' ───────────
OUT=$( cd "$REPO" && bash "$SCAN" 2>&1 ); RC=$?
check "no args exits 0 (fail-open)" 0 $RC
checkout "no args reports no overlap signal" "no overlap signal" "$OUT"

# ── Case 2: term matching a recent commit subject → overlap(commit) ──────────
OUT=$( cd "$REPO" && bash "$SCAN" --terms "alerting notification" 2>&1 ); RC=$?
check "matching term exits 0" 0 $RC
checkout "matching commit term surfaces overlap(commit)" "overlap(commit)" "$OUT"

# ── Case 3: term matching an existing spec filename → overlap(spec) ──────────
OUT=$( cd "$REPO" && bash "$SCAN" --terms "alerting" 2>&1 ); RC=$?
checkout "matching spec name surfaces overlap(spec" "overlap(spec" "$OUT"

# ── Case 4: nonsense term → no overlap signal, still exit 0 ──────────────────
OUT=$( cd "$REPO" && bash "$SCAN" --terms "zzqqxx-nonexistent-token" 2>&1 ); RC=$?
check "nonsense term exits 0" 0 $RC
checkout "nonsense term reports no overlap" "no overlap signal" "$OUT"

# ── Case 5: path recently touched → overlap(path) ───────────────────────────
OUT=$( cd "$REPO" && bash "$SCAN" --paths "docs/specs/alerting-system.md" 2>&1 ); RC=$?
checkout "touched path surfaces overlap(path)" "overlap(path)" "$OUT"

# ── Case 6: fail-open outside a git repo (no crash) ─────────────────────────
OUT=$( cd "$TMPD" && bash "$SCAN" --terms "anything" 2>&1 ); RC=$?
check "non-git dir fail-open exits 0" 0 $RC

echo ""
echo "plan-w-team-reuse-overlap-scan.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
