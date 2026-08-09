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
#   plan-w-team-followups.sh add --slug S --text T      queue one open row
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

# ── Effective-status resolution ──────────────────────────────────────────────
# The ledger is append-only: `close` appends a resolution row and never rewrites
# the original, which therefore keeps `status:"open"` FOREVER. So "is this row
# open?" cannot be answered by reading the row alone — it is open only if no
# LATER row closes it, which a resolution row records as `closes_index: <i>`
# (the closed row's 0-based index in the raw file; stable because we only ever
# append).
#
# Reading `.status` directly — as list/stats did until 2026-08-02 — meant a
# closed row stayed listed as open and the counters never moved. The ledger was
# structurally undrainable: closing rows only ever ADDED "closed" rows on top of
# a permanently-open one. Row 1 was closed on 2026-07-31 and still listed open,
# which then let a second run close it again.
#
# $cidx = the DISTINCT set of closed indices, so a double-close (the old bug's
# own residue) counts once and cannot inflate `closed`.
_JQ_PRELUDE='
  (map(.closes_index // empty) | map(tonumber? // empty) | unique) as $cidx
  | to_entries as $e
  | ($e | map(select(.value | has("closes_index") | not))) as $orig
  | ($orig
     | map(select(.key as $k | ($cidx | index($k)) == null))
     | map(select(.value.status == "open"))) as $open
'

# Open rows, newest last, with their 0-based index in the raw file.
_open_rows() {
  jq -rs "$_JQ_PRELUDE"' | $open' "$LEDGER" 2>/dev/null || echo '[]'
}

# Is raw index $1 already closed by a resolution row?
# Coerces via tonumber in lockstep with $cidx above: a hand-edited or legacy
# ledger may carry `closes_index` as a STRING, and a strict `==` would miss it
# and silently re-allow the double-close this guard exists to stop.
_close_count() {
  jq -rs --argjson i "$1" \
    '[.[] | select((.closes_index // empty | tonumber? // empty) == $i)] | length' \
    "$LEDGER" 2>/dev/null || echo 0
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
    # Counts are over ORIGINAL follow-up rows only ($orig — resolution rows are
    # bookkeeping, not backlog). closed = originals no longer open, which covers
    # both closes_index closures and legacy rows written `status:"done"` inline.
    jq -rs --argjson j "$JSON_OUT" "$_JQ_PRELUDE"'
      | ($open | map(.value.ts // .value.timestamp // "")
              | map(select(. != "")) | sort | first) as $oldest
      | ($orig | length) as $total
      | ($open | length) as $nopen
      | ($total - $nopen) as $nclosed
      | if $j == 1
        then {open: $nopen, closed: $nclosed, total: $total, oldest_open: $oldest}
        else "open: \($nopen)   closed: \($nclosed)   total: \($total)\noldest open: \($oldest // "n/a")"
        end
    ' "$LEDGER"
    exit 0
    ;;

  show)
    IDX="${1:?usage: show <index>}"
    jq -rs --argjson i "$IDX" '.[$i] // "no such index"' "$LEDGER"
    exit 0
    ;;

  add)
    # Append ONE open row. Exists because `04-fix-first-review.md` §5d outcome 3
    # has always TOLD the lead to "record a follow-up in the recursive-followups
    # ledger" while supplying no command — so the only append path was
    # plan-w-team-retro-capture.sh, which is a retro-time, once-per-run writer.
    # A Step-5 consolidation deferral needs to queue at the moment it is decided.
    #
    # Row shape is identical to retro-capture.sh's (ts, slug, source, status,
    # text) so `list`/`stats`/`close` treat both writers' rows the same, and the
    # append is built with `jq -cn --arg` — never printf interpolation — because
    # a malformed row is invisible to the close-aware reader and silently drops
    # a backlog item rather than merely logging badly.
    #
    # NOTE: rows here can become agent instructions. plan-w-team-followup-drain.sh
    # feeds an open row's `.text` to pwt-goal.sh --worker-only, so `--text`
    # should be self-contained enough to brief a run, not a bare label.
    ADD_SLUG=""; ADD_TEXT=""; ADD_SOURCE="followups-add"
    while [ $# -gt 0 ]; do
      case "$1" in
        --slug)   ADD_SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --text)   ADD_TEXT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --source) ADD_SOURCE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        *) echo "followups: unknown add argument: $1" >&2; exit 2 ;;
      esac
    done
    [ -n "$ADD_SLUG" ] || { echo "followups: add requires --slug" >&2; exit 2; }
    [ -n "$ADD_TEXT" ] || { echo "followups: add requires --text — a row with no text is unactionable" >&2; exit 2; }
    case "$ADD_SLUG" in
      *[!a-z0-9-]*) echo "followups: --slug may contain only [a-z0-9-]" >&2; exit 2 ;;
    esac
    [ "${#ADD_SLUG}" -le 128 ] || { echo "followups: --slug exceeds 128 characters" >&2; exit 2; }
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg slug "$ADD_SLUG" \
           --arg source "$ADD_SOURCE" \
           --arg text "$ADD_TEXT" \
      '{ts:$ts, slug:$slug, source:$source, status:"open", text:$text}' >> "$LEDGER" || {
        echo "followups: could not append to $LEDGER" >&2; exit 1; }
    echo "queued [$ADD_SLUG] $ADD_TEXT"
    exit 0
    ;;

  close)
    IDX="${1:?usage: close <index> \"<reason>\"}"
    REASON="${2:?a reason is required — closure without one is how a backlog gets erased}"
    ROW=$(jq -rs --argjson i "$IDX" '.[$i] // empty' "$LEDGER")
    [ -n "$ROW" ] || { echo "followups: no row at index $IDX" >&2; exit 1; }
    STATUS=$(printf '%s' "$ROW" | jq -r '.status // "?"')
    [ "$STATUS" = "open" ] || { echo "followups: row $IDX is already '$STATUS' — nothing to close" >&2; exit 1; }
    # The row's own `.status` stays "open" forever (append-only), so it cannot
    # detect a prior closure — only a later resolution row can. Without this the
    # same row is closeable an unbounded number of times; row 1 was in fact
    # closed twice (2026-07-31, 2026-08-02) before this guard existed.
    PRIOR=$(_close_count "$IDX")
    [ "${PRIOR:-0}" -eq 0 ] || {
      echo "followups: row $IDX was already closed by $PRIOR resolution row(s) — nothing to close" >&2
      echo "  (see: plan-w-team-followups.sh show $IDX)" >&2
      exit 1
    }
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
