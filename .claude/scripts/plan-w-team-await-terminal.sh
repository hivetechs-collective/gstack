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
#   6  dead-but-unflipped (F7, RC4 2026-08-19) → stdout:
#         "terminal=UNFLIPPED diagnosis=<COMPLETE_UNLANDED|DIED_MID_<stage>> …"
#         The watched worker is PRESENT in `claude agents --json` but its state is
#         blocked/done — dead in every sense that matters — while the goal-state's
#         terminal_state is still null. Distinct from 0 (a real terminal), because
#         the supervisor's next action differs: land it, or resume the work. The
#         line names the last stage event and the exact remediation command.
#         Kill switch: PWT_DISABLE_UNFLIPPED_DETECT=1.
#   5  host distress (F3, 2026-08-19) → stdout: a "⚠ HOST-DISTRESS" block naming
#         the consumer and the evidence. NOT a terminal and NOT a re-arm: the run
#         is alive, and something (possibly the run itself) is starving the host.
#         Deliberately distinct from 0/3/4 so a supervisor can never misread
#         distress as a terminal verdict or as a routine heartbeat.
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

# ── Goal-state corroboration for TERTIARY (DEFECT A, 2026-07-16) ────────────
# Returns 0 ("unfinished — do NOT trust transcript anchors") ONLY on positive,
# authoritative evidence that the run is still working:
#   the goal-state file resolves AND terminal_state is null AND at least one
#   feature_specific_done_criteria row is not met:true.
# Everything else returns 1 ("nothing contradicts the anchors") so the 1.48.3
# behaviour is preserved exactly: no goal file, unreadable JSON, no jq, empty
# criteria array, or all rows met → the transcript verdict stands.
#
# Deliberately conservative on shape: a row that is not an object, or that lacks
# met:true, counts as UNMET. That is the same fail-closed reading the evaluator
# now uses (a malformed criteria contract must never read as "done"), and here it
# only costs extra polling — the safe direction.
__goal_state_shows_unfinished() {
  local gf ts unmet
  command -v jq >/dev/null 2>&1 || return 1
  gf="$(__resolve_goal_file)"
  [ -n "$gf" ] && [ -f "$gf" ] || return 1
  ts=$(jq -r '.terminal_state // ""' "$gf" 2>/dev/null || echo "")
  # A written terminal_state is PRIMARY's business and it already returned above.
  [ -n "$ts" ] && [ "$ts" != "null" ] && return 1
  unmet=$(jq -r '
      (.feature_specific_done_criteria // [])
      | map(select((type != "object") or (.met != true)))
      | length
  ' "$gf" 2>/dev/null || echo "")
  printf '%s' "${unmet:-}" | grep -qE '^[0-9]+$' || return 1   # unreadable → fail open
  [ "$unmet" -gt 0 ] 2>/dev/null || return 1
  return 0
}

# ── F7 — landing awareness (RC4, 2026-08-19) ────────────────────────────────
# The RC4 run emitted `retro-complete` and had EVERY done-criterion met:true, so
# TERTIARY above would have reported `terminal=SUCCESS source=transcript` for a run
# whose 31 commits never left its worktree branch — the watcher would have
# certified the exact ending the landing gate exists to prevent, and F7's
# dead-but-unflipped detector below would never be reached.
#
# So the watcher consults the same deterministic artifact the evaluator's F6 gate
# reads: `.claude/state/plan-w-team-landed-<slug>.json`, written ONLY by
# `plan-w-team-land.sh verify` after recomputing merged/tag-reachable/pushed from
# git.  Read-only here — never a git call on the poll loop.
#
# Returns 0 when the LANDING GATE APPLIES AND IS UNSATISFIED, i.e. "do not certify
# this run as done".  Everything indeterminate returns 1, preserving pre-2.13.0
# behaviour exactly: not worktree-isolated, kill switch set, or no jq.
__landing_missing() {
  local gf art slug_in verdict d __wt_iso
  [ "${PWT_DISABLE_LANDING_GATE:-0}" = "1" ] && return 1
  command -v jq >/dev/null 2>&1 || return 1

  gf="$(__resolve_goal_file)"
  # Isolation comes from the RUN MANIFEST's worktree_path and nothing else —
  # the SAME rule the evaluator's F6 gate uses. If these two ever disagreed, the
  # gate and the watcher could reach opposite conclusions about the same run.
  #
  # Deliberately NOT keyed on a path spelling (neither the goal file's nor the
  # observer's $PWD): "this CHECKOUT sits under a worktrees dir" is not the same
  # fact as "this RUN is worktree-isolated", and conflating them false-fires
  # wherever a checkout happens to live in one — including claude-pattern's own
  # repo root when the skill self-hosts (feedback_test_worktree_cwd_fragility).
  __wt_iso=0
  for d in "$(dirname "$gf")" "$PROJECT_ROOT/.claude/state"; do
    [ -n "$d" ] || continue
    [ -f "$d/plan-w-team-manifest-${SLUG}.json" ] || continue
    case "$(jq -r '.worktree_path // ""' "$d/plan-w-team-manifest-${SLUG}.json" 2>/dev/null)" in
      *"/.claude/worktrees/"*) __wt_iso=1; break ;;
    esac
  done
  [ "$__wt_iso" = "1" ] || return 1

  for d in "$(dirname "$gf")" "$PROJECT_ROOT/.claude/state" "$PWD/.claude/state"; do
    [ -n "$d" ] || continue
    art="$d/plan-w-team-landed-${SLUG}.json"
    [ -f "$art" ] || continue
    slug_in=$(jq -r '.slug // ""' "$art" 2>/dev/null || echo "")
    [ "$slug_in" = "$SLUG" ] || continue          # a foreign artifact proves nothing
    verdict=$(jq -r '.verdict // ""' "$art" 2>/dev/null || echo "")
    [ "$verdict" = "LANDED" ] && return 1         # landed → gate satisfied
  done
  return 0
}

# Last stage event for the F7 diagnosis.  The stage-event stream is written by
# plan-w-team-surface-status.sh at every stage via pwt-manifest.sh, so it is the
# cheapest honest answer to "how far did this run get before it died?".
__last_stage() {
  local f d v
  command -v jq >/dev/null 2>&1 || { printf '%s' ""; return 0; }
  # Capture, then test for a NON-EMPTY value before accepting it. Emitting on the
  # pipeline's exit status alone would accept an EMPTY answer as success — an
  # empty stage-events file, or a last line with no `.stage`, both make `jq -r`
  # exit 0 with no output — and the manifest fallback below would never run. The
  # diagnosis would silently degrade to "unknown" while the real stage sat one
  # source away.
  for d in "$PROJECT_ROOT/.claude/state" "$(dirname "$(__resolve_goal_file)")"; do
    [ -n "$d" ] || continue
    f="$d/plan-w-team-stage-events-${SLUG}.jsonl"
    [ -f "$f" ] || continue
    v=$(tail -1 "$f" 2>/dev/null | jq -r '.stage // ""' 2>/dev/null || echo "")
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  # Manifest fallback — current_stage is the same value, last writer wins.
  for d in "$PROJECT_ROOT/.claude/state" "$(dirname "$(__resolve_goal_file)")"; do
    [ -n "$d" ] || continue
    f="$d/plan-w-team-manifest-${SLUG}.json"
    [ -f "$f" ] || continue
    v=$(jq -r '.current_stage // ""' "$f" 2>/dev/null || echo "")
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  printf '%s' ""
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
# reclaimed. bash 3.2 safe. A duplicate exits 4 (NOT 0) with a distinct message
# (no `terminal=` line) — exit 0 is contractually "terminal reached" and exit 3
# is "re-launch"; 4 is a dedicated "another watcher owns this wait, no-op" code so
# callers never misread a duplicate as a terminal verdict or a re-arm.
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

# ── Host-distress watch (F3, 2026-08-19 incident) ───────────────────────────
# The 2026-08-19 run was alive-but-drowning for 4.5 hours and the detection
# mechanism was a human asking "is it stuck?". Every signal the supervisor had
# was about the WORKER (terminal_state, liveness, transcript) — none about the
# HOST the worker was failing to make progress on. This samples the shared
# host-health sampler on the same loop and surfaces distress PROACTIVELY.
#
# Debounced exactly like the WORKER_GONE path above (C2 lesson: never act on a
# single sample of a noisy signal). A CPU spike during a build is normal; the
# same breach on two consecutive samples is a condition.
#
# Fail-open throughout: no sampler, no jq, an unreadable sample, or a sampler
# that itself says supported=false ⇒ no breach, streak reset, watch unaffected.
DISTRESS_INTERVAL="${PWT_HOST_DISTRESS_INTERVAL_S:-60}"
DISTRESS_CONFIRM="${PWT_HOST_DISTRESS_CONFIRM:-2}"
HOST_HEALTH_BIN="$PROJECT_ROOT/.claude/scripts/plan-w-team-host-health.sh"
case "$DISTRESS_INTERVAL" in ''|*[!0-9]*) DISTRESS_INTERVAL=60 ;; esac
case "$DISTRESS_CONFIRM"  in ''|*[!0-9]*) DISTRESS_CONFIRM=2 ;; esac

