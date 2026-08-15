#!/bin/bash
# plan-w-team Goal Evaluator — Stop hook
#
# Replaces Anthropic's /goal wrapper with a deterministic shell evaluator.
# Fires after every Claude turn. Reads active /plan-w-team goal state file
# (created by the skill at top-of-pipeline) and decides whether the pipeline
# reached a terminal state.
#
# Why deterministic instead of Haiku-based: every terminal-state anchor in
# shared/goal-conditions.md is concrete enough to detect by jq-decoding the
# transcript JSONL (assistant text, tool_result, user content — escaped or
# raw) and pattern-matching the unescaped payloads. No LLM judgment needed,
# no eval hallucination, no tokens.
#
# Spec: docs/specs/pwt-t5-goal-wrapper.md (origin design);
#       docs/specs/pwt-evaluator-escaped-quotes.md (escaped-quote transcript detection)
# State file: .claude/state/plan-w-team-goal-<SLUG>.json
# Kill switch: PLAN_W_TEAM_DISABLE_GOAL=1 → exit 0 (let stop proceed normally)
# Block cap: default 8; set CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=200 in shell env
#            for long /plan-w-team runs

set -u

# Always read stdin (hook contract)
INPUT=$(cat 2>/dev/null || echo '{}')

# Debug mode — emit structured diagnostics to stderr explaining WHY the hook
# decided terminal / not-terminal (which detector ran, what it matched). Enable
# via env PWT_GOAL_EVALUATOR_DEBUG=1 OR the --debug CLI flag (any position).
# This is the only window into the hook when it false-negatives — keep it
# informative. All debug output goes to stderr so the stdout JSON decision
# contract is never polluted.
PWT_DEBUG=0
[ "${PWT_GOAL_EVALUATOR_DEBUG:-}" = "1" ] && PWT_DEBUG=1
case " $* " in *" --debug "*) PWT_DEBUG=1 ;; esac
dbg() { [ "$PWT_DEBUG" = "1" ] && echo "[goal-evaluator:debug] $*" >&2 || true; }

# Kill switch — skip goal evaluation entirely
if [ "${PLAN_W_TEAM_DISABLE_GOAL:-}" = "1" ]; then
    dbg "kill switch PLAN_W_TEAM_DISABLE_GOAL=1 → allow stop"
    exit 0
fi

