#!/usr/bin/env bash
# .claude/scripts/plan-w-team-post-push-confirm.sh
#
# NON-BLOCKING full-suite confirmation after a push to the default branch
# (2.51.0, docs/operations/test-green-retest.md §Post-push confirm).
#
# A targeted retest (plan-w-team-test-green.sh --retest) lets a COMMIT through on a
# partial rerun measured against one full base. That is the right trade for the
# commit loop and the wrong one to leave standing on the default branch, so every
# push whose HEAD is not already covered by a full green verdict gets ONE detached
# full run of the pushed commit. It never blocks the push: the push has happened by
# the time this runs, and a red result is surfaced afterwards — at the next
# SessionStart (one short line) and as a desktop notification.
#
# MODES
#   --launch [--root R] [--command "<git push …>"]
#       Called from .claude/hooks/post-git-push.sh. Cheap and bounded (one
#       `git ls-tree`, one digest, a scan of the verdict files); starts the run
#       DETACHED (`nohup nice -n 10 … &`) and returns. Launches only when ALL hold:
#         - PWT_DISABLE_POST_PUSH_CONFIRM is not 1 (kill switch);
#         - R carries the skill harness (Makefile test-skill + tests/skill/run.sh);
#         - the push command is not a dry run / delete;
#         - HEAD is what origin/<default> now points at (a push to the default
#           branch — a feature-branch push is left to its own merge);
#         - the newest verdict is mode=retest, OR no green FULL verdict's
#           tree_digest matches the watched-set digest of HEAD;
#         - no confirm for this sha is already running or green.
#   --run <sha> [--root R]
#       The detached body: a temporary `git worktree` at <sha> under TMPDIR, the
#       full suite through plan-w-team-test-green.sh with both root envs pinned at
#       that worktree (so its verdict never lands in — or outranks anything in — the
#       checkout's own state dirs, and the checkout's per-checkout lock stays free),
#       then the result recorded, a red result notified, the worktree removed, and
#       a fresh --launch in case origin/<default> moved on while it ran.
#   --surface [--root R]
#       Called from session-start.sh. Reads ONE small JSON; prints one line when the
#       last confirm is red (or died), nothing otherwise.
#
# RECORD  <R>/.claude/state/pwt-post-push-confirm.json
#   {sha, slug, started, status: running|green|red|died, pid, finished?,
#    suite_exit?, reason?, log_path?}
#   The run's log is copied to <R>/.claude/state/pwt-post-push-confirm.log.
#
# ENV
#   PWT_DISABLE_POST_PUSH_CONFIRM=1   kill switch (launch AND surface)
#   PWT_POST_PUSH_CONFIRM_NOTIFY=0    no desktop notification on red
#   PWT_POST_PUSH_CONFIRM_CMD         TEST SEAM: replaces the detached --run body
#                                     (run via `sh -c`); the record is still written
#
# Exit 0 always for --launch/--surface (a post-push hook must never fail the tool
# call); --run exits 0 green, 1 red, 2 setup failure.
#
# bash 3.2 compatible (mac-mini): no declare -A, no mapfile, no ${v,,}.

set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SELF")"
MODE=""
ROOT=""
PUSH_CMD=""
RUN_SHA=""

usage() {
  sed -n '2,50p' "$SELF" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --launch)  MODE="launch"; shift ;;
    --surface) MODE="surface"; shift ;;
    --run)     MODE="run"; RUN_SHA="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --root)    ROOT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --command) PUSH_CMD="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$MODE" ] || usage

[ -n "$ROOT" ] || ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || exit 0
STATE_DIR="$ROOT/.claude/state"
RECORD="$STATE_DIR/pwt-post-push-confirm.json"
CONFIRM_LOG="$STATE_DIR/pwt-post-push-confirm.log"

[ "${PWT_DISABLE_POST_PUSH_CONFIRM:-0}" = "1" ] && exit 0

