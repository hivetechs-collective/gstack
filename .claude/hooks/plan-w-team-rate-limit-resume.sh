#!/bin/bash
# plan-w-team-rate-limit-resume.sh — StopFailure auto-resume for /goal runs.
#
# THE GAP (2026-08-06, friction row 8): a /goal run's outer loop re-engages via
# the Stop hook, but a rate-limited turn dies as StopFailure — which nothing
# re-engages. The roster-restructure run parked idle for 90+ minutes over a
# 3-minute 429 wall at a 5h-block boundary, defeating the no-wall-clock design.
#
# THE FIX: on a rate-limit/overloaded StopFailure in a repo with a live
# /plan-w-team goal-state, write a resume ticket and spawn a DETACHED sleeper
# that waits until the usage block resets, then re-engages the parked session
# in its own tmux pane. Attempt ladder:
#   1. plain "continue" after the gate lifts
#   2. still parked → step the lead down a model rung (/model claude-opus-5)
#      and continue — the interactive-lead analog of the spawn sites'
#      --fallback-model degradation
#   3. still parked → one more wait + continue
#   4. give up loudly (desktop + ntfy via stop-failure-notify.sh)
#
# Scope guards (all must hold before anything is scheduled):
#   - error text matches rate-limit/429/overloaded/529
#   - a plan-w-team goal-state file exists in this repo (i.e. /goal-initiated
#     work; ordinary sessions just get the existing halt notification)
#   - the session has a TMUX pane to re-engage (bg sessions are the daemon's
#     job to resume; we only handle attended-launched /goal leads)
#   - no fresh ticket already exists for this session (dedupe)
#
# Contract: NEVER blocks, never exits non-zero, bash 3.2 safe.
# Kill switch: PWT_RATE_RESUME_DISABLE=1
# Test seams:  PWT_RATE_RESUME_TEST=1  → sleeper waits 2s, injections are
#              echoed to the log instead of sent; PWT_RATE_RESUME_STATE_DIR
#              overrides the state dir.

MODE="${1:-hook}"

STATE_DIR="${PWT_RATE_RESUME_STATE_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}/.claude/state}"
LOG="$STATE_DIR/rate-resume.log"
log() { printf '%s | %s\n' "$(date "+%Y-%m-%d %H:%M:%S")" "$1" >> "$LOG" 2>/dev/null; }