# stop_hook_active protection — if Claude Code already overrode us, don't fight
if [ "$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    exit 0
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
FALLBACK_STATE_DIR="$PROJECT_ROOT/.claude/state"
PWD_STATE_DIR="$PWD/.claude/state"

# Resolve and export CLAUDE_BIN so any helper script this hook invokes
# (or transitively spawns) can call claude without PATH lookup failures.
# The evaluator itself does not currently shell out to claude, but future
# helpers (e.g. supervisor-mirror lifecycle hooks, child-cleanup) will
# inherit a resolved $CLAUDE_BIN. Best-effort: missing helper = silent no-op.
LOCATE_CLAUDE="$PROJECT_ROOT/.claude/scripts/locate-claude.sh"
if [ -x "$LOCATE_CLAUDE" ]; then
    CLAUDE_BIN="$("$LOCATE_CLAUDE" 2>/dev/null)" || CLAUDE_BIN=""
    [ -n "$CLAUDE_BIN" ] && export CLAUDE_BIN
fi

# Source the shared transient-connection-error pattern set (API_HALT detection).
# Best-effort: a missing helper (older consumer repo) leaves pwt_is_transient_error
# undefined, and the API_HALT classifier below is guarded on `command -v`, so it
# simply no-ops there — fail-safe, no regression.
TRANSIENT_HELPER="$PROJECT_ROOT/.claude/scripts/pwt-transient-errors.sh"
if [ -r "$TRANSIENT_HELPER" ]; then
    # shellcheck source=/dev/null
    . "$TRANSIENT_HELPER"
fi

# Worktree-aware state lookup: check $PWD/.claude/state first (the case when
# /plan-w-team is running in a worktree), fall back to project root. We
# aggregate goal files from both locations so the evaluator catches active
# goals regardless of where they were written. See 2026-05-20 holistic-check
# retro for the failure this fixes.
# ── MAIN-checkout state dir (recursive-followup row 1, 2026-07-31) ────────────
# Under `claude --bg --worktree`, BOTH $PWD and $CLAUDE_PROJECT_DIR equal the
# WORKTREE (verified by a live Stop-hook probe on run f52cd09d:
# `cpd=<worktree> pwd=<worktree> goalfiles=0`), so the two sources above are
# really ONE source. `pwt-goal.sh --worker-only` dual-seeds the goal-state, but
# its worktree arm is gated on `[ -d "$WORKER_WT_ROOT" ]` and loses the race
# against `claude --bg` worktree creation — leaving ONLY the MAIN copy. The
# evaluator therefore found nothing, exited 0, and the deterministic anti-skip
# anchor was INERT on exactly the autonomous path it exists to protect.
#
# Resolving the MAIN checkout via `git rev-parse --git-common-dir` (a worktree's
# .git file points at the common dir, so no env var is needed) makes the
# always-written MAIN copy reachable — and makes true the "git-common-dir MAIN
# lookup (defense-in-depth Fix B)" that pwt-goal.sh already documents.
# `PWT_PROJECT_ROOT_OVERRIDE` wins first, matching 01-specification.md §1.5 and
# the hermetic test-corpus isolation contract (without it, sandboxed suites
# would see the real repo's live goal states).
# Fail-open on every error: an unresolvable MAIN degrades to the prior
# two-source behavior. A Stop hook that errors is worse than one that
# under-detects.
MAIN_STATE_DIR=""
if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    MAIN_STATE_DIR="$PWT_PROJECT_ROOT_OVERRIDE/.claude/state"
else
    __cdir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    case "$__cdir" in
        "") MAIN_STATE_DIR="" ;;
        /*) MAIN_STATE_DIR="$(dirname "$__cdir")/.claude/state" ;;
        *)  __mroot=$(cd "$(dirname "$__cdir")" 2>/dev/null && pwd || echo "")
            [ -n "$__mroot" ] && MAIN_STATE_DIR="$__mroot/.claude/state" ;;
    esac
    unset __cdir __mroot
fi

# CONTAINMENT (required — without it this source breaks hermetic sandboxes).
# `git rev-parse --git-common-dir` answers about $PWD's repo, which is NOT
# necessarily the repo the effective PROJECT_ROOT belongs to. A hermetic test
# (or any caller) that points CLAUDE_PROJECT_DIR at a temp dir while running
# with cwd inside a real repo would otherwise inherit that real repo's live
# goal-states and block on someone else's run.
# The MAIN source is only legitimate when PROJECT_ROOT actually belongs to the
# resolved MAIN repo — i.e. it IS MAIN, or it is nested under it (the
# `<main>/.claude/worktrees/<wt>` production case). An explicit
# PWT_PROJECT_ROOT_OVERRIDE is a deliberate caller instruction and is exempt.
if [ -n "$MAIN_STATE_DIR" ] && [ -z "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    # Identity, not path-prefix: a git worktree may live anywhere on disk, so
    # "is PROJECT_ROOT under MAIN?" is the wrong question. The right one is
    # "does PROJECT_ROOT belong to the SAME repository?" — i.e. does it resolve
    # to the same common git dir. Non-repo / foreign-repo project roots resolve
    # to something else (or nothing) and are excluded.
    __main_root="${MAIN_STATE_DIR%/.claude/state}"
    __proj_cdir=$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir 2>/dev/null || echo "")
    case "$__proj_cdir" in
        "") __proj_main="" ;;
        /*) __proj_main=$(cd "$(dirname "$__proj_cdir")" 2>/dev/null && pwd || echo "") ;;
        *)  __proj_main=$(cd "$PROJECT_ROOT/$(dirname "$__proj_cdir")" 2>/dev/null && pwd || echo "") ;;
    esac
    [ -n "$__proj_main" ] && [ "$__proj_main" = "$__main_root" ] || MAIN_STATE_DIR=""
    unset __main_root __proj_cdir __proj_main
fi

# Resolve a dir to its absolute physical path (empty if it does not exist), so
# de-duplication compares real paths rather than spellings.
__abs_dir() { [ -n "${1:-}" ] && [ -d "$1" ] && (cd "$1" 2>/dev/null && pwd) || echo ""; }

shopt -s nullglob
declare -a GOAL_FILES=()
__seen_dirs=""
__collect_goals() {
    local d
    d=$(__abs_dir "${1:-}")
    [ -n "$d" ] || return 0
    # De-dup by resolved path: in a MAIN-checkout run these collapse to the same
    # dir, and evaluating one goal twice would emit duplicate blocks.
    case "$__seen_dirs" in *"|$d|"*) return 0 ;; esac
    __seen_dirs="$__seen_dirs|$d|"
    local f
    for f in "$d"/plan-w-team-goal-*.json; do
        GOAL_FILES+=("$f")
    done
}
__collect_goals "$PWD_STATE_DIR"
__collect_goals "$FALLBACK_STATE_DIR"

# MAIN is a FALLBACK, not a union member: consult it only when the local scope
# ($PWD / project root) yielded no goal at all. That is precisely the broken
# case — a worktree worker whose own state dir is empty because pwt-goal.sh's
# worktree seed lost its race, leaving only the MAIN copy.
# Making it unconditional would be wrong in the other direction: a caller that
# DOES scope state locally (every hermetic test in this repo passes its
# goal-state via $PWD and sets no CLAUDE_PROJECT_DIR) would silently inherit the
# real repo's live goal-states and block on another run's work.
#
# It is additionally gated on an EXPLICIT project-root signal
# (CLAUDE_PROJECT_DIR, which settings.json requires to even invoke this hook, or
# PWT_PROJECT_ROOT_OVERRIDE). Without one, PROJECT_ROOT is only a guess derived
# from $0's location, and guessing our way into another checkout's state is the
# failure this whole fix exists to prevent — just pointed the other way.
if [ "${#GOAL_FILES[@]}" -eq 0 ] \
   && { [ -n "${CLAUDE_PROJECT_DIR:-}" ] || [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; }; then
    __collect_goals "$MAIN_STATE_DIR"
fi
shopt -u nullglob

# Pick effective STATE_DIR for any downstream writes: prefer $PWD if it holds a
# matching goal, then the project-root fallback, then the MAIN checkout.
# (Used by terminal-state persistence below. Note the per-goal write-back uses
# $GOAL_FILE — the file actually read — so a MAIN-only goal is persisted in
# MAIN, which is where await-terminal.sh and the Run-State Router read it.)
if [ -d "$PWD_STATE_DIR" ] && compgen -G "$PWD_STATE_DIR/plan-w-team-goal-*.json" >/dev/null 2>&1; then
    STATE_DIR="$PWD_STATE_DIR"
elif compgen -G "$FALLBACK_STATE_DIR/plan-w-team-goal-*.json" >/dev/null 2>&1; then
    STATE_DIR="$FALLBACK_STATE_DIR"
elif [ -n "$MAIN_STATE_DIR" ] && compgen -G "$MAIN_STATE_DIR/plan-w-team-goal-*.json" >/dev/null 2>&1; then
    STATE_DIR="$MAIN_STATE_DIR"
else
    STATE_DIR="$FALLBACK_STATE_DIR"
fi

# No active goal → let Claude stop normally
[ "${#GOAL_FILES[@]}" -eq 0 ] && exit 0

# Tools: jq required for state file parsing
if ! command -v jq >/dev/null 2>&1; then
    echo "[goal-evaluator] WARN: jq not available, skipping evaluation" >&2
    exit 0
fi

# ── ISO8601-or-mtime → epoch helper (portable, bash 3.2) ──────────────────────
# Used by the stale-snapshot guard below. Tries GNU `date -d` then BSD/macOS
# `date -j -f`. Emits epoch seconds on success, empty on failure (caller decides).
__iso_to_epoch() {
    local iso="$1"
    [ -z "$iso" ] && return 0
    date -u -d "$iso" +%s 2>/dev/null && return 0
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null && return 0
    return 0
}

# ── Anti-park signal reader (PWT-ANTIPARK, 2026-06-07) ────────────────────────
# Promotes feedback_supervisor_progress_objective from prose to an ENFORCED gate
# by letting the Stop hook consult the objective progress snapshot that
# supervisor-progress-check.sh writes. Echoes one line:
#   "<backlogKnown> <backlog> <verdict> <stallStreak>".
#
# SLUG-SCOPED (2026-06-07 hermeticity fix): the snapshot is keyed PER-RUN as
# `supervisor-progress-<slug>.json`, and $1 is the CURRENT run's SLUG. A snapshot
# written by another run (or a stale dead run) therefore can NEVER drive this run's
# Stop decision — the prior global, non-slug-keyed `supervisor-progress.json` read
# let a stale May-28 file (verdict STALLED, backlog 9) contaminate a live run's U18
# (the defect this fixes). Three independent fail-open guards, any of which yields
# NO signal (empty output → caller behaves byte-for-byte as pre-fix):
#   1. No slug arg, or no slug-keyed file        → empty.
#   2. Snapshot's own `slug` field != current    → empty (foreign-slug guard).
#   3. Snapshot older than PWT_ANTIPARK_MAX_AGE_S → empty (stale guard; ts, else
#      file mtime). A dead run's STALLED verdict must not haunt a new run forever.
# The gate can only ever ADD a block where the run was about to silently park; it
# never removes an existing block and never relaxes a terminal.
# Kill switch: PLAN_W_TEAM_DISABLE_ANTIPARK=1 → always empty (feature off).
# Staleness threshold: PWT_ANTIPARK_MAX_AGE_S (default 3600s = 1h).
__antipark_state() {
    [ "${PLAN_W_TEAM_DISABLE_ANTIPARK:-}" = "1" ] && return 0
    local slug="${1:-}"
    [ -z "$slug" ] && return 0
    local d f=""
    for d in "$STATE_DIR" "$FALLBACK_STATE_DIR"; do
        if [ -f "$d/supervisor-progress-${slug}.json" ]; then
            f="$d/supervisor-progress-${slug}.json"; break
        fi
    done
    [ -z "$f" ] && return 0
    # Foreign-slug guard: the snapshot's own slug must equal the current run's.
    # (A corrupt file yields empty snap_slug → mismatch → ignored, fail-open.)
    local snap_slug
    snap_slug=$(jq -r '.slug // ""' "$f" 2>/dev/null || echo "")
    [ "$snap_slug" != "$slug" ] && return 0
    # Stale-snapshot guard: ignore snapshots older than PWT_ANTIPARK_MAX_AGE_S.
    # Prefer the embedded ISO `ts`; fall back to file mtime if ts is unparseable.
    local max_age snap_ts snap_epoch now_epoch age
    max_age="${PWT_ANTIPARK_MAX_AGE_S:-3600}"
    snap_ts=$(jq -r '.ts // ""' "$f" 2>/dev/null || echo "")
    snap_epoch=$(__iso_to_epoch "$snap_ts")
    if [ -z "$snap_epoch" ]; then
        snap_epoch=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")
    fi
    if [ -n "$snap_epoch" ] && [ "$snap_epoch" -gt 0 ] 2>/dev/null; then
        now_epoch=$(date -u +%s)
        age=$(( now_epoch - snap_epoch ))
        [ "$age" -ge "$max_age" ] 2>/dev/null && return 0
    fi
    # Corrupt JSON → jq fails → empty (fail-open). Defaults guard missing keys.
    jq -r '"\(.backlogKnown // 0) \(.backlog // 0) \(.verdict // "") \(.stallStreak // 0)"' "$f" 2>/dev/null || true
}

# ── Stale-foreign goal skip (PWT-STALE-SKIP, prong A, 2026-06-10) ─────────────
# The GOAL_FILES loop below counts EVERY non-terminal plan-w-team-goal-*.json
# toward the block decision. A stale, foreign-slug, non-terminal leftover — e.g.
# an UNOWNABLE goal (no worker_sid) from an aborted run — therefore forces the
# fail-safe BLOCKING_GOAL_UNOWNABLE block and can trap a legitimate Stop. This
# helper identifies a goal that is provably NOT this run's live work so the loop
# can SKIP it for the in-flight/block decision (mirrors the foreign-slug + stale
# idiom already used by __antipark_state above).
#
# Returns 0 = SKIP (do not count toward block), 1 = KEEP (evaluate normally).
# A goal is SKIP-eligible ONLY when ALL hold (each clause fails toward KEEP):
#   1. feature enabled (PLAN_W_TEAM_DISABLE_STALE_SKIP != 1).
#   2. NOT ours — worker_sid prefix != this session's SELF_SID prefix.
#   3. worker NOT live — worker_sid not in ACTIVE_SIDS (when ACTIVE_SIDS known);
#      a live concurrent run is never skipped.
#   4. AGED — file mtime older than PWT_GOAL_STALE_HOURS (default 24). Age is the
#      universal safety: nothing recent is ever skipped, so our own recent goal
#      (even one with no worker_sid) is never touched. Unreadable mtime → KEEP.
#
# SAFETY: a skip NEVER marks a goal terminal and NEVER deletes anything — it only
# declines to let a foreign/stale goal force THIS session to keep running. The
# foreign run's own session still blocks on its own goal, so an over-aggressive
# skip is benign (this session stops; the other run is unaffected). Fail-OPEN
# throughout. Kill switch PLAN_W_TEAM_DISABLE_STALE_SKIP=1 → always KEEP.
# Threshold knob PWT_GOAL_STALE_HOURS (default 24) — distinct from the worktree
# lock knob PWT_STALE_LOCK_HOURS (different lifetime; goal-state, not a lock).
__is_stale_foreign_goal() {
    [ "${PLAN_W_TEAM_DISABLE_STALE_SKIP:-}" = "1" ] && return 1
    local gf="$1"
    local wsid
    wsid=$(jq -r '.worker_sid // ""' "$gf" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$wsid" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
            # Clause 2 — ours? well-formed 8-hex worker_sid whose prefix == SELF_SID.
            if [ -n "$SELF_SID" ] && [ "${SELF_SID:0:8}" = "${wsid:0:8}" ]; then
                return 1   # ours → KEEP (the owning worker always runs to terminal)
            fi
            # Clause 3 — live? worker_sid present and in ACTIVE_SIDS (8-char form).
            if [ -n "$ACTIVE_SIDS" ] && echo "$ACTIVE_SIDS" | grep -qFx "${wsid:0:8}"; then
                return 1   # live concurrent run → KEEP
            fi
            ;;
        *)
            : # no/malformed worker_sid → ownership+liveness unprovable; rely on age
            ;;
    esac
    # Clause 4 — AGED? (the universal safety gate; recent goals are never skipped)
    local mtime now age max_age
    mtime=$(stat -f %m "$gf" 2>/dev/null || stat -c %Y "$gf" 2>/dev/null || echo "")
    [ -n "$mtime" ] || return 1                       # unreadable age → KEEP (fail-open)
    [ "$mtime" -gt 0 ] 2>/dev/null || return 1
    now=$(date -u +%s)
    age=$(( now - mtime ))
    max_age=$(( ${PWT_GOAL_STALE_HOURS:-24} * 3600 ))
    [ "$age" -lt "$max_age" ] 2>/dev/null && return 1  # recent → KEEP
    return 0   # aged + not-ours + not-live → SKIP
}

# Transcript: Claude Code passes the path in the hook input
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)

# ── Transcript decoder ──────────────────────────────────────────────────────
# THE FIX (2026-05-25): Claude Code stores assistant/user/tool message content
# as JSON-encoded strings inside the transcript JSONL. A status block emitted
# as assistant text therefore lands on disk with ESCAPED quotes:
#     ...,"text":"{\"stage\":\"retro-complete\",\"slug\":\"x\"}"
# The previous detectors ran `grep -F '"stage":"retro-complete"'` against the
# raw transcript file, which can NEVER match the escaped form — so valid
# terminal signals were silently rejected (false-negative), trapping
# autonomous runs (cleanscale hard-gate escalation incident, 2026-05-25).
#
# Approach A (implemented): parse each transcript entry with jq, extract every
# candidate text payload — assistant `.message.content[].text`, tool_result
# `.content` (string OR nested {type:text,text} array), and string-form user
# `.message.content` — and emit ONE decoded line per transcript entry with the
# quotes UNESCAPED by jq's own string decoding. Detectors then match against
# this decoded corpus. Because all keys of a single status block live in one
# entry's text payload, "same decoded line" is the faithful translation of the
# original "±5 lines of the slug anchor" proximity intent.
#
# Approach B (REJECTED): just add a second grep for the escaped variant
# `\"stage\":\"retro-complete\"`. Rejected because escaping is context-
# dependent and unbounded: double-encoding (`\\\"`) occurs when a status block
# is quoted inside another JSON string (tool input echoing an assistant
# message, nested tool_result arrays); fenced ```json blocks add their own
# layer; and matching literal backslash-quote sequences across the raw file
# also defeats the slug-anchor proximity defense (the anchor and the trigger
# can land on different physical lines after `tail`). jq decoding collapses ALL
# escape layers to canonical text in one pass and keeps each status block on a
# single logical line — Approach B would need a new grep per escape depth and
# still miss the array/double-encoded cases.
#
# Backward-compat: the RAW transcript tail is retained as a second corpus and
# OR'd into every detector, so transcripts that happened to carry raw-form
# patterns (direct file-write emission paths) are still detected. The fix ADDS
# escaped-form detection; it does not remove raw-form detection.
#
# Fail-safe: malformed JSONL lines are skipped by `jq -R 'fromjson? // empty'`
# so a corrupt transcript never crashes the hook (exits non-terminal cleanly).
decode_transcript() {
    # $1 = transcript file. Emits one decoded text line per parseable entry.
    local file="$1"
    [ -n "$file" ] && [ -f "$file" ] || return 0
    tail -500 "$file" 2>/dev/null \
        | jq -R 'fromjson? // empty' 2>/dev/null \
        | jq -r '
            ( .message.content? // empty ) as $c
            | if   ($c | type) == "string" then $c
              elif ($c | type) == "array" then
                [ $c[]
                  | if   (.type? == "text")        then (.text // "")
                    elif (.type? == "tool_result") then
                      ( if   (.content | type) == "string" then .content
                        elif (.content | type) == "array"  then
                          ([ .content[] | (.text? // "") ] | join(" "))
                        else "" end )
                    elif (.type? == "tool_use")    then
                      # Tool input may carry a status block (e.g. a Write of a
                      # state file). Flatten the input object back to compact
                      # JSON so its keys are matchable on this same line.
                      ( (.input // {}) | tostring )
                    else "" end
                ] | join("  ")
              else "" end
            # Collapse newlines so a multi-line status block stays on ONE
            # decoded line — preserves the "same status block" proximity model.
            | gsub("[\r\n]+"; " ")
            | select(length > 0)
        ' 2>/dev/null
}

# Background-task liveness (added 2026-05-22 — leverages Claude Code 2.1.145 feature).
# Hook input now includes a `background_tasks` array of currently-alive bg sessions.
# We extract the set of active SIDs (short 8-char form) to enable DEAD-worker
# detection in the parent-child propagation step: when a registered child has
# NO terminal_state AND its SID is not in active SIDs, the child crashed —
# we can propagate without stalling.
#
# Backward-compat: if the field is absent (older Claude Code versions),
# ACTIVE_SIDS will be empty and the dead-worker check is skipped — preserving
# the previous "wait forever for terminal_state" behavior.
ACTIVE_SIDS=$(echo "$INPUT" \
    | jq -r '.background_tasks // [] | .[] | .session_id // .sessionId // empty' 2>/dev/null \
    | awk '{print substr($0, 1, 8)}' \
    | sort -u)

# Evaluate each active goal. If ANY hits terminal, allow stop.
# If ALL are still pending, block stop with the most recent goal's reason.
BLOCK_REASON=""
ANY_TERMINAL=false

# PWT-SUP-YIELD-SID (2026-06-03): identity-based supervisor yield. The env-only
# PLAN_W_TEAM_SUPERVISOR_SESSION flag (checked far below) cannot exempt an ORIGIN
# chat that BECOMES a supervisor mid-session — it can't set its own launch env — so
# such a session was dragged into Stop-hook busy-poll every turn. PWT-WT2 worsened
# it: pwt-goal now reliably SEEDS the goal-state (with the owning worker's SID) into
# the launching checkout, so this hook always finds it for the origin session. Fix:
# only the OWNING worker (whose SID == the goal's worker_sid) must be blocked to run
# to terminal; any other session (supervisor/observer) yields and is re-woken
# event-driven by its background await-loop. SAFETY: a blocking goal with NO
# worker_sid (legacy / in-session /plan-w-team with no bg worker) is un-ownable →
# fail safe to BLOCK; an empty SELF_SID (older harness w/o .session_id) disables SID
# matching → BLOCK. The owning worker thus always blocks ("worker runs to terminal").
SELF_SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
OWNS_BLOCKING=0             # this session IS the owning worker of some blocking goal
BLOCKING_GOAL_UNOWNABLE=0  # some blocking goal has no worker_sid → ownership unprovable

for GOAL_FILE in "${GOAL_FILES[@]}"; do
    if ! jq -e . "$GOAL_FILE" >/dev/null 2>&1; then
        # Corrupt state file — log and skip
        echo "[goal-evaluator] WARN: corrupt goal state at $GOAL_FILE; skipping" >&2
        continue
    fi

    SLUG=$(jq -r '.slug' "$GOAL_FILE")
    STARTED_AT=$(jq -r '.started_at' "$GOAL_FILE")
    EXISTING_TERMINAL=$(jq -r '.terminal_state // ""' "$GOAL_FILE")

    # Already marked terminal in a previous turn → allow stop.
    # Backward-compat escape hatch: a user/agent can write terminal_state
    # directly into the goal state file to force a graceful halt.
    #
    # C3 spoof-guard: inside a bg worker (--launch / --worker-only, marked by
    # PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1) this short-circuit is spoofable — the
    # worker's own LLM can jq-write terminal_state=SUCCESS to stop the /goal loop
    # while skipping the ship gate and AC AND-check. So in worker mode honor a
    # pre-existing terminal_state ONLY when the EVALUATOR itself wrote it
    # (terminal_state_source=evaluator, set on its write-back below). Interactive
    # sessions keep the unrestricted escape hatch — a human is watching. A human
    # halting a worker does so out-of-band (stop the bg session), not by trusting
    # the worker's own self-write. See audit C3.
    if [ -n "$EXISTING_TERMINAL" ]; then
        TERMINAL_SRC=$(jq -r '.terminal_state_source // ""' "$GOAL_FILE")
        HONOR_EXISTING=1
        if [ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-}" = "1" ]; then
            # Worker mode: a self-written terminal_state is spoofable. Honor a
            # pre-existing terminal_state ONLY with accepted provenance:
            #   evaluator       → we wrote it (trusted).
            #   retro | ship    → trusted ONLY when corroborated by a deterministic
            #                     PASS ship-verdict artifact for this slug (the same
            #                     anchor C3 requires). The worker's own LLM cannot
            #                     fabricate that without crossing every §6 ENFORCING
            #                     gate, so the spoof-guard's INTENT (no un-provenanced
            #                     mid-run self-completion) is preserved, not weakened.
            #                     Lets retro's authoritative SUCCESS write (PWT-TERM1)
            #                     terminate the run deterministically.
            #   any other/empty → ignore (fall through to real anchor detection).
            case "$TERMINAL_SRC" in
                evaluator) HONOR_EXISTING=1 ;;
                retro|ship)
                    SV_FILE="$(dirname "$GOAL_FILE")/plan-w-team-ship-verdict-${SLUG}.json"
                    if [ "$(jq -r '.verdict // ""' "$SV_FILE" 2>/dev/null)" = "PASS" ]; then
                        HONOR_EXISTING=1
                    else
                        HONOR_EXISTING=0
                    fi
                    ;;
                *) HONOR_EXISTING=0 ;;
            esac
        fi
        if [ "$HONOR_EXISTING" = "1" ]; then
            dbg "SLUG=$SLUG already terminal_state=$EXISTING_TERMINAL (state-file short-circuit, source=$TERMINAL_SRC) → allowing stop"
            ANY_TERMINAL=true
            continue
        else
            echo "[goal-evaluator] SLUG=$SLUG worker-mode spoof-guard: ignoring self-written terminal_state=$EXISTING_TERMINAL (source='$TERMINAL_SRC' not accepted or uncorroborated by PASS ship-verdict) — continuing real detection" >&2
            dbg "SLUG=$SLUG worker-mode: un-provenanced/uncorroborated terminal_state ignored (spoof guard)"
            # Do NOT short-circuit; fall through to real anchor detection.
        fi
    fi

    # PWT-STALE-SKIP (prong A): a NON-terminal goal that is provably not this run's
    # live work (aged + not-ours + worker-not-live) is skipped for the block
    # decision, so a stale/foreign leftover can't trap this session's Stop. Only
    # applies to genuinely non-terminal goals; never marks/deletes anything.
    if [ -z "$EXISTING_TERMINAL" ] && __is_stale_foreign_goal "$GOAL_FILE"; then
        echo "[goal-evaluator] SLUG=$SLUG stale-foreign skip — aged, not-this-session, worker not live; not counted toward block (PWT-STALE-SKIP)" >&2
        dbg "SLUG=$SLUG stale-foreign skip → continue (not counted toward block)"
        continue
    fi

    # Read recent transcript lines (last ~500) for anchor detection.
    #
    # SCAN is the union of two corpora:
    #   RAW     — the literal transcript tail (backward-compat: catches raw-form
    #             status blocks emitted via direct file-write paths).
    #   DECODED — jq-decoded text payloads, one per transcript entry, with
    #             escaped quotes unescaped (the FIX: catches status blocks
    #             stored inside assistant/user/tool message strings).
    #
    # Detectors match against SCAN so BOTH forms are detected. The slug-anchor
    # proximity defense is preserved because each DECODED entry is one logical
    # line — a status block's keys (stage/workflow_lock/slug, or
    # pending_escalations+slug, or low_confidence_routes+slug) all colocate on
    # that single line, so "same line" == "same status block".
    if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
        RAW=$(tail -500 "$TRANSCRIPT_PATH" 2>/dev/null || echo "")
        DECODED=$(decode_transcript "$TRANSCRIPT_PATH")
        RECENT=$(printf '%s\n%s\n' "$RAW" "$DECODED")
        dbg "SLUG=$SLUG transcript=$TRANSCRIPT_PATH raw_lines=$(printf '%s' "$RAW" | grep -c '' || echo 0) decoded_lines=$(printf '%s' "$DECODED" | grep -c '' || echo 0)"
    else
        RECENT=""
        dbg "SLUG=$SLUG no transcript path (TRANSCRIPT_PATH='$TRANSCRIPT_PATH') — transcript detectors will be no-ops"
    fi

    TERMINAL=""
    REASON=""

    # (1) SUCCESS: status block with stage="retro-complete" AND workflow_lock="done"
    # PWT-T5b dogfood fix (2026-05-20): also require slug match to prevent
    # false positives from documentation/example text that mentions the
    # anchor strings. The status block always includes "slug":"<this-SLUG>".
    #
    # 2026-05-25 escaped-quote fix: all three anchors must colocate on the SAME
    # decoded line. Because decode_transcript emits one logical line per
    # transcript entry (newlines collapsed), a genuine status block's three
    # keys land together. Requiring same-line co-occurrence is the faithful
    # translation of "same status block" and is strictly stronger than the old
    # anywhere-in-corpus check — it prevents a documentation example that
    # mentions stage=retro-complete in one entry and this slug in an unrelated
    # entry from falsely combining into a SUCCESS.
    #
    # 2026-05-25 spacing fix: surface-status.sh emits PRETTY-PRINTED JSON
    # (`"stage": "retro-complete"` — colon-SPACE), and decode_transcript only
    # collapses newlines (not inner spacing), so the decoded block keeps the
    # `": "` form. A fixed-string grep for the compact `"stage":"retro-complete"`
    # never matched the real block — the very signal the retro emits. We use
    # space-tolerant ERE (`"key"[[:space:]]*:[[:space:]]*"val"`) which matches
    # BOTH compact (direct-write/tool-input) AND pretty-printed (status helper)
    # forms. The SLUG is safe-slugged (kebab `[a-z0-9-]`), so it carries no ERE
    # metacharacters.
    SLUG_RE="\"slug\"[[:space:]]*:[[:space:]]*\"${SLUG}\""
    MARKER_MATCH=0
    if printf '%s\n' "$RECENT" \
         | grep -E '"stage"[[:space:]]*:[[:space:]]*"retro-complete"' \
         | grep -E '"workflow_lock"[[:space:]]*:[[:space:]]*"done"' \
         | grep -E "$SLUG_RE" >/dev/null 2>&1; then
        MARKER_MATCH=1
    fi

    # PWT-TERM2 runaway guard — a deterministic PASS ship-verdict is the objective
    # "we already shipped" signal and must dominate a missing/fragile transcript
    # marker. Without it, a worker that shipped (PASS verdict) but failed to emit the
    # exact paired stage=retro-complete + workflow_lock=done block leaves
    # terminal_state null → /goal keeps the session alive → the model invents phantom
    # work (the 2026-06-22 runaway). Accept the verdict only when its ts is at/after
    # this goal's started_at, so a STALE PASS verdict left by an aborted prior run of
    # the same slug cannot prematurely succeed a new run. Unparseable timestamps fail
    # toward honoring (consistent with C3 already trusting this artifact). The
    # feature-AC AND-check + empty-AC antipark check BELOW still run, so a genuinely
    # incomplete multi-AC run is never prematurely terminated.
    SHIP_VERDICT_PASS=0
    SV_FILE="$(dirname "$GOAL_FILE")/plan-w-team-ship-verdict-${SLUG}.json"
    if [ "$(jq -r '.verdict // ""' "$SV_FILE" 2>/dev/null)" = "PASS" ]; then
        SV_TS=$(jq -r '.ts // ""' "$SV_FILE" 2>/dev/null)
        SV_EPOCH=$(__iso_to_epoch "$SV_TS")
        START_EPOCH=$(__iso_to_epoch "$STARTED_AT")
        if [ -z "$SV_EPOCH" ] || [ -z "$START_EPOCH" ] || [ "$SV_EPOCH" -ge "$START_EPOCH" ] 2>/dev/null; then
            SHIP_VERDICT_PASS=1
        else
            dbg "(1/PWT-TERM2) PASS ship-verdict ignored — ts=$SV_TS precedes started_at=$STARTED_AT (stale prior-run verdict)"
        fi
    fi

    # ── Test-green corroboration (R3/AC3, 2026-07-16) ────────────────────────
    # "The suite is green" used to be a CLAIM in a transcript; nothing read it.
    # plan-w-team-test-green.sh now writes a deterministic verdict artifact, and
    # the SUCCESS gate consults it — the same hand-off-the-check move as
    # PWT-TERM2's ship-verdict read, whose idiom this mirrors exactly:
    # $(dirname "$GOAL_FILE") resolution (WT2-safe on both sides), ts>=started_at
    # freshness, fail-open on anything unreadable.
    #
    # FAIL-OPEN is deliberate and asymmetric: this check may only ever WITHHOLD
    # success on positive evidence of a FRESH RED suite. Absent / stale /
    # malformed / green / kill-switched → behave exactly as before. A consumer
    # repo with no wrapper is untouched.
    #
    # BOUNDED: there are no wall-clock or turn caps in this pipeline by design,
    # so a permanently-red artifact could otherwise wedge the loop forever.
    # After 3 consecutive turns blocked on the SAME red ts, convert to
    # USER_ESCALATION_HALT so a human sees it (mirrors the low-confidence-streak
    # precedent). A NEW red ts means a new suite run — the streak restarts.
    TEST_GREEN_BLOCK=""
    if [ "$MARKER_MATCH" = "1" ] || [ "$SHIP_VERDICT_PASS" = "1" ]; then
      if [ "${PLAN_W_TEAM_DISABLE_TEST_GREEN:-0}" != "1" ]; then
        TG_FILE="$(dirname "$GOAL_FILE")/plan-w-team-test-green-${SLUG}.json"
        # NOT `.green // ""` — jq's `//` treats FALSE as empty and takes the
        # alternative, so a RED artifact ({"green": false}) would read as
        # unreadable and fail open: the exact defect class this check exists to
        # close. Stringify explicitly instead: "true" | "false" | "" (absent).
        TG_GREEN=$(jq -r 'if (type == "object" and has("green")) then (.green | tostring) else "" end' \
            "$TG_FILE" 2>/dev/null || echo "")
        if [ "$TG_GREEN" = "false" ]; then
            TG_TS=$(jq -r '.ts // ""' "$TG_FILE" 2>/dev/null || echo "")
            TG_EPOCH=$(__iso_to_epoch "$TG_TS")
            START_EPOCH=$(__iso_to_epoch "$STARTED_AT")
            # Unparseable ts → treat as STALE (fail-open); only a verdict we can
            # positively date to this run may block.
            if [ -n "$TG_EPOCH" ] && [ -n "$START_EPOCH" ] && [ "$TG_EPOCH" -ge "$START_EPOCH" ] 2>/dev/null; then
                TG_SEEN=$(jq -r '.test_green_block_ts // ""' "$GOAL_FILE" 2>/dev/null || echo "")
                TG_STREAK=$(jq -r '.test_green_block_streak // 0' "$GOAL_FILE" 2>/dev/null || echo 0)
                printf '%s' "${TG_STREAK:-}" | grep -qE '^[0-9]+$' || TG_STREAK=0
                if [ "$TG_SEEN" = "$TG_TS" ]; then
                    TG_STREAK=$((TG_STREAK + 1))
                else
                    TG_STREAK=1   # new red ts = new suite run = fresh streak
                fi
                jq --arg ts "$TG_TS" --argjson n "$TG_STREAK" \
                   '.test_green_block_ts = $ts | .test_green_block_streak = $n' \
                   "$GOAL_FILE" > "$GOAL_FILE.tmp" 2>/dev/null && mv "$GOAL_FILE.tmp" "$GOAL_FILE"
                TG_EXIT=$(jq -r '.suite_exit // "null"' "$TG_FILE" 2>/dev/null || echo "null")
                TG_REASON=$(jq -r '.reason // ""' "$TG_FILE" 2>/dev/null || echo "")
                if [ "$TG_STREAK" -ge 3 ] 2>/dev/null; then
                    TERMINAL="USER_ESCALATION_HALT"
                    REASON="TEST_GREEN_RED persisted across ${TG_STREAK} consecutive stop attempts on the same verdict (ts=$TG_TS, suite_exit=$TG_EXIT, reason=$TG_REASON). The suite is not going green on its own — escalating to the user rather than looping. Fix the suite, or set PLAN_W_TEAM_DISABLE_TEST_GREEN=1 to bypass."
                    dbg "(1/TEST_GREEN) streak=$TG_STREAK on ts=$TG_TS → USER_ESCALATION_HALT"
                else
                    TEST_GREEN_BLOCK="TEST_GREEN_RED: the deterministic test-green verdict for slug=$SLUG is RED (ts=$TG_TS, suite_exit=$TG_EXIT, reason=$TG_REASON). SUCCESS is withheld until the suite is green. Re-run: .claude/scripts/plan-w-team-test-green.sh --slug $SLUG. Kill switch: PLAN_W_TEAM_DISABLE_TEST_GREEN=1. (Blocked ${TG_STREAK}/3 — a 3rd consecutive block on this same verdict escalates to the user.)"
                    dbg "(1/TEST_GREEN) fresh red ts=$TG_TS streak=$TG_STREAK → withholding SUCCESS"
                fi
            else
                dbg "(1/TEST_GREEN) red verdict ignored — ts=$TG_TS not at/after started_at=$STARTED_AT (stale prior-run verdict)"
            fi
        elif [ -f "$TG_FILE" ] && [ -z "$TG_GREEN" ]; then
            echo "[goal-evaluator] test-green artifact present but unreadable: $TG_FILE — treating as absent (fail-open)" >&2
        fi
      fi
    fi

    if [ -n "$TEST_GREEN_BLOCK" ]; then
        # Fresh-red block: route through the same BLOCK_REASON branch the
        # criteria gate uses, so the caller sees one consistent block shape.
        TERMINAL=""
        REASON=""
        CRITERIA_BLOCK_REASON="$TEST_GREEN_BLOCK"
    elif [ "$MARKER_MATCH" = "1" ] || [ "$SHIP_VERDICT_PASS" = "1" ]; then
        [ -z "$TERMINAL" ] && TERMINAL="SUCCESS"
        if [ "$MARKER_MATCH" = "1" ]; then
            REASON="retro-complete status block emitted with workflow_lock=done for slug=$SLUG"
            dbg "(1) SUCCESS matched: stage=retro-complete + workflow_lock=done + slug=$SLUG colocated on one decoded line"
        else
            REASON="runaway-guard (PWT-TERM2): deterministic PASS ship-verdict for slug=$SLUG with transcript marker absent — resolving SUCCESS instead of continuing into unrequested work"
            dbg "(1/PWT-TERM2) SUCCESS via PASS ship-verdict (marker absent) for slug=$SLUG"
        fi

        # PWT-T5c: AND-check feature-specific done criteria
        #
        # DEFECT B (2026-07-16) — this contract MUST fail CLOSED.
        # Previously a row that was not the canonical
        # {pattern, description, met, met_at} object (e.g. a bare string, the
        # shape a mis-written §1.5 injection emits) made `.pattern` error out to
        # an EMPTY string, and the subsequent `grep -E ""` matched every line —
        # silently marking the row MET. The write-back then errored too, so
        # nothing persisted and UNMET_DESCRIPTIONS stayed empty: the run resolved
        # SUCCESS having checked NOTHING. A criteria contract the evaluator
        # cannot parse is the one case where it must never award SUCCESS.
        #
        # Rules now: unparseable array → BLOCK; non-object row → UNMET
        # ("malformed done-criteria row"); empty/absent pattern → UNMET (never
        # grep -E ""); non-compiling regex → UNMET. Canonical rows behave
        # exactly as before.
        CRITERIA_LEN=$(jq '.feature_specific_done_criteria // [] | length' "$GOAL_FILE" 2>/dev/null)
        if ! printf '%s' "${CRITERIA_LEN:-}" | grep -qE '^[0-9]+$'; then
            # The array could not be read at all (malformed JSON / wrong type).
            # Fail CLOSED: never let an unreadable contract mean "all met".
            CRITERIA_LEN=0
            TERMINAL=""
            REASON=""
            CRITERIA_BLOCK_REASON="Generic SUCCESS anchors present but feature_specific_done_criteria could not be parsed in $(basename "$GOAL_FILE") — treating as UNMET (fail-closed). Repair the criteria array to canonical {pattern, description, met, met_at} rows, then re-emit retro-complete."
            dbg "(1/T5c) criteria array unparseable → fail-closed BLOCK"
        elif [ "$CRITERIA_LEN" -gt 0 ]; then
            UNMET_DESCRIPTIONS=""
            NEW_CRITERIA=$(jq -c '.feature_specific_done_criteria' "$GOAL_FILE")
            for i in $(seq 0 $((CRITERIA_LEN - 1))); do
                # Shape gate FIRST — everything below assumes a canonical object.
                ROW_TYPE=$(echo "$NEW_CRITERIA" | jq -r ".[$i] | type" 2>/dev/null)
                ROW_OK=$(echo "$NEW_CRITERIA" | jq -r \
                    ".[$i] | if (type==\"object\" and has(\"pattern\") and has(\"description\") and has(\"met\") and has(\"met_at\")) then \"1\" else \"0\" end" 2>/dev/null)
                if [ "$ROW_OK" != "1" ]; then
                    ROW_RAW=$(echo "$NEW_CRITERIA" | jq -c ".[$i]" 2>/dev/null | head -c 120)
                    UNMET_DESCRIPTIONS="${UNMET_DESCRIPTIONS}${UNMET_DESCRIPTIONS:+; }malformed done-criteria row [$i] (type=${ROW_TYPE:-unknown}, expected object with pattern/description/met/met_at): ${ROW_RAW}"
                    dbg "(1/T5c) row $i malformed (type=${ROW_TYPE:-unknown}) → UNMET, fail-closed"
                    continue
                fi
                PATTERN=$(echo "$NEW_CRITERIA" | jq -r ".[$i].pattern")
                ALREADY_MET=$(echo "$NEW_CRITERIA" | jq -r ".[$i].met")
                if [ "$ALREADY_MET" = "true" ]; then continue; fi
                DESC=$(echo "$NEW_CRITERIA" | jq -r ".[$i].description")
                # An empty pattern would make `grep -E ""` match EVERY line —
                # self-satisfying. Treat as malformed, never as met.
                if [ -z "$PATTERN" ] || [ "$PATTERN" = "null" ]; then
                    UNMET_DESCRIPTIONS="${UNMET_DESCRIPTIONS}${UNMET_DESCRIPTIONS:+; }malformed done-criteria row [$i]: empty pattern (${DESC})"
                    dbg "(1/T5c) row $i has empty pattern → UNMET, fail-closed"
                    continue
                fi
                # A pattern that does not compile can never legitimately match;
                # count it UNMET rather than letting grep's error read as no-match.
                if ! printf '' | grep -E "$PATTERN" >/dev/null 2>&1; then
                    if [ "$?" -gt 1 ]; then
                        UNMET_DESCRIPTIONS="${UNMET_DESCRIPTIONS}${UNMET_DESCRIPTIONS:+; }malformed done-criteria row [$i]: pattern is not a valid regex (${DESC})"
                        dbg "(1/T5c) row $i pattern does not compile → UNMET, fail-closed"
                        continue
                    fi
                fi
                if echo "$RECENT" | grep -E "$PATTERN" >/dev/null 2>&1; then
                    NEW_CRITERIA=$(echo "$NEW_CRITERIA" \
                        | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                             ".[$i].met = true | .[$i].met_at = \$ts")
                else
                    UNMET_DESCRIPTIONS="${UNMET_DESCRIPTIONS}${UNMET_DESCRIPTIONS:+; }${DESC}"
                fi
            done
            # Persist updated criteria atomically
            jq --argjson c "$NEW_CRITERIA" '.feature_specific_done_criteria = $c' "$GOAL_FILE" \
                > "$GOAL_FILE.tmp" && mv "$GOAL_FILE.tmp" "$GOAL_FILE"
            if [ -n "$UNMET_DESCRIPTIONS" ]; then
                TERMINAL=""
                REASON=""
                # Will be picked up by the BLOCK_REASON branch below
                CRITERIA_BLOCK_REASON="Generic SUCCESS anchors present but feature-specific criteria unmet: ${UNMET_DESCRIPTIONS}. Continue pipeline until each criterion appears in transcript (typically as 'AC<N>: PASS' lines emitted by Step 5 review and Step 6 ship)."
            fi
        else
            # PWT-ANTIPARK (AC2) — empty/missing AC contract ≠ done while backlog remains.
            # An empty feature_specific_done_criteria array must NOT let the generic
            # retro-complete anchor trivially fire SUCCESS when the objective progress
            # snapshot reports an unmet backlog (the multi-epic program trap: epics
            # unbuilt, no AC contract, a stray retro-complete would otherwise win).
            # Fail-open: no snapshot / kill-switch → generic SUCCESS as today (T5b).
            AP_STATE=$(__antipark_state "$SLUG")
            if [ -n "$AP_STATE" ]; then
                AP_BK=$(echo "$AP_STATE" | awk '{print $1}')
                AP_BL=$(echo "$AP_STATE" | awk '{print $2}')
                if [ "${AP_BK:-0}" = "1" ] && [ "${AP_BL:-0}" -gt 0 ] 2>/dev/null; then
                    TERMINAL=""
                    REASON=""
                    CRITERIA_BLOCK_REASON="Generic SUCCESS anchors present but the feature-AC contract is EMPTY and objective backlog=${AP_BL} remains (supervisor-progress-${SLUG}.json). An empty AC contract is treated as not-done while unblocked backlog remains (PWT-ANTIPARK AC2). Drain the backlog or encode remaining work as ACs, then re-emit retro-complete. Kill switch: PLAN_W_TEAM_DISABLE_ANTIPARK=1."
                    echo "[goal-evaluator] SLUG=$SLUG empty-AC-not-done: withholding SUCCESS (backlog=${AP_BL}, PWT-ANTIPARK)" >&2
                fi
            fi
        fi
    fi

    # C3 — deterministic ship-verdict corroboration (worker mode only).
    # Transcript anchors are assistant free-text a worker can fabricate. Inside a
    # bg worker, require Step 6 to have written a real PASS ship-verdict artifact
    # (only reachable after every §6 ENFORCING gate passed) before honoring
    # SUCCESS. Interactive runs keep transcript-only detection (human watching).
    if [ "$TERMINAL" = "SUCCESS" ] && [ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-}" = "1" ]; then
        SHIP_VERDICT_FILE="$(dirname "$GOAL_FILE")/plan-w-team-ship-verdict-${SLUG}.json"
        if [ "$(jq -r '.verdict // ""' "$SHIP_VERDICT_FILE" 2>/dev/null)" != "PASS" ]; then
            TERMINAL=""
            REASON=""
            CRITERIA_BLOCK_REASON="Generic SUCCESS anchors present but no deterministic ship-verdict for slug=$SLUG. Step 6 writes .claude/state/plan-w-team-ship-verdict-${SLUG}.json with verdict=PASS only after every §6 ENFORCING gate passes; SUCCESS is withheld until it exists. Continue the pipeline through a real ship."
            echo "[goal-evaluator] SLUG=$SLUG worker-mode: SUCCESS anchors present but ship-verdict missing/!=PASS — withholding SUCCESS (C3 anti-spoof)" >&2
            dbg "SLUG=$SLUG worker-mode SUCCESS withheld — no PASS ship-verdict at $SHIP_VERDICT_FILE"
        fi
    fi

    # PWT-LANE2 — actor-aware SUCCESS (2026-08-09 cleanscale incident). C3
    # above corroborates only inside a bg WORKER (env-marked). But the
    # supervisor/origin chat is an interactive session, and detector (1) reads
    # THIS session's transcript: a supervisor that hand-emitted the
    # retro-complete status block terminated the goal with zero pipeline stages
    # run — the evaluator measured whether the goal LOOKED done, never who did
    # the work. Close it: when the goal records a well-formed worker_sid and
    # THIS session is not that worker, anchors in this transcript are hearsay —
    # require the same deterministic PASS ship-verdict Step 6 writes. The
    # legitimate completion path is untouched: the WORKER's own transcript
    # carries the real retro-complete (SID match → gate skipped), and
    # parent-child propagation (4) already surfaces worker terminals to the
    # supervisor without transcript anchors.
    # Fail-open: SID-less harness, or a goal with no/malformed worker_sid
    # (in-session interactive run — a human is watching), keeps today's
    # behavior. Kill switch: PLAN_W_TEAM_DISABLE_ACTOR_GATE=1.
    if [ "$TERMINAL" = "SUCCESS" ] && [ "${PLAN_W_TEAM_DISABLE_ACTOR_GATE:-}" != "1" ] \
       && [ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-}" != "1" ] && [ -n "$SELF_SID" ]; then
        AA_WSID=$(jq -r '.worker_sid // ""' "$GOAL_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        case "$AA_WSID" in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
                if [ "${SELF_SID:0:8}" != "${AA_WSID:0:8}" ]; then
                    AA_SV_FILE="$(dirname "$GOAL_FILE")/plan-w-team-ship-verdict-${SLUG}.json"
                    if [ "$(jq -r '.verdict // ""' "$AA_SV_FILE" 2>/dev/null)" != "PASS" ]; then
                        TERMINAL=""
                        REASON=""
                        CRITERIA_BLOCK_REASON="SUCCESS anchors found in THIS session's transcript, but the goal's owning worker is ${AA_WSID:0:8} and this session is ${SELF_SID:0:8} — a supervisor/observer cannot testify that the pipeline ran (PWT-LANE2 actor gate). SUCCESS requires the worker's own retro or the deterministic PASS ship-verdict at plan-w-team-ship-verdict-${SLUG}.json. Do NOT hand-build the outcome; steer the worker to run the pipeline to terminal, or escalate to the user."
                        echo "[goal-evaluator] SLUG=$SLUG actor-gate: SUCCESS anchors from non-owner session ${SELF_SID:0:8} (worker ${AA_WSID:0:8}) without PASS ship-verdict — withholding SUCCESS (PWT-LANE2)" >&2
                        dbg "SLUG=$SLUG PWT-LANE2 withheld SUCCESS — non-owner transcript anchors, no PASS ship-verdict"
                    fi
                fi
                ;;
        esac
    fi

    if [ -z "$TERMINAL" ]; then
        dbg "(1) SUCCESS not matched: needed stage=retro-complete + workflow_lock=done + slug=$SLUG colocated on one decoded line"
    fi

    # (2) USER_ESCALATION_HALT: pending_escalations contains a hard-gate label
    # Slug-match defense: the status/summary block including the escalation MUST
    # carry "slug":"<SLUG>" within the same ~10 lines, otherwise the match is
    # likely from documentation text mentioning the site name.
    #
    # 2026-05-25 escaped-quote fix: $RECENT now includes the jq-decoded corpus,
    # so an escalation block emitted as escaped assistant text is matched. The
    # ±5-line window remains correct for both corpora: in DECODED text the
    # pending_escalations array and slug colocate on ONE line (well inside the
    # window); in RAW text a multi-line status block stays inside ±5 lines.
    if [ -z "$TERMINAL" ]; then
        # credential-wall (2026-06-02): a CLI non-interactive credential/token
        # wall hit during deploy/ship is a blocked-external operator escalation —
        # same shape as the browser-console REQ-5 gate. The credential-wall
        # detector hook emits a USER_ESCALATION_HALT block carrying
        # "pending_escalations":["credential-wall"], so the run halts for the
        # operator to provision the missing secret. Additive — the original three
        # hard-gate sites are unchanged.
        # regression-halt (2.5.0): the §6b no-regression gate emits
        # "pending_escalations":["regression-halt"] when a test green at run-start
        # is now red/removed. Per the chosen enforcement (hard-block + escalate),
        # an autonomous run HALTS to the user rather than shipping the regression.
        for SITE in push-ack secret-scan-allow scope-unlock-for-drift credential-wall regression-halt; do
            # grep -B/-A scope: any pending_escalations line referencing $SITE
            # must have $SLUG within 10 lines (status block size).
            # Space-tolerant (2026-05-25): pretty-printed blocks render
            # `"pending_escalations": [ "push-ack" ]` with spaces; match both
            # compact and spaced via [[:space:]]* around colon and bracket.
            if echo "$RECENT" | grep -B5 -A5 -E "\"pending_escalations\"[[:space:]]*:[[:space:]]*\[[^]]*\"$SITE\"" \
                | grep -E "\"slug\"[[:space:]]*:[[:space:]]*\"$SLUG\"" >/dev/null 2>&1; then
                TERMINAL="USER_ESCALATION_HALT"
                REASON="hard-gate site '$SITE' in pending_escalations for slug=$SLUG — user must respond"
                dbg "(2) USER_ESCALATION_HALT matched: site=$SITE in pending_escalations within ±5 lines of slug=$SLUG"
                break
            fi
        done
        [ -z "$TERMINAL" ] && dbg "(2) USER_ESCALATION_HALT not matched: no hard-gate site (push-ack/secret-scan-allow/scope-unlock-for-drift) in pending_escalations within ±5 lines of slug=$SLUG"
    fi

    # (3) LOW_CONFIDENCE_STREAK: status block reports low_confidence_routes >= 3
    # Slug-match defense: extract low_confidence_routes values only from
    # transcript regions where this slug appears within ±5 lines.
    #
    # 2026-05-25 escaped-quote fix: same union-corpus + ±5-line-window
    # rationale as (2). Decoded lines colocate slug + low_confidence_routes.
    if [ -z "$TERMINAL" ]; then
        # Space-tolerant (2026-05-25): match both `"low_confidence_routes":N`
        # (compact) and `"low_confidence_routes": N` (pretty-printed). Extract
        # the trailing integer regardless of the colon spacing.
        MAX_LOW=$(echo "$RECENT" \
            | grep -B5 -A5 -E "\"slug\"[[:space:]]*:[[:space:]]*\"$SLUG\"" \
            | grep -oE '"low_confidence_routes"[[:space:]]*:[[:space:]]*[0-9]+' \
            | grep -oE '[0-9]+$' | sort -n | tail -1)
        if [ -n "$MAX_LOW" ] && [ "$MAX_LOW" -ge 3 ]; then
            TERMINAL="LOW_CONFIDENCE_STREAK"
            REASON="low_confidence_routes=$MAX_LOW (≥3 — supervisor confidence threshold breached)"
            dbg "(3) LOW_CONFIDENCE_STREAK matched: low_confidence_routes=$MAX_LOW within ±5 lines of slug=$SLUG"
        else
            dbg "(3) LOW_CONFIDENCE_STREAK not matched: max low_confidence_routes near slug=$SLUG = ${MAX_LOW:-none} (need ≥3)"
        fi
    fi

    # No (4) TIME_OR_TURN_CAP: removed by design. Only goal-success and hard-gate
    # escalations are valid terminal states (see shared/goal-conditions.md). If the
    # evaluator never returns success, the supervisor's low-confidence streak signal
    # (state 3) is the human-attention trigger, not a wall-clock or turn fallback.

    # (4) PARENT-CHILD PROPAGATION: when this goal has spawned workers (via
    # pwt-goal.sh --launch or similar), the worker's retro-complete anchors
    # land in the WORKER's transcript, not the parent's. Transcript-only
    # detection therefore stalls the parent indefinitely (2026-05-20 incident:
    # parent stalled 13 min after worker shipped).
    #
    # The spawned-children registry (.claude/state/plan-w-team-spawned-children-
    # <PARENT_SLUG>.jsonl) authoritatively records which workers this run
    # spawned. Each worker maintains its own goal state file. When every
    # registered worker has a non-null terminal_state, propagate the
    # worst-precedence state to the parent.
    #
    # Precedence (low → high severity):
    #   SUCCESS < API_HALT < LOW_CONFIDENCE_STREAK < USER_ESCALATION_HALT
    # A halted worker must halt the parent (surface to user). A clean worker
    # satisfies parent SUCCESS. Mixed signals win toward the more severe.
    #
    # Fail-open: missing/corrupt worker state never falsely terminates the
    # parent. Self-referential registry rows (slug == parent SLUG) are
    # skipped to prevent infinite hold-open.
    if [ -z "$TERMINAL" ]; then
        REGISTRY="${STATE_DIR}/plan-w-team-spawned-children-${SLUG}.jsonl"
        if [ ! -f "$REGISTRY" ] && [ "$STATE_DIR" != "$FALLBACK_STATE_DIR" ]; then
            REGISTRY="${FALLBACK_STATE_DIR}/plan-w-team-spawned-children-${SLUG}.jsonl"
        fi
        if [ -f "$REGISTRY" ]; then
            CHILD_SLUGS=$(jq -r 'select(.slug != null and .slug != "") | .slug' "$REGISTRY" 2>/dev/null \
                | sort -u)
            if [ -n "$CHILD_SLUGS" ]; then
                ALL_TERMINAL=true
                WORST_STATE=""
                WORST_REASON=""
                CHECKED_COUNT=0
                while IFS= read -r CHILD_SLUG; do
                    [ -z "$CHILD_SLUG" ] && continue
                    # Self-reference guard: prevent infinite hold-open if a
                    # registry row accidentally references the parent itself.
                    [ "$CHILD_SLUG" = "$SLUG" ] && continue

                    CHILD_STATE="${STATE_DIR}/plan-w-team-goal-${CHILD_SLUG}.json"
                    if [ ! -f "$CHILD_STATE" ] && [ "$STATE_DIR" != "$FALLBACK_STATE_DIR" ]; then
                        CHILD_STATE="${FALLBACK_STATE_DIR}/plan-w-team-goal-${CHILD_SLUG}.json"
                    fi

                    if [ ! -f "$CHILD_STATE" ]; then
                        # Child hasn't written its goal state yet — not terminal.
                        ALL_TERMINAL=false
                        continue
                    fi

                    if ! jq -e . "$CHILD_STATE" >/dev/null 2>&1; then
                        # Corrupt child state — warn and skip. Do NOT count
                        # toward ALL_TERMINAL=false; a corrupt file would
                        # otherwise pin the parent forever.
                        echo "[goal-evaluator] WARN: corrupt child state at $CHILD_STATE; skipping" >&2
                        continue
                    fi

                    CHILD_TERMINAL=$(jq -r '.terminal_state // ""' "$CHILD_STATE")
                    if [ -z "$CHILD_TERMINAL" ]; then
                        # 2.1.145 DEAD-worker detection: registry has the child's SID;
                        # if that SID is NOT in background_tasks AND the child has no
                        # terminal_state, the worker crashed without writing retro.
                        # Without this check, the parent stalls forever. Backward-compat:
                        # if ACTIVE_SIDS is empty (older Claude Code), skip → preserves
                        # original behavior of waiting for terminal_state.
                        CHILD_SID=$(jq -r 'select(.slug == "'"$CHILD_SLUG"'") | .session_id // ""' \
                            "$REGISTRY" 2>/dev/null | head -1 | cut -c1-8)
                        if [ -n "$ACTIVE_SIDS" ] && [ -n "$CHILD_SID" ] \
                           && ! echo "$ACTIVE_SIDS" | grep -qFx "$CHILD_SID"; then
                            # Worker dead, no terminal state → treat as LOW_CONFIDENCE
                            # so user investigates; do NOT pretend it succeeded.
                            # ALSO persist DEAD to the child's own goal file so this
                            # evaluator pass (and future ones) don't block on it.
                            DEAD_REASON="DEAD — SID $CHILD_SID not in background_tasks, no terminal_state written by worker"
                            jq --arg t "LOW_CONFIDENCE_STREAK" --arg r "$DEAD_REASON" \
                               --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                               '.terminal_state = $t | .terminal_reason = $r | .terminated_at = $ts' \
                               "$CHILD_STATE" > "$CHILD_STATE.tmp" 2>/dev/null \
                                && mv "$CHILD_STATE.tmp" "$CHILD_STATE"
                            CHILD_TERMINAL="DEAD"
                            CHECKED_COUNT=$((CHECKED_COUNT+1))
                            if [ "$WORST_STATE" != "USER_ESCALATION_HALT" ]; then
                                WORST_STATE="LOW_CONFIDENCE_STREAK"
                                WORST_REASON="child SLUG=$CHILD_SLUG $DEAD_REASON"
                            fi
                            continue
                        fi
                        # 2026-05-29 API_HALT detection (additive, FAIL-SAFE): a worker
                        # that halted on a transient API/socket error is STILL listed in
                        # background_tasks (alive process, idle session), so the DEAD
                        # check above did NOT fire and it would otherwise block the parent
                        # forever. Classify API_HALT only when BOTH gates hold, so quoted
                        # error text in an ACTIVE transcript cannot false-positive:
                        #   (a) child transcript idle — mtime older than the threshold;
                        #   (b) last meaningful decoded turn matches a transient pattern.
                        # A healthy worker has recent mtime → gate (a) fails → IMMUNE.
                        # If the helper is absent or the transcript can't be resolved,
                        # this whole block no-ops and falls through to today's behavior.
                        if command -v pwt_is_transient_error >/dev/null 2>&1 \
                           && [ -n "$ACTIVE_SIDS" ] && [ -n "$CHILD_SID" ] \
                           && echo "$ACTIVE_SIDS" | grep -qFx "$CHILD_SID"; then
                            CT_BASE="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}/$(printf '%s' "$PROJECT_ROOT" | sed 's#/#-#g')"
                            CHILD_TX=""
                            if [ -d "$CT_BASE" ]; then
                                for cand in "$CT_BASE/${CHILD_SID}"*.jsonl; do
                                    [ -f "$cand" ] && { CHILD_TX="$cand"; break; }
                                done
                            fi
                            if [ -n "$CHILD_TX" ]; then
                                NOW_EPOCH=$(date +%s)
                                TX_MTIME=$(stat -f %m "$CHILD_TX" 2>/dev/null || stat -c %Y "$CHILD_TX" 2>/dev/null || echo "$NOW_EPOCH")
                                IDLE_S=$(( NOW_EPOCH - TX_MTIME ))
                                IDLE_THRESH="${PWT_API_HALT_IDLE_S:-600}"
                                if [ "$IDLE_S" -ge "$IDLE_THRESH" ]; then
                                    LAST_MEANINGFUL=$(decode_transcript "$CHILD_TX" | grep -v '^[[:space:]]*$' | tail -1)
                                    if [ -n "$LAST_MEANINGFUL" ] && pwt_is_transient_error "$LAST_MEANINGFUL"; then
                                        HALT_REASON="API_HALT — child SID $CHILD_SID idle ${IDLE_S}s (>=${IDLE_THRESH}s) and last turn matches transient-connection pattern"
                                        jq --arg t "API_HALT" --arg r "$HALT_REASON" \
                                           --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                                           '.terminal_state = $t | .terminal_reason = $r | .terminated_at = $ts' \
                                           "$CHILD_STATE" > "$CHILD_STATE.tmp" 2>/dev/null \
                                            && mv "$CHILD_STATE.tmp" "$CHILD_STATE" || rm -f "$CHILD_STATE.tmp" 2>/dev/null
                                        CHECKED_COUNT=$((CHECKED_COUNT+1))
                                        # Precedence: SUCCESS < API_HALT < LOW_CONFIDENCE_STREAK < USER_ESCALATION_HALT.
                                        if [ "$WORST_STATE" != "USER_ESCALATION_HALT" ] && [ "$WORST_STATE" != "LOW_CONFIDENCE_STREAK" ]; then
                                            WORST_STATE="API_HALT"
                                            WORST_REASON="child SLUG=$CHILD_SLUG $HALT_REASON"
                                        fi
                                        continue
                                    fi
                                fi
                            fi
                        fi
                        ALL_TERMINAL=false
                        continue
                    fi
                    CHECKED_COUNT=$((CHECKED_COUNT+1))

                    # Worst-precedence selection.
                    case "$CHILD_TERMINAL" in
                        USER_ESCALATION_HALT)
                            WORST_STATE="USER_ESCALATION_HALT"
                            WORST_REASON=$(jq -r '.terminal_reason // ""' "$CHILD_STATE")
                            ;;
                        LOW_CONFIDENCE_STREAK)
                            if [ "$WORST_STATE" != "USER_ESCALATION_HALT" ]; then
                                WORST_STATE="LOW_CONFIDENCE_STREAK"
                                WORST_REASON=$(jq -r '.terminal_reason // ""' "$CHILD_STATE")
                            fi
                            ;;
                        API_HALT)
                            # Recoverable (supervisor restarts bounded); ranks above
                            # SUCCESS but below LOW_CONFIDENCE_STREAK / USER_ESCALATION_HALT.
                            if [ "$WORST_STATE" != "USER_ESCALATION_HALT" ] && [ "$WORST_STATE" != "LOW_CONFIDENCE_STREAK" ]; then
                                WORST_STATE="API_HALT"
                                WORST_REASON=$(jq -r '.terminal_reason // ""' "$CHILD_STATE")
                            fi
                            ;;
                        SUCCESS)
                            if [ -z "$WORST_STATE" ]; then
                                WORST_STATE="SUCCESS"
                                WORST_REASON=$(jq -r '.terminal_reason // ""' "$CHILD_STATE")
                            fi
                            ;;
                    esac
                done <<< "$CHILD_SLUGS"

                if [ "$ALL_TERMINAL" = "true" ] && [ "$CHECKED_COUNT" -gt 0 ] && [ -n "$WORST_STATE" ]; then
                    TERMINAL="$WORST_STATE"
                    REASON="parent SLUG=$SLUG: all $CHECKED_COUNT spawned worker(s) terminal; worst-precedence=$WORST_STATE; worker_reason=$WORST_REASON"
                fi
            fi

            # (5) SUPERVISOR-MIRROR DEAD PROPAGATION: when a spawned-child
            # registry row has type=supervisor_mirror, its `path` field points
            # at an origin-side mirror goal-state file. If the worker's SID
            # (registry session_id) is NOT in background_tasks AND the mirror
            # is still non-terminal, the worker crashed without retro AND
            # without writing terminal_state to its OWN goal file. We must
            # propagate DEAD into the mirror so the origin chat's evaluator
            # stops waiting. See docs/specs/supervisor-mirror-lifecycle.md.
            #
            # This is a pure side-effect sweep — it does NOT modify the
            # current goal's TERMINAL/REASON. The patched mirror is itself
            # one of the GOAL_FILES iterated on subsequent evaluator passes
            # (via plan-w-team-goal-*.json glob), so its newly-set
            # terminal_state surfaces through normal EXISTING_TERMINAL.
            #
            # Backward-compat: when ACTIVE_SIDS is empty (older Claude Code
            # without background_tasks hook input), skip to preserve original
            # behavior — no mirror patches without authoritative liveness data.
            if [ -n "$ACTIVE_SIDS" ]; then
                while IFS= read -r MIRROR_ROW; do
                    [ -z "$MIRROR_ROW" ] && continue
                    MIRROR_PATH=$(printf '%s' "$MIRROR_ROW" | jq -r '.path // ""' 2>/dev/null)
                    MIRROR_SID=$(printf '%s' "$MIRROR_ROW" | jq -r '.session_id // ""' 2>/dev/null \
                        | cut -c1-8)
                    [ -z "$MIRROR_PATH" ] && continue
                    [ ! -f "$MIRROR_PATH" ] && continue
                    [ -z "$MIRROR_SID" ] && continue

                    MIRROR_EXISTING=$(jq -r '.terminal_state // ""' "$MIRROR_PATH" 2>/dev/null || echo "")
                    [ -n "$MIRROR_EXISTING" ] && continue

                    if ! echo "$ACTIVE_SIDS" | grep -qFx "$MIRROR_SID"; then
                        # Worker dead AND mirror non-terminal → propagate
                        # LOW_CONFIDENCE_STREAK so origin investigates.
                        MIRROR_DEAD_REASON="DEAD — supervisor_mirror worker SID $MIRROR_SID not in background_tasks, no terminal_state written by worker"
                        jq --arg t "LOW_CONFIDENCE_STREAK" --arg r "$MIRROR_DEAD_REASON" \
                           --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                           '.terminal_state = $t | .terminal_reason = $r | .terminated_at = $ts' \
                           "$MIRROR_PATH" > "$MIRROR_PATH.tmp" 2>/dev/null \
                            && mv "$MIRROR_PATH.tmp" "$MIRROR_PATH" \
                            || rm -f "$MIRROR_PATH.tmp" 2>/dev/null
                        echo "[goal-evaluator] supervisor_mirror DEAD propagation: patched $MIRROR_PATH (worker $MIRROR_SID)" >&2
                    fi
                done < <(jq -c 'select(.type == "supervisor_mirror")' "$REGISTRY" 2>/dev/null)
            fi
        fi
    fi

    if [ -n "$TERMINAL" ]; then
        # Persist terminal state. terminal_state_source=evaluator is the C3
        # provenance marker: the worker-mode short-circuit guard above honors a
        # pre-existing terminal_state only when the evaluator (not the worker's
        # own LLM) wrote it.
        jq --arg t "$TERMINAL" --arg r "$REASON" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
           '.terminal_state = $t | .terminal_reason = $r | .terminated_at = $ts | .terminal_state_source = "evaluator"' \
           "$GOAL_FILE" > "$GOAL_FILE.tmp" && mv "$GOAL_FILE.tmp" "$GOAL_FILE"
        ANY_TERMINAL=true
        echo "[goal-evaluator] SLUG=$SLUG terminal=$TERMINAL reason=$REASON" >&2
    else
        # Build a block reason combining condition status
        # PWT-T5c: prefer the specific criteria-unmet reason when it exists
        if [ -n "${CRITERIA_BLOCK_REASON:-}" ]; then
            BLOCK_REASON="$CRITERIA_BLOCK_REASON"
        else
            BLOCK_REASON="/plan-w-team SLUG=$SLUG not yet terminal. Continue pipeline. Need ONE of: status block with stage=retro-complete + workflow_lock=done; pending_escalations containing a hard-gate site (push-ack/secret-scan-allow/scope-unlock-for-drift); low_confidence_routes>=3."
        fi
        # PWT-SUP-YIELD-SID bookkeeping: this goal is BLOCKING — record whether THIS
        # session owns it. Match the goal's recorded worker_sid (8-hex short SID, see
        # pwt-goal PWT-WT2) against SELF_SID's prefix (session_id is a full UUID whose
        # first 8 chars are the short SID). No worker_sid → ownership unprovable.
        # Normalize (trim ALL whitespace + lowercase) so a malformed/padded worker_sid
        # can't slip past the fail-safe (adversarial verify CASE J: "  5de5b9ac" would
        # else make the GENUINE owner yield). Ownership is established ONLY by a
        # well-formed token starting with 8 hex chars; anything else (empty, short,
        # non-hex, was-whitespace) is UN-OWNABLE → fail safe to BLOCK, never yield.
        THIS_WORKER_SID=$(jq -r '.worker_sid // ""' "$GOAL_FILE" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        case "$THIS_WORKER_SID" in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
                [ -n "$SELF_SID" ] && [ "${SELF_SID:0:8}" = "${THIS_WORKER_SID:0:8}" ] && OWNS_BLOCKING=1 ;;
            *)
                BLOCKING_GOAL_UNOWNABLE=1 ;;
        esac
        dbg "SLUG=$SLUG NOT terminal → blocking stop. reason=$BLOCK_REASON"
    fi
done

# PWT-ANTIPARK yield gate (2026-06-07) — promote feedback_supervisor_progress_objective
# from PROSE to an ENFORCED gate at the terminal-decision site. A supervisor session is
# normally allowed to YIELD (sleep) in the two branches below, on the assumption that its
# background await-loop will re-wake and re-dispatch. But when the objective progress
# snapshot says STALL-ALERT with backlog>0 (N flat ticks while unblocked work remains),
# a yield is a PARK — the exact 2026-06-07 cleanscale defect (run stopped with epics
# A/B/D/E/F unbuilt). Block it instead, so the supervisor is dragged back to RE-DISPATCH
# the next unblocked backlog item OR escalate a genuine hard-gate, never silently stop.
# The instant a dispatch moves a metric (commit/PR/AC) or touches a worktree, the
# progress verdict flips to PROGRESSING/IN-FLIGHT and the yield is permitted again
# (self-correcting). A single capability-blocked item (deploy token missing) is NOT one
# of the 3 registered hard-gates, so it never produces USER_ESCALATION_HALT and this gate
# keeps the run building the rest — single-item-blocker partitioning by construction.
# FAIL-OPEN: no snapshot / kill-switch (PLAN_W_TEAM_DISABLE_ANTIPARK=1) → ANTIPARK_BLOCK
# stays 0 and the yields behave byte-for-byte as before. This NEVER blocks a worker
# (workers don't take the yield path) and never relaxes an existing block or terminal.
ANTIPARK_BLOCK=0
if [ -n "$BLOCK_REASON" ]; then
    # $SLUG holds the last-iterated goal's slug (single-goal is the norm); the
    # slug-keyed snapshot read therefore scopes to this run only.
    AP_STATE=$(__antipark_state "$SLUG")
    if [ -n "$AP_STATE" ]; then
        AP_BK=$(echo "$AP_STATE" | awk '{print $1}')
        AP_BL=$(echo "$AP_STATE" | awk '{print $2}')
        AP_VERDICT=$(echo "$AP_STATE" | awk '{print $3}')
        if [ "${AP_BK:-0}" = "1" ] && [ "${AP_BL:-0}" -gt 0 ] 2>/dev/null && [ "$AP_VERDICT" = "STALL-ALERT" ]; then
            ANTIPARK_BLOCK=1
            BLOCK_REASON="ANTI-PARK: objective progress is STALL-ALERT with backlog=${AP_BL} unmet — a supervisor yield here would be a silent park (the 2026-06-07 incident). RE-DISPATCH the next unblocked backlog item OR escalate a genuine hard-gate (push-ack/secret-scan-allow/scope-unlock-for-drift); do NOT stop while safe unblocked work remains. Kill switch: PLAN_W_TEAM_DISABLE_ANTIPARK=1. (suppressed yield; original reason: ${BLOCK_REASON})"
            echo "[goal-evaluator] anti-park: STALL-ALERT + backlog=${AP_BL} → blocking supervisor yield (re-dispatch/escalate, PWT-ANTIPARK)" >&2
            dbg "anti-park engaged: verdict=$AP_VERDICT backlog=$AP_BL → ANTIPARK_BLOCK=1"
        fi
    fi
fi

# PWT-SUP-YIELD — a SUPERVISOR/origin session YIELDS instead of being blocked.
# A session that marks itself PLAN_W_TEAM_SUPERVISOR_SESSION=1 is SUPERVISING
# spawned workers, not driving a pipeline itself — its job is to WAIT. So it
# should be allowed to sleep (let Claude stop) and be re-woken EVENT-DRIVEN by
# its background await-loop (plan-w-team-await-terminal.sh) / ScheduleWakeup,
# rather than the goal-evaluator dragging it back to busy-poll every single turn
# (the friction observed 2026-06-02 in a live run). SAFETY INVARIANT — the
# owning WORKER never sets this flag: pwt-goal.sh forces PLAN_W_TEAM_SUPERVISOR_
# SESSION=0 into the worker's LAUNCH_ENV so it can't be inherited, so worker
# blocking is UNCHANGED ("the worker runs to terminal" holds by construction).
# All per-goal terminal detection + parent-child/mirror propagation above STILL
# ran this turn (a dead child is still propagated, a real terminal still
# persisted); only the final no-terminal-yet outcome flips block→yield, and only
# for the supervisor. The heartbeat re-arm in the await-loop still wakes the
# supervisor periodically to run its Step-0 progress/stall check, so a stalled
# worker is NOT masked.
if [ -n "$BLOCK_REASON" ] && [ "${PLAN_W_TEAM_SUPERVISOR_SESSION:-0}" = "1" ] && [ "$ANTIPARK_BLOCK" != "1" ]; then
    echo "[goal-evaluator] supervisor session (PLAN_W_TEAM_SUPERVISOR_SESSION=1) → yield, not block. Re-wake event-driven via plan-w-team-await-terminal.sh. (suppressed: $BLOCK_REASON)" >&2
    exit 0
fi

# PWT-SUP-YIELD-SID — identity-based supervisor yield (complements the env flag
# above). A session that owns NONE of the blocking goals — its SID differs from
# EVERY blocking goal's recorded worker_sid, and no blocking goal is un-ownable —
# is a supervisor/observer, not the worker driving a pipeline. It yields (lets
# Claude stop) and is re-woken event-driven by its background await-loop, exactly
# like an env-flagged supervisor. This fixes the mid-session supervisor that cannot
# set PLAN_W_TEAM_SUPERVISOR_SESSION in its launch env. The owning worker (SID
# match → OWNS_BLOCKING=1) and any un-ownable goal (no worker_sid →
# BLOCKING_GOAL_UNOWNABLE=1) still BLOCK, so "the worker runs to terminal" holds.
# ANTI-PARK GUARD (mirrors the env-flag path at the PWT-SUP-YIELD gate above): when
# objective progress is STALL-ALERT with unmet backlog (ANTIPARK_BLOCK=1), even a
# non-owning supervisor must NOT yield — that is the silent park the gate exists to
# prevent, and this SID path is the dominant mid-session origin-chat supervisor case
# (it cannot set PLAN_W_TEAM_SUPERVISOR_SESSION in its launch env), so without this
# guard the whole PWT-ANTIPARK protection is bypassed exactly where it matters most.
if [ -n "$BLOCK_REASON" ] && [ -n "$SELF_SID" ] \
   && [ "$OWNS_BLOCKING" = "0" ] && [ "$BLOCKING_GOAL_UNOWNABLE" = "0" ] \
   && [ "$ANTIPARK_BLOCK" != "1" ]; then
    echo "[goal-evaluator] non-owning session (SID ${SELF_SID:0:8} != every blocking goal's worker_sid) → supervisor yield, not block. Event-driven re-wake via plan-w-team-await-terminal.sh. (suppressed: $BLOCK_REASON)" >&2
    exit 0
fi

# Allow stop only if no pending blocks remain.
# (Previously: "if ANY_TERMINAL || no_block" — wrong. One goal going terminal
# must NOT suppress block emission for other still-pending goals. PWT-T5c
# dogfood fix: multi-goal isolation.)
if [ -z "$BLOCK_REASON" ]; then
    exit 0
fi

# Block stop — Claude continues with reason as guidance
jq -n --arg r "$BLOCK_REASON" '{"decision":"block","reason":$r}'
exit 0
