#!/usr/bin/env bash
# plan-w-team-credential-wall-gate.sh — the step-completeness invariant for
# credential walls (brief: credential-wall-escalation, 2026-06-02).
#
# THE INVARIANT: no /plan-w-team stage step blocked on a credential can be skipped
# or marked done. Advancing past an incomplete deploy/ship step is impossible —
# this gate FAILS CLOSED.
#
# It is the read-side of the durable artifact written by
# plan-w-team-credential-wall-detect.sh. While any
#   .claude/state/plan-w-team-credwall-<SLUG>.json
# exists with "resolved": false, this gate exits 1 and re-surfaces the escalation
# so the ship/deploy step cannot be marked complete. Wired ENFORCING in
# 05-ship.md §6a-quinquies (before §6b) and referenced by 03-execute.md deploy
# discipline.
#
# Fail-CLOSED posture (the whole point of an un-bypassable gate):
#   - An artifact present with resolved=false  → exit 1 (BLOCK).
#   - An artifact present but MALFORMED        → exit 1 (BLOCK) — a garbled
#     artifact must never silently pass, exactly like §6c-ter's access-control gate.
#   - No artifact, OR every artifact resolved=true → exit 0 (PASS).
#
# Usage:
#   plan-w-team-credential-wall-gate.sh [--slug SLUG] [--state-dir DIR] [--json]
#   (default: glob ALL plan-w-team-credwall-*.json under the state dir, so
#    a best-effort SLUG mismatch on the writer side still blocks.)
#
# Exit: 0 = clear (no unresolved wall) · 1 = BLOCKED (unresolved wall) · 2 = bad args
# bash 3.2 safe.

set -u

SLUG=""; JSON=0
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$PROJECT_ROOT" ] || PROJECT_ROOT="$PWD"
PWD_STATE_DIR="$PWD/.claude/state"
ROOT_STATE_DIR="$PROJECT_ROOT/.claude/state"
STATE_DIR="$ROOT_STATE_DIR"
[ -d "$PWD_STATE_DIR" ] && STATE_DIR="$PWD_STATE_DIR"

while [ $# -gt 0 ]; do
    case "$1" in
        --slug)      SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --state-dir) STATE_DIR="${2:-$STATE_DIR}"; shift; [ $# -gt 0 ] && shift ;;
        --json)      JSON=1; shift ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           echo "credential-wall-gate: unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Build the candidate artifact list.
if [ -n "$SLUG" ]; then
    CANDIDATES="$STATE_DIR/plan-w-team-credwall-${SLUG}.json"
else
    CANDIDATES=""
    for f in "$STATE_DIR"/plan-w-team-credwall-*.json; do
        [ -e "$f" ] || continue
        CANDIDATES="$CANDIDATES
$f"
    done
fi

BLOCKED=0
BLOCK_DETAIL=""
for f in $CANDIDATES; do
    [ -e "$f" ] || continue
    # Parse resolved + key fields. A malformed file fails closed.
    PARSED="$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print('MALFORMED'); sys.exit(0)
resolved = d.get('resolved', False)
if resolved is True:
    print('RESOLVED')
else:
    print('UNRESOLVED\t' + str(d.get('missing_secret','?')) + '\t' + str(d.get('provider','?')) + '\t' + str(d.get('operator_action','')))
" "$f" 2>/dev/null || echo "MALFORMED")"

    case "$PARSED" in
        RESOLVED) : ;;  # cleared — does not block
        MALFORMED)
            BLOCKED=1
            BLOCK_DETAIL="${BLOCK_DETAIL}
  ✗ $f — MALFORMED artifact (fail-closed; fix or delete it)"
            ;;
        UNRESOLVED*)
            BLOCKED=1
            MS="$(printf '%s' "$PARSED" | cut -f2)"
            PV="$(printf '%s' "$PARSED" | cut -f3)"
            OA="$(printf '%s' "$PARSED" | cut -f4)"
            BLOCK_DETAIL="${BLOCK_DETAIL}
  ✗ $f — UNRESOLVED credential wall (provider=$PV, missing_secret=$MS)
      operator action: $OA"
            ;;
    esac
done

if [ "$BLOCKED" = "1" ]; then
    if [ "$JSON" = "1" ]; then
        printf '{"gate":"credential-wall","verdict":"BLOCKED"}\n'
    else
        echo "✗ Ship gate 6a-quinquies (credential-wall): deploy/ship step BLOCKED on an unresolved credential wall."
        echo "  This gate FAILS CLOSED — the step cannot be marked complete or skipped (USER_ESCALATION_HALT, blocked-external)."
        printf '%s\n' "$BLOCK_DETAIL"
        echo "  Resolve: provision the missing secret per shared/no-github-actions.md §\"Deploy Secret Access\""
        echo "           (or complete the documented login), set \"resolved\": true in the artifact, then re-run."
        echo "  See shared/secret-safety.md §REQ-6."
    fi
    exit 1
fi

if [ "$JSON" = "1" ]; then
    printf '{"gate":"credential-wall","verdict":"PASS"}\n'
else
    echo "✓ Ship gate 6a-quinquies (credential-wall): no unresolved credential wall."
fi
exit 0
