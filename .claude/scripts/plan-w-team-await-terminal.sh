#!/usr/bin/env bash
# plan-w-team-await-terminal.sh — event-driven supervisor wait (principle #2).
#
# Blocks until a /plan-w-team run reaches a terminal/halt state, then exits so
# the harness re-invokes the supervisor THE INSTANT the state flips. Run it via
# Bash(run_in_background: true): the harness contract "a backgrounded command
# re-invokes you when it exits" turns this into an event-driven wake — replacing
# active polling on a guessed 30–60s cadence (which wastes dev time between a
# worker finishing and the supervisor noticing, and burns a supervisor turn per
# unchanged tick).
#
# Watches the goal-state file's `terminal_state`, which the goal-evaluator writes
# for ALL terminal/halt states (SUCCESS, USER_ESCALATION_HALT, LOW_CONFIDENCE_
# STREAK, API_HALT) — so one field covers the happy AND sad paths. Optionally
# also watches a worker session id and reports it gone (debounced against the
# flaky `claude agents --json`, per the C2 lesson).
#
# Usage:
#   plan-w-team-await-terminal.sh --slug <slug> [--worker-sid <sid>] \
#       [--interval <s>] [--heartbeat <s>] [--state-dir <dir>]
#
# Env (overridable): PWT_AWAIT_INTERVAL_S (10), PWT_AWAIT_HEARTBEAT_S (1800),
#                    PWT_AWAIT_GONE_CONFIRM (2).
#
# Exit codes:
#   0  terminal/halt reached     → stdout: "terminal=<STATE> reason=<...> slug=<slug>"
#   0  watched worker gone       → stdout: "terminal=WORKER_GONE sid=<sid> ..." (only with --worker-sid)
#   3  heartbeat re-arm          → stdout: "rearm ..." — NOT a terminal. The supervisor
#         re-checks state and re-launches the wait. This is a heartbeat, NOT a
#         wall-clock cap on the work (principle #3: no turn/time caps) — it only
#         re-invokes the supervisor so a silently-hung worker still surfaces.
#   2  bad usage
set -u

SLUG=""; WORKER_SID=""; STATE_DIR_OVERRIDE=""
INTERVAL="${PWT_AWAIT_INTERVAL_S:-10}"
HEARTBEAT="${PWT_AWAIT_HEARTBEAT_S:-1800}"
GONE_CONFIRM="${PWT_AWAIT_GONE_CONFIRM:-2}"
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG="${2:-}"; shift 2 ;;
    --worker-sid) WORKER_SID="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR_OVERRIDE="${2:-}"; shift 2 ;;
    --interval) INTERVAL="${2:-10}"; shift 2 ;;
    --heartbeat) HEARTBEAT="${2:-1800}"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$SLUG" ] && [ -z "$WORKER_SID" ]; then
  echo "usage: plan-w-team-await-terminal.sh --slug <slug> [--worker-sid <sid>]" >&2
  exit 2
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${STATE_DIR_OVERRIDE:-$PROJECT_ROOT/.claude/state}"
GOAL="$STATE_DIR/plan-w-team-goal-${SLUG}.json"
EXT="$PROJECT_ROOT/.claude/scripts/claude-agents-extended.sh"

elapsed=0
gone_streak=0
while :; do
  # (1) PRIMARY — terminal/halt via goal-state (reliable: the evaluator writes it).
  if [ -n "$SLUG" ] && [ -f "$GOAL" ]; then
    TS=$(jq -r '.terminal_state // ""' "$GOAL" 2>/dev/null || echo "")
    if [ -n "$TS" ] && [ "$TS" != "null" ]; then
      TR=$(jq -r '.terminal_reason // ""' "$GOAL" 2>/dev/null || echo "")
      echo "terminal=$TS reason=$TR slug=$SLUG"
      exit 0
    fi
  fi

  # (2) SECONDARY — watched worker vanished without writing terminal. Debounced
  #     against flaky `claude agents --json`: require GONE_CONFIRM consecutive
  #     absences from a VALID (array, non-empty) listing before trusting it.
  if [ -n "$WORKER_SID" ] && [ -x "$EXT" ]; then
    AGENTS=$(CLAUDE_AGENTS_RETRY="${CLAUDE_AGENTS_RETRY:-3}" "$EXT" --json 2>/dev/null || echo "")
    if printf '%s' "$AGENTS" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
      if printf '%s' "$AGENTS" | jq -e --arg s "${WORKER_SID:0:8}" 'any(.[]?; ((.sessionId//"")|tostring)[0:8]==$s)' >/dev/null 2>&1; then
        gone_streak=0   # still present
      else
        gone_streak=$((gone_streak + 1))
        if [ "$gone_streak" -ge "$GONE_CONFIRM" ]; then
          echo "terminal=WORKER_GONE sid=$WORKER_SID slug=$SLUG (absent ${gone_streak} consecutive checks)"
          exit 0
        fi
      fi
    fi
  fi

  # (3) Heartbeat re-arm — NOT a cap. Re-invoke the supervisor to re-check + re-arm.
  if [ "$HEARTBEAT" -gt 0 ] && [ "$elapsed" -ge "$HEARTBEAT" ]; then
    echo "rearm elapsed=${elapsed}s slug=$SLUG — no terminal yet; supervisor re-checks state and re-arms (heartbeat, NOT a halt)"
    exit 3
  fi

  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done
