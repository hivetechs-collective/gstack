#!/usr/bin/env bash
# plan-w-team-bypass-rate.sh
#
# Counts stage-file-bypass occurrences for a run and emits a 1-5 quality signal
# as JSON: {"count":N,"score":S,"source":"<path|none>"}.
#
# WHY (audit P1, docs/operations/pwt-principles-enforcement-audit-2026-06-02.md):
# plan-w-team.md says the lead "MUST emit" a `⚠ stage-file-bypass:` marker when
# it skips a stage-file Read outside the fast path, and that "retros MAY count"
# it. Both were unenforced prose — nothing counted the marker, so the sole
# observability for skill-drift was fictional. The marker is now ALSO appended to
# a slug-keyed state log when emitted (plan-w-team.md Fast Path), and this script
# turns that log into a deterministic, testable retro signal.
#
# This is a FLOOR: it counts markers the lead actually emitted. A silently
# skipped Read that never emitted a marker is not caught here — true detection
# would need a hook diffing actual stage-file Read tool-calls against the stage
# sequence (a deferred follow-up). It converts "retros MAY count" (aspirational)
# into "retro DOES count" (deterministic).
#
# Usage: plan-w-team-bypass-rate.sh --slug <slug> [--state-dir <dir>]
# Exit:  always 0 (advisory signal; never blocks a retro). Empty/missing log =>
#        count 0, score 5 (no bypass happened is the best score, not an error).
set -uo pipefail

SLUG=""
STATE_DIR_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --state-dir) STATE_DIR_OVERRIDE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    *) shift ;;
  esac
done

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${STATE_DIR_OVERRIDE:-$PROJECT_ROOT/.claude/state}"
LOG="$STATE_DIR/plan-w-team-bypass-${SLUG:-unscoped}.log"

count=0
source="none"
if [ -f "$LOG" ]; then
  # Count only genuine marker lines (defensive: ignore blank lines / stray text).
  count=$(grep -c 'stage-file-bypass:' "$LOG" 2>/dev/null || echo 0)
  source="$LOG"
fi
# Normalize to an integer (grep -c on a missing file path can yield noise).
case "$count" in ''|*[!0-9]*) count=0 ;; esac

# 0 bypasses = best (5); each bypass costs a point; floor at 1.
if   [ "$count" -le 0 ]; then score=5
elif [ "$count" -eq 1 ]; then score=4
elif [ "$count" -eq 2 ]; then score=3
elif [ "$count" -eq 3 ]; then score=2
else                          score=1
fi

printf '{"count":%d,"score":%d,"source":"%s"}\n' "$count" "$score" "$source"
exit 0