# ─── helpers ────────────────────────────────────────────────────────────────
_have_harness() {
  [ -f "$1/tests/skill/run.sh" ] && [ -f "$1/Makefile" ] \
    && grep -q '^test-skill:' "$1/Makefile" 2>/dev/null \
    && [ -f "$1/.claude/scripts/plan-w-team-test-green.sh" ]
}

# _record_set <jq-filter> [--arg k v …] — atomic temp+rename update of the record.
_record_set() {
  local filter="$1" tmp
  shift
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  tmp="$RECORD.tmp.$$"
  if [ -f "$RECORD" ] && jq -e . "$RECORD" >/dev/null 2>&1; then
    jq "$@" "$filter" "$RECORD" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  else
    jq -n "$@" "{} | $filter" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$RECORD" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

_rec() { jq -r "$1 // \"\"" "$RECORD" 2>/dev/null || echo ""; }

_pid_alive() {
  case "${1:-}" in ""|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null
}

# The watched-glob block, read from test-green.sh's anchored copy rather than
# transcribed a third time — the two existing copies are symmetry-locked by
# pre-commit-hook-timeout.bats and a third would drift.
_watched_globs() {
  sed -n '/^# BEGIN pwt-watched-globs/,/^# END pwt-watched-globs/p' \
      "$1/.claude/scripts/plan-w-team-test-green.sh" 2>/dev/null \
    | sed -e '/^#/d' -e "s/^PWT_WATCHED_GLOBS='//" -e "s/'\$//" \
    | sed '/^$/d'
}

_default_branch_ref() {
  local r
  r=$(git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo "")
  if [ -n "$r" ]; then printf '%s\n' "$r"; return 0; fi
  for r in origin/main origin/master; do
    if git -C "$ROOT" rev-parse -q --verify "$r" >/dev/null 2>&1; then printf '%s\n' "$r"; return 0; fi
  done
  return 1
}

_notify_red() {
  [ "${PWT_POST_PUSH_CONFIRM_NOTIFY:-1}" = "0" ] && return 0
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"$(printf '%s' "$1" | tr '"' "'")\" with title \"Post-push suite RED\" sound name \"Basso\"" >/dev/null 2>&1 || true
  return 0
}

# ─── --surface ──────────────────────────────────────────────────────────────
if [ "$MODE" = "surface" ]; then
  [ -f "$RECORD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  st=$(_rec '.status'); sha=$(_rec '.sha'); short="${sha:0:10}"
  case "$st" in
    red)
      echo ""
      echo "⚠ POST-PUSH CONFIRM RED — the full skill suite failed on pushed ${short} ($(_rec '.reason' | tr -cd 'a-z-' | cut -c1-40)); log: $(_rec '.log_path')"
      echo "   the default branch is red: fix it before building on it (details: docs/operations/test-green-retest.md)" ;;
    running)
      if ! _pid_alive "$(_rec '.pid')"; then
        echo ""
        echo "⚠ post-push confirm for ${short} died before finishing — relaunch: .claude/scripts/plan-w-team-post-push-confirm.sh --launch"
      fi ;;
  esac
  exit 0
fi

