#!/usr/bin/env bash
# plan-w-team-friction-triage-due.sh — deterministic triage-due advisory for
# the /plan-w-team friction log (T4 friction-log right-sizing).
# Spec: docs/specs/bottom-line-loops-hardening.md R7/AC7.
#
# The friction log (.claude/state/plan-w-team-friction-log.jsonl, gitignored)
# had a writer (07-retro.md §8i), 3 schema generations across its live rows,
# an enum its own rows violated, and ZERO programmatic readers before this
# script. A launchd triage timer was right-sized AWAY (actor problem — see
# docs/operations/friction-log-audit-2026-07-06.md); this advisory rides the
# two channels that already have a human actor: session-start.sh (attended
# session start) and the 07-retro.md preflight (attended retro run).
#
# ── Default mode ────────────────────────────────────────────────────────
#   Counts friction-log rows AFTER the last {type:"triage"} marker row.
#   Rows >= PWT_FRICTION_TRIAGE_THRESHOLD (default 5) -> print ONE line
#   containing the literal marker FRICTION_TRIAGE_DUE. Otherwise silent.
#   Malformed (non-JSON) lines count as untriaged (never silently drop a
#   possible friction signal). Missing log file -> silent. ALWAYS exits 0 —
#   this is an advisory, never a blocking gate; callers key on stdout
#   content, not exit code.
#
# ── --validate <file> mode ──────────────────────────────────────────────
#   Fixture-based schema validator for the canonical gen-3 schema:
#     {ts, slug, category, severity, finding}
#   category must be one of:
#     spec-gap|builder-struggle|review-noise|hook-friction|hygiene|
#     orchestrator-quality|goal-evaluator-quality|other
#   ({type:"triage"} marker rows are accepted as-is, not schema-checked.)
#   Exits 0 if every row validates, 1 otherwise. This mode DOES use the
#   exit code deliberately — it is a CI/test primitive that makes the
#   07-retro.md §8i writer instruction mechanically checkable, not the
#   fail-open advisory path above.
#
# Wired fail-open (`[ -x ... ] && ... || true`) from:
#   .claude/hooks/session-start.sh
#   .claude/commands/plan-w-team/07-retro.md §8i preflight
#
# Env knobs:
#   PWT_FRICTION_TRIAGE_THRESHOLD   untriaged-row threshold (default 5)
#   PWT_PROJECT_ROOT_OVERRIDE       pin repo root (tests)
#
# bash 3.2 compatible (mac-mini /bin/bash): no associative arrays, no
# bash-4-only case-conversion parameter expansion, no bulk-array-read builtin.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null)" || exit 0

CANON_ENUM='spec-gap|builder-struggle|review-noise|hook-friction|hygiene|orchestrator-quality|goal-evaluator-quality|other'

# ── --validate <file> mode ────────────────────────────────────────────────
if [ "${1:-}" = "--validate" ]; then
    FILE="${2:-}"
    if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
        echo "[friction-triage-due] --validate: file required and must exist" >&2
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "[friction-triage-due] --validate: jq required" >&2
        exit 1
    fi

    BAD=0
    LINE_NO=0
    while IFS= read -r line || [ -n "$line" ]; do
        LINE_NO=$((LINE_NO + 1))
        [ -z "$line" ] && continue

        if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
            echo "[friction-triage-due] line $LINE_NO: invalid JSON" >&2
            BAD=1
            continue
        fi

        TYPE=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)
        if [ "$TYPE" = "triage" ]; then
            continue
        fi

        HASALL=$(printf '%s' "$line" | jq -e 'has("ts") and has("slug") and has("category") and has("severity") and has("finding")' 2>/dev/null)
        if [ "$HASALL" != "true" ]; then
            echo "[friction-triage-due] line $LINE_NO: missing canonical key(s) (ts/slug/category/severity/finding)" >&2
            BAD=1
            continue
        fi

        CAT=$(printf '%s' "$line" | jq -r '.category' 2>/dev/null)
        case "$CAT" in
            spec-gap|builder-struggle|review-noise|hook-friction|hygiene|orchestrator-quality|goal-evaluator-quality|other) : ;;
            *)
                echo "[friction-triage-due] line $LINE_NO: category '$CAT' not in enum ($CANON_ENUM)" >&2
                BAD=1
                ;;
        esac
    done < "$FILE"

    exit "$BAD"
fi

# ── Default mode: triage-due advisory ──────────────────────────────────────
REPO_ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-}"
if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT=""
    [ -z "$REPO_ROOT" ] && REPO_ROOT="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)"
fi
[ -z "$REPO_ROOT" ] && exit 0

LOG="$REPO_ROOT/.claude/state/plan-w-team-friction-log.jsonl"
[ -f "$LOG" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

THRESHOLD="${PWT_FRICTION_TRIAGE_THRESHOLD:-5}"
case "$THRESHOLD" in
    ''|*[!0-9]*) THRESHOLD=5 ;;
esac

# Pass 1: find the line number of the LAST {type:"triage"} marker row (0 = none).
LAST_MARKER_LINE=0
LINE_NO=0
while IFS= read -r line || [ -n "$line" ]; do
    LINE_NO=$((LINE_NO + 1))
    [ -z "$line" ] && continue
    TYPE=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)
    if [ "$TYPE" = "triage" ]; then
        LAST_MARKER_LINE=$LINE_NO
    fi
done < "$LOG"

# Pass 2: count rows AFTER the last marker. Malformed (non-JSON) lines count
# as untriaged — a parse failure must never silently drop a friction signal.
COUNT=0
LINE_NO=0
while IFS= read -r line || [ -n "$line" ]; do
    LINE_NO=$((LINE_NO + 1))
    [ -z "$line" ] && continue
    [ "$LINE_NO" -le "$LAST_MARKER_LINE" ] && continue
    if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
        TYPE=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)
        [ "$TYPE" = "triage" ] && continue
    fi
    COUNT=$((COUNT + 1))
done < "$LOG"

if [ "$COUNT" -ge "$THRESHOLD" ]; then
    echo "FRICTION_TRIAGE_DUE: $COUNT rows since last triage (threshold $THRESHOLD) — review $LOG"
fi

exit 0
