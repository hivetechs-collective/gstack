#!/usr/bin/env bash
# plan-w-team-spec-fanout-tally.sh
#
# Scores the Step-1 §1b-pre spec fan-out advisory records
# (.claude/state/plan-w-team-spec-fanout-<slug>.json) by COUNT, whatever shape
# the writer used, and gives the keep/park verdict for the AUTO default.
#
#   record mode:  plan-w-team-spec-fanout-tally.sh --file <record> [--json]
#   tally mode:   plan-w-team-spec-fanout-tally.sh [--state-dir <dir>]... [--min-runs N]
#                   [--park-below X] [--window N] [--json]
#
# WHY (recursive-followup row 29, 2026-09-24): the §1b-pre writer contract names
# an integer `findings_folded`, but 2 of 8 real records stored a LIST. Retro
# §8j-nonies read the field with an untyped `jq -r`, so for those runs it
# printed a raw JSON array where the "≈0?" comparison expected a number, and the
# ledger's "tally across the records" step was a manual per-file read.
#
# Rules this script holds (pinned by tests/skill/cases/spec-fanout-tally.bats):
#   * A count is a non-negative integer (≤ 999999999), an array (its length),
#     or a 1-9 digit string. Anything else is UNSCORABLE — never read as 0,
#     because a silent 0 biases the verdict toward PARK.
#   * A record whose reviewers all failed (degraded:true, or every recorded
#     verdict — top-level `verdicts` and `attempts[].verdicts` — is "failed") is
#     listed but not counted: the lead's self-review is not a fan-out catch. A
#     `fallback` key alone is NOT a degraded marker (under Model Tiering v9
#     "fallback" also names the model fallback chain).
#   * `findings_folded_blocker` (optional, same count rules) is reported but never
#     changes the verdict: it is the BLOCKER-class subset a future re-check can
#     use, because "folded > 0" alone is close to unfalsifiable (an LLM critic
#     always finds something — the degraded self-review record still folded 3).
#   * Nothing a record controls reaches the output except validated integers and
#     fixed tokens. A record filename outside plan-w-team-spec-fanout-[A-Za-z0-9._-]+.json
#     is never read and prints as <unprintable>: the goal evaluator greps the
#     transcript for `AC<N>: PASS` and status blocks, and a filename is text an
#     LLM-written run chose.
#   * Symlinks, non-regular files (a FIFO would block jq forever) and files over
#     1 MiB are UNREADABLE and never opened.
#   * jq filters are literals; values enter only through --arg/--argjson after a
#     regex check; records are read on stdin (a path starting with "-" is never a flag).
#
# Verdict (tally mode): INSUFFICIENT when fewer than --min-runs records score, or
# more than half the records found were excluded; PARK when the median folded
# count is below --park-below or at least half the scored runs folded 0; KEEP
# otherwise. Median, not mean: one 40-finding run must not hide four zeros.
#
# Exit: 0 for every data condition (advisory — never blocks a retro), including
# jq missing (status "unavailable"). 2 for a usage error only. bash 3.2 compatible.
set -uo pipefail

SCHEMA="pwt-spec-fanout-tally/1"
SAFE_RE='^plan-w-team-spec-fanout-[A-Za-z0-9._-]+\.json$'
MAX_BYTES=1048576

usage() {
  cat >&2 <<'EOF'
Usage:
  plan-w-team-spec-fanout-tally.sh --file <record.json> [--json]
  plan-w-team-spec-fanout-tally.sh [--state-dir <dir>]... [--min-runs N] [--park-below X]
                                   [--window N] [--json]

  --file        score one §1b-pre fan-out record (record mode)
  --state-dir   scan <dir>/plan-w-team-spec-fanout-*.json (repeatable; first dir wins
                on a duplicate basename; default <repo-root>/.claude/state)
  --min-runs    scored runs needed for a verdict (default 5)
  --park-below  PARK when the median folded count is below this (default 1)
  --window      only the newest N records found, by file mtime (default: all)
  --json        machine-readable output (schema pwt-spec-fanout-tally/1)
EOF
}