# ─── --launch ───────────────────────────────────────────────────────────────
if [ "$MODE" = "launch" ]; then
  _have_harness "$ROOT" || exit 0
  case " $PUSH_CMD " in
    *" --dry-run "*|*" -n "*|*" --delete "*|*" -d "*) exit 0 ;;
  esac
  command -v jq >/dev/null 2>&1 || exit 0
  command -v shasum >/dev/null 2>&1 || exit 0
  LIB="$ROOT/.claude/scripts/plan-w-team-retest-lib.sh"
  [ -f "$LIB" ] || LIB="$SCRIPT_DIR/plan-w-team-retest-lib.sh"
  [ -f "$LIB" ] || exit 0
  # shellcheck source=/dev/null
  . "$LIB"

  HEAD_SHA=$(git -C "$ROOT" rev-parse -q --verify HEAD 2>/dev/null || echo "")
  [ -n "$HEAD_SHA" ] || exit 0
  DEF_REF=$(_default_branch_ref) || exit 0
  DEF_SHA=$(git -C "$ROOT" rev-parse -q --verify "$DEF_REF" 2>/dev/null || echo "")
  [ "$HEAD_SHA" = "$DEF_SHA" ] || exit 0

  # Already running / done for this sha → idempotent no-op. Any live confirm (even
  # for an older sha) also defers: it relaunches for the newest HEAD when it ends.
  if [ -f "$RECORD" ]; then
    r_sha=$(_rec '.sha'); r_st=$(_rec '.status')
    if [ "$r_st" = "running" ] && _pid_alive "$(_rec '.pid')"; then exit 0; fi
    if [ "$r_sha" = "$HEAD_SHA" ] && { [ "$r_st" = "green" ] || [ "$r_st" = "red" ]; }; then exit 0; fi
  fi

  # Does a full green verdict already describe exactly what was pushed?
  NEED=1
  NEWEST=""
  for f in "$STATE_DIR"/plan-w-team-test-green-*.json; do
    [ -f "$f" ] || continue
    if [ -z "$NEWEST" ] || [ "$f" -nt "$NEWEST" ]; then NEWEST="$f"; fi
  done
  NEWEST_MODE=""
  [ -n "$NEWEST" ] && NEWEST_MODE=$(jq -r '.mode // ""' "$NEWEST" 2>/dev/null || echo "")
  if [ "$NEWEST_MODE" != "retest" ]; then
    GLOBS="$(_watched_globs "$ROOT")"
    HEAD_DIGEST=""
    MAN_TMP=$(mktemp -t pwt-post-push-man.XXXXXX 2>/dev/null || echo "")
    if [ -n "$GLOBS" ] && [ -n "$MAN_TMP" ] \
       && pwt_rt_manifest "$ROOT" head "$GLOBS" > "$MAN_TMP" 2>/dev/null; then
      HEAD_DIGEST=$(pwt_rt_digest "$MAN_TMP" 2>/dev/null || echo "")
    fi
    [ -n "$MAN_TMP" ] && rm -f "$MAN_TMP"
    if pwt_rt_is_hex64 "$HEAD_DIGEST"; then
      for f in "$STATE_DIR"/plan-w-team-test-green-*.json; do
        [ -f "$f" ] || continue
        if jq -e --arg d "$HEAD_DIGEST" --arg c "$PWT_RT_DEFAULT_SUITE_CMD" \
             '.green == true and .mode == "full" and .suite_cmd == $c and .tree_digest == $d' \
             "$f" >/dev/null 2>&1; then
          NEED=0; break
        fi
      done
    fi
  fi
  [ "$NEED" = "1" ] || exit 0

  SHORT="${HEAD_SHA:0:10}"
  SLUG="post-push-$SHORT"
  if [ -n "${PWT_POST_PUSH_CONFIRM_CMD:-}" ]; then
    nohup nice -n 10 sh -c "$PWT_POST_PUSH_CONFIRM_CMD" >/dev/null 2>&1 < /dev/null &
  else
    nohup nice -n 10 bash "$SELF" --run "$HEAD_SHA" --root "$ROOT" >/dev/null 2>&1 < /dev/null &
  fi
  PID=$!
  _record_set '{sha:$sha, slug:$slug, started:$started, status:"running", pid:$pid}' \
    --arg sha "$HEAD_SHA" --arg slug "$SLUG" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson pid "$PID" || true
  echo "→ post-push confirm: full skill suite for ${SHORT} started in the background (non-blocking; a red result surfaces at the next session start)"
  exit 0
fi

