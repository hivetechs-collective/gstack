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
#
# ENV
#   PWT_PRIMARY_MODEL   (default claude-opus-5)    — pinned; never inherit the CLI default
#   PWT_FALLBACK_MODEL  (default claude-sonnet-5)
#   PWT_STEER_POLL_S    (default 1)                — verification poll interval
#   CLAUDE_PROJECTS_DIR (default ~/.claude/projects)
#
# EXIT CODES (contract — callers and tests depend on these)
#   0  steered AND delivery verified
#   5  steered but delivery UNVERIFIED (bookkeeping done, steer_verified:false).
#      Attribution policy (W6): with exactly ONE marker-less new transcript the
#      best guess is adopted; with MULTIPLE candidates adoption is REFUSED —
#      worker_sid keeps the old sid and the history row records new_sid:"" with
#      reason "steer-refused-ambiguous" (never point the watcher at a stranger).
#   2  usage
#   6  validation refuse — NOTHING was mutated, worker untouched
#   7  new session UUID undiscoverable — no history row is written with an empty new_sid
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

PRIMARY_MODEL="${PWT_PRIMARY_MODEL:-claude-opus-5}"
FALLBACK_MODEL="${PWT_FALLBACK_MODEL:-claude-sonnet-5}"
POLL_S="${PWT_STEER_POLL_S:-1}"

usage() {
  cat >&2 <<'EOF'
usage: pwt-steer.sh --slug <slug> --message <steer-text>
                    [--worker-sid <uuid>] [--state-dir <dir>]
                    [--dry-run] [--timeout-s <n>] [--allow-main]

  operator-invoked only — never forward unreviewed third-party text via --message.

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
STEER_TEXT="$MESSAGE

$MARKER"

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
  echo "  would run:       $CLAUDE_BIN stop $WORKER_SID"
  echo "  would run:       env PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 $CLAUDE_BIN --bg --resume $WORKER_SID --model $PRIMARY_MODEL --fallback-model $FALLBACK_MODEL <steer-text>"
  echo "  delivery marker: $MARKER"
  exit 0
fi

# Snapshot the transcript set BEFORE the resume: "the new session" is identified
# by a transcript that did not exist a moment ago, which is immune to filesystem
# timestamp granularity (a -newer comparison is not).
BEFORE_LIST="$(__steer_list_transcripts)"

# ─── (2) STOP — tolerate an already-dead worker ─────────────────────────────
echo "pwt-steer: stopping worker $WORKER_SID …"
"$CLAUDE_BIN" stop "$WORKER_SID" >/dev/null 2>&1 || \
  echo "  note: stop returned non-zero (worker may already be stopped) — continuing" >&2

# ─── (3) RESUME — argv-form exec, inside the worktree, pinned + route-guarded ─
# No `sh -c`, no eval, no re-quoting: the steer text is ONE argv element handed
# straight to execve, so quotes/backslashes/`$`/`;`/globs in the operator's
# message can never be re-parsed by a shell.
RESUME_OUT="${TMPDIR:-/tmp}/pwt-steer-resume-$$.out"
(
  cd "$RESUME_CWD" 2>/dev/null || exit 127
  exec env PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 "$CLAUDE_BIN" \
    --bg --resume "$WORKER_SID" \
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
     --arg reason "$ROW_REASON" --argjson ver "$VERJSON" '
      (if $ns != "" and $ns != (.worker_sid // "") then .worker_sid = $ns else . end)
      | .respawn_history = ((.respawn_history // []) + [{
            ts: $ts, old_sid: $os, new_sid: $ns,
            reason: $reason, steer_verified: $ver
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

if [ "$VERIFIED" = "1" ]; then
  echo "✓ pwt-steer: delivery VERIFIED in $NEW_TX (marker $MARKER)"
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

[ "$VERIFIED" = "1" ] && exit 0
exit 5
