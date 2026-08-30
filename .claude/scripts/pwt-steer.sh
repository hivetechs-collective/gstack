#!/usr/bin/env bash
# pwt-steer.sh — verified steer of a running `claude --bg` /plan-w-team worker.
#
# OPERATOR-INVOKED ONLY. This script is never hook-triggered and never
# agent-triggered: it opens an instruction channel into a worker running under
# bypassPermissions, so the text passed to --message must be the OPERATOR'S OWN
# words. Never forward unreviewed third-party text (issue bodies, web content,
# tool output, another agent's message) through --message — that would turn a
# steer into a prompt-injection delivery mechanism with the worker's full
# permissions behind it. Registered as prose contract in
# `shared/supervisor-protocol.md`; a structural PreToolUse binding is a
# deferred item.
#
# WHY THIS EXISTS
#   There is NO message channel into a `claude --bg` worker — no inbox, and
#   SendMessage cannot address it. The only steer path is stop + resume, and the
#   field procedure failed 2-of-3 attempts (cleanscale, 2026-08-07, ~15 min lost)
#   on three separate traps this script closes by construction:
#     1. `--resume` MUST take the 36-char session UUID. A bg process HANDLE
#        silently strands the session at a resume picker while the process still
#        reports "working" — the failure is invisible.
#     2. The resume MUST run from INSIDE the worker's worktree. Resuming from the
#        main checkout re-anchors the worker's cwd there and breaks isolation.
#     3. Launch-succeeded is NOT delivery-succeeded. Delivery is only proven by
#        finding a unique marker in the worker-side transcript.
#   …plus the bookkeeping that the rest of the pipeline depends on: the goal-state
#   `worker_sid` in BOTH state dirs, a `respawn_history` row, and teardown of the
#   OLD await-watcher (an orphaned watcher whose SID just vanished emits a FALSE
#   `terminal=WORKER_GONE` ~20s after every steer — see
#   plan-w-team-await-terminal.sh's SECONDARY liveness path).
#
# ORDERING IS THE SAFETY PROPERTY: every validation runs BEFORE the stop. A
# refused steer leaves the worker completely untouched — it is never "half
# steered" into a stopped-but-not-resumed state.
#
# USAGE
#   pwt-steer.sh --slug <slug> --message <steer-text> \
#                [--worker-sid <uuid>] [--state-dir <dir>] \
#                [--dry-run] [--timeout-s <n>] [--allow-main]
#
#   --worker-sid   defaults to the goal-state's `worker_sid`
#   --state-dir    pin goal-state resolution (tests, and an explicit operator override)
#   --dry-run      validate + print the plan; mutate nothing
#   --timeout-s    delivery-verification budget, default 60
#   --allow-main   permit the resume from the main checkout when no worker
#                  worktree exists (breaks isolation — deliberate opt-in)
#   --env K=V      repeatable; regenerate launch-time env the resume would
#                  otherwise lose (RC4/F8: plan-w-team-land.sh passes
#                  PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 so the resumed session's ship
#                  stage behaves like the run it is continuing). KEY must be a
#                  shell identifier, and any guard-shaped key (*DISABLE*/*FORCE*)
#                  is REFUSED: this injects env into a bypassPermissions session,
#                  and ~50 such switches exist here — including the lane guard,
#                  the actor gate, the goal evaluator, the PWT-DS2 cascade guard
#                  and FORCE_SPAWN. Refused by name SHAPE, not by an enumerated
#                  list, so the rule cannot rot as new switches are added.
#
# ENV
#   PWT_PRIMARY_MODEL   (default claude-opus-4-8)  — pinned; never inherit the CLI default; claude-opus-5 is FORBIDDEN (founder order 2026-08-29)
#   PWT_FALLBACK_MODEL  (default claude-opus-4-8)  — a fallback doing the lead's work is intelligent work, never Sonnet (founder doctrine 2026-08-29)
#   PWT_STEER_POLL_S    (default 1)                — verification poll interval
#   CLAUDE_PROJECTS_DIR (default ~/.claude/projects)
#
# EXIT CODES (contract — callers and tests depend on these)
#   0  steered, delivery verified, AND the resumed session is PROCESS-LIVE
#      (pid + pty-sock present in ~/.claude/daemon/roster.json) — OR liveness is
#      indeterminate because no daemon roster exists (roster-less env: the steer
#      falls back to delivery-only rather than downgrading with nothing to check).
#   5  steered but NOT fully verified. TWO shapes, both distinguished in the
#      respawn_history row (steer_verified = delivery-marker; process_live = liveness):
#        (a) delivery UNVERIFIED — the marker never reached a transcript; OR
#        (b) delivery verified but the resumed session is NOT process-live — the
#            fix-respawn-steer-liveness case: a fake respawn wrote a fresh
#            marker-bearing transcript then the process never ran / died. The
#            lane still needs respawn; a marker is DELIVERY, not liveness.
#      Attribution policy (W6): with exactly ONE marker-less new transcript the
#      best guess is adopted; with MULTIPLE candidates adoption is REFUSED —
#      worker_sid keeps the old sid and the history row records new_sid:"" with
#      reason "steer-refused-ambiguous" (never point the watcher at a stranger).
#   2  usage
#   6  validation refuse — NOTHING was mutated, worker untouched
#   7  new session UUID undiscoverable — no history row is written with an empty new_sid
#   8  duplicate lead after resume — bookkeeping WAS done (worker_sid rotated, history row written),
#      but 2+ live leads remain under the worktree (a rival worker survived the stop); stop the
#      straggler(s) named on stderr, then re-arm. Distinct from 7, which means "nothing to adopt".
#
# The script does NOT launch the terminal watcher; it prints the exact re-arm
# command and leaves wait mechanics to the caller.
#
# bash 3.2 (mac-mini /bin/bash): no `declare -A`, no mapfile, no `${v,,}`.
# `set -u` only — no `set -e`: the stop/teardown steps must tolerate a
# already-dead worker and an absent lock without aborting the sequence.

set -u

SLUG=""
MESSAGE=""
WORKER_SID=""
STATE_DIR_OVERRIDE=""
DRY_RUN=0
ALLOW_MAIN=0
TIMEOUT_S=60
MESSAGE_SET=0
# --env KEY=VAL, repeatable.  A resume does NOT inherit the environment the
# launcher originally granted the worker, so a run resumed to finish a stage that
# depends on a launch-time flag (e.g. PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 at the ship
# stage) would silently behave differently from the run it is continuing.  Added
# for plan-w-team-land.sh's resume-to-land remediation (RC4/F8).
# bash 3.2: a plain indexed array is fine; associative arrays are not.
EXTRA_ENV=()