# ─── --run ──────────────────────────────────────────────────────────────────
if [ "$MODE" = "run" ]; then
  case "$RUN_SHA" in ""|*[!0-9a-f]*) echo "--run needs a commit sha" >&2; exit 2 ;; esac
  command -v jq >/dev/null 2>&1 || exit 2
  SHORT="${RUN_SHA:0:10}"
  SLUG="post-push-$SHORT"
  _finish() {  # _finish <status> <suite_exit|null> <reason> <log>
    _record_set '.sha = $sha | .slug = $slug | .status = $st | .finished = $fin
                 | .suite_exit = $ex | .reason = $reason | .log_path = $log' \
      --arg sha "$RUN_SHA" --arg slug "$SLUG" --arg st "$1" \
      --arg fin "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ex "$2" \
      --arg reason "$3" --arg log "$4" || true
  }

  TMP_PARENT=$(mktemp -d -t pwt-post-push.XXXXXX 2>/dev/null) || { _finish red null setup-failed ""; exit 2; }
  WT="$TMP_PARENT/wt"
  if ! git -C "$ROOT" worktree add --detach "$WT" "$RUN_SHA" >/dev/null 2>&1; then
    rmdir "$TMP_PARENT" 2>/dev/null
    _finish red null worktree-add-failed ""
    _notify_red "could not create a worktree for ${SHORT}"
    exit 2
  fi
  # The vendored bats-core is gitignored: copy it (a symlink would show up as an
  # untracked watched path) so the suite never needs a network clone. node_modules
  # sits outside the watched set, so a symlink is fine there.
  if [ -d "$ROOT/tests/skill/.bats" ] && [ ! -e "$WT/tests/skill/.bats" ]; then
    cp -R "$ROOT/tests/skill/.bats" "$WT/tests/skill/.bats" 2>/dev/null || true
  fi
  if [ -d "$ROOT/node_modules" ] && [ ! -e "$WT/node_modules" ]; then
    ln -s "$ROOT/node_modules" "$WT/node_modules" 2>/dev/null || true
  fi

  # PROJECT_ROOT/CONFIG_FILE: post-git-push.sh sources .claude/lib/config.sh,
  # which EXPORTS both pointing at the main checkout, and this run inherits the
  # hook's env. A suite that honours them tests the checkout, not the pushed sha:
  # the 204245ca confirm went red on the statusline tests that way (2.51.4).
  ( cd "$WT" && env -u PWT_TEST_GREEN_SUITE_CMD -u PWT_TEST_GREEN_RETEST_CMD \
      -u PROJECT_ROOT -u CONFIG_FILE \
      CLAUDE_PROJECT_DIR="$WT" PWT_PROJECT_ROOT_OVERRIDE="$WT" \
      bash "$WT/.claude/scripts/plan-w-team-test-green.sh" --slug "$SLUG" ) > /dev/null 2>&1

  V="$WT/.claude/state/plan-w-team-test-green-${SLUG}.json"
  GREEN="false"; EXITV="null"; REASON="no-verdict"; LOG_OUT=""
  if [ -f "$V" ] && jq -e . "$V" >/dev/null 2>&1; then
    GREEN=$(jq -r 'if .green == true then "true" else "false" end' "$V")
    EXITV=$(jq -r 'if .suite_exit == null then "null" else (.suite_exit|tostring) end' "$V")
    case "$EXITV" in null|*[!0-9]*) [ "$EXITV" = "null" ] || EXITV="null" ;; esac
    REASON=$(jq -r '.reason // "?"' "$V" | tr -cd 'a-z-' | cut -c1-40)
    SRC_LOG=$(jq -r '.log_path // ""' "$V")
    if [ -n "$SRC_LOG" ] && [ -f "$SRC_LOG" ] && cp "$SRC_LOG" "$CONFIRM_LOG" 2>/dev/null; then
      LOG_OUT="$CONFIRM_LOG"
    fi
  fi

  git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || git -C "$ROOT" worktree prune >/dev/null 2>&1
  rmdir "$TMP_PARENT" 2>/dev/null || true

  if [ "$GREEN" = "true" ]; then
    _finish green "$EXITV" "$REASON" "$LOG_OUT"
    RC=0
  else
    _finish red "$EXITV" "$REASON" "$LOG_OUT"
    _notify_red "The full skill suite failed on pushed ${SHORT} (${REASON}). The default branch is red."
    RC=1
  fi
  # origin/<default> may have moved while this ran; confirm the newest push too.
  bash "$SELF" --launch --root "$ROOT" >/dev/null 2>&1 || true
  exit "$RC"
fi

exit 0
