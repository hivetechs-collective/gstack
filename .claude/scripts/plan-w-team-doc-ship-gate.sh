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
#
# `docs/specs/**` is EXCLUDED (row-12 re-audit). The rest of the contract is
# unambiguous that a spec does not discharge the documentation duty —
# `plan-w-team-netnew-surface.sh` excludes `docs/specs/` from the docs it will
# accept as a reference, `01-specification.md` says "docs/specs/ does NOT satisfy
# it", and `02-task-breakdown.md`'s N.d rule says the same. This gate accepted it
# anyway, so a net-new script documented ONLY in `docs/specs/<slug>.md` passed the
# ship gate while the subscanner reported it UNDOCUMENTED. Since every run writes a
# spec at that path, the exclusion matters. Reproduced and regression-tested.
#
# NOTE (design limitation, deliberately NOT changed here): a CHANGELOG touch alone
# still satisfies this gate, and /plan-w-team touches CHANGELOG.md on essentially
# every run — so in this pipeline the gate rarely binds. That is what AC3 and the
# brief specify ("neither a CHANGELOG entry nor a doc target was touched"), so
# tightening it to key off the subscanner residual is a SPEC change with fleet-wide
# blast radius, not a bug fix. Queued as a follow-up rather than slipped in here.
CHANGED=$(git diff --name-only "$RANGE" 2>/dev/null || true)
DOC_TOUCHED=$(printf '%s\n' "$CHANGED" \
  | grep -Ev '^docs/specs/' \
  | grep -Ei '(^|/)CHANGELOG|\.(md|rst|adoc)$' || true)

# Does net-new public surface remain UNDOCUMENTED (after waivers)?
NETNEW="$SCRIPT_DIR/plan-w-team-netnew-surface.sh"
if [ ! -x "$NETNEW" ]; then
  # Without the subscanner this gate tests NOTHING. Reporting success here is the
  # C7-part-2 silent-degradation shape (a consumer whose sync dropped the file);
  # a gate that cannot run must not claim a pass. Fail closed and say why.
  echo "✗ doc-ship-gate: subscanner missing or not executable at $NETNEW —" >&2
  echo "  cannot verify that net-new surface is documented. Restore it (sync-to-project.sh" >&2
  echo "  allowlist), or set PLAN_W_TEAM_NETNEW_DISABLE=1 with a recorded reason." >&2
  exit 1
fi

NETNEW_RESIDUAL=0
"$NETNEW" --range "$RANGE" --slug "$SLUG" --quiet || NETNEW_RESIDUAL=$?

# rc 2 = the subscanner could not resolve a range (fail-toward-review), rc 1 =
# residual UNDOCUMENTED items. Both mean "cannot prove the surface is documented".
if [ "$NETNEW_RESIDUAL" -ne 0 ] && [ -z "$DOC_TOUCHED" ] && [ ! -f "$DOCS_WAIVE" ]; then
  echo "✗ doc-ship-gate: the diff adds public surface but no CHANGELOG/doc was touched" >&2
  echo "  and no docs-waived note exists (subscanner rc=$NETNEW_RESIDUAL). Offending items:" >&2
  "$NETNEW" --range "$RANGE" --slug "$SLUG" 2>&1 | sed 's/^/    /' >&2 || true
  echo "  Document each under docs/operations/ (a docs/specs/ entry does NOT satisfy this)," >&2
  echo "  add a CHANGELOG entry, or record a waiver in $DOCS_WAIVE. (audit gap A3)" >&2
  exit 1
fi
echo "✓ doc-ship-gate: documentation present (or no new public surface / waived)"
exit 0
