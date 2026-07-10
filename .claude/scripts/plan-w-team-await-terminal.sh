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
#   4  duplicate watcher (1.54.0) → stdout: "duplicate slug=<slug> pid=<pid> ..." —
#         another watcher already owns this slug+worker-sid wait; DEFER to it,
#         do NOT re-launch (re-launching would loop straight back here).
#   2  bad usage
set -u

SLUG=""; WORKER_SID=""; STATE_DIR_OVERRIDE=""; PRINT_GOAL_FILE=0
INTERVAL="${PWT_AWAIT_INTERVAL_S:-10}"
HEARTBEAT="${PWT_AWAIT_HEARTBEAT_S:-1800}"
GONE_CONFIRM="${PWT_AWAIT_GONE_CONFIRM:-2}"
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --worker-sid) WORKER_SID="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --state-dir) STATE_DIR_OVERRIDE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --interval) INTERVAL="${2:-10}"; shift; [ $# -gt 0 ] && shift ;;
    --heartbeat) HEARTBEAT="${2:-1800}"; shift; [ $# -gt 0 ] && shift ;;
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

# ── Worker-transcript success detection (TERTIARY) ──────────────────────────
# A `--worker-only` worker is caller-supervised: it completes the whole lifecycle
# (commit→push→ff mac-mini→emits the canonical Step-8 retro status block in its
# TRANSCRIPT) but, unlike `--supervisor-goal`/`--launch` (PWT-TERM3), does NOT
# write `terminal_state` to the goal-state file and LINGERS idle (verified
# 2026-06-29, run that shipped 1.48.2). So neither PRIMARY (terminal_state) nor
# SECONDARY (WORKER_GONE — it never vanishes) ever fires, and this wait would
# heartbeat forever on a SUCCESSFUL run. Detect success from the transcript.
#
# The canonical Step-8 emission is one line:
#   status stage="retro-complete" workflow_lock="done" slug="<slug>"
# The DISCRIMINATOR is the ADJACENCY of stage="retro-complete" immediately
# followed by workflow_lock="done": the GOAL echo separates them
# ("...appears in transcript with...") and planning mentions put backticks/commas
# between, so a tight adjacency match fires ONLY on the emitted block — never the
# echo or a mid-run mention (false-positive-safe; validated against real
# transcripts 2026-06-29). The optional backslash tolerates JSONL `\"` escaping.
# CLAUDE_PROJECTS_DIR mirrors claude-agents-extended.sh's override (test seam).
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
TX_PATH=""   # resolved-once cache (find is bounded: top-level session transcript)
__ensure_worker_transcript() {
  # Sets global TX_PATH once (cache). No stdout. NOT called in a subshell, so the
  # cache persists across ticks. Top-level session transcript:
  #   <projects>/<project-dir>/<sid>.jsonl  (depth 2) — maxdepth 2 keeps it cheap
  #   and excludes deeper sidechain subagent transcripts.
  [ -z "$WORKER_SID" ] && return 0
  [ -n "$TX_PATH" ] && return 0
  [ -d "$PROJECTS_DIR" ] || return 0
  local sid8 f
  sid8="${WORKER_SID%%-*}"
  f=$(find "$PROJECTS_DIR" -maxdepth 2 -type f -name "${sid8}*.jsonl" 2>/dev/null | head -1)
  [ -n "$f" ] && TX_PATH="$f"
  return 0
}
__transcript_shows_success() {
  __ensure_worker_transcript
  [ -n "$TX_PATH" ] && [ -f "$TX_PATH" ] || return 1
  # Legacy adjacency form (pre-1.54.0 hand-written shell-equals blocks) — kept verbatim.
  grep -Eq 'retro-complete\\?"[[:space:]]+workflow_lock=\\?"done' "$TX_PATH" 2>/dev/null && return 0
  # 1.54.0: the canonical emitter (plan-w-team-surface-status.sh) pretty-prints JSON
  # colon form — "stage": "retro-complete" … "workflow_lock": "done" on separate lines
  # of ONE fenced block, which lands in the transcript as ONE JSONL line with \n
  # escapes. The legacy regex above requires equals-form adjacency and NEVER matched
  # the canonical emission (two detectors, two formats — field audit 2026-07-10).
  #
  # BOUNDED-WINDOW ADJACENCY (review finding, CRITICAL): a whole FILE read via the
  # Read tool is also ONE physical JSONL line, so independent same-line greps would
  # false-fire on a worker merely READING goal-conditions.md (fence + both anchors
  # co-present file-level). The emitted block is contiguous: fence → {slug,stage}
  # within ~160 chars, stage → ts → workflow_lock within ~120 chars. One regex with
  # bounded gaps matches the real emission and rejects doc reads (anchors thousands
  # of chars apart / out of order).
  grep -Eq '```status.{0,160}"stage\\?"?[[:space:]]*:[[:space:]]*\\?"?retro-complete.{0,120}"workflow_lock\\?"?[[:space:]]*:[[:space:]]*\\?"?done' "$TX_PATH" 2>/dev/null
}

# Non-looping diagnostic seam (--print-goal-file): resolve and exit, never watch.
if [ "${PRINT_GOAL_FILE:-0}" = "1" ]; then
  __resolve_goal_file
  exit 0
fi

# ── Watcher singleton (1.54.0) ──────────────────────────────────────────────
# Field evidence 2026-07-09/10: TWO watchers per worker-sid observed twice in 24h
# (parts run-3 orphan pair; cleanscale apple-continuation pair) — each supervisor
# turn that re-issues the await spawns another poller, and orphans poll forever.
# Atomic mkdir claim keyed on slug+worker-sid; a stale lock (dead holder PID) is
# reclaimed. bash 3.2 safe. A duplicate exits 0 with a distinct message (no
# `terminal=` line) so callers cannot misread it as a terminal verdict.
LOCK_KEY="${SLUG:-noslug}-${WORKER_SID:-nosid}"
LOCK_DIR="${TMPDIR:-/tmp}/pwt-await-${LOCK_KEY}.lock"
__pwt_await_claim() {
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
  trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT
  return 0
}
if ! __pwt_await_claim; then
  OLD_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    # Distinct exit code 4 (review finding): exit 0 is contractually "terminal
    # reached" and exit 3 is "re-launch the wait" — both would mislead a
    # supervisor into a malformed terminal block or an instant re-launch loop.
    echo "duplicate slug=${SLUG:-} pid=${OLD_PID} — another watcher owns this wait; defer to it (do NOT re-launch)"
    exit 4
  fi
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  __pwt_await_claim || true   # fail-open: if the re-claim races, watch anyway
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

  # (1b) TERTIARY — `--worker-only` success via the worker transcript. The worker
  #      emitted the canonical retro status block but (worker-only) never wrote
  #      terminal_state and lingers, so PRIMARY/SECONDARY can't see it. ADDITIVE:
  #      runs after PRIMARY, never short-circuits it; gated on --worker-sid.
  if [ -n "$WORKER_SID" ] && __transcript_shows_success; then
    echo "terminal=SUCCESS source=transcript sid=$WORKER_SID slug=$SLUG"
    exit 0
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
