#!/bin/bash
# plan-w-team-followups.sh — read/close the recursive-improvement follow-up ledger.
#
# The ledger (.claude/state/plan-w-team-recursive-followups.jsonl) is append-only
# and cross-run durable. Before this script the ONLY way to close a row was to
# hand-edit JSONL, so rows accumulated: 34 open as of 2026-07-26, oldest
# 2026-06-07.
#
# DELIBERATELY NOT IMPLEMENTED: auto-close by slug match. A follow-up is a
# DEFERRAL recorded *during* run X — it is precisely the work X did not do.
# Closing rows because X shipped would erase the backlog rather than drain it,
# converting a visible debt into an invisible one. Closure requires a reason,
# always, and is recorded with who/when so the ledger stays auditable.
#
# Append-only: `close` writes a NEW row carrying the resolution rather than
# rewriting history, matching how the retro and Step-5 writers already work.
#
# bash 3.2 compatible. Fail-open on a missing/unreadable ledger — this is
# advisory tooling and must never block a run.
#
# Usage:
#   plan-w-team-followups.sh list [--all] [--limit N]   open rows (default 20)
#   plan-w-team-followups.sh stats                      counts + oldest age
#   plan-w-team-followups.sh show <index>               full row
#   plan-w-team-followups.sh close <index> "<reason>"   append a resolution row
#   plan-w-team-followups.sh --json stats               machine-readable

set -e

REPO_ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-$(cd "$(dirname "$0")/../.." && pwd)}"
LEDGER="$REPO_ROOT/.claude/state/plan-w-team-recursive-followups.jsonl"
JSON_OUT=0

[ "${1:-}" = "--json" ] && { JSON_OUT=1; shift; }
CMD="${1:-list}"; shift || true

command -v jq >/dev/null 2>&1 || { echo "followups: jq not available — skipping (advisory tooling)" >&2; exit 0; }
[ -f "$LEDGER" ] || { echo "followups: no ledger at $LEDGER (nothing to do)" >&2; exit 0; }

# Open rows, newest last, with their 0-based index in the raw file.
_open_rows() {
  jq -rs 'to_entries | map(select(.value.status=="open"))' "$LEDGER" 2>/dev/null || echo '[]'
}

case "$CMD" in
  list)
    LIMIT=20; ALL=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --all) ALL=1; shift ;;
        --limit) LIMIT="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ "$ALL" = "1" ] && LIMIT=100000
    _open_rows | jq -r --argjson lim "$LIMIT" '
      (length) as $n
      | .[-$lim:][]
      | "[\(.key)] \(.value.slug // "?")\n      \((.value.text // .value.note // "(no text)") | gsub("\n";" ") | .[0:150])"
    '
    n=$(_open_rows | jq 'length')
    shown=$([ "$n" -lt "$LIMIT" ] && echo "$n" || echo "$LIMIT")
    [ "$n" -gt "$shown" ] && echo "  … showing $shown of $n open (use --all)"
    exit 0
    ;;

  stats)
    jq -rs --argjson j "$JSON_OUT" '
      (map(select(.status=="open"))) as $open
      | (map(select(.status=="done" or .status=="closed"))) as $closed
      | ($open | map(.ts // .timestamp // "") | map(select(. != "")) | sort | first) as $oldest
      | if $j == 1
        then {open: ($open|length), closed: ($closed|length), total: length, oldest_open: $oldest}
        else "open: \($open|length)   closed: \($closed|length)   total: \(length)\noldest open: \($oldest // "n/a")"
        end
    ' "$LEDGER"
    exit 0
    ;;

  show)
    IDX="${1:?usage: show <index>}"
    jq -rs --argjson i "$IDX" '.[$i] // "no such index"' "$LEDGER"
    exit 0
    ;;

  close)
    IDX="${1:?usage: close <index> \"<reason>\"}"
    REASON="${2:?a reason is required — closure without one is how a backlog gets erased}"
    ROW=$(jq -rs --argjson i "$IDX" '.[$i] // empty' "$LEDGER")
    [ -n "$ROW" ] || { echo "followups: no row at index $IDX" >&2; exit 1; }
    STATUS=$(printf '%s' "$ROW" | jq -r '.status // "?"')
    [ "$STATUS" = "open" ] || { echo "followups: row $IDX is already '$STATUS' — nothing to close" >&2; exit 1; }
    SLUG=$(printf '%s' "$ROW" | jq -r '.slug // "?"')
    # Append a resolution row; never rewrite history.
    printf '%s\n' "$ROW" | jq -c \
      --arg r "$REASON" \
      --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '. + {status:"done", resolution:$r, resolved_at:$t, resolved_by:"plan-w-team-followups.sh", closes_index:'"$IDX"'}' \
      >> "$LEDGER"
    echo "closed [$IDX] $SLUG — $REASON"
    exit 0
    ;;

  *)
    sed -n '1,30p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac
