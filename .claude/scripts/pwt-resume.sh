#!/usr/bin/env bash
# pwt-resume.sh — resume-that-continues front over plan-w-team-land.sh resume (BRIEF §5/§6b, C5).
#
# A thin, reuse-first front: it does NOT re-implement the resume mechanics (the 36-char UUID, resume
# from inside the worktree, delivery verification, watcher teardown) — those live in pwt-steer.sh,
# which plan-w-team-land.sh resume already delegates to. pwt-resume.sh adds two things on top:
#   1. a labelled reason (limit-death | steer | host-restart | gate-answered) recorded in the audit;
#   2. a SANCTIONED gate-answered re-entry that clears an EVALUATOR-stamped terminal with provenance,
#      so a legitimately-answered hard gate (push-ack, etc.) does not leave the goal permanently
#      halted while the work is ready to finish.
#
# Reuse: it reuses the run's worktree + UUID (via land.sh→pwt-steer), the land.sh refusal guards
# (already-landed / already-terminal / no worker_sid / no steer-bin), and the ONE shared launch-env
# function (pwt-launch-env.sh, sourced below and consumed by pwt-steer's resume) — one definition
# across pwt-goal.sh, pwt-steer.sh and pwt-resume.sh (AC4, grep-provable).
#
# Usage: pwt-resume.sh --slug S --reason <limit-death|steer|host-restart|gate-answered>
#                      [--at ISO] [--gate SITE] [--dry-run]
# Exit:  0 launched / cleared · 6 refused (nothing mutated) · 2 usage · 3 environment
#
# Ungoverned it is an operator convenience with no behaviour change; the governor (phase-2 C4) calls
# it after a decision.json. Kill switches inherited from land.sh / pwt-steer.

set -u

SLUG=""; REASON=""; AT=""; GATE=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)     SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --reason)   REASON="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --at)       AT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --gate)     GATE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          shift ;;
  esac
done
[ -n "$SLUG" ]   || { echo "pwt-resume: --slug required" >&2; exit 2; }
[ -n "$REASON" ] || { echo "pwt-resume: --reason required (limit-death|steer|host-restart|gate-answered)" >&2; exit 2; }
case "$REASON" in
  limit-death|steer|host-restart|gate-answered) : ;;
  *) echo "pwt-resume: invalid --reason '$REASON'" >&2; exit 2 ;;
esac
[ -n "$AT" ] || AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

# The ONE shared launch-env module — sourced so the resume path uses the SAME leak-scrub and
# launch-env builder pwt-goal.sh and pwt-steer.sh use (the resume mechanics themselves run through
# pwt-steer, which calls __pwt_build_launch_env). Here we call __pwt_scrub_leak_env DIRECTLY before
# delegating, so a leaked PLAN_W_TEAM_ALLOW_CONTEXT_BLIND / FORCE_FABLE_CONSULT in this front's env
# cannot ride into land.sh → pwt-steer. Absence is non-fatal (pwt-steer sources its own copy).
if [ -r "$DIR/pwt-launch-env.sh" ]; then
  # shellcheck disable=SC1090
  . "$DIR/pwt-launch-env.sh"
  command -v __pwt_scrub_leak_env >/dev/null 2>&1 && __pwt_scrub_leak_env
fi

# MAIN checkout + state dir (git-common-dir idiom; PWT_PROJECT_ROOT_OVERRIDE wins for tests).
if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
  MAIN="${PWT_PROJECT_ROOT_OVERRIDE%/}"