die_usage() {
  echo "plan-w-team-spec-fanout-tally: $1" >&2
  usage
  exit 2
}

MODE="tally"
FILE=""
JSON=0
MIN_RUNS=5
PARK_BELOW=1
WINDOW=0
DIRS=()
NDIRS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || die_usage "--file needs a path"
      MODE="record"; FILE="$2"; shift 2 ;;
    --state-dir)
      [ $# -ge 2 ] || die_usage "--state-dir needs a directory"
      DIRS[NDIRS]="$2"; NDIRS=$((NDIRS + 1)); shift 2 ;;
    --min-runs)
      [ $# -ge 2 ] || die_usage "--min-runs needs a value"
      [[ "$2" =~ ^[1-9][0-9]{0,5}$ ]] || die_usage "--min-runs must be a positive integer: $2"
      MIN_RUNS="$2"; shift 2 ;;
    --park-below)
      [ $# -ge 2 ] || die_usage "--park-below needs a value"
      # No leading zeros: the value goes to jq --argjson, which rejects "01" as JSON.
      [[ "$2" =~ ^(0|[1-9][0-9]{0,5})(\.[0-9]{1,6})?$ ]] || die_usage "--park-below must be a non-negative number: $2"
      PARK_BELOW="$2"; shift 2 ;;
    --window)
      [ $# -ge 2 ] || die_usage "--window needs a value"
      [[ "$2" =~ ^[1-9][0-9]{0,5}$ ]] || die_usage "--window must be a positive integer: $2"
      WINDOW="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

# ── jq probe (before anything else — no git, no file reads without it) ──────
# A jq without regex support (no oniguruma) would fail every record's filter and
# blame the writer ("invalid-json"); probe the capability once instead.
JQ_REASON=""
if ! command -v jq >/dev/null 2>&1; then
  JQ_REASON="jq-not-found"
elif ! jq -n '"1" | test("1")' >/dev/null 2>&1; then
  JQ_REASON="jq-no-regex"
fi
if [ -n "$JQ_REASON" ]; then
  if [ "$JSON" = "1" ]; then
    printf '{"schema":"%s","status":"unavailable","reason":"%s"}\n' "$SCHEMA" "$JQ_REASON"
  elif [ "$MODE" = "record" ]; then
    echo "Spec fan-out: n/a ($JQ_REASON — record not scored)"
  else
    echo "spec-fanout-tally: verdict=n/a status=unavailable ($JQ_REASON)"
  fi
  exit 0
fi

# One literal filter per record. Input is `jq -s` over the file, so a record
# holding zero or several JSON values is caught as not-one-json-value.
RECORD_FILTER='
def cnt:
  # `floor` canonicalizes: jq 1.7 keeps literal formatting, so 26.0 / 1e2 would
  # otherwise print back as "26.0" / "1E+2".
  if type == "number" then (if . >= 0 and . == floor and . <= 999999999 then floor else null end)
  elif type == "array" then length
  elif type == "string" then (if test("^[0-9]{1,9}$") then tonumber else null end)
  else null end;
def shp: if type == "string" and test("^[0-9]{1,9}$") then "digit-string" else type end;
def allfailed:
  [ (.verdicts? // [] | if type == "array" then .[] else empty end),
    (.attempts? // [] | if type == "array" then .[] else empty end
       | (.verdicts? // []) | if type == "array" then .[] else empty end) ]
  | map(select(type == "string")) as $v
  | ($v | length) > 0 and all($v[]; ascii_downcase == "failed");
if length != 1 then
  {status: "unreadable", reason: "not-one-json-value", folded: null, deferred: null,
   blocker: null, folded_shape: null, degraded: false}
else
  .[0]
  | if type == "object" then
      {folded: (.findings_folded | cnt), deferred: (.findings_deferred | cnt),
       blocker: (.findings_folded_blocker | cnt),
       folded_shape: (.findings_folded | shp),
       degraded: ((.degraded == true) or allfailed)}
      | .status = (if .folded == null then "unscorable" else "ok" end)
      | .reason = null
    else
      {status: "unscorable", reason: null, folded: null, deferred: null,
       blocker: null, folded_shape: ("top-level-" + type), degraded: false}
    end
end'

# unreadable_row <fixed-token-reason>
unreadable_row() {
  printf '{"status":"unreadable","reason":"%s","folded":null,"deferred":null,"blocker":null,"folded_shape":null,"degraded":false}\n' "$1"
}

# classify <path> — prints one compact JSON row. Never opens a symlink, a
# non-regular file, or anything over MAX_BYTES.
classify() {
  local f="$1" sz out
  if [ -L "$f" ]; then unreadable_row symlink; return; fi
  if [ ! -e "$f" ]; then
    printf '{"status":"missing","reason":null,"folded":null,"deferred":null,"blocker":null,"folded_shape":null,"degraded":false}\n'
    return
  fi
  if [ ! -f "$f" ]; then unreadable_row not-regular; return; fi
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  case "$sz" in ''|*[!0-9]*) unreadable_row unreadable; return ;; esac
  if [ "$sz" -gt "$MAX_BYTES" ]; then unreadable_row too-large; return; fi
  out=$(jq -c -s "$RECORD_FILTER" < "$f" 2>/dev/null) || out=""
  case "$out" in '{'*) printf '%s\n' "$out" ;; *) unreadable_row invalid-json ;; esac
}

# ── record mode ─────────────────────────────────────────────────────────────
if [ "$MODE" = "record" ]; then
  ROW=$(classify "$FILE")
  if [ "$JSON" = "1" ]; then
    printf '%s\n' "$ROW" | jq -c --arg sch "$SCHEMA" --arg src "$FILE" '{schema: $sch, source: $src} + .'
  else
    printf '%s\n' "$ROW" | jq -r '
      if .status == "ok" then
        "Spec fan-out: \(.folded) findings folded pre-freeze, "
        + (if .deferred == null then "deferred count unscorable." else "\(.deferred) deferred." end)
        + (if .blocker == null then "" else " (\(.blocker) BLOCKER-class)" end)
        + (if .degraded then " (degraded run — reviewers failed; lead self-review, not a fan-out catch)" else "" end)
      elif .status == "unscorable" then
        "Spec fan-out: record unscorable (findings_folded shape=\(.folded_shape)) — writer broke the integer-count contract (§1b-pre)."
      elif .status == "unreadable" then
        "Spec fan-out: record unreadable (\(.reason)) — not scored."
      else
        "Spec fan-out: n/a (no record at the given path)."
      end'
  fi
  exit 0
fi

# ── tally mode ──────────────────────────────────────────────────────────────
if [ "$NDIRS" -eq 0 ]; then
  ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  DIRS[0]="$ROOT/.claude/state"
  NDIRS=1
fi

NL='
'
SEEN="$NL"
ROWS=""
DIRS_MISSING=0
i=0
while [ "$i" -lt "$NDIRS" ]; do
  d="${DIRS[$i]}"
  i=$((i + 1))
  # A mistyped dir must not read like an empty one: count it, report it, and keep
  # tallying the others (the verdict line carries dirs_missing=N).
  if [ ! -d "$d" ] || [ ! -r "$d" ]; then
    DIRS_MISSING=$((DIRS_MISSING + 1))
    echo "plan-w-team-spec-fanout-tally: warning: state dir missing or unreadable — skipped: $d" >&2
    continue
  fi
  for f in "$d"/plan-w-team-spec-fanout-*.json; do
    # An unmatched glob stays literal; skip it (a dangling symlink still counts as found).
    [ -e "$f" ] || [ -L "$f" ] || continue
    b="${f##*/}"
    case "$SEEN" in *"$NL$b$NL"*) continue ;; esac
    SEEN="$SEEN$b$NL"
    if [[ "$b" =~ $SAFE_RE ]]; then
      name="$b"
      row=$(classify "$f")
    else
      name="<unprintable>"
      row=$(unreadable_row unsafe-name)
    fi
    mtime=$(date -r "$f" +%s 2>/dev/null || echo 0)
    case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
    ann=$(printf '%s\n' "$row" | jq -c --arg r "$name" --arg d "$d" --argjson m "$mtime" \
      '. + {record: $r, dir: $d, mtime: $m}' 2>/dev/null) || ann=""
    case "$ann" in
      '{'*) ;;
      # Never drop a found record: keep it, visibly unreadable.
      *) ann=$(unreadable_row row-annotate-failed | jq -c --arg r "$name" --arg d "$d" \
           '. + {record: $r, dir: $d, mtime: 0}') ;;
    esac
    ROWS="$ROWS$ann$NL"
  done