__steer_primary_env_set=0; [ -n "${PWT_PRIMARY_MODEL:-}" ] && __steer_primary_env_set=1
__steer_fallback_env_set=0; [ -n "${PWT_FALLBACK_MODEL:-}" ] && __steer_fallback_env_set=1
PRIMARY_MODEL="${PWT_PRIMARY_MODEL:-claude-opus-4-8}"
FALLBACK_MODEL="${PWT_FALLBACK_MODEL:-claude-opus-4-8}"
# Governor Contract phase 3 (C2/R4): governed intelligent-tier override at resume (downward-only,
# NEVER opus-5). An explicit env pin wins; empty ungoverned ⇒ the opus-4-8 default stands (parity).
__steer_gov_lib="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/pwt-governor-lib.sh"
[ -r "$__steer_gov_lib" ] && { . "$__steer_gov_lib" 2>/dev/null || true; }
if type pwt_governor_model >/dev/null 2>&1; then
    __steer_gov_int=$(pwt_governor_model intelligent)
    if [ -n "$__steer_gov_int" ] && [ "$__steer_gov_int" != "claude-opus-4-8" ]; then
        [ "$__steer_primary_env_set" = "0" ] && PRIMARY_MODEL="$__steer_gov_int"
        [ "$__steer_fallback_env_set" = "0" ] && FALLBACK_MODEL="$__steer_gov_int"
    fi
fi
# #1673 (Model Tiering v6 item 3): a RESUMED bg worker inherits no bypass grant, so it wedges at its
# first Bash/Edit (`waiting` in the roster, forever) unless the resume passes --permission-mode. A
# FRESH pwt-goal spawn works; only the steer/resume path died (reproduced 2026-08-30 00:26Z; eleven
# mass-steers 2026-08-29 23:07Z did zero work). Default bypassPermissions — a bg fleet worker runs
# unattended. One forward-only seam (PWT_STEER_PERMISSION_MODE); an unrecognized/empty value falls
# back to bypassPermissions with ONE warning, so a steered lane can never wedge again over a typo.
STEER_PERMISSION_MODE="${PWT_STEER_PERMISSION_MODE:-bypassPermissions}"
case "$STEER_PERMISSION_MODE" in
  bypassPermissions|acceptEdits|default|plan|auto) ;;
  *) echo "pwt-steer: unrecognized PWT_STEER_PERMISSION_MODE='${STEER_PERMISSION_MODE}' — falling back to bypassPermissions" >&2
     STEER_PERMISSION_MODE="bypassPermissions" ;;
esac
POLL_S="${PWT_STEER_POLL_S:-1}"