else
  CDIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  case "$CDIR" in
    /*) MAIN=$(dirname "$CDIR") ;;
    "") MAIN=$(git rev-parse --show-toplevel 2>/dev/null || echo "") ;;
    *)  MAIN=$(cd "$(dirname "$CDIR")" 2>/dev/null && pwd || echo "") ;;
  esac
fi
STATE="$MAIN/.claude/state"
GOAL="$STATE/plan-w-team-goal-${SLUG}.json"
AUDIT="$STATE/plan-w-team-land-audit.jsonl"
LAND="${PWT_LAND_BIN:-$DIR/plan-w-team-land.sh}"

__audit() {  # $1=action $2=detail
  [ -d "$STATE" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg slug "$SLUG" --arg action "$1" \
     --arg reason "$REASON" --arg detail "$2" \
     '{ts:$ts,slug:$slug,tool:"pwt-resume",action:$action,reason:$reason,detail:$detail}' \
     >> "$AUDIT" 2>/dev/null || true
}

# ── gate-answered: clear an EVALUATOR-stamped terminal WITH provenance ─────────
# A hard-gate answer (push-ack, secret-scan-allow, scope-unlock) leaves the goal-state stamped
# terminal by the evaluator; land.sh resume then refuses ("already terminal") forever. Only an
# EVALUATOR-stamped terminal is clearable, only via this sanctioned path, and only WITH provenance
# (terminal_state_source=gate-answered:<actor>) so the clear is attributable. A bound supervisor
# writing terminal_state directly stays lane-guard-denied (this path records who cleared and why).
if [ "$REASON" = "gate-answered" ]; then
  [ -f "$GOAL" ] || { echo "pwt-resume: no goal-state for $SLUG at $GOAL" >&2; exit 6; }
  TS=$(jq -r '.terminal_state // ""' "$GOAL" 2>/dev/null || echo "")
  SRC=$(jq -r '.terminal_state_source // ""' "$GOAL" 2>/dev/null || echo "")
  if [ -z "$TS" ] || [ "$TS" = "null" ]; then
    __audit "gate-answered-noop" "terminal_state already null — nothing to clear"
    echo "pwt-resume: run is not terminal; proceeding to a normal resume" >&2
  elif [ "$SRC" != "evaluator" ]; then
    echo "✗ pwt-resume: refusing to clear a terminal not stamped by the evaluator (terminal_state_source='${SRC:-unset}'). Only an evaluator halt is gate-answer-clearable." >&2
    __audit "gate-answered-refused" "terminal_state_source=${SRC:-unset} (not evaluator)"
    exit 6
  else
    ACTOR="${CLAUDE_CODE_SESSION_ID:-operator}"; ACTOR="${ACTOR:0:8}"
    [ -n "$GATE" ] || GATE="unspecified"
    if [ "$DRY" = "1" ]; then
      echo "pwt-resume: dry-run — would clear evaluator terminal (was $TS) → terminal_state_source=gate-answered:$ACTOR gate=$GATE"
    else
      jq --arg src "gate-answered:$ACTOR" --arg at "$AT" --arg gate "$GATE" \
         '.terminal_state=null | .terminal_reason=null | .terminal_state_source=$src | .gate_answered={gate:$gate, at:$at}' \
         "$GOAL" > "$GOAL.tmp" 2>/dev/null && mv "$GOAL.tmp" "$GOAL" \
         && echo "pwt-resume: cleared evaluator terminal (was $TS) with provenance gate-answered:$ACTOR (gate=$GATE)"
      __audit "gate-answered-cleared" "was $TS; gate=$GATE; actor=$ACTOR"
    fi
  fi
fi

# ── delegate to land.sh resume (fronts the refusal guards; reuses worktree+UUID; → pwt-steer) ──
[ -x "$LAND" ] || { echo "pwt-resume: plan-w-team-land.sh not executable at $LAND" >&2; exit 3; }
__audit "resume-requested" "reason=$REASON at=$AT gate=${GATE:-n/a} dry=$DRY"
# land.sh resume ALREADY hardcodes `--env PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` into its pwt-steer call
# (plan-w-team-land.sh §resume), and its arg parser has NO `--env` arm — passing one here would abort
# the delegation with "unknown argument" (exit 2). So we DON'T re-pass it: the auto-approve-push still
# reaches the resumed worker, through land.sh, unchanged.
if [ "$DRY" = "1" ]; then
  "$LAND" resume --slug "$SLUG" --dry-run
else
  "$LAND" resume --slug "$SLUG"
fi
LRC=$?
__audit "resume-delegated" "land.sh resume exit=$LRC"
exit "$LRC"
