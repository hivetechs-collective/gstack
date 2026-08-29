#!/usr/bin/env bash
# plan-w-team-verify-run.sh — bounded verification runner with stall semantics,
# process-group reaping, and a hard retry cap.
#
# WHY THIS EXISTS (2026-08-19 incident — docs/specs/pwt-host-load-and-stall-protection.md)
#   The ship stage of a 14-hour run spent 4.5 HOURS looping on "Running the full
#   suite and validators…" with no commit, no stage event, and no alert. Three
#   things were missing, and all three are structural:
#
#   1. NO REAPING. When a foreground Bash call hits the tool's 600s cap, the
#      harness stops waiting — it does not kill the process TREE. Each abandoned
#      attempt left its zsh wrapper and pytest children alive: ~17 orphan
#      wrappers spaced ~10 minutes apart (exactly the cap), plus hung pytest
#      processes 40+ minutes old. The leak was itself part of the load that
#      caused the next timeout.
#   2. NO STALL SEMANTICS. A timeout was indistinguishable from progress. The
#      step was simply retried, forever, with nothing written down.
#   3. NO CAP. Retry #47 is not a strategy. Past a small number of identical
#      timeouts the problem is the HOST, and the only useful next move is to
#      diagnose it and then decide — explicitly — between degraded mode and
#      halting to the operator.
#
#   The human asking "is it stuck?" was the detection mechanism. This script is
#   the replacement.
#
# CONTRACT
#   The command runs as the leader of its OWN process group, so a timeout kills
#   the whole tree (`kill -TERM -PGID`, grace, then `-KILL`). Zero surviving
#   descendants is the contract, and the survivor count is RECORDED rather than
#   assumed — `orphans_after` in every stall event.
#
# USAGE
#   plan-w-team-verify-run.sh --slug SLUG --step NAME [--timeout SEC]
#                             [--grace SEC] [--cap N] [--] CMD [ARG...]
#
# EXIT CODES (registry — keep in sync with tests/skill/cases/host-load-protection.bats)
#   0    the command succeeded
#   <n>  the command's own exit code when it failed on its own terms
#        (127 "not found" is an ORDINARY failure, never a stall)
#   10   STALL_TIMEOUT       — exceeded the bound, group reaped, retry permitted
#   12   STALL_CAP_EXCEEDED  — cap reached; no further attempt is made, a
#                              host-health diagnosis and distress artifact are
#                              written, and the caller MUST choose degraded mode
#                              or a USER_ESCALATION halt. Never a blind retry.
#   2    usage error
#
# ENV
#   PWT_DISABLE_STALL_DETECTION=1  kill switch — exec the command directly
#                                  (pre-change behavior exactly: no bound, no
#                                  reaping, no state written)
#   PWT_VERIFY_TIMEOUT_S           default bound, 900
#   PWT_VERIFY_GRACE_S             TERM→KILL grace, default 10
#   PWT_VERIFY_RETRY_CAP           consecutive-timeout cap K, default 3
#   PWT_PROJECT_ROOT_OVERRIDE      state-dir root (test seam, house pattern)
#
# bash 3.2 (mac-mini /bin/bash): no `declare -A`, no `${v,,}`, no mapfile.

set -u

TIMEOUT_S="${PWT_VERIFY_TIMEOUT_S:-900}"
GRACE_S="${PWT_VERIFY_GRACE_S:-10}"
CAP="${PWT_VERIFY_RETRY_CAP:-3}"
SLUG=""
STEP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --slug)    SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --step)    STEP="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --timeout) TIMEOUT_S="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --grace)   GRACE_S="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --cap)     CAP="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --)        shift; break ;;
    -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
    *)         break ;;
  esac
done