done

AGG_FILTER='
def r2: (. * 100 | round) / 100;
def median: sort | length as $n
  | if $n == 0 then 0
    elif $n % 2 == 1 then .[($n - 1) / 2]
    else (.[$n / 2 - 1] + .[$n / 2]) / 2 end;
length as $total
| (if $win > 0 then (sort_by(-.mtime) | .[:$win]) else . end) as $rows
| ($rows | map(. + {counted: (.status == "ok" and (.degraded | not))})) as $all
| ($all | map(select(.counted))) as $sc
| ($sc | map(.folded)) as $f
| ($f | length) as $n
| ($rows | length) as $found
| ($found - $n) as $excl
| ($f | median | r2) as $med
| ($f | map(select(. == 0)) | length) as $zero
| {schema: $sch, status: "ok",
   runs_found: $found, runs_scored: $n, runs_excluded: $excl,
   total_folded: ($f | add // 0),
   total_deferred: ($sc | map(.deferred // empty) | add // 0),
   deferred_unscorable: ($sc | map(select(.deferred == null)) | length),
   blocker_folded_total: ($sc | map(.blocker // empty) | add // 0),
   blocker_runs: ($sc | map(select(.blocker != null)) | length),
   median_folded: $med,
   mean_folded: (if $n == 0 then 0 else (($f | add) / $n | r2) end),
   runs_zero: $zero, min_runs: $min, park_below: $pb, window: $win,
   runs_total: $total, dirs_scanned: ($dscan - $dmiss), dirs_missing: $dmiss,
   verdict: (if $n < $min or ($excl * 2) > $found then "INSUFFICIENT"
             elif $med < $pb or ($zero * 2) >= $n then "PARK"
             else "KEEP" end),
   runs: ($all | sort_by(.record)
          | map({record, dir, status, reason, folded, deferred, blocker, folded_shape, degraded, counted}))}'

AGG=$(printf '%s' "$ROWS" | jq -c -s --arg sch "$SCHEMA" --argjson min "$MIN_RUNS" \
  --argjson pb "$PARK_BELOW" --argjson win "$WINDOW" \
  --argjson dscan "$NDIRS" --argjson dmiss "$DIRS_MISSING" "$AGG_FILTER")

# Never a silent blank: an aggregation failure is reported, still exit 0 (advisory).
case "$AGG" in
  '{'*) ;;
  *)
    if [ "$JSON" = "1" ]; then
      printf '{"schema":"%s","status":"error","reason":"aggregate-failed"}\n' "$SCHEMA"
    else
      echo "spec-fanout-tally: verdict=n/a status=error (aggregation failed — no verdict)"
    fi
    exit 0 ;;
esac

if [ "$JSON" = "1" ]; then
  printf '%s\n' "$AGG"
else
  printf '%s\n' "$AGG" | jq -r '
    (.runs[] | "  \(.record)  status=\(.status) folded=\(.folded // "-") deferred=\(.deferred // "-") degraded=\(.degraded) counted=\(.counted)"),
    "spec-fanout-tally: verdict=\(.verdict) scored=\(.runs_scored)/\(.runs_found) excluded=\(.runs_excluded) folded=\(.total_folded) median=\(.median_folded) mean=\(.mean_folded) zero=\(.runs_zero)"
    + (if .window > 0 then " window=\(.window) of \(.runs_total)" else "" end)
    + (if .dirs_missing > 0 then " dirs_missing=\(.dirs_missing)" else "" end)'
fi
exit 0
