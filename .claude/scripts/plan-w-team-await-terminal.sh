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

SLUG=""; WORKER_SID=""; STATE_DIR_OVERRIDE=""; PRINT_GOAL_FILE=0
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
    # Non-looping diagnostic seam: resolve the goal-state file path and exit.
    # Used by the seed-path regression test (and handy for debugging which
    # same-slug worktree the supervisor would watch). Does NOT enter the watch
    # loop, so it can never hang.
    --print-goal-file) PRINT_GOAL_FILE=1; shift ;;
    *) shift ;;
  esac
done

if [ -z "$SLUG" ] && [ -z "$WORKER_SID" ]; then
  echo "usage: plan-w-team-await-terminal.sh --slug <slug> [--worker-sid <sid>]" >&2
  exit 2
fi

# PROJECT_ROOT honors PWT_PROJECT_ROOT_OVERRIDE (test-friendly, consistent with
# pwt-goal.sh) before falling back to the worktree-aware git toplevel.
PROJECT_ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
EXT="$PROJECT_ROOT/.claude/scripts/claude-agents-extended.sh"

# ── Worktree-aware goal-state resolution (per-tick) ─────────────────────────
# Spec: docs/specs/supervisor-wait-worktree-aware.md. PWT-WT1 (2026-06-02) made
# `pwt-goal --worker-only` spawn the worker with `claude --bg --worktree`, so the
# worker runs INSIDE .claude/worktrees/<slug>/ and may write its goal-state there
# rather than in the launching MAIN checkout. The 1.24.0 event-driven wait (587d577)
# resolved GOAL ONCE from the main checkout, so the PRIMARY terminal trigger could
# never fire for a worktree-isolated worker — degrading to the WORKER_GONE +
# 30-min-heartbeat backstops. Resolve each tick (the file can also appear AFTER the
# wait starts), in precedence:
#   1. explicit --state-dir override (highest — deterministic; used by tests + Step 3c)
#   2. main  <root>/.claude/state/plan-w-team-goal-<SLUG>.json
#   3. worktree fallback: <root>/.claude/worktrees/*/.claude/state/plan-w-team-goal-<SLUG>.json,
#      SID-DISAMBIGUATED — when --worker-sid is given and ≥2 worktrees carry a
#      same-slug goal-state, prefer the one whose .worker_sid matches (defense-in-depth
#      Fix B for the 2026-06-07 seed-path incident: a stale sibling worktree may carry
#      a same-slug goal-state from a prior run, so first-match could watch the wrong one).
#   4. default to (2)'s path (may not exist yet — keep watching / heartbeat re-arm)
# MAIN_ROOT (git-common-dir) is also searched so a supervisor that itself runs inside a
# worktree (PROJECT_ROOT=its own worktree) still sees the main checkout's worktrees.
# Bash 3.2-safe: no nullglob; an unmatched glob yields the literal pattern, which the
# `[ -f ]` guard rejects. Detection is purely file-based, so a worker that goes IDLE
# at terminal (never exits) is still detected via terminal_state — independent of the
# WORKER_GONE liveness path, which is PRESERVED below as a backstop (not removed).
__await_main_root() {
  local cdir root
  cdir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  if [ -n "$cdir" ]; then
    case "$cdir" in
      /*) root=$(dirname "$cdir") ;;
      *)  root=$(cd "$(dirname "$cdir")" 2>/dev/null && pwd || echo "") ;;
    esac
  fi
  [ -n "${root:-}" ] && [ -e "$root/.git" ] && { printf '%s\n' "$root"; return 0; }
  printf '%s\n' "$PROJECT_ROOT"
}

__resolve_goal_file() {
  [ -z "$SLUG" ] && return 0
  if [ -n "$STATE_DIR_OVERRIDE" ]; then
    printf '%s\n' "$STATE_DIR_OVERRIDE/plan-w-team-goal-${SLUG}.json"
    return 0
  fi
  local main_goal="$PROJECT_ROOT/.claude/state/plan-w-team-goal-${SLUG}.json"
  if [ -f "$main_goal" ]; then
    printf '%s\n' "$main_goal"
    return 0
  fi
  # Also consider the true main checkout (PROJECT_ROOT may be a worktree).
  local mroot mroot_goal
  mroot="$(__await_main_root)"
  if [ -n "$mroot" ] && [ "$mroot" != "$PROJECT_ROOT" ]; then
    mroot_goal="$mroot/.claude/state/plan-w-team-goal-${SLUG}.json"
    [ -f "$mroot_goal" ] && { printf '%s\n' "$mroot_goal"; return 0; }
  fi
  # Worktree fallback with SID disambiguation. Gather same-slug matches across
  # both PROJECT_ROOT's and the main checkout's worktrees; if --worker-sid is set,
  # return the SID-matching file; otherwise return the first match.
  local f first="" want="${WORKER_SID:0:8}" wsid
  for f in \
      "$PROJECT_ROOT"/.claude/worktrees/*/.claude/state/plan-w-team-goal-${SLUG}.json \
      "$mroot"/.claude/worktrees/*/.claude/state/plan-w-team-goal-${SLUG}.json; do
    [ -f "$f" ] || continue
    [ -z "$first" ] && first="$f"
    if [ -n "$want" ]; then
      wsid=$(jq -r '.worker_sid // ""' "$f" 2>/dev/null | tr -d '[:space:]' | cut -c1-8)
      if [ -n "$wsid" ] && [ "$wsid" = "$want" ]; then
        printf '%s\n' "$f"; return 0
      fi
    fi
  done
  [ -n "$first" ] && { printf '%s\n' "$first"; return 0; }
  printf '%s\n' "$main_goal"
}

# Non-looping diagnostic seam (--print-goal-file): resolve and exit, never watch.
if [ "${PRINT_GOAL_FILE:-0}" = "1" ]; then
  __resolve_goal_file
  exit 0
fi

elapsed=0
gone_streak=0
while :; do
  # (1) PRIMARY — terminal/halt via goal-state (reliable: the evaluator writes it).
  #     Re-resolve each tick: the worktree-isolated worker may create the file after
  #     this wait started, or write it inside its worktree rather than the main checkout.
  GOAL="$(__resolve_goal_file)"
  if [ -n "$SLUG" ] && [ -n "$GOAL" ] && [ -f "$GOAL" ]; then
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
    # --bg-only is ESSENTIAL (round-2 audit §3.1): the merged wrapper appends
    # on-disk Agent-tool SUBAGENTS to the base list. When the base `claude agents
    # --json` flakes to [] under load (the documented C2 empty-but-exit-0 — the
    # exact high-fan-out condition here), live subagents still make the merged
    # array non-empty, passing the length>0 guard while the watched BG SID is
    # absent → a LIVE worker is reported WORKER_GONE. A bg-worker liveness check
    # must ignore subagents entirely: --bg-only emits ONLY base bg/interactive
    # sessions, so a flaky base degrades to [] (empty) → fails the length>0 guard
    # → no false gone (rearm/heartbeat instead).
    AGENTS=$(CLAUDE_AGENTS_RETRY="${CLAUDE_AGENTS_RETRY:-3}" "$EXT" --json --bg-only 2>/dev/null || echo "")
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