usage() {
  cat >&2 <<'EOF'
usage: pwt-steer.sh --slug <slug> --message <steer-text>
                    [--worker-sid <uuid>] [--state-dir <dir>]
                    [--dry-run] [--timeout-s <n>] [--allow-main]
                    [--env KEY=VALUE]...

  operator-invoked only — never forward unreviewed third-party text via --message.
  --env regenerates launch-time environment the resume would otherwise lose
        (e.g. PLAN_W_TEAM_AUTO_APPROVE_PUSH=1). KEY must be a shell identifier,
        and guard-shaped keys (*DISABLE*/*FORCE*) are refused — they would turn
        off protections in a bypassPermissions session. Export those instead.

exit: 0 verified · 5 steered-unverified · 2 usage · 6 validation refuse
      7 new session UUID undiscoverable
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --slug)       SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --message)    MESSAGE="${2:-}"; MESSAGE_SET=1; shift; [ $# -gt 0 ] && shift ;;
    --worker-sid) WORKER_SID="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --state-dir)  STATE_DIR_OVERRIDE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --timeout-s)  TIMEOUT_S="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --env)
      __e="${2:-}"
      # Strict shape check.  This value is injected into a session running under
      # bypassPermissions, so a malformed or hostile entry is refused outright
      # rather than best-effort parsed.
      case "$__e" in
        [A-Za-z_]*=*) : ;;
        *) echo "✗ --env expects KEY=VALUE with a valid shell identifier KEY (got: '$__e')" >&2; exit 2 ;;
      esac
      printf '%s' "${__e%%=*}" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || {
        echo "✗ --env KEY is not a valid identifier: '${__e%%=*}'" >&2; exit 2; }
      # GUARD-DISABLING KEYS ARE REFUSED BY NAME SHAPE, not by an enumerated list.
      #
      # This flag injects environment into a session running under
      # bypassPermissions, and this repo has ~50 `*_DISABLE_*` / `*_FORCE_*` kill
      # switches — among them PLAN_W_TEAM_DISABLE_LANE_GUARD (the PreToolUse
      # cross-lane write guard), _DISABLE_ACTOR_GATE (PWT-LANE2 anti-spoof),
      # _DISABLE_GOAL (the terminal evaluator), _DISABLE_PROMPT_ROUTE (the PWT-DS2
      # cascade guard) and _FORCE_SPAWN (bypasses BOTH double-spawn tiers).
      # A denylist naming today's guards would go stale the first time a release
      # adds one — the same observed-once-enum defect that made double-spawn
      # Tier B structurally inert. A name-shape rule cannot rot.
      #
      # This costs the operator nothing: pwt-steer is OPERATOR-INVOKED ONLY, and
      # an operator who genuinely needs one of these can `export` it before
      # invoking. `--env` exists so a SCRIPT can regenerate launch-time env
      # (RC4/F8), not so a caller can turn guards off in someone else's session.
      case "${__e%%=*}" in
        *DISABLE*|*FORCE*)
          echo "✗ --env refuses guard-shaped keys (*DISABLE*/*FORCE*): '${__e%%=*}'" >&2
          echo "  These turn off protections in a session running under bypassPermissions." >&2
          echo "  If you genuinely need it, export it before invoking pwt-steer.sh." >&2
          exit 2 ;;
      esac
      EXTRA_ENV[${#EXTRA_ENV[@]}]="$__e"
      shift; [ $# -gt 0 ] && shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --allow-main) ALLOW_MAIN=1; shift ;;
    -h|--help)    usage ;;
    *) echo "✗ unknown argument: $1" >&2; usage ;;
  esac
done

# ─── helpers ────────────────────────────────────────────────────────────────

__steer_is_uuid() {
  printf '%s' "${1:-}" \
    | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# Root resolution mirrors pwt-goal.sh's __pwt_main_repo_root (and the identical
# helpers in plan-w-team-test-green.sh / plan-w-team-await-terminal.sh): the
# --git-common-dir form resolves the MAIN checkout correctly even when this
# script runs from inside a worktree, where --show-toplevel returns the caller's
# worktree instead.
__steer_main_repo_root() {
  if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    printf '%s\n' "$PWT_PROJECT_ROOT_OVERRIDE"
    return 0
  fi
  local cdir root
  cdir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  if [ -n "$cdir" ]; then
    case "$cdir" in
      /*) root=$(dirname "$cdir") ;;
      *)  root=$(cd "$(dirname "$cdir")" 2>/dev/null && pwd || echo "") ;;
    esac
  fi
  if [ -z "${root:-}" ] || [ ! -e "$root/.git" ]; then
    root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  fi
  [ -z "$root" ] && root="$PWD"
  printf '%s\n' "$root"
}

__steer_current_root() {
  printf '%s\n' "${CLAUDE_PROJECT_DIR:-${PWT_PROJECT_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
}

# Goal-state resolution precedence — the same order plan-w-team-await-terminal.sh
# uses (:76-140), so a steer and the watcher it re-arms can never disagree about
# WHICH goal-state file is the run's:
#   1. --state-dir override    2. current checkout    3. main checkout
#   4. SID-disambiguated worktree fallback            5. (2)'s path as default
__steer_resolve_goal_file() {
  local name="plan-w-team-goal-${SLUG}.json"
  if [ -n "$STATE_DIR_OVERRIDE" ]; then
    printf '%s\n' "$STATE_DIR_OVERRIDE/$name"
    return 0
  fi
  local cur_goal="$CUR_ROOT/.claude/state/$name"
  [ -f "$cur_goal" ] && { printf '%s\n' "$cur_goal"; return 0; }
  if [ "$MAIN_ROOT" != "$CUR_ROOT" ]; then
    local main_goal="$MAIN_ROOT/.claude/state/$name"
    [ -f "$main_goal" ] && { printf '%s\n' "$main_goal"; return 0; }
  fi
  local f first="" want wsid
  want=$(printf '%s' "$WORKER_SID" | cut -c1-8)
  for f in \
      "$CUR_ROOT"/.claude/worktrees/*/.claude/state/"$name" \
      "$MAIN_ROOT"/.claude/worktrees/*/.claude/state/"$name"; do
    [ -f "$f" ] || continue
    [ -z "$first" ] && first="$f"
    if [ -n "$want" ]; then
      wsid=$(jq -r '.worker_sid // ""' "$f" 2>/dev/null | tr -d '[:space:]' | cut -c1-8)
      if [ -n "$wsid" ] && [ "$wsid" = "$want" ]; then printf '%s\n' "$f"; return 0; fi
    fi
  done
  [ -n "$first" ] && { printf '%s\n' "$first"; return 0; }
  printf '%s\n' "$cur_goal"
}

# Reused verbatim from pwt-goal.sh:1497-1510 — a bare `claude` fails with
# "env: claude: No such file or directory" under the harness-stripped PATH.
__steer_locate_claude() {
  local locator
  for locator in \
      "$CUR_ROOT/.claude/scripts/locate-claude.sh" \
      "$(dirname "$0")/locate-claude.sh"; do
    if [ -x "$locator" ]; then
      "$locator" && return 0
    fi
  done
  echo "claude"
}

refuse() {   # message… → exit 6 with nothing mutated
  printf '✗ pwt-steer: %s\n' "$1" >&2
  shift
  while [ $# -gt 0 ]; do printf '  %s\n' "$1" >&2; shift; done
  exit 6
}

# ─── (1) VALIDATE — every check below runs BEFORE any mutation ──────────────

[ -n "$SLUG" ] || { echo "✗ --slug is required" >&2; usage; }
[ "$MESSAGE_SET" = "1" ] && [ -n "$MESSAGE" ] || { echo "✗ --message is required and must be non-empty" >&2; usage; }
case "$SLUG" in
  *[!A-Za-z0-9._-]*|.|..)
    echo "✗ --slug must be [A-Za-z0-9._-] only (it reaches filenames and lock paths)" >&2; usage ;;
esac
case "$TIMEOUT_S" in
  ""|*[!0-9]*) echo "✗ --timeout-s must be a non-negative integer" >&2; usage ;;
esac
case "$POLL_S" in
  ""|*[!0-9]*) POLL_S=1 ;;
esac
[ "$POLL_S" -gt 0 ] 2>/dev/null || POLL_S=1

CUR_ROOT="$(__steer_current_root)"
MAIN_ROOT="$(__steer_main_repo_root)"

# jq is REQUIRED, and required HERE — the bookkeeping in step 6 edits JSON in
# place, so discovering a missing jq after the stop would leave a steered worker
# with stale state. Refusing up front keeps the "nothing mutated" invariant.
command -v jq >/dev/null 2>&1 || refuse \
  "jq is required (goal-state bookkeeping edits JSON in place)" \
  "install jq, then re-run — the worker has NOT been touched"

GOAL_FILE="$(__steer_resolve_goal_file)"
[ -n "$GOAL_FILE" ] && [ -f "$GOAL_FILE" ] || refuse \
  "goal-state for slug '$SLUG' is unresolvable" \
  "looked for plan-w-team-goal-${SLUG}.json under --state-dir, $CUR_ROOT, $MAIN_ROOT, and their worktrees" \
  "pass --state-dir <dir> if the run's state lives elsewhere"

if [ -z "$WORKER_SID" ]; then
  WORKER_SID=$(jq -r '.worker_sid // ""' "$GOAL_FILE" 2>/dev/null | tr -d '[:space:]')
fi
[ -n "$WORKER_SID" ] || refuse \
  "no worker session id: --worker-sid not given and $GOAL_FILE carries no .worker_sid"

# W6 — the confusion class that cost 2-of-3 field attempts. `claude --bg` PRINTS
# an 8-char process HANDLE ("backgrounded · aabbccdd"); `--resume` needs the
# 36-char session UUID. A handle strands the resume at a picker while the process
# still reports "working", so the steer silently never lands.
if ! __steer_is_uuid "$WORKER_SID"; then
  refuse \
    "'$WORKER_SID' is not a full session UUID" \
    "--resume requires the 36-char full session UUID (8-4-4-4-12 lowercase hex)," \
    "NOT the 8-char bg process handle printed as 'backgrounded · <handle>'." \
    "A handle strands the resume at a picker while the worker still reports 'working'." \
    "Find the UUID: ls -t \"\${CLAUDE_PROJECTS_DIR:-\$HOME/.claude/projects}\"/*/<handle>*.jsonl"
fi

# Worker worktree — the resume MUST run from inside it (isolation). pwt-goal.sh
# names worker worktrees `pwt-<safe-slug>` truncated to 60 chars, so both the
# literal <slug> directory and that derived form are accepted; the literal form
# is checked first.
WT_DIR=""
for cand in \
    "$MAIN_ROOT/.claude/worktrees/$SLUG" \
    "$MAIN_ROOT/.claude/worktrees/$(printf '%s' "$SLUG" | cut -c1-60)" \
    "$MAIN_ROOT/.claude/worktrees/$(printf 'pwt-%s' "$SLUG" | cut -c1-60)"; do
  if [ -d "$cand" ]; then WT_DIR="$cand"; break; fi
done

if [ -n "$WT_DIR" ]; then
  RESUME_CWD="$WT_DIR"
elif [ "$ALLOW_MAIN" = "1" ]; then
  RESUME_CWD="$MAIN_ROOT"
  echo "  warn: no worker worktree for '$SLUG' — resuming from the main checkout (--allow-main)" >&2
else
  refuse \
    "no worker worktree at $MAIN_ROOT/.claude/worktrees/$SLUG" \
    "resuming from the main checkout re-anchors the worker's cwd there and breaks isolation." \
    "Pass --allow-main to accept that, or correct --slug."
fi

# Singleton steer lock (slug-keyed, atomic mkdir — same idiom as
# plan-w-team-await-terminal.sh:243-260). Two concurrent steers on one slug is
# the recorded double-worker failure class: both stop, both resume, two live
# sessions claim the same run.
STEER_LOCK="${TMPDIR:-/tmp}/pwt-steer-${SLUG}.lock"
LOCK_OWNED=0
__steer_release_lock() { [ "$LOCK_OWNED" = "1" ] && rm -rf "$STEER_LOCK" 2>/dev/null; return 0; }
__steer_claim_lock() {
  mkdir "$STEER_LOCK" 2>/dev/null || return 1
  LOCK_OWNED=1
  printf '%s\n' "$$" > "$STEER_LOCK/pid" 2>/dev/null || true
  trap '__steer_release_lock' EXIT
  return 0
}
if ! __steer_claim_lock; then
  HOLDER=$(cat "$STEER_LOCK/pid" 2>/dev/null || echo "")
  if [ -n "$HOLDER" ] && kill -0 "$HOLDER" 2>/dev/null; then
    refuse \
      "another steer is in flight for slug '$SLUG' (pid $HOLDER)" \
      "two concurrent steers stop and resume the same worker twice — wait for it to finish."
  fi
  rm -rf "$STEER_LOCK" 2>/dev/null
  __steer_claim_lock || refuse "could not acquire the steer lock at $STEER_LOCK"
fi

# Unique per-invocation delivery marker. Verification greps for it with
# `grep -F` so no character in it (or in the operator's message) is ever read as
# a regex, and it survives the transcript's JSON escaping unchanged.
MARKER="[pwt-steer:$(date -u +%s)-$$]"

# ── Resume at the recorded manifest stage (BRIEF §5) ─────────────────────────
# A resumed run that re-enters Step 0 re-does scope+spec it already finished (observed: two steers
# on 2026-08-29 both re-entered Step 0). Map the manifest's current_stage onto the EXISTING
# Run-State Router verdict routes so the worker continues where it stopped. Gated on run_sid match
# (the manifest must describe THIS worker), and fail-SAFE to the full 0→8 pipeline (parity) on a
# missing/unrecognized stage. Kill switch: PWT_DISABLE_MANIFEST_STAGE_RESUME=1.
STAGE_DIRECTIVE=""; M_STAGE=""
if [ "${PWT_DISABLE_MANIFEST_STAGE_RESUME:-0}" != "1" ]; then
  __steer_mf="$MAIN_ROOT/.claude/state/plan-w-team-manifest-${SLUG}.json"
  if [ -f "$__steer_mf" ]; then
    M_STAGE=$(jq -r '.current_stage // ""' "$__steer_mf" 2>/dev/null || echo "")
    __steer_mrsid=$(jq -r '.run_sid // ""' "$__steer_mf" 2>/dev/null || echo "")
    # The arms below match the REAL manifest vocabulary written to `current_stage` — the exact
    # labels surface-status.sh / pwt-manifest.sh emit at each step: 0-spawn, scope-challenge,
    # specification, task-breakdown, 3-execute, review, ship, post-ship, retro-complete, stall:*.
    # (Earlier arms used invented aliases like `docs*`/`6-ship` that never matched, so `post-ship`
    # silently fell through to the full-pipeline default — code-review MODERATE #2/#8, 2026-08-29.)
    if [ -z "$__steer_mrsid" ] || [ "${__steer_mrsid:0:8}" = "${WORKER_SID:0:8}" ]; then
      case "$M_STAGE" in
        specification)   STAGE_DIRECTIVE="Resume at Step 2 (task breakdown) — the spec already exists; do NOT re-run Step 0/1. Continue 2→8." ;;
        task-breakdown)  STAGE_DIRECTIVE="Resume at Steps 3-4 (execute) — tasks are broken down; do NOT re-enter Step 0. Continue 3-4→8." ;;
        3-execute)       STAGE_DIRECTIVE="Resume at Steps 3-4 (execute) — this is a mid-execution continuation; do NOT re-enter Step 0. Continue the build, then 5→8." ;;
        review)          STAGE_DIRECTIVE="Resume at Step 5 (fix-first review) — the build is complete but unreviewed; continue 5→8." ;;
        ship)            STAGE_DIRECTIVE="Resume at Step 6 (ship) — the run ENTERED ship, but 'ship' is written on ENTRY so the landing may be INCOMPLETE. Re-verify with plan-w-team-land.sh status --slug ${SLUG}; if it is not LANDED, finish the merge/push, THEN 7→8. Do NOT assume the ship already completed." ;;
        post-ship)       STAGE_DIRECTIVE="Resume at Steps 7-8 (post-ship → retro) — the run shipped and landed; finish docs and the retro. Do NOT re-execute or re-ship." ;;
        retro-complete)  STAGE_DIRECTIVE="The run already reached retro-complete — verify the landing and, if unlanded, land it (plan-w-team-land.sh status/resume)." ;;
        *)               STAGE_DIRECTIVE="" ;;   # 0-spawn / scope-challenge / stall:* / none → full 0→8 (parity)
      esac
    fi
  fi