__distress_state_dir() {
  if [ -n "$STATE_DIR_OVERRIDE" ]; then printf '%s\n' "$STATE_DIR_OVERRIDE"; return 0; fi
  local gf; gf="$(__resolve_goal_file)"
  if [ -n "$gf" ]; then printf '%s\n' "$(dirname "$gf")"; return 0; fi
  printf '%s\n' "$PROJECT_ROOT/.claude/state"
}

__write_distress_artifact() {  # $1 = health JSON
  local dir file tmp
  dir="$(__distress_state_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  file="$dir/plan-w-team-host-distress-${SLUG}.json"
  tmp="$file.tmp.$$"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg slug "$SLUG" \
     --arg sid "$WORKER_SID" --arg source "await-terminal" \
     --argjson health "$1" \
     '{ts:$ts, slug:$slug, source:$source, worker_sid:$sid, host_health:$health,
       guidance:"Supervisor observed host distress on two consecutive samples. The run is ALIVE — do not terminate it for this. Identify the consumer named in host_health.top_consumers; if it is not lane work, host hygiene (kill/renice) is an ALLOWED supervisor action."}' \
     > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

__emit_distress_block() {  # $1 = health JSON
  local reasons load ncpu ratio topcmd toppcpu orphans
  reasons=$(printf '%s' "$1" | jq -r '(.breach_reasons // []) | join(", ")' 2>/dev/null || echo "")
  load=$(printf '%s' "$1"    | jq -r '.load_1m // "?"' 2>/dev/null || echo "?")
  ncpu=$(printf '%s' "$1"    | jq -r '.ncpu // "?"' 2>/dev/null || echo "?")
  ratio=$(printf '%s' "$1"   | jq -r '.load_ratio // "?"' 2>/dev/null || echo "?")
  topcmd=$(printf '%s' "$1"  | jq -r '.top_consumers[0].command // "(none identified)"' 2>/dev/null || echo "(none)")
  toppcpu=$(printf '%s' "$1" | jq -r '.top_consumers[0].pcpu // 0' 2>/dev/null || echo 0)
  orphans=$(printf '%s' "$1" | jq -r '.orphan_count // 0' 2>/dev/null || echo 0)
  cat <<DISTRESSEOF
⚠ HOST-DISTRESS  slug=$SLUG${WORKER_SID:+ worker=${WORKER_SID:0:8}}
   breached: $reasons  (confirmed on $DISTRESS_CONFIRM consecutive samples)
   load 1m:  $load  vs ncpu $ncpu  (ratio ${ratio}x)
   consumer: $topcmd  (${toppcpu}% CPU)
   lane orphans: $orphans
   The run is ALIVE — this is NOT a terminal state and the goal evaluator must
   not end the run for it. Act on the consumer: if it is not lane work, host
   hygiene (kill/renice) is an allowed supervisor action; if it IS lane work,
   prefer degraded mode over adding parallelism.
   Artifact: $(__distress_state_dir)/plan-w-team-host-distress-${SLUG}.json
DISTRESSEOF
}