# ─── sleeper mode: runs detached; args: <sid8> <pane> <wait_secs> <transcript> ──
if [ "$MODE" = "--sleeper" ]; then
  sid8="$2"; pane="$3"; wait_secs="$4"; transcript="$5"
  ticket="$STATE_DIR/rate-resume-$sid8.ticket"

  session_active() {
    # transcript written in the last 120s = session is doing something
    [ -f "$transcript" ] || return 1
    local m now
    m=$(stat -f %m "$transcript" 2>/dev/null || stat -c %Y "$transcript" 2>/dev/null || echo 0)
    now=$(date +%s)
    [ $((now - m)) -lt 120 ]
  }

  inject() {
    # $1 = text to type into the pane
    if [ "${PWT_RATE_RESUME_TEST:-0}" = "1" ]; then
      log "TEST-INJECT [$sid8] $1"
      return 0
    fi
    tmux has-session 2>/dev/null || { log "inject failed: no tmux server"; return 1; }
    tmux send-keys -t "$pane" "$1" 2>/dev/null || { log "inject failed: pane $pane gone"; return 1; }
    sleep 1
    tmux send-keys -t "$pane" Enter 2>/dev/null
  }

  woke_up() {
    # did the session start writing again within 90s of an injection?
    local i=0
    while [ $i -lt 9 ]; do
      sleep 10
      session_active && return 0
      i=$((i+1))
    done
    return 1
  }

  log "sleeper armed [$sid8] pane=$pane wait=${wait_secs}s"
  sleep "$wait_secs"

  attempt=1
  while [ $attempt -le 3 ]; do
    if session_active; then
      log "self-healed before attempt $attempt [$sid8] — ticket cleared"
      rm -f "$ticket" 2>/dev/null
      exit 0
    fi
    case $attempt in
      1) inject "continue — auto-resume: the rate-limit gate has lifted (plan-w-team rate-limit-resume, attempt 1)" ;;
      2) # fallback-model rung: step the lead down a tier, then continue
         inject "/model claude-opus-5"
         sleep 5
         inject "continue — auto-resume attempt 2: stepped down to claude-opus-5 (fallback rung) after the previous attempt stayed rate-limited; continue the pipeline" ;;
      3) inject "continue — auto-resume: final attempt (plan-w-team rate-limit-resume, attempt 3)" ;;
    esac
    if woke_up; then
      log "RESUMED [$sid8] on attempt $attempt"
      rm -f "$ticket" 2>/dev/null
      # quiet success ping through the existing notify channel (best-effort)
      TOPIC="${CLAUDE_HALT_NTFY_TOPIC:-}"
      [ -z "$TOPIC" ] && [ -f "$HOME/.config/claude/halt-ntfy-topic" ] && TOPIC=$(head -1 "$HOME/.config/claude/halt-ntfy-topic" 2>/dev/null)
      [ -n "$TOPIC" ] && command -v curl >/dev/null 2>&1 && \
        curl -fsS -m 5 -H "Title: Claude auto-resume" -d "goal run $sid8 auto-resumed after rate-limit gate (attempt $attempt)" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1
      exit 0
    fi
    log "attempt $attempt did not wake [$sid8]"
    attempt=$((attempt+1))
    [ $attempt -le 3 ] && sleep 600
  done

  log "GAVE UP [$sid8] after 3 attempts — surfacing loudly"
  # feed the repeated-give-up breaker (2 give-ups in 24h → stop re-arming)
  GU="$STATE_DIR/rate-resume-$sid8.gaveup"
  prev=$(cat "$GU" 2>/dev/null | tr -dc '0-9')
  printf '%s' "$(( ${prev:-0} + 1 ))" > "$GU" 2>/dev/null
  rm -f "$ticket" 2>/dev/null
  NOTIFY="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/hooks/stop-failure-notify.sh"
  [ -x "$NOTIFY" ] && printf '{"error":"auto-resume FAILED for goal run %s after 3 attempts — manual continue needed"}' "$sid8" | "$NOTIFY" >/dev/null 2>&1
  exit 0
fi

# ─── hook mode: StopFailure stdin ─────────────────────────────────────────────
[ "${PWT_RATE_RESUME_DISABLE:-0}" = "1" ] && exit 0

INPUT=$(cat 2>/dev/null || true)

ERR=$(printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for k in ("error","errorMessage","message","reason","stopReason"):
    v=d.get(k)
    if isinstance(v,str) and v.strip():
        print(v[:200]); break
' 2>/dev/null)

case "$ERR" in
  *rate*limit*|*rate_limit*|*429*|*overloaded*|*529*|*Overloaded*) : ;;
  *) exit 0 ;;   # not a capacity wall — the notify hook already handled it
esac

# only /goal-initiated work gets auto-resume
ls "$STATE_DIR"/plan-w-team-goal-*.json >/dev/null 2>&1 || exit 0

# need a pane to re-engage; bg sessions are the daemon's resume problem
[ -n "${TMUX_PANE:-}" ] || { log "rate-limit StopFailure but no TMUX pane — skipping (bg session)"; exit 0; }

SID="${CLAUDE_CODE_SESSION_ID:-}"
SID8=$(printf '%s' "$SID" | cut -c1-8)
[ -z "$SID8" ] && exit 0