fi

if [ -n "$STAGE_DIRECTIVE" ]; then
  STEER_TEXT="[resume-at-stage: ${M_STAGE}] ${STAGE_DIRECTIVE}

$MESSAGE

$MARKER"
else
  STEER_TEXT="$MESSAGE

$MARKER"
fi

# Transcript search root. Claude Code names a project dir after the cwd with the
# separators flattened; that derivation is an OPTIMIZATION only — if the computed
# name does not exist (encoding drift, first session in this cwd) we fall back to
# scanning every project dir at the same depth, which is still correct because
# discovery below is anchored on the delivery marker, not on the directory name.
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
ENC=$(printf '%s' "$RESUME_CWD" | sed 's#[/._]#-#g')
if [ -d "$PROJECTS_DIR/$ENC" ]; then SEARCH_DIR="$PROJECTS_DIR/$ENC"; else SEARCH_DIR="$PROJECTS_DIR"; fi

__steer_list_transcripts() {
  [ -d "$SEARCH_DIR" ] || return 0
  find "$SEARCH_DIR" -maxdepth 2 -type f -name '*.jsonl' 2>/dev/null
  return 0
}
__steer_old_transcript() {
  local exact
  exact="$SEARCH_DIR/${WORKER_SID}.jsonl"
  [ -f "$exact" ] && { printf '%s\n' "$exact"; return 0; }
  find "$SEARCH_DIR" -maxdepth 2 -type f -name "$(printf '%s' "$WORKER_SID" | cut -c1-8)*.jsonl" 2>/dev/null | head -1
  return 0
}
__steer_marker_in() { [ -n "${1:-}" ] && [ -f "$1" ] && grep -qF -- "$MARKER" "$1" 2>/dev/null; }

CLAUDE_BIN=$(__steer_locate_claude)