elapsed=0
gone_streak=0
dead_streak=0
breach_streak=0
dist_elapsed=0
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
  #
  #      DEFECT A (2026-07-16) — CORROBORATION GATE.
  #      Transcript anchors are a HISTORY, not a STATE: once ANY stop attempt
  #      emits them they match on every subsequent poll, forever. If that stop
  #      was BLOCKED by the /goal evaluator for unmet done-criteria, the run is
  #      still going and this detector would report SUCCESS on every tick (field
  #      incident: SUCCESS fired twice while four criteria were unmet). So a
  #      transcript-only SUCCESS must be corroborated against the authoritative
  #      goal-state before it is trusted.
  #
  #      Corroboration can only ever WITHHOLD on positive evidence of unfinished
  #      work; it never invents a blocker. Absent/unreadable goal-state, empty
  #      criteria, or all-met criteria → emit as before, preserving the 1.48.3
  #      lingering-worker fix this layer exists for.
  if [ -n "$WORKER_SID" ] && __transcript_shows_success; then
    if __goal_state_shows_unfinished; then
      # Still working: the anchors are stale history from a blocked stop.
      # Say so once per tick at heartbeat volume, then keep polling.
      :
    elif __landing_missing; then
      # F7/R7 (RC4): retro-complete + every criterion met, but the run is
      # worktree-isolated and nothing landed. This is the RC4 ending exactly —
      # certifying SUCCESS here would launder it. Withhold and keep polling; when
      # the worker dies, (2c) below classifies it as COMPLETE_UNLANDED.
      :
    else
      echo "terminal=SUCCESS source=transcript sid=$WORKER_SID slug=$SLUG"
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
        # ── (2c) F7 — dead-but-unflipped (RC4, 2026-08-19) ────────────────────
        # PRESENCE IS NOT LIFE. The RC4 worker showed idle/done in
        # `claude agents --json` while this watcher kept exiting 3 (heartbeat)
        # forever; a human asking "are we close?" was the detection mechanism.
        # The asymmetry was already documented: PWT-DS1 Tier B defines
        #   alive = present AND state ∉ {blocked, done}
        # and this loop checked presence ONLY. Adopt the same EXCLUSION predicate.
        #
        # `.state` is absent on interactive rows (the mixed-schema reality measured
        # 2026-08-19: interactive rows carry `status`, background rows carry
        # `state`), so a row WITHOUT `.state` counts as ALIVE. Narrowing a liveness
        # predicate must never invent a death — that is the direction that reaps
        # live work, and it is why followup row 147 exists.
        if [ "${PWT_DISABLE_UNFLIPPED_DETECT:-0}" != "1" ] \
           && printf '%s' "$AGENTS" | jq -e --arg s "${WORKER_SID:0:8}" '
                 any(.[]?; ((.sessionId//"")|tostring)[0:8]==$s
                           and ((.state//"") == "blocked" or (.state//"") == "done"))
             ' >/dev/null 2>&1; then
          dead_streak=$((dead_streak + 1))
          if [ "$dead_streak" -ge "$GONE_CONFIRM" ]; then
            # Only a NULL terminal_state is a gap. PRIMARY already returned for a
            # written one, but re-read defensively: a race between PRIMARY's read
            # and this branch must resolve toward "the run is fine".
            UNF_GOAL="$(__resolve_goal_file)"
            UNF_TS=""
            [ -n "$UNF_GOAL" ] && [ -f "$UNF_GOAL" ] \
              && UNF_TS=$(jq -r '.terminal_state // ""' "$UNF_GOAL" 2>/dev/null || echo "")
            if [ -z "$UNF_TS" ] || [ "$UNF_TS" = "null" ]; then
              UNF_STAGE="$(__last_stage)"
              [ -n "$UNF_STAGE" ] || UNF_STAGE="unknown"
              # Two diagnoses, and they need different actions from the supervisor:
              # a run that FINISHED and did not land is remediated by landing it;
              # a run that DIED mid-execute is remediated by resuming the work.
              if [ "$UNF_STAGE" = "retro-complete" ] || __transcript_shows_success; then
                UNF_DIAG="COMPLETE_UNLANDED"
              else
                UNF_DIAG="DIED_MID_${UNF_STAGE}"
              fi
              echo "terminal=UNFLIPPED diagnosis=$UNF_DIAG last_stage=$UNF_STAGE sid=$WORKER_SID slug=$SLUG (state in {blocked,done} for ${dead_streak} consecutive checks, terminal_state=null)"
              if [ "$UNF_DIAG" = "COMPLETE_UNLANDED" ]; then
                echo "  → the run finished every stage but did not LAND. Remediate:"
                echo "      .claude/scripts/plan-w-team-land.sh status --slug $SLUG"
                echo "      .claude/scripts/plan-w-team-land.sh resume --slug $SLUG"
              else
                echo "  → the run died at stage '$UNF_STAGE' without writing a terminal. Inspect, then steer:"
                echo "      .claude/scripts/pwt-steer.sh --slug $SLUG --message '<next action>'"
              fi
              exit 6
            fi
          fi
        else
          dead_streak=0
        fi
      else
        gone_streak=$((gone_streak + 1))
        dead_streak=0
        if [ "$gone_streak" -ge "$GONE_CONFIRM" ]; then
          # C3 (BRIEF §4.4): absence from the registry is NOT death — corroborate with the ONE
          # liveness truth before declaring WORKER_GONE. exit 1 (confirmed dead) or predicate
          # unavailable → gone (unchanged); exit 0 (alive — registry lag) → reset the streak and
          # keep waiting; exit 2 (cannot-determine) → keep waiting (never DIED on uncertainty).
          # Kill switch: PWT_DISABLE_AWAIT_LANE_ALIVE=1 restores presence-only.
          __await_gone=1
          if [ "${PWT_DISABLE_AWAIT_LANE_ALIVE:-0}" != "1" ]; then
            __await_la="${PWT_LANE_ALIVE_BIN:-$(dirname "$0")/pwt-lane-alive.sh}"
            if [ -x "$__await_la" ]; then
              "$__await_la" "$SLUG" --worker-sid "$WORKER_SID" >/dev/null 2>&1
              case "$?" in
                0) gone_streak=0; __await_gone=0 ;;   # alive (registry lag) → keep waiting
                2) __await_gone=0 ;;                   # cannot-determine → keep waiting (fail-closed)
              esac
            fi
          fi
          if [ "$__await_gone" = "1" ]; then
            echo "terminal=WORKER_GONE sid=$WORKER_SID slug=$SLUG (absent ${gone_streak} consecutive checks, process-confirmed)"
            exit 0
          fi
        fi
      fi
    fi
  fi

  # (2b) HOST DISTRESS — proactive, additive, and strictly AFTER the terminal
  #      checks above, so a real terminal always wins: a run that finished must
  #      never be reported as distressed instead of done.
  if [ "${PWT_DISABLE_HOST_DISTRESS:-0}" != "1" ] \
     && [ -x "$HOST_HEALTH_BIN" ] && command -v jq >/dev/null 2>&1 \
     && [ "$dist_elapsed" -ge "$DISTRESS_INTERVAL" ]; then
    dist_elapsed=0
    HEALTH=$("$HOST_HEALTH_BIN" --repo-root "$PROJECT_ROOT" 2>/dev/null || echo "")
    IS_BREACH=""
    [ -n "$HEALTH" ] && IS_BREACH=$(printf '%s' "$HEALTH" | jq -r '.breach // false' 2>/dev/null || echo "")
    if [ "$IS_BREACH" = "true" ]; then
      breach_streak=$((breach_streak + 1))
      if [ "$breach_streak" -ge "$DISTRESS_CONFIRM" ]; then
        __write_distress_artifact "$HEALTH"
        __emit_distress_block "$HEALTH"
        exit 5
      fi
    else
      # Anything that is not a POSITIVE breach — including an unreadable sample
      # or an unsupported host — resets the streak. Distress is only ever
      # claimed on repeated positive evidence.
      breach_streak=0
    fi
  fi

  # (3) Heartbeat re-arm — NOT a cap. Re-invoke the supervisor to re-check + re-arm.
  if [ "$HEARTBEAT" -gt 0 ] && [ "$elapsed" -ge "$HEARTBEAT" ]; then
    echo "rearm elapsed=${elapsed}s slug=$SLUG — no terminal yet; supervisor re-checks state and re-arms (heartbeat, NOT a halt)"
    exit 3
  fi

  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
  dist_elapsed=$((dist_elapsed + INTERVAL))
done