[ $# -gt 0 ] || { echo "✗ verify-run: no command given" >&2; exit 2; }

# ── Kill switch — FIRST, before any state resolution ────────────────────────
# A kill switch that still writes state is not a revert. `exec` replaces this
# process entirely, so the caller sees precisely what it would have seen if this
# wrapper had never existed.
if [ "${PWT_DISABLE_STALL_DETECTION:-0}" = "1" ]; then
  exec "$@"
fi

[ -n "$SLUG" ] || { echo "✗ verify-run: --slug is required" >&2; exit 2; }
[ -n "$STEP" ] || { echo "✗ verify-run: --step is required" >&2; exit 2; }

# The step name reaches a JSON key built by printf in the jq-absent path, so it
# must never carry a quote, a brace, or a newline.
__vr_safe() { printf '%s' "${1:-}" | tr -d '\n\r' | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//' | cut -c1-80; }
SLUG=$(__vr_safe "$SLUG")
STEP=$(__vr_safe "$STEP")
[ -n "$SLUG" ] && [ -n "$STEP" ] || { echo "✗ verify-run: --slug/--step reduced to empty" >&2; exit 2; }

case "$TIMEOUT_S" in ''|*[!0-9]*) TIMEOUT_S=900 ;; esac
case "$GRACE_S"   in ''|*[!0-9]*) GRACE_S=10 ;; esac
case "$CAP"       in ''|*[!0-9]*) CAP=3 ;; esac

ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="$ROOT/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
STALL_STATE="$STATE_DIR/plan-w-team-stall-${SLUG}.json"
EVENTS="$STATE_DIR/plan-w-team-stall-events-${SLUG}.jsonl"
DISTRESS="$STATE_DIR/plan-w-team-host-distress-${SLUG}.json"
LOCK_DIR="$STATE_DIR/plan-w-team-stall-${SLUG}.lock"
HOST_HEALTH="$ROOT/.claude/scripts/plan-w-team-host-health.sh"
[ -x "$HOST_HEALTH" ] || HOST_HEALTH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/plan-w-team-host-health.sh"

TS() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""; }
HAS_JQ=0
command -v jq >/dev/null 2>&1 && HAS_JQ=1

# ── Stall-state accounting (mkdir-locked read-modify-write) ─────────────────
# Two runners racing the counter could each read "2" and both proceed, granting
# a 4th attempt against a cap of 3 — the same class of bug the Fable ledger lock
# exists to prevent. macOS has no flock; mkdir is the atomic primitive.
__lock() {
  local i=0
  while [ "$i" -lt 50 ]; do
    mkdir "$LOCK_DIR" 2>/dev/null && { printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  # Never lose the command over a lock we could not take: proceed unlocked and
  # say so. Under-counting an attempt is safe; refusing to run the verification
  # is not.
  echo "⚠ verify-run: stall-state lock busy — proceeding without incrementing" >&2
  return 1
}
__unlock() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }

__read_consecutive() {
  [ -f "$STALL_STATE" ] || { echo 0; return 0; }
  local n=""
  if [ "$HAS_JQ" = "1" ]; then
    n=$(jq -r --arg s "$STEP" '.steps[$s].consecutive_timeouts // 0' "$STALL_STATE" 2>/dev/null)
  else
    n=$(sed -n "s/.*\"${STEP}\":{\"consecutive_timeouts\":\([0-9]*\).*/\1/p" "$STALL_STATE" 2>/dev/null | head -1)
  fi
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

__write_consecutive() {  # $1 = new count
  local n="$1" tmp="$STALL_STATE.tmp.$$"
  if [ "$HAS_JQ" = "1" ]; then
    if [ -f "$STALL_STATE" ]; then
      jq --arg s "$STEP" --arg ts "$(TS)" --argjson n "$n" \
        '.updated_at = $ts | .steps[$s].consecutive_timeouts = $n
         | .steps[$s].total_timeouts = ((.steps[$s].total_timeouts // 0) + (if $n > 0 then 1 else 0 end))
         | .steps[$s].last_ts = $ts' \
        "$STALL_STATE" > "$tmp" 2>/dev/null && mv -f "$tmp" "$STALL_STATE" 2>/dev/null
    else
      jq -n --arg slug "$SLUG" --arg s "$STEP" --arg ts "$(TS)" --argjson n "$n" \
        '{slug:$slug, updated_at:$ts,
          steps: {($s): {consecutive_timeouts:$n, total_timeouts:(if $n > 0 then 1 else 0 end), last_ts:$ts}}}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$STALL_STATE" 2>/dev/null
    fi
  else
    # Every value here is program-controlled: $SLUG/$STEP passed __vr_safe and
    # $n is an integer this script computed.
    printf '{"slug":"%s","updated_at":"%s","steps":{"%s":{"consecutive_timeouts":%s,"last_ts":"%s"}}}\n' \
      "$SLUG" "$(TS)" "$STEP" "$n" "$(TS)" > "$tmp" 2>/dev/null && mv -f "$tmp" "$STALL_STATE" 2>/dev/null
  fi
  rm -f "$tmp" 2>/dev/null || true
}

__emit_stall_event() {  # $1=attempt $2=elapsed $3=pgid $4=orphans $5=action
  if [ "$HAS_JQ" = "1" ]; then
    jq -cn --arg ts "$(TS)" --arg slug "$SLUG" --arg step "$STEP" \
      --argjson attempt "$1" --argjson timeout_s "$TIMEOUT_S" --argjson elapsed_s "$2" \
      --argjson pgid "$3" --argjson orphans_after "$4" --arg action "$5" \
      '{ts:$ts, slug:$slug, step:$step, attempt:$attempt, timeout_s:$timeout_s,
        elapsed_s:$elapsed_s, pgid:$pgid, orphans_after:$orphans_after, action:$action}' \
      >> "$EVENTS" 2>/dev/null || true
  else
    printf '{"ts":"%s","slug":"%s","step":"%s","attempt":%s,"timeout_s":%s,"elapsed_s":%s,"pgid":%s,"orphans_after":%s,"action":"%s"}\n' \
      "$(TS)" "$SLUG" "$STEP" "$1" "$TIMEOUT_S" "$2" "$3" "$4" "$5" >> "$EVENTS" 2>/dev/null || true
  fi
  # Fire-and-forget structured stage event for the manifest reader.
  if [ -x "$ROOT/.claude/scripts/pwt-manifest.sh" ]; then
    "$ROOT/.claude/scripts/pwt-manifest.sh" set --slug "$SLUG" --stage "stall:$STEP" >/dev/null 2>&1 || true
  fi
}

# ── Mandatory host-health diagnosis at the cap ──────────────────────────────
# The whole point of the cap is that the NEXT action is a diagnosis, not another
# attempt. The artifact is what makes the run legible after the fact — the
# 2026-08-19 run left nothing on disk explaining 4.5 hours.
__write_distress() {  # $1 = attempt count
  local health='{"supported":false,"breach":false}'
  if [ -x "$HOST_HEALTH" ]; then
    health=$("$HOST_HEALTH" --repo-root "$ROOT" 2>/dev/null || echo '{"supported":false,"breach":false}')
    [ -n "$health" ] || health='{"supported":false,"breach":false}'
  fi
  local tmp="$DISTRESS.tmp.$$"
  if [ "$HAS_JQ" = "1" ]; then
    jq -n --arg ts "$(TS)" --arg slug "$SLUG" --arg step "$STEP" \
      --argjson attempts "$1" --argjson timeout_s "$TIMEOUT_S" \
      --argjson health "$health" --arg source "verify-run" \
      '{ts:$ts, slug:$slug, source:$source, step:$step, attempts:$attempts,
        timeout_s:$timeout_s, host_health:$health,
        choices:["degraded-mode","user-escalation-halt"],
        guidance:"Cap reached. Choose ONE: (a) degraded mode — serial/backgrounded re-run with a longer bound, when host_health says the cause is internal; (b) USER_ESCALATION halt, when the cause is external capacity. A fourth blind retry is not a legal continuation."}' \
      > "$tmp" 2>/dev/null && mv -f "$tmp" "$DISTRESS" 2>/dev/null
  else
    printf '{"ts":"%s","slug":"%s","source":"verify-run","step":"%s","attempts":%s,"timeout_s":%s,"choices":["degraded-mode","user-escalation-halt"]}\n' \
      "$(TS)" "$SLUG" "$STEP" "$1" "$TIMEOUT_S" > "$tmp" 2>/dev/null && mv -f "$tmp" "$DISTRESS" 2>/dev/null
  fi
  rm -f "$tmp" 2>/dev/null || true
  printf '%s' "$health"
}

__report_cap() {  # $1=attempts $2=health-json
  cat >&2 <<CAPEOF
⛔ STALL_CAP_EXCEEDED — step '$STEP' timed out $1 consecutive times (bound ${TIMEOUT_S}s).
   Refusing a further attempt. A repeated identical timeout is a HOST verdict,
   not a flaky test — retry #4 would only add load.

   Host health at diagnosis:
$(printf '%s' "$2" | sed 's/^/     /')

   Distress artifact: $DISTRESS

   Choose ONE — never a fourth blind retry:
     (a) degraded-mode        re-run serially / backgrounded with a longer bound
                              (use when host_health shows the cause is INTERNAL)
     (b) user-escalation-halt emit the hard-gate escalation block and stop
                              (use when the cause is EXTERNAL capacity)
CAPEOF
}

# ── Entry gate: already at the cap? Do not run the command at all. ──────────
PRIOR=$(__read_consecutive)
if [ "$PRIOR" -ge "$CAP" ] 2>/dev/null; then
  HEALTH=$(__write_distress "$PRIOR")
  __report_cap "$PRIOR" "$HEALTH"
  exit 12
fi

# ── Run in its OWN process group ────────────────────────────────────────────
# `set -m` (job control) makes the backgrounded job a process-group LEADER, so
# its pid doubles as the pgid and `kill -SIGNAL -pid` reaches every descendant.
# Without this the children are in OUR group and a timeout kill would either
# miss them (kill by pid) or kill this script too (kill by our own group).
KILLED_MARK="${TMPDIR:-/tmp}/pwt-verify-killed.$$.$RANDOM"
rm -f "$KILLED_MARK" 2>/dev/null || true
START=$(date +%s)