if [ "$DRY_RUN" = "1" ]; then
  echo "pwt-steer: dry-run — validations passed, nothing mutated"
  echo "  slug:            $SLUG"
  echo "  goal-state:      $GOAL_FILE"
  echo "  worker sid:      $WORKER_SID"
  echo "  resume cwd:      $RESUME_CWD"
  echo "  would run:       $CLAUDE_BIN stop ${WORKER_SID:0:8}"
  echo "  resume-at-stage: ${M_STAGE:-<none>} → ${STAGE_DIRECTIVE:-full pipeline 0→8}"
  echo "  extra env:       ${EXTRA_ENV[@]+${EXTRA_ENV[@]}}"
  echo "  would run:       env PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 ${EXTRA_ENV[@]+${EXTRA_ENV[@]} }$CLAUDE_BIN --bg --resume $WORKER_SID --permission-mode $STEER_PERMISSION_MODE --model $PRIMARY_MODEL --fallback-model $FALLBACK_MODEL <steer-text>"
  echo "  steer-text:"
  printf '%s\n' "$STEER_TEXT" | sed 's/^/    | /'
  echo "  delivery marker: $MARKER"
  exit 0
fi

# Snapshot the transcript set BEFORE the resume: "the new session" is identified
# by a transcript that did not exist a moment ago, which is immune to filesystem
# timestamp granularity (a -newer comparison is not).
BEFORE_LIST="$(__steer_list_transcripts)"

# ─── (2) STOP by HANDLE — classify truthfully; a genuine failure or a still-live lead REFUSES ──
# BRIEF §6b, CONFIRMED on this run's own resume: `claude stop` addresses jobs by the 8-char bg
# HANDLE, not the 36-char session UUID. The old code stopped by "$WORKER_SID" (the UUID) — it NEVER
# matched ("No job matching '<uuid>'"), so the stop silently failed and the resume created a SECOND
# live lead beside the still-running old one (the double-worker the operator had to reap by hand).
# Fix: stop by ${WORKER_SID:0:8}; classify stopped|already-gone|failed; a GENUINE failure exits
# non-zero (never the old "continuing" line); and process evidence must show the old lead dead
# before resuming — a still-alive lead REFUSES rather than duplicating.
WORKER_HANDLE="${WORKER_SID:0:8}"
echo "pwt-steer: stopping worker $WORKER_SID (handle $WORKER_HANDLE) …"
STOP_OUT=$("$CLAUDE_BIN" stop "$WORKER_HANDLE" 2>&1); STOP_RC=$?
STOP_TAIL=$(printf '%s' "$STOP_OUT" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-160)
STOP_CLASS="failed"
if [ "$STOP_RC" -eq 0 ]; then
  STOP_CLASS="stopped"
  echo "  stop: worker $WORKER_HANDLE stopped (exit 0)${STOP_TAIL:+ — $STOP_TAIL}"
else
  case "$STOP_OUT" in
    *[Nn]"ot found"*|*"o such"*|*"o session"*|*"nknown session"*|*"o job matching"*|*"already"*)
      STOP_CLASS="already-gone"
      echo "  stop: worker $WORKER_HANDLE already gone / not found (exit $STOP_RC)${STOP_TAIL:+ — $STOP_TAIL}" >&2 ;;
    *)
      STOP_CLASS="failed"
      echo "  stop: FAILED (exit $STOP_RC)${STOP_TAIL:+ — $STOP_TAIL}" >&2 ;;
  esac
fi
# A genuine stop FAILURE is a real failure — do not resume blind over a possibly-live worker.
if [ "$STOP_CLASS" = "failed" ]; then
  refuse "stop of worker $WORKER_HANDLE FAILED (exit $STOP_RC) — not resuming; investigate, then retry"
fi
# Confirm the old lead is DEAD by process evidence before resuming (never duplicate a live lead).
# Exit 0 (alive) → refuse. Exit 1/2 (dead / cannot-determine) → proceed: a fresh stop lags the
# registry, and cannot-determine after a clean stop is the expected transient. Reuses the ONE
# liveness truth. Kill switch: PWT_DISABLE_STEER_LIVENESS=1.
LA_BIN="${PWT_LANE_ALIVE_BIN:-$MAIN_ROOT/.claude/scripts/pwt-lane-alive.sh}"
if [ -x "$LA_BIN" ] && [ "${PWT_DISABLE_STEER_LIVENESS:-0}" != "1" ]; then
  __steer_liveness_tries=0
  while [ "$__steer_liveness_tries" -lt 3 ]; do
    "$LA_BIN" "$SLUG" --worker-sid "$WORKER_SID" >/dev/null 2>&1; LA_RC=$?
    [ "$LA_RC" != "0" ] && break        # dead or cannot-determine → clear to resume
    __steer_liveness_tries=$((__steer_liveness_tries + 1))
    sleep 1
  done
  if [ "${LA_RC:-2}" = "0" ]; then
    refuse "the OLD lead $WORKER_HANDLE is STILL process-alive after stop — refusing to resume (would create a duplicate lead)." \
           "Stop it by hand and retry:  claude stop $WORKER_HANDLE"
  fi
fi

# ─── (3) RESUME — argv-form exec, inside the worktree, pinned + route-guarded ─
# No `sh -c`, no eval, no re-quoting: the steer text is ONE argv element handed
# straight to execve, so quotes/backslashes/`$`/`;`/globs in the operator's
# message can never be re-parsed by a shell.
#
# Regain the FULL launch environment a fresh spawn gets (BRIEF §5, AC4): source the ONE shared
# builder (pwt-launch-env.sh) so a resumed worker keeps the stop-hook-cap raise, workflow-disable,
# lean statusline and supervisor=0 — not just the recursion guard it used to carry. Operator --env
# (EXTRA_ENV) is appended AFTER, so it still overrides (e.g. land.sh's PLAN_W_TEAM_AUTO_APPROVE_PUSH=1).
STEER_LAUNCH_LIB="$MAIN_ROOT/.claude/scripts/pwt-launch-env.sh"
STEER_LAUNCH_ENV="PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1"
if [ -r "$STEER_LAUNCH_LIB" ]; then
  # shellcheck disable=SC1090
  . "$STEER_LAUNCH_LIB"
  __pwt_scrub_leak_env
  STEER_LAUNCH_ENV=$(__pwt_build_launch_env 0)
fi
# Governor Contract phase 3 (C2): governed nice prefix for the resume spawn (the resume path is
# one of the three spawn sites). Definedness-guarded; empty ungoverned ⇒ byte-identical argv.
# (No post-spawn renice here: the launch `exec`s, so there is no return to renice from.)
if type __pwt_nice_prefix >/dev/null 2>&1; then STEER_NICE_PREFIX=$(__pwt_nice_prefix); else STEER_NICE_PREFIX=""; fi
RESUME_OUT="${TMPDIR:-/tmp}/pwt-steer-resume-$$.out"
(
  cd "$RESUME_CWD" 2>/dev/null || exit 127
  # `${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}` — the bash 3.2 empty-array-under-set-u
  # idiom.  A bare "${EXTRA_ENV[@]}" on an EMPTY array is an unbound-variable
  # error there, which would break every steer that passes no --env.
  # $STEER_LAUNCH_ENV is intentionally UNQUOTED so `env` word-splits its KEY=VAL pairs
  # (same idiom as pwt-goal.sh's `env $LAUNCH_ENV claude`).
  exec env $STEER_LAUNCH_ENV \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    $STEER_NICE_PREFIX \
    "$CLAUDE_BIN" \
    --bg --resume "$WORKER_SID" \
    --permission-mode "$STEER_PERMISSION_MODE" \
    --model "$PRIMARY_MODEL" --fallback-model "$FALLBACK_MODEL" \
    "$STEER_TEXT"
) </dev/null >"$RESUME_OUT" 2>&1
RESUME_RC=$?