TICKET="$STATE_DIR/rate-resume-$SID8.ticket"
if [ -f "$TICKET" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$TICKET" 2>/dev/null || stat -c %Y "$TICKET" 2>/dev/null || echo 0) ))
  [ "$age" -lt 7200 ] && exit 0   # sleeper already armed
fi

# Repeated-give-up breaker: a wall that outlives full attempt ladders is not a
# 5h block — it's the WEEKLY cap (or an account problem). Re-arming hourly for
# days would be futile churn. After 2 give-ups inside 24h, stop re-arming and
# say so once, loudly.
GAVEUP="$STATE_DIR/rate-resume-$SID8.gaveup"
if [ -f "$GAVEUP" ]; then
  g_age=$(( $(date +%s) - $(stat -f %m "$GAVEUP" 2>/dev/null || stat -c %Y "$GAVEUP" 2>/dev/null || echo 0) ))
  g_count=$(cat "$GAVEUP" 2>/dev/null | tr -dc '0-9')
  if [ "$g_age" -lt 86400 ] && [ "${g_count:-0}" -ge 2 ]; then
    log "breaker OPEN [$SID8]: $g_count give-ups in 24h — likely weekly cap; not re-arming"
    exit 0
  fi
  [ "$g_age" -ge 86400 ] && rm -f "$GAVEUP" 2>/dev/null
fi
printf '%s | %s | %s\n' "$(date "+%Y-%m-%d %H:%M:%S")" "$SID" "$ERR" > "$TICKET" 2>/dev/null

# wait-until, best source first:
#   1. a reset timestamp stated in the error text itself (Anthropic 429s often
#      carry one — authoritative even for weekly caps)
#   2. the local ccusage active-block end time (5h block walls)
#   3. fallback 15 min
WAIT=900
ERR_WAIT=$(printf '%s' "$ERR" | /usr/bin/python3 -c '
import sys,re,datetime
s=sys.stdin.read()
m=re.search(r"reset[s]?\s+at\s+([0-9T:\-\+\.Z]+)", s, re.I)
if m:
    try:
        t=datetime.datetime.fromisoformat(m.group(1).replace("Z","+00:00"))
        now=datetime.datetime.now(datetime.timezone.utc)
        d=int((t-now).total_seconds())+90
        if d>0: print(min(d, 86400))
    except Exception: pass
' 2>/dev/null)
if [ "${PWT_RATE_RESUME_TEST:-0}" = "1" ]; then
  WAIT=2
elif [ -n "$ERR_WAIT" ]; then
  WAIT="$ERR_WAIT"
elif command -v ccusage >/dev/null 2>&1; then
  W=$(ccusage blocks --json 2>/dev/null | /usr/bin/python3 -c '
import json,sys,datetime
try:
    d=json.load(sys.stdin)
    blocks=d.get("blocks") or d
    for b in (blocks if isinstance(blocks,list) else []):
        if b.get("isActive"):
            end=b.get("endTime") or b.get("end")
            if end:
                t=datetime.datetime.fromisoformat(end.replace("Z","+00:00"))
                now=datetime.datetime.now(datetime.timezone.utc)
                print(max(120,int((t-now).total_seconds())+90))
            break
except Exception: pass
' 2>/dev/null)
  [ -n "$W" ] && WAIT="$W"
fi
# clamp block-derived waits to 2h; an error-stated reset (weekly cap) may
# legitimately be longer and is already capped at 24h in the parser
if [ -z "$ERR_WAIT" ]; then
  [ "$WAIT" -gt 7200 ] 2>/dev/null && WAIT=7200
fi

# transcript path for liveness checks (project dir = cwd with / and . → -)
PROJ_DIR=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}" | sed 's/[\/.]/-/g')
TRANSCRIPT="$HOME/.claude/projects/$PROJ_DIR/$SID.jsonl"

log "rate-limit StopFailure [$SID8] err='$ERR' — sleeper in ${WAIT}s (pane $TMUX_PANE)"
(
  set -m 2>/dev/null
  nohup "$0" --sleeper "$SID8" "$TMUX_PANE" "$WAIT" "$TRANSCRIPT" </dev/null >/dev/null 2>&1 &
) 2>/dev/null

exit 0