set -m 2>/dev/null
"$@" &
CHILD=$!
set +m 2>/dev/null

# The watchdog gets its OWN process group too. Killing the subshell by pid would
# leave its `sleep` running — an orphan living up to the full bound, from the very
# script whose contract is "no orphans". Group-killing takes the sleep with it.
set -m 2>/dev/null
(
  # Watchdog. Counts DOWN the bound in 1-second slices rather than issuing one
  # `sleep $TIMEOUT_S`.
  #
  # Why not one long sleep: tearing the watchdog down then depends on the GROUP
  # kill landing. When `set -m` does not actually give this subshell its own
  # process group (it is best-effort — hence `2>/dev/null`), `kill -TERM -$pid`
  # fails, the `||` falls through to a pid-only kill, bash dies and its `sleep`
  # is re-parented to init — leaving a multi-HOUR orphan. Observed for real:
  # `sleep 3671`, PPID 1, from the very script whose contract is zero surviving
  # descendants. Short slices make the worst case a 1-second orphan that clears
  # itself, and the loop also exits the instant the child finishes, so the common
  # path needs no kill at all.
  waited=0
  while [ "$waited" -lt "$TIMEOUT_S" ]; do
    kill -0 "$CHILD" 2>/dev/null || exit 0   # child finished — nothing to reap
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$CHILD" 2>/dev/null; then
    : > "$KILLED_MARK" 2>/dev/null
    kill -TERM -"$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
    sleep "$GRACE_S"
    kill -KILL -"$CHILD" 2>/dev/null || kill -KILL "$CHILD" 2>/dev/null
  fi
) </dev/null >/dev/null 2>&1 &
WATCHDOG=$!
set +m 2>/dev/null

wait "$CHILD"
RC=$?
kill -TERM -"$WATCHDOG" 2>/dev/null || kill -TERM "$WATCHDOG" 2>/dev/null || true
wait "$WATCHDOG" 2>/dev/null || true
ELAPSED=$(( $(date +%s) - START ))

# ── Ordinary outcome (the command decided its own fate) ────────────────────
if [ ! -f "$KILLED_MARK" ]; then
  rm -f "$KILLED_MARK" 2>/dev/null || true
  if [ "$RC" -eq 0 ]; then
    # Success resets the consecutive-timeout streak — the cap is about a step
    # that CANNOT complete, not a step that was once slow.
    if [ "$PRIOR" -gt 0 ]; then
      __lock && { __write_consecutive 0; __unlock; } || __write_consecutive 0
    fi
  fi
  exit "$RC"
fi

# ── Stall: the bound fired and we reaped the group ─────────────────────────
rm -f "$KILLED_MARK" 2>/dev/null || true

# Count survivors in the group. Reported, not assumed: a non-zero count is the
# single most useful number in the next incident.
ORPHANS=0
if command -v pgrep >/dev/null 2>&1; then
  i=0
  while [ "$i" -lt 20 ]; do
    ORPHANS=$(pgrep -g "$CHILD" 2>/dev/null | grep -c . 2>/dev/null)
    case "$ORPHANS" in ''|*[!0-9]*) ORPHANS=0 ;; esac
    [ "$ORPHANS" -eq 0 ] && break
    sleep 0.1
    i=$((i + 1))
  done
fi

ATTEMPT=$((PRIOR + 1))
__lock && { __write_consecutive "$ATTEMPT"; __unlock; } || __write_consecutive "$ATTEMPT"

if [ "$ATTEMPT" -ge "$CAP" ] 2>/dev/null; then
  __emit_stall_event "$ATTEMPT" "$ELAPSED" "$CHILD" "$ORPHANS" "cap-exceeded"
  HEALTH=$(__write_distress "$ATTEMPT")
  __report_cap "$ATTEMPT" "$HEALTH"
  exit 12
fi

__emit_stall_event "$ATTEMPT" "$ELAPSED" "$CHILD" "$ORPHANS" "reaped-retry-permitted"
cat >&2 <<STALLEOF
⏱ STALL_TIMEOUT — step '$STEP' exceeded ${TIMEOUT_S}s (attempt $ATTEMPT of $CAP).
   Process group $CHILD reaped; surviving descendants: $ORPHANS.
   Event: $EVENTS
   A retry is permitted, but attempt $CAP triggers a mandatory host-health
   diagnosis instead of another run.
STALLEOF
exit 10
