#!/usr/bin/env bash
# plan-w-team-reuse-audit-gate.sh  (H1 — Reuse Audit freeze gate)
#
# ENFORCING Step-1 pre-condition, mirroring the Step-2 scope-lock coupling-ack
# pre-condition (`02-task-breakdown.md` §Scope-Lock). The Step-1 AC-snapshot
# freeze refuses to proceed unless the spec carries a non-blank
# "Existing-Code Survey / Reuse Audit" section (H1). This closes the gap where
# Step 0 ASKS the reuse question but mandates no written output, so the central
# reuse-vs-build decision never exists on paper.
#
# A spec satisfies the gate when it contains a heading matching
#   "Reuse Audit"  OR  "Existing-Code Survey"
# whose body is non-blank AND contains EITHER:
#   - a verdict token: REUSE / EXTEND / BUILD-NEW, OR
#   - an explicit "surveyed, nothing overlaps" statement
#     (matches: "nothing overlaps", "no overlap", "no overlapping").
# A heading with an empty/whitespace-only body is a FAIL — "never silently blank".
#
# Kill switch (consistent with the PLAN_W_TEAM_DISABLE_* family):
#   PLAN_W_TEAM_DISABLE_REUSE_AUDIT=1  → exit 0 with a notice, never blocks.
#
# Usage:
#   plan-w-team-reuse-audit-gate.sh --spec docs/specs/<slug>.md
#   plan-w-team-reuse-audit-gate.sh --slug <slug>      # → docs/specs/<slug>.md
#   plan-w-team-reuse-audit-gate.sh docs/specs/<slug>.md   # positional
#
# Exit codes:
#   0 — audit present + non-blank (gate passes), OR kill switch active
#   1 — audit section missing OR present-but-blank (gate FAILS — refuse freeze)
#   2 — spec file not found (caller should author the spec first)
#
# bash 3.2 compatible (no associative arrays, no mapfile).

set -u

PROG="plan-w-team-reuse-audit-gate"

# ── Kill switch ──────────────────────────────────────────────────────────────
if [ "${PLAN_W_TEAM_DISABLE_REUSE_AUDIT:-}" = "1" ]; then
  echo "[$PROG] PLAN_W_TEAM_DISABLE_REUSE_AUDIT=1 — reuse-audit gate disabled (exit 0)"
  exit 0
fi

# ── Arg parsing ──────────────────────────────────────────────────────────────
SPEC=""
SLUG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) SPEC="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --slug) SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -40; exit 0 ;;
    *) [ -z "$SPEC" ] && SPEC="$1"; shift ;;
  esac
done

if [ -z "$SPEC" ] && [ -n "$SLUG" ]; then
  SPEC="docs/specs/${SLUG}.md"
fi

if [ -z "$SPEC" ]; then
  echo "[$PROG] ✗ no --spec or --slug given" >&2
  exit 2
fi

# Resolve: as-given, else relative to git repo root.
if [ ! -f "$SPEC" ]; then
  if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) && [ -f "$REPO_ROOT/$SPEC" ]; then
    SPEC="$REPO_ROOT/$SPEC"
  fi
fi

if [ ! -f "$SPEC" ]; then
  echo "[$PROG] ✗ spec file not found: $SPEC" >&2
  echo "[$PROG]   author the spec (Step 1) before the freeze gate runs." >&2
  exit 2
fi

# ── Extract the Reuse Audit section body ─────────────────────────────────────
# From the first heading line matching Reuse Audit / Existing-Code Survey
# (case-insensitive, any heading level) up to (but not including) the next
# markdown heading line (^#{1,6}\s). awk with a case-insensitive match.
BODY=$(awk '
  BEGIN { insec = 0 }
  # heading detector
  /^#{1,6}[[:space:]]/ {
    line = $0
    low = tolower(line)
    if (insec == 1) {
      # a new heading ends the section (unless it is a deeper heading nested
      # inside — we treat any heading as a boundary for simplicity/robustness)
      insec = 0
    }
    if (low ~ /reuse audit/ || low ~ /existing-code survey/) {
      insec = 1
      next   # do not include the heading itself in the body
    }
    if (insec == 0) next
  }
  insec == 1 { print }
' "$SPEC")

# Heading present at all?
if ! grep -qiE '^#{1,6}[[:space:]].*(reuse audit|existing-code survey)' "$SPEC"; then
  echo "[$PROG] ✗ spec has no 'Existing-Code Survey / Reuse Audit' section: $SPEC" >&2
  echo "[$PROG]   add the mandatory Reuse Audit section (see 01-specification.md)." >&2
  exit 1
fi

# Non-blank body? (strip whitespace)
BODY_STRIPPED=$(printf '%s' "$BODY" | tr -d '[:space:]')
if [ -z "$BODY_STRIPPED" ]; then
  echo "[$PROG] ✗ Reuse Audit section present but BLANK: $SPEC" >&2
  echo "[$PROG]   list REUSE/EXTEND/BUILD-NEW verdicts, or state 'surveyed, nothing overlaps'." >&2
  exit 1
fi

# Verdict token OR explicit-empty statement?
if printf '%s' "$BODY" | grep -qE 'REUSE|EXTEND|BUILD-NEW'; then
  echo "[$PROG] ✓ Reuse Audit present with verdict(s) — gate passes"
  exit 0
fi
if printf '%s' "$BODY" | grep -qiE 'nothing overlaps|no overlap|no overlapping'; then
  echo "[$PROG] ✓ Reuse Audit present with explicit 'nothing overlaps' statement — gate passes"
  exit 0
fi

echo "[$PROG] ✗ Reuse Audit section has neither a REUSE/EXTEND/BUILD-NEW verdict" >&2
echo "[$PROG]   nor an explicit 'surveyed, nothing overlaps' statement: $SPEC" >&2
exit 1