# Capture + ANSI-strip the spawn output (pwt-goal.sh:1560-1569 idiom). The
# 8-char handle it prints is deliberately NOT used as the new sid — that is
# exactly the W6 confusion this script exists to end.
if [ -s "$RESUME_OUT" ]; then
  sed -E 's/\x1b\[[0-9;]*m//g' "$RESUME_OUT" 2>/dev/null >&2 || cat "$RESUME_OUT" >&2
fi
rm -f "$RESUME_OUT" 2>/dev/null
[ "$RESUME_RC" = "0" ] || echo "  note: resume exited $RESUME_RC — continuing to delivery verification" >&2

# ─── (4)+(5) DISCOVER the new session UUID, then VERIFY delivery ────────────
# Discovery is MARKER-ANCHORED: the session that owns the steer is the one whose
# transcript contains this invocation's unique marker. Identifying it by "newest
# new transcript" alone would mis-attribute an unrelated session that happened to
# start in the same window — and that wrong sid would then be written into the
# goal-state as worker_sid, pointing the watcher and the evaluator at a stranger.
# A marker-less new transcript is kept only as a LAST-RESORT best guess for the
# steered-but-unverified (exit 5) report, where the operator is explicitly told
# the delivery was never proven — and only when it is the SOLE candidate: with
# several marker-less new transcripts the guess would be a coin flip over
# strangers, so adoption is refused (see the attribution policy below).
NEW_SID=""
NEW_TX=""
FALLBACK_TX=""
FALLBACK_N=0
REFUSED_ADOPT=0
VERIFIED=0
ELAPSED=0
while :; do
  OLDIFS="$IFS"
  IFS='
'
  for f in $(__steer_list_transcripts); do
    printf '%s\n' "$BEFORE_LIST" | grep -qxF -- "$f" && continue
    stem=$(basename "$f" .jsonl)
    __steer_is_uuid "$stem" || continue
    if __steer_marker_in "$f"; then
      NEW_TX="$f"; NEW_SID="$stem"; VERIFIED=1
      break
    fi
  done
  IFS="$OLDIFS"
  [ "$VERIFIED" = "1" ] && break

  # Same-session resume: `claude --resume` can continue the EXISTING session, in
  # which case no new transcript ever appears and the steer lands in the old
  # file. Accept that identification only on POSITIVE evidence (the marker is
  # actually there) — otherwise a resume that simply failed would be misreported
  # as a same-session steer instead of surfacing as undiscoverable (exit 7).
  OLD_TX="$(__steer_old_transcript)"
  if __steer_marker_in "$OLD_TX"; then
    NEW_SID="$WORKER_SID"; NEW_TX="$OLD_TX"; VERIFIED=1; break
  fi

  [ "$ELAPSED" -ge "$TIMEOUT_S" ] && break
  sleep "$POLL_S"
  ELAPSED=$((ELAPSED + POLL_S))
done

# ATTRIBUTION POLICY for the unverified path (W6 — never point the watcher at a
# stranger). Enumerate the marker-less new-transcript candidates ONCE, after the
# poll budget is spent:
#   exactly ONE candidate  → adopt it as the best guess (exit 5, steer_verified:false)
#   MULTIPLE candidates    → REFUSE to adopt — the newest-wins guess this branch
#                            used to make is a coin flip over strangers, and the
#                            wrong sid written into worker_sid points the watcher
#                            and the evaluator at an unrelated session from then
#                            on. worker_sid keeps the old sid; the history row
#                            records new_sid:"" with the refusal reason.
if [ "$VERIFIED" != "1" ]; then
  OLDIFS="$IFS"
  IFS='
'
  for f in $(__steer_list_transcripts); do
    printf '%s\n' "$BEFORE_LIST" | grep -qxF -- "$f" && continue
    stem=$(basename "$f" .jsonl)
    __steer_is_uuid "$stem" || continue
    FALLBACK_N=$((FALLBACK_N + 1))
    if [ -z "$FALLBACK_TX" ] || [ "$f" -nt "$FALLBACK_TX" ]; then FALLBACK_TX="$f"; fi
  done
  IFS="$OLDIFS"
  if [ "$FALLBACK_N" -eq 1 ] && [ -n "$FALLBACK_TX" ]; then
    NEW_TX="$FALLBACK_TX"
    NEW_SID=$(basename "$FALLBACK_TX" .jsonl)
  elif [ "$FALLBACK_N" -gt 1 ]; then
    REFUSED_ADOPT=1
    echo "⚠ pwt-steer: $FALLBACK_N new transcripts appeared and NONE carries the marker — refusing to adopt a best guess" >&2
    echo "  adopting the newest would risk pointing the watcher/evaluator at a stranger's session (W6)." >&2
    echo "  worker_sid keeps $WORKER_SID; a respawn_history row records new_sid:\"\" with the refusal." >&2
  fi
fi

if [ -z "$NEW_SID" ] && [ "$REFUSED_ADOPT" != "1" ]; then
  echo "✗ pwt-steer: the resumed session's UUID could not be discovered within ${TIMEOUT_S}s" >&2
  echo "  searched: $SEARCH_DIR (no new *.jsonl, and the marker never reached ${WORKER_SID}.jsonl)" >&2
  echo "  NO respawn_history row was written — bookkeeping with an empty new_sid would" >&2
  echo "  poison the watcher and the evaluator. Re-check the worker manually:" >&2
  echo "    claude agents --json | jq '.[] | select((.sessionId//\"\")|startswith(\"$(printf '%s' "$WORKER_SID" | cut -c1-8)\"))'" >&2
  exit 7
fi

