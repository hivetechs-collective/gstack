#!/usr/bin/env bash
# plan-w-team-fable-guard.sh
#
# The single gate for every Fable 5 spawn in /plan-w-team (Model Tiering v3).
# Owns the four things that keep a bounded, deliberate rung from becoming the
# 2026-07 Fable-default incident again (CHANGELOG.md 1.51.0 entry): env
# overrides, the weekly-bucket budget, the per-run escalation cap, and the
# evidence ledger.
#
# Usage:
#   plan-w-team-fable-guard.sh --slug <slug> --kind <consult|escalation>
#                              [--nontrivial true|false] [--task <id>] [--note <text>]
#
# Exit codes:
#   0   ALLOW — caller MAY spawn exactly ONE Fable-pinned agent
#   10  SKIP  — caller MUST continue on Opus; the run is NOT failed
#   2   usage error (bad or missing arguments only)
#
# === FAIL-CLOSED DIRECTION (read before changing anything) ===
# "Fail open" in this design means FAIL OPEN TO SKIPPING FABLE. An unknown
# budget, an unwritable ledger, a corrupt ledger, or a missing jq must never
# authorize spend — and must never fail the run. This is the INVERSE of the
# usual "unknown -> allow" reading. Inverting it silently re-opens the incident
# class this script exists to prevent.
#
# The caller contract is equally load-bearing: ONLY exit 0 authorizes a spawn.
# Any other exit — including 127 (script absent in a consumer repo that synced
# the agent but not this file) — means continue on Opus.

set -u

EXIT_ALLOW=0
EXIT_SKIP=10
EXIT_USAGE=2

SLUG=""
KIND=""
NONTRIVIAL=""
TASK=""
NOTE=""

usage_error() {
  echo "usage: $(basename "$0") --slug <slug> --kind <consult|escalation> [--nontrivial true|false] [--task <id>] [--note <text>]" >&2
  [ -n "${1:-}" ] && echo "error: $1" >&2
  exit "$EXIT_USAGE"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --slug)       [ $# -ge 2 ] || usage_error "--slug needs a value"; SLUG="$2"; shift 2 ;;
    --kind)       [ $# -ge 2 ] || usage_error "--kind needs a value"; KIND="$2"; shift 2 ;;
    --nontrivial) [ $# -ge 2 ] || usage_error "--nontrivial needs a value"; NONTRIVIAL="$2"; shift 2 ;;
    --task)       [ $# -ge 2 ] || usage_error "--task needs a value"; TASK="$2"; shift 2 ;;
    --note)       [ $# -ge 2 ] || usage_error "--note needs a value"; NOTE="$2"; shift 2 ;;
    # NEVER exit 0 here: in this script the exit code IS the authorization, so a
    # help path returning 0 would read as ALLOW to any caller that forwarded a
    # -h-shaped token through.
    -h|--help)    grep '^#' "$0" | head -30; exit "$EXIT_SKIP" ;;
    *)            usage_error "unknown argument: $1" ;;
  esac
done

# --- argument validation -----------------------------------------------------
# The slug becomes a filesystem path component, so it is validated rather than
# trusted (shell-safety.md). Bound is 128, not the canonical 64: real
# pwt-goal-derived slugs run to ~94 characters.
[ -n "$SLUG" ] || usage_error "--slug is required"
[ "${#SLUG}" -le 128 ] || usage_error "--slug exceeds 128 characters"
case "$SLUG" in
  *[!A-Za-z0-9._-]*) usage_error "--slug may contain only [A-Za-z0-9._-]" ;;
  *..*)              usage_error "--slug may not contain '..'" ;;
esac

case "$KIND" in
  consult|escalation) : ;;
  "")                 usage_error "--kind is required" ;;
  *)                  usage_error "--kind must be 'consult' or 'escalation'" ;;
esac

