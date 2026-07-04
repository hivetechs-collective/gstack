#!/usr/bin/env bash
# plan-w-team-doc-ship-gate.sh
#
# Gap A3 (1.33.0): the Step-6 Documentation Ship Gate. Refuses to ship when the diff
# adds NEW public surface (per plan-w-team-netnew-surface.sh) and NEITHER a CHANGELOG
# entry NOR a doc target was touched AND no `docs-waived` note exists for the run.
#
# Layered ALONGSIDE the existing enforcing gates (secret scan, credential-wall, tests,
# coverage, security-tier, access-control); weakens none of them. Soft-but-present: the
# escape hatch is a recorded waiver, not silence.
#
# Usage:
#   plan-w-team-doc-ship-gate.sh --slug SLUG [--range A..B] [--base REF]
#
# Exit codes:
#   0  docs present, OR no net-new public surface, OR waived, OR gate disabled
#   1  net-new public surface added with no CHANGELOG/doc touched and no waiver
#   2  bad arguments
#
# Kill switch: PLAN_W_TEAM_NETNEW_DISABLE=1 → warn and exit 0.
# bash 3.2 compatible.

set -u

SLUG=""
RANGE=""
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --range) RANGE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --base) BASE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed -E 's|^#[[:space:]]?||'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$SLUG" ] || { echo "--slug is required" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${PLAN_W_TEAM_NETNEW_DISABLE:-}" = "1" ]; then
  echo "⚠ doc-ship-gate: disabled via PLAN_W_TEAM_NETNEW_DISABLE — skipping"
  exit 0
fi

if [ -z "$RANGE" ]; then
  DEFBR="${BASE_BRANCH:-main}"
  if [ -z "$BASE" ]; then
    if git rev-parse --verify --quiet "origin/$DEFBR" >/dev/null 2>&1; then BASE="origin/$DEFBR"
    elif git rev-parse --verify --quiet "$DEFBR" >/dev/null 2>&1; then BASE="$DEFBR"
    else BASE="HEAD"; fi
  fi
  RANGE="${BASE}..HEAD"
fi

DOCS_WAIVE=".claude/state/plan-w-team-docs-waived-${SLUG}.txt"

# Did the diff touch a CHANGELOG or any doc (.md/.rst/.adoc)?
CHANGED=$(git diff --name-only "$RANGE" 2>/dev/null || true)
DOC_TOUCHED=$(printf '%s\n' "$CHANGED" | grep -Ei '(^|/)CHANGELOG|\.(md|rst|adoc)$' || true)

# Does net-new public surface remain UNDOCUMENTED (after waivers)?
NETNEW_RESIDUAL=0
NETNEW="$SCRIPT_DIR/plan-w-team-netnew-surface.sh"
if [ -x "$NETNEW" ]; then
  "$NETNEW" --range "$RANGE" --slug "$SLUG" --quiet || NETNEW_RESIDUAL=$?
fi

if [ "$NETNEW_RESIDUAL" -ne 0 ] && [ -z "$DOC_TOUCHED" ] && [ ! -f "$DOCS_WAIVE" ]; then
  echo "✗ doc-ship-gate: the diff adds public surface but no CHANGELOG/doc was touched" >&2
  echo "  and no docs-waived note exists. Document the new surface, add a CHANGELOG entry," >&2
  echo "  or record a waiver in $DOCS_WAIVE. (audit gap A3)" >&2
  exit 1
fi
echo "✓ doc-ship-gate: documentation present (or no new public surface / waived)"
exit 0