# ─── (5b) PROCESS/PTY-SOCK LIVENESS — a marker proves DELIVERY, not that the
# resumed session is RUNNING (fix-respawn-steer-liveness). A fake respawn writes
# a fresh marker-bearing transcript then the process never runs / dies; gating
# exit-0 on the marker alone reported that corpse as "delivery VERIFIED", and the
# fresh transcript reset the watchdog's quiet clock so the dead lane looked alive
# ~80min. Require the resumed sid to also be LIVE in the daemon roster (pid alive
# + pty-sock present) via the ONE canonical bash entry point.
#
# Three-way verdict, NEVER collapsed (fail-open contract — a healthy resume must
# not be reported unverified):
#   live     → PROCESS_LIVE="1"  (verified: delivery + process)
#   dead     → PROCESS_LIVE="0"  (CONFIRMED corpse: registered, pid/pty-sock gone
#                                 → exit 5, the true fake-respawn signature)
#   unknown  → PROCESS_LIVE=""   (INDETERMINATE: the resume may not be in the
#                                 roster yet on a loaded host, or there is no
#                                 usable roster — do NOT downgrade; the watchdog's
#                                 dead-no-process rule is the authoritative corpse
#                                 detector for a never-registered session)
PROCESS_LIVE=""
LIVENESS_BUDGET="${PWT_STEER_LIVENESS_TIMEOUT_S:-15}"
case "$LIVENESS_BUDGET" in ""|*[!0-9]*) LIVENESS_BUDGET=15 ;; esac
ROSTER_FILE="${SESSION_LIVENESS_ROSTER:-$HOME/.claude/daemon/roster.json}"
# Source the canonical bash liveness lib (session_liveness_verdict) so this gate
# and every other bash caller share exactly one roster-reading implementation.
LIVENESS_LIB=""
for __ll in \
    "$CUR_ROOT/scripts/ops/lib/session-liveness.sh" \
    "$MAIN_ROOT/scripts/ops/lib/session-liveness.sh" \
    "$(dirname "$0")/../../scripts/ops/lib/session-liveness.sh"; do
  [ -f "$__ll" ] && { LIVENESS_LIB="$__ll"; break; }
done
[ -n "$LIVENESS_LIB" ] && . "$LIVENESS_LIB"
if [ "$VERIFIED" = "1" ] && [ -n "$NEW_SID" ] && [ -n "$LIVENESS_LIB" ]; then
  __saw_dead=0
  __le=0
  while :; do
    __v=$(session_liveness_verdict "$NEW_SID" "$ROSTER_FILE" 2>/dev/null)
    if [ "$__v" = "live" ]; then PROCESS_LIVE="1"; break; fi
    [ "$__v" = "dead" ] && __saw_dead=1
    [ "$__le" -ge "$LIVENESS_BUDGET" ] && break
    sleep "$POLL_S"
    __le=$((__le + POLL_S))
  done
  # Only a CONFIRMED-dead roster entry downgrades; a run of `unknown` (never
  # registered) stays indeterminate.
  if [ "$PROCESS_LIVE" != "1" ] && [ "$__saw_dead" = "1" ]; then PROCESS_LIVE="0"; fi
fi

# ─── (6) BOOKKEEP — temp+rename writes only, BOTH state dirs ────────────────
# Same dual-write set as __pwt_emit_goal_state (worker worktree + canonical
# main), so every reader resolution path sees the new sid.
BOOK_DIRS=""
__steer_add_dir() {
  [ -n "${1:-}" ] || return 0
  printf '%s\n' "$BOOK_DIRS" | grep -qxF -- "$1" && return 0
  BOOK_DIRS="$BOOK_DIRS
$1"
  return 0
}
[ -n "$STATE_DIR_OVERRIDE" ] && __steer_add_dir "$STATE_DIR_OVERRIDE"
__steer_add_dir "$(dirname "$GOAL_FILE")"
__steer_add_dir "$MAIN_ROOT/.claude/state"
[ -n "$WT_DIR" ] && __steer_add_dir "$WT_DIR/.claude/state"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VERJSON=false
[ "$VERIFIED" = "1" ] && VERJSON=true
PLJSON=null
[ "$PROCESS_LIVE" = "1" ] && PLJSON=true
[ "$PROCESS_LIVE" = "0" ] && PLJSON=false
ROW_REASON="steer"
[ "$REFUSED_ADOPT" = "1" ] && ROW_REASON="steer-refused-ambiguous"

