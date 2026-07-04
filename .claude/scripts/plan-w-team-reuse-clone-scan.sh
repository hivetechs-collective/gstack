#!/usr/bin/env bash
# plan-w-team-reuse-clone-scan.sh  (M3 — opt-in mechanical clone/duplication scan)
#
# An OPT-IN, default-OFF duplication scan gated exactly like deep-audit
# (`shared/deep-audit.md`). It is a thin wrapper around `jscpd` if available and
# degrades gracefully (skip, exit 0) when the tool is absent — it adds NO hard
# dependency and is a NO-OP when disabled. Advisory only: it never blocks ship.
#
# Activation:
#   PLAN_W_TEAM_CLONE_SCAN=1   → run if a clone detector is available
#   (unset / != 1)             → immediate no-op (exit 0), byte-for-byte unchanged
#
# Tool resolution (no network — never installs):
#   1. `jscpd` on PATH
#   2. `npx --no-install jscpd` (uses an already-installed local/global copy only)
#   absent → graceful skip (exit 0). NO hard dependency is introduced.
#
# Usage:
#   PLAN_W_TEAM_CLONE_SCAN=1 plan-w-team-reuse-clone-scan.sh [--paths "<dir...>"] [--min-tokens N]
#
# Flags:
#   --paths "<space-separated dirs>"   what to scan (default ".")
#   --min-tokens N                     jscpd min-tokens (default 50)
#
# Exit: ALWAYS 0 (advisory / opt-in / fail-open). bash 3.2 compatible.

set -u

PROG="plan-w-team-reuse-clone-scan"
PATHS="."
MIN_TOKENS=50

while [ $# -gt 0 ]; do
  case "$1" in
    --paths) PATHS="${2:-.}"; shift; [ $# -gt 0 ] && shift ;;
    --min-tokens) MIN_TOKENS="${2:-50}"; shift; [ $# -gt 0 ] && shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30; exit 0 ;;
    *) shift ;;
  esac
done

# ── Opt-in gate — default OFF is a byte-for-byte no-op ────────────────────────
if [ "${PLAN_W_TEAM_CLONE_SCAN:-0}" != "1" ]; then
  echo "[$PROG] clone scan disabled (set PLAN_W_TEAM_CLONE_SCAN=1 to enable) — no-op exit 0"
  exit 0
fi

# ── Tool resolution (no install, no network) ─────────────────────────────────
TOOL=""
if command -v jscpd >/dev/null 2>&1; then
  TOOL="jscpd"
elif command -v npx >/dev/null 2>&1 && npx --no-install jscpd --version >/dev/null 2>&1; then
  TOOL="npx --no-install jscpd"
fi

if [ -z "$TOOL" ]; then
  echo "[$PROG] enabled but no clone detector available (jscpd not installed)."
  echo "[$PROG] degrading gracefully — skipping (NO hard dependency added). exit 0"
  echo "[$PROG] to use it: npm i -g jscpd  (or add as a devDependency), then re-run."
  exit 0
fi

echo "[$PROG] running clone scan via '$TOOL' on: $PATHS (min-tokens=$MIN_TOKENS)"
# Advisory: run and surface output; never fail the pipeline on findings.
# shellcheck disable=SC2086
$TOOL $PATHS --min-tokens "$MIN_TOKENS" --reporters consoleFull 2>&1 || true

echo ""
echo "[$PROG] clone scan complete (advisory — review duplicates above; consolidate per shared/reuse-first.md). exit 0"
exit 0