# --- canonical state location ------------------------------------------------
# ONE ledger per slug regardless of which checkout invoked us. A worktree-local
# ledger would make the cap "2 per checkout" instead of "2 per run" — the same
# split that stranded goal-state files (01-specification.md §1.5 dual-write note).
resolve_root() {
  if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    printf '%s' "$PWT_PROJECT_ROOT_OVERRIDE"
    return
  fi
  local cdir
  cdir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  case "$cdir" in
    # Empty => not a git repo. Emit NOTHING so the caller fails closed rather
    # than forking the ledger into whatever cwd happens to be.
    "") printf '%s' "" ;;
    /*) dirname "$cdir" ;;
    # A RELATIVE common-dir resolves against the current directory, so a call
    # from a subdirectory would otherwise land the ledger in that subdirectory.
    *)  (cd "$(dirname "$cdir")" 2>/dev/null && pwd) || printf '%s' "" ;;
  esac
}

# Numeric validation. `[ "$x" -gt N ]` does NOT return false on a digit string
# wider than 64 bits — it ERRORS with "integer expected" and returns status 2.
# With `set -e` absent, a `[ ... ] && clamp` line then skips its own clamp and a
# later `[ ... ] && skip` skips its own skip, falling through to ALLOW. That is a
# one-variable bypass of both the budget and the cap, so width is checked BEFORE
# any arithmetic comparison.
is_bounded_int() {  # $1 value  $2 max-digits  $3 max-value
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le "$2" ] || return 1
  [ "$1" -le "$3" ] || return 1
  return 0
}

ROOT=$(resolve_root)
# An unresolvable root is an UNKNOWN, and unknowns must not silently pick a
# location: a $PWD fallback forks the ledger per directory, quietly resetting the
# cap. Fail closed instead (matters in consumer repos, tarball exports, and CI
# checkouts without .git — all of which reach this branch).
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "SKIP kind=$KIND reason=root-unresolved bucket=unknown${TASK:+ task=$TASK}"
  exit "$EXIT_SKIP"
fi
STATE_DIR="$ROOT/.claude/state"
LEDGER="$STATE_DIR/plan-w-team-fable-ledger-${SLUG}.jsonl"
LOCK_DIR="$STATE_DIR/plan-w-team-fable-ledger-${SLUG}.lock"

# --- ledger row emission -----------------------------------------------------
# Rows are built by jq --arg, never by printf interpolation. A --note carrying a
# quote or a newline would otherwise emit a malformed row; because the cap reads
# this file, a malformed row is not just bad logging, it is a cap bypass.
LOCK_HELD=0
release_lock() { [ "$LOCK_HELD" -eq 1 ] && rmdir "$LOCK_DIR" 2>/dev/null; LOCK_HELD=0; }
trap release_lock EXIT
# A bare `trap handler INT TERM` handler RETURNS and execution resumes at the
# next statement — so a signal during the multi-second plan-usage call would be
# swallowed and the script would proceed into the authorization decision (and
# would have dropped the mutex mid-sequence). Signals must ABORT, never allow.
trap 'release_lock; echo "SKIP kind=$KIND reason=interrupted bucket=unknown"; exit $EXIT_SKIP' INT TERM

# Serialize read-count-append. Without it two concurrent escalations can both
# read count=1 and both proceed, granting 3 against a cap of 2.
acquire_lock() {
  local i=0
  while [ "$i" -lt 50 ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then LOCK_HELD=1; return 0; fi
    # Stale-lock reclaim: a kill -9 or OOM between mkdir and rmdir would
    # otherwise disable the rung PERMANENTLY for this slug, with a reason string
    # indistinguishable from an unwritable state dir. Reclaim after 5 minutes.
    if [ -d "$LOCK_DIR" ]; then
      local age
      age=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || date +%s) ))
      if [ "$age" -gt 300 ] 2>/dev/null; then rmdir "$LOCK_DIR" 2>/dev/null || true; fi
    fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

# Bound the note by TOTAL bytes, not per line: `cut -c1-500` is line-oriented,
# so a multi-line note survives it intact and can exceed PIPE_BUF, tearing an
# append. A torn row fails closed (jq -s rejects it) but does so PERMANENTLY for
# this slug, so the bound matters.
NOTE=$(printf '%s' "$NOTE" | tr '\n\r' '  ' | cut -c1-500)

append_row() {  # $1 verdict  $2 reason  $3 bucket
  command -v jq >/dev/null 2>&1 || return 1
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  [ -w "$STATE_DIR" ] || return 1
  local row
  row=$(jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg slug "$SLUG" --arg kind "$KIND" --arg verdict "$1" \
    --arg reason "$2" --arg bucket "$3" --arg task "$TASK" --arg note "$NOTE" \
    '{ts:$ts,slug:$slug,kind:$kind,verdict:$verdict,reason:$reason,bucket:$bucket,task:$task,note:$note}' \
    2>/dev/null) || return 1
  printf '%s\n' "$row" >> "$LEDGER" 2>/dev/null || return 1
  return 0
}

skip() {  # $1 reason  $2 bucket
  append_row "SKIP" "$1" "${2:-}" || true
  release_lock
  echo "SKIP kind=$KIND reason=$1 bucket=${2:-unknown}${TASK:+ task=$TASK}"
  exit "$EXIT_SKIP"
}

allow() {  # $1 bucket
  if ! append_row "ALLOW" "ok" "$1"; then
    # Cannot record => cannot allow. A cap whose evidence store is unwritable
    # is not a cap; allowing here would spend with no record and no counter.
    release_lock
    echo "SKIP kind=$KIND reason=cannot-record bucket=$1${TASK:+ task=$TASK}"
    exit "$EXIT_SKIP"
  fi
  release_lock
  echo "ALLOW kind=$KIND reason=ok bucket=$1${TASK:+ task=$TASK}"
  exit "$EXIT_ALLOW"
}

# --- 0. serialize BEFORE any ledger append -----------------------------------
# Writability first: without this an unwritable state dir would spin the whole
# lock retry budget and then report `lock-held`, masking the real cause.
mkdir -p "$STATE_DIR" 2>/dev/null || true
if [ ! -d "$STATE_DIR" ] || [ ! -w "$STATE_DIR" ]; then
  echo "SKIP kind=$KIND reason=cannot-record bucket=unknown${TASK:+ task=$TASK}"
  exit "$EXIT_SKIP"
fi

# Every skip() below appends a row, so the lock must be held before the first
# one — otherwise the kill-switch and not-hard paths write unserialized.
if ! acquire_lock; then
  # Deliberately does NOT append: if we could not take the lock, an unlocked
  # append is exactly the tear this lock exists to prevent.
  echo "SKIP kind=$KIND reason=lock-held bucket=unknown${TASK:+ task=$TASK}"
  exit "$EXIT_SKIP"
fi

# --- 1. kill switches (highest precedence) -----------------------------------
if [ "${PLAN_W_TEAM_DISABLE_FABLE:-}" = "1" ]; then skip "disabled"; fi
if [ "$KIND" = "consult" ] && [ "${PLAN_W_TEAM_DISABLE_FABLE_CONSULT:-}" = "1" ]; then skip "disabled"; fi
if [ "$KIND" = "escalation" ] && [ "${PLAN_W_TEAM_DISABLE_FABLE_ESCALATION:-}" = "1" ]; then skip "disabled"; fi

# --- 2. consult gating -------------------------------------------------------
# The trigger is §1b-pre's EXISTING non-triviality classifier, passed in by the
# caller — this script deliberately does not re-implement a classifier.
# FORCE overrides only this skip; it never bypasses budget or cap below.
if [ "$KIND" = "consult" ] \
   && [ "$NONTRIVIAL" != "true" ] \
   && [ "${PLAN_W_TEAM_FORCE_FABLE_CONSULT:-}" != "1" ]; then
  skip "not-hard"
fi

# --- 3. ledger integrity (fail closed) ---------------------------------------
command -v jq >/dev/null 2>&1 || skip "ledger-unreadable"

if [ -s "$LEDGER" ]; then
  # Any unparseable line fails the whole read. Ignoring bad lines WAS the
  # bypass: an ignored line may be a real ALLOW, so the cap would grant extra.
  jq -s '.' "$LEDGER" >/dev/null 2>&1 || skip "ledger-unreadable"
fi

# --- 4. escalation cap -------------------------------------------------------
# Width-checked before any comparison (see is_bounded_int): a 20-digit CAP would
# otherwise error out of both its own clamp and the cap check, granting unlimited
# escalations. Anything invalid falls back to the DEFAULT, never to "unbounded".
CAP="${PLAN_W_TEAM_FABLE_ESCALATION_CAP:-2}"
is_bounded_int "$CAP" 2 10 || CAP=2

if [ "$KIND" = "escalation" ]; then
  USED=0
  if [ -s "$LEDGER" ]; then
    # Field-exact selection: a --note containing the word "escalation" must not
    # be counted, and SKIP rows must not consume the cap.
    USED=$(jq -s '[.[] | select(.verdict=="ALLOW" and .kind=="escalation")] | length' "$LEDGER" 2>/dev/null || echo "")
    case "$USED" in *[!0-9]*|'') skip "ledger-unreadable" ;; esac
  fi
  [ "$USED" -ge "$CAP" ] && skip "cap-exhausted"
fi

# --- 5. budget ---------------------------------------------------------------
# Read the Fable-scoped weekly bucket — the actual 50%-inclusion bucket. There
# is deliberately NO fallback to .seven_day.utilization: that is the ALL-MODELS
# bucket, systematically lower and causally unrelated, so falling back to it
# would silently degrade this guard into a permissive unrelated number the day
# "Fable" is renamed at GA. An unresolvable bucket is reported as such instead.
PLAN_USAGE_CMD="${PWT_PLAN_USAGE_CMD:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)/plan-usage.sh}"
USAGE_JSON=$("$PLAN_USAGE_CMD" 2>/dev/null || echo '{}')
[ -n "$USAGE_JSON" ] || USAGE_JSON='{}'

BUCKET=$(printf '%s' "$USAGE_JSON" | jq -r '
  [ .limits[]?
    | select(.kind == "weekly_scoped")
    | select(((.scope.model.display_name) // "") | test("Fable"; "i"))
    | .percent ] | first // empty' 2>/dev/null || echo "")

[ -n "$BUCKET" ] || skip "bucket-unresolved"

# The percent is UNTRUSTED input (whatever plan-usage emits), so it gets the same
# width check as the operator vars — a 20-digit percent is all-digits and would
# otherwise pass a naive validator and then error the comparison into ALLOW.
BUCKET_INT="${BUCKET%%.*}"
is_bounded_int "$BUCKET_INT" 3 100 || skip "bucket-unresolved"

# Scale plausibility: if the upstream ever reshapes percent into a 0..1 fraction,
# every value would floor to 0 and the budget guard would never trip. Treat a
# fractional-looking sub-1 value as an unresolved bucket rather than as "0% used".
case "$BUCKET" in
  0.*) skip "bucket-unresolved" ;;
esac

MAXPCT="${PLAN_W_TEAM_FABLE_BUDGET_MAX_PCT:-80}"
is_bounded_int "$MAXPCT" 3 100 || MAXPCT=80

[ "$BUCKET_INT" -ge "$MAXPCT" ] && skip "budget" "$BUCKET_INT"

# --- 6. authorized -----------------------------------------------------------
allow "$BUCKET_INT"