UPDATED=0
OLDIFS="$IFS"
IFS='
'
for dir in $BOOK_DIRS; do
  [ -n "$dir" ] || continue
  f="$dir/plan-w-team-goal-${SLUG}.json"
  if [ ! -f "$f" ]; then
    echo "  note: no goal-state at $f — skipped" >&2
    continue
  fi
  tmp="$f.tmp.$$"
  jq --arg ns "$NEW_SID" --arg os "$WORKER_SID" --arg ts "$TS" \
     --arg reason "$ROW_REASON" --argjson ver "$VERJSON" --argjson pl "$PLJSON" '
      (if $ns != "" and $ns != (.worker_sid // "") then .worker_sid = $ns else . end)
      | .respawn_history = ((.respawn_history // []) + [{
            ts: $ts, old_sid: $os, new_sid: $ns,
            reason: $reason, steer_verified: $ver, process_live: $pl
        }])
  ' "$f" > "$tmp" 2>/dev/null
  if [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
    if mv -f "$tmp" "$f" 2>/dev/null; then
      UPDATED=$((UPDATED + 1))
    else
      rm -f "$tmp" 2>/dev/null
      echo "  warn: could not replace $f" >&2
    fi
  else
    rm -f "$tmp" 2>/dev/null
    echo "  warn: goal-state update produced invalid JSON for $f — left untouched" >&2
  fi
done
IFS="$OLDIFS"

# Keep the run manifest's run_sid tracking the LIVE lead. The resume-at-stage gate above compares
# manifest.run_sid to the current worker_sid; without this, a SECOND steer would see the ORIGINAL
# spawn sid (never rotated) versus the first steer's rotated worker_sid, the prefixes would differ,
# and the stage directive would be dropped — re-entering the full 0→8 pipeline, the exact bug the
# gate exists to prevent (code-review MODERATE #1, 2026-08-29). Best-effort; never fatal.
if [ -n "$NEW_SID" ] && [ "$NEW_SID" != "$WORKER_SID" ]; then
  __steer_manifest="$MAIN_ROOT/.claude/state/plan-w-team-manifest-${SLUG}.json"
  if [ -f "$__steer_manifest" ]; then
    __mtmp="$__steer_manifest.tmp.$$"
    if jq --arg ns "$NEW_SID" '.run_sid = $ns' "$__steer_manifest" > "$__mtmp" 2>/dev/null \
         && [ -s "$__mtmp" ] && jq -e . "$__mtmp" >/dev/null 2>&1; then
      mv -f "$__mtmp" "$__steer_manifest" 2>/dev/null || rm -f "$__mtmp" 2>/dev/null
    else
      rm -f "$__mtmp" 2>/dev/null
    fi
  fi
fi

if [ "$UPDATED" = "0" ]; then
  echo "✗ pwt-steer: no goal-state file could be updated — the run's bookkeeping is now stale" >&2
  echo "  the worker WAS steered (new sid $NEW_SID); update worker_sid manually before re-arming." >&2
  exit 6
fi

if [ "$REFUSED_ADOPT" = "1" ]; then
  echo "  worker_sid:      unchanged ($WORKER_SID) — adoption REFUSED, ambiguity recorded in respawn_history"
elif [ "$NEW_SID" = "$WORKER_SID" ]; then
  echo "  worker_sid:      unchanged (same-session resume) — respawn_history row appended"
else
  echo "  worker_sid:      $WORKER_SID → $NEW_SID (updated in $UPDATED state dir(s))"
fi

# TEAR DOWN the OLD await watcher. Its SECONDARY liveness path reports
# terminal=WORKER_GONE once the SID it watches vanishes — which a steer
# guarantees — so an orphan emits a FALSE terminal ~20s after every steer.
# Idempotent: an absent lock or a dead PID is fine.
OLD_LOCK="${TMPDIR:-/tmp}/pwt-await-${SLUG}-${WORKER_SID}.lock"
if [ -d "$OLD_LOCK" ]; then
  OLD_WATCHER=$(cat "$OLD_LOCK/pid" 2>/dev/null || echo "")
  if [ -n "$OLD_WATCHER" ] && kill -0 "$OLD_WATCHER" 2>/dev/null; then
    kill "$OLD_WATCHER" 2>/dev/null || true
    echo "  old watcher:     stopped (pid $OLD_WATCHER)"
  fi
  rm -rf "$OLD_LOCK" 2>/dev/null
  echo "  old watcher lock: removed ($OLD_LOCK)"
fi

AWAIT_HELPER="$(dirname "$0")/plan-w-team-await-terminal.sh"
[ -f "$AWAIT_HELPER" ] || AWAIT_HELPER="plan-w-team-await-terminal.sh"

if [ "$VERIFIED" = "1" ] && [ "$PROCESS_LIVE" = "0" ]; then
  echo "⚠ pwt-steer: steered and delivery CONFIRMED, but the resumed session is NOT running —" >&2
  echo "  no live process/pty-sock for $NEW_SID after ${LIVENESS_BUDGET}s. This is the fake-respawn" >&2
  echo "  signature: a marker was written but the process never ran / died. Recorded" >&2
  echo "  process_live:false — the lane is NOT healthy and still needs respawn." >&2
elif [ "$VERIFIED" = "1" ] && [ "$PROCESS_LIVE" = "1" ]; then
  echo "✓ pwt-steer: delivery VERIFIED and session LIVE (pid+pty-sock) in $NEW_TX (marker $MARKER)"
elif [ "$VERIFIED" = "1" ]; then
  echo "✓ pwt-steer: delivery VERIFIED in $NEW_TX (marker $MARKER) — process liveness INDETERMINATE (sid not yet in the daemon roster, or no usable roster); the watchdog will catch a true corpse"
elif [ "$REFUSED_ADOPT" = "1" ]; then
  echo "⚠ pwt-steer: steered but UNATTRIBUTABLE — no marker in any of the $FALLBACK_N new transcripts after ${TIMEOUT_S}s" >&2
  echo "  worker_sid was NOT changed; identify the live session manually before re-arming the watcher:" >&2
  echo "    ls -t \"\${CLAUDE_PROJECTS_DIR:-\$HOME/.claude/projects}\"/*/*.jsonl | head" >&2
  echo "    claude agents --json" >&2
else
  echo "⚠ pwt-steer: steered but delivery UNVERIFIED after ${TIMEOUT_S}s — marker absent from $NEW_TX" >&2
  echo "  bookkeeping recorded steer_verified:false; re-check the transcript before trusting the steer." >&2
fi

if [ "$REFUSED_ADOPT" = "1" ]; then
  echo "  re-arm watcher (after resolving the sid):  $AWAIT_HELPER --slug $SLUG --worker-sid <RESOLVED-UUID>"
else
  echo "  re-arm watcher:  $AWAIT_HELPER --slug $SLUG --worker-sid $NEW_SID"
fi

# ─── (7) POST-RESUME liveness assertion (O3, 2026-08-29) — loud ADVISORY ─────
# After the steer, exactly ONE live lead should own the slug's worktree. Two
# means a rival worker is still running (the double-worker failure the operator
# had to detect by hand); zero means the resume never took. This is a FAIL-OPEN
# ADVISORY, not a new hard-fail exit: `claude agents --json` is intermittently
# empty under load (G9), and the exit-code contract above is depended on by
# callers/tests, so a transient miscount must never flip a good steer to failure.
# Only a CLEAN registry read showing a count != 1 warns; an unqueryable registry
# is silent. Reuses pwt-live-session-cwds.sh (its __QUERY_FAILED__ discipline ==
# silence here) so there is no second, divergent liveness probe.
# BRIEF §5, AC4: a live duplicate NAMES every sid and FAILS LOUDLY (exit 8), instead of the old
# bare-count advisory. Uses claude-agents-extended.sh so the sid↔cwd correlation is EXACT (its
# CLAUDE_AGENTS_RAW seam makes this testable). Fail-OPEN on an unqueryable/flaky registry — a
# transient miscount must never flip a good steer to failure. Kill switch: PWT_DISABLE_STEER_ONE_LEAD=1.
DUP_LEAD=0
if [ "${PWT_DISABLE_STEER_ONE_LEAD:-0}" != "1" ]; then
  EXT_AGENTS="$(dirname "$0")/claude-agents-extended.sh"
  if [ -x "$EXT_AGENTS" ]; then
    AGENTS_JSON=$(CLAUDE_AGENTS_RETRY="${CLAUDE_AGENTS_RETRY:-3}" "$EXT_AGENTS" --json --bg-only 2>/dev/null || echo "")
  else
    AGENTS_JSON=$("$CLAUDE_BIN" agents --json 2>/dev/null || echo "")
  fi
  if printf '%s' "$AGENTS_JSON" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
    LEAD_SIDS=$(printf '%s' "$AGENTS_JSON" | jq -r --arg wt "$RESUME_CWD" '
      .[]? | select((.kind//"background")=="background")
           | select(((.cwd//"")==$wt) or ((.cwd//"")|startswith($wt+"/")))
           | (.sessionId//"") | select(.!="")' 2>/dev/null)
    LEAD_N=$(printf '%s\n' "$LEAD_SIDS" | grep -c . 2>/dev/null || echo 0)
    if [ "${LEAD_N:-0}" -gt 1 ]; then
      DUP_LEAD=1
      echo "✗ pwt-steer: DUPLICATE LEAD — found $LEAD_N live leads under $RESUME_CWD after the steer (exactly ONE allowed); a rival worker is still running." >&2
      echo "  live lead sids (stop the straggler(s); handle = first 8 chars of a sid):" >&2
      printf '%s\n' "$LEAD_SIDS" | while IFS= read -r __sid; do [ -n "$__sid" ] && echo "    $__sid   (claude stop ${__sid:0:8})" >&2; done
    elif [ "${LEAD_N:-0}" -eq 0 ]; then
      echo "⚠ pwt-steer: no live lead visible under $RESUME_CWD yet — re-check before trusting the steer (sid ${NEW_SID:0:8})." >&2
    fi
  fi
fi

[ "$DUP_LEAD" = "1" ] && exit 8
# exit 0 = delivery verified AND (process-live OR liveness indeterminate).
# A delivery-verified steer whose process is NOT live (PROCESS_LIVE=0) is the
# fake respawn — report steered-unverified (exit 5), same class as a missing marker.
if [ "$VERIFIED" = "1" ] && [ "$PROCESS_LIVE" != "0" ]; then
  exit 0
fi
exit 5
