#!/usr/bin/env bash
# .claude/scripts/plan-w-team-post-push-confirm.sh
#
# NON-BLOCKING full-suite confirmation after a push that moves the default branch
# (2.51.0; hardened after the 2.51.x review — docs/operations/post-push-confirm.md).
#
# A targeted retest (plan-w-team-test-green.sh --retest) lets a COMMIT through on a
# partial rerun measured against one full base. That is the right trade for the
# commit loop and the wrong one to leave standing on the default branch, so every
# push that moves origin/<default> to a commit not already covered gets ONE
# detached full run of THAT commit. It never blocks the push: the push has happened
# by the time this runs, and a red (or could-not-run) result is surfaced afterwards
# — at the next SessionStart (one short line) and, when red, a desktop notification.
#
# The decision reads git STATE, never the push command's flags: TARGET is what
# refs/remotes/origin/<default> points at now, in the repo the push ran in.
#
# MODES
#   --launch [--cwd DIR] [--command "<cmd>"] [--root R] [--relaunch]
#       Called from .claude/hooks/post-git-push.sh. Cheap and bounded; starts the
#       run DETACHED (`nohup nice -n 10 … &`) and returns. Steps:
#         1. push repo: the first of these that is inside a git work tree —
#              a. the dir the command's git-push segment ran in: its `git -C
#                 <dir>`, a preceding `cd <dir>` / `pushd <dir>`, resolved
#                 against DIR (shell keywords — if/then/else/elif/do/while/
#                 until/! — and wrappers — VAR=v, env, command, exec, nice,
#                 nohup, time, timeout/gtimeout <dur>, stdbuf — are skipped,
#                 `(…)` / `{…}` are stripped, a subshell's cd ends at its `)`,
#                 and a simply quoted word may hold spaces, the quote opening
#                 anywhere in it: `-C "/a b"`, `VAR="a b"`, `-c k="a b"`);
#              b. DIR, the hook input cwd — which is the cwd AFTER the command
#                 ran, so `cd sub && git push` arrives as DIR=…/sub and (a)
#                 names …/sub/sub;
#              c. CLAUDE_PROJECT_DIR, then R.
#            Taking (b) or (c) instead of (a) writes one note line to the
#            confirm log; so does a command the parser finds no git-push
#            segment in (there is no (a) then: the hook's pre-filter matched
#            it, so it is a form the parser does not model, never proof that
#            nothing was pushed), and so does "no candidate is a git work
#            tree". The command is ONLY parsed for where; whether anything
#            happened is read from git.
#         2. the push repo carries the skill harness (Makefile test-skill +
#            tests/skill/run.sh + plan-w-team-test-green.sh), else no-op;
#         3. TARGET = refs/remotes/origin/<default>. It MOVED when that ref's
#            newest reflog entry is "update by push" no older than
#            PWT_POST_PUSH_CONFIRM_PUSH_WINDOW_S (no reflog → HEAD == TARGET).
#            A dry run, a delete, a feature-branch push move nothing → no-op.
#            --relaunch skips this step (the end-of-run catch-up, a manual rerun);
#         4. under the single-flight lock, TARGET is NOT covered — covered means a
#            live running record (any sha: it catches up when it ends) that is not
#            stale, or a green/red record for TARGET, or (when the push repo's
#            HEAD is TARGET and the newest verdict is not a retest) a full green
#            verdict whose tree_digest matches TARGET's watched-set manifest AND,
#            when the verdict carries a subject_digest (2.53.0+ verdicts do),
#            whose subject_digest matches TARGET's subject manifest (older
#            verdicts without the key are judged on tree_digest alone);
#         5. re-check the lock is still ours, spawn, write the running record,
#            release the lock.
#   --run <sha> [--root R]
#       The detached body: disk preflight, a temporary `git worktree` at <sha>
#       under TMPDIR, the full suite through plan-w-team-test-green.sh under
#       `env -i` + an allowlist and a wall-clock bound, the result classified
#       (green | red | error), the worktree removed, and a fresh --launch
#       --relaunch when origin/<default> moved past <sha> while it ran. A trap
#       on EXIT/TERM/HUP/INT kills the suite's process groups, removes the
#       worktree and records `died`.
#   --surface [--root R]
#       Called from session-start.sh. Reads ONE small JSON; prints one line when
#       the last confirm is red or could not run, nothing otherwise.
#
# STATE  <main working tree of R>/.claude/state/ — shared by every worktree
#   pwt-post-push-confirm.json   {sha, slug, started, status, pid, repo?, worktree?,
#                                 finished?, suite_exit?, reason?, log_path?, watchdog?}
#     status: running | green | red | error | died | skipped-disk
#       red           a FULL-mode verdict with suite_exit != 0 — the branch is red
#       error         could not produce a trustworthy verdict (mktemp, worktree
#                     add, timeout, no verdict, not full mode, digest mismatch …)
#       died          the run was killed (signal) or its process vanished
#       skipped-disk  free disk below the floor; nothing was created
#     Only green/red stop a relaunch for the same sha; the others retry on the
#     next push that moves origin/<default> (or a --launch --relaunch).
#   pwt-post-push-confirm.log    the last run's suite log, plus one-line launch
#                                notes (a fallback push dir, an unparsed
#                                command, a skip, a lost lock)
#   pwt-post-push-confirm.lock/  single-flight lock. Holds ONE empty owner-token
#                                dir (`o.<pid>.<epoch>.<rand>`) and never a file,
#                                so git never sees it. A lock whose single token
#                                is older than LOCK_STALE_S is reclaimed by
#                                renaming THAT token out (transiently
#                                pwt-post-push-confirm.reclaim.<token>/), which
#                                exactly one reclaimer can do; a tokenless lock
#                                older than LOCK_STALE_S (a pre-2.53.0 lock, or
#                                a holder that died between its two mkdirs) is
#                                adopted by adding a token. A holder owns the lock
#                                only while its token is the lock's ONLY entry,
#                                and re-checks that before it spawns.
#
# ENV
#   PWT_DISABLE_POST_PUSH_CONFIRM=1       kill switch (launch, run AND surface)
#   PWT_POST_PUSH_CONFIRM_NOTIFY=0        no desktop notification on red
#   PWT_POST_PUSH_CONFIRM_TIMEOUT_S       wall-clock bound on the suite (default
#                                         2700; 0 = unbounded, no watchdog)
#   PWT_POST_PUSH_CONFIRM_STALE_FACTOR    a running record older than FACTOR x the
#                                         bound (0 → 2700) is stale (default 2)
#   PWT_POST_PUSH_CONFIRM_MIN_FREE_GB     disk floor for the temp worktree, via
#                                         disk-budget.sh (default 20; 0 = no check)
#   PWT_POST_PUSH_CONFIRM_PUSH_WINDOW_S   max age of the "update by push" reflog
#                                         entry that counts as "moved" (default 900)
#   PWT_POST_PUSH_CONFIRM_LOCK_STALE_S    reclaim a lock older than this (default 120)
#   PWT_POST_PUSH_CONFIRM_ENV_PASS        extra variable NAMES (space/comma separated)
#                                         let through the suite's env allowlist — a
#                                         consumer whose suite needs e.g. a toolchain
#                                         variable names it here, never in this file
#   PWT_POST_PUSH_CONFIRM_CMD             TEST SEAM: replaces the detached --run body
#                                         (run via `sh -c`); the record is still written
#   PWT_POST_PUSH_CONFIRM_TEST_RECLAIM_PAUSE_S  TEST SEAM: sleep between judging a
#                                         lock stale and claiming it (pins the
#                                         two-reclaimer race)
#   PWT_POST_PUSH_CONFIRM_TEST_HOLD_S     TEST SEAM: --launch sleeps this long,
#                                         holding the lock, just before its
#                                         spawn re-check
#
# Exit 0 always for --launch/--surface (a post-push hook must never fail the tool
# call); --run exits 0 green, 1 red, 2 could not run (error / skipped-disk / bad
# argument), 3 died (signal).
#
# bash 3.2 compatible (mac-mini): no declare -A, no mapfile, no ${v,,}.

set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SELF")"
MODE=""
ROOT=""
PUSH_CMD=""
HOOK_CWD=""
RUN_SHA=""
RELAUNCH=0

usage() {
  sed -n '2,/^set -u$/p' "$SELF" | sed -e '/^set -u$/d' -e 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --launch)   MODE="launch"; shift ;;
    --surface)  MODE="surface"; shift ;;
    --run)      MODE="run"; RUN_SHA="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --root)     ROOT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --command)  PUSH_CMD="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --cwd)      HOOK_CWD="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --relaunch) RELAUNCH=1; shift ;;
    -h|--help)  usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$MODE" ] || usage

[ "${PWT_DISABLE_POST_PUSH_CONFIRM:-0}" = "1" ] && exit 0

# ─── knobs ──────────────────────────────────────────────────────────────────
_int() {  # _int <value> <default> — the value when a non-negative integer
  case "${1:-}" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}
TIMEOUT_S=$(_int "${PWT_POST_PUSH_CONFIRM_TIMEOUT_S:-}" 2700)
STALE_FACTOR=$(_int "${PWT_POST_PUSH_CONFIRM_STALE_FACTOR:-}" 2)
MIN_FREE_GB=$(_int "${PWT_POST_PUSH_CONFIRM_MIN_FREE_GB:-}" 20)
PUSH_WINDOW_S=$(_int "${PWT_POST_PUSH_CONFIRM_PUSH_WINDOW_S:-}" 900)
LOCK_STALE_S=$(_int "${PWT_POST_PUSH_CONFIRM_LOCK_STALE_S:-}" 120)
_bound=$TIMEOUT_S; [ "$_bound" -gt 0 ] || _bound=2700
[ "$STALE_FACTOR" -gt 0 ] || STALE_FACTOR=2
STALE_AFTER_S=$((STALE_FACTOR * _bound))

# ─── helpers ────────────────────────────────────────────────────────────────
_have_harness() {
  [ -f "$1/tests/skill/run.sh" ] && [ -f "$1/Makefile" ] \
    && grep -q '^test-skill:' "$1/Makefile" 2>/dev/null \
    && [ -f "$1/.claude/scripts/plan-w-team-test-green.sh" ]
}

# _main_tree <dir> — the repo's MAIN working tree (so every worktree of one repo
# shares one record and one lock); the toplevel when there is none (bare/odd).
_main_tree() {
  local top common
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  common=$(cd "$top" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd) || common=""
  case "$common" in
    */.git) printf '%s\n' "${common%/.git}" ;;
    *)      printf '%s\n' "$top" ;;
  esac
}

_now() { date +%s; }
# _mtime <path> — epoch mtime, or 0. GNU first: BSD `stat -c` fails with nothing on
# stdout, whereas GNU `stat -f %m` reads -f as --file-system and PRINTS that path's
# filesystem info before failing on the `%m` operand — the junk then broke the lock
# age arithmetic and a stale lock was never reclaimed on a Linux host (P28).
_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || m=""
  case "$m" in ''|*[!0-9]*) echo 0 ;; *) printf '%s\n' "$m" ;; esac
}

# _record_set <jq-filter> [--arg k v …] — atomic temp+rename update of the record.
_record_set() {
  local filter="$1" tmp
  shift
  # Never re-create a checkout that vanished while a detached run was going.
  [ -d "$ROOT" ] || return 1
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

# Single-flight lock: mkdir is the atomic primitive (macOS has no flock). The
# lock dir holds one EMPTY owner-token dir and never a file, so it never shows
# up as an untracked path. Ownership is "my token is the lock's ONLY entry":
# two parties that each saw themselves alone cannot overlap, because a token
# stays in place from its creation to its holder's release (proof: if A saw no
# B-token after creating its own and B saw no A-token after creating its own,
# each check preceded the other's creation — impossible). The one thing that
# removes a live token is a reclaimer, and it only takes a token older than
# LOCK_STALE_S (the section is sub-second), so a holder that stalled that long
# re-checks its token before it spawns (_lock_still_ours).
#
# 2.51.x-2.52.x renamed the whole STALE LOCK DIR aside instead, and two
# reclaimers that both measured it stale could each rename one away — the
# second took the first one's fresh lock and both spawned (round-1 review).
# Renaming the specific TOKEN a reclaimer measured cannot hit a fresh lock:
# a fresh lock carries a different token.
LOCK_HELD=0
LOCK_TOKEN=""
NL='
'
_lock_kids() { ls -A "$LOCK" 2>/dev/null; }
_lock_pause() {  # test seam: the gap between judging a lock stale and claiming it
  case "${PWT_POST_PUSH_CONFIRM_TEST_RECLAIM_PAUSE_S:-}" in
    ''|*[!0-9.]*) ;;
    *) sleep "$PWT_POST_PUSH_CONFIRM_TEST_RECLAIM_PAUSE_S" ;;
  esac
}
_lock_take() {  # _lock_take <tries> (0.2 s apart) — 0 when held
  local tries="${1:-1}" i=0 age kids tok claim
  [ -d "$ROOT" ] || return 1
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  tok="o.$$.$(_now).${RANDOM:-0}${RANDOM:-0}"
  while :; do
    if mkdir "$LOCK" 2>/dev/null; then
      # Ours unless an adopter (below) slipped a token in first; a failed
      # token mkdir means a reclaimer removed the still-empty dir — retry.
      if mkdir "$LOCK/$tok" 2>/dev/null; then
        if [ "$(_lock_kids)" = "$tok" ]; then LOCK_HELD=1; LOCK_TOKEN="$tok"; return 0; fi
        rmdir "$LOCK/$tok" 2>/dev/null && rmdir "$LOCK" 2>/dev/null
      fi
    else
      kids=$(_lock_kids)   # the entries BEFORE the age is read: the age is of these
      case "$kids" in
        "")
          # Tokenless: a pre-2.53.0 lock, or a holder that died between its two
          # mkdirs. A fresh one is a take in flight (microseconds) — wait.
          age=$(( $(_now) - $(_mtime "$LOCK") ))
          if [ -d "$LOCK" ] && [ "$age" -gt "$LOCK_STALE_S" ]; then
            _lock_pause
            if mkdir "$LOCK/$tok" 2>/dev/null; then
              if [ "$(_lock_kids)" = "$tok" ]; then LOCK_HELD=1; LOCK_TOKEN="$tok"; return 0; fi
              rmdir "$LOCK/$tok" 2>/dev/null && rmdir "$LOCK" 2>/dev/null
            fi
          fi ;;
        *"$NL"*) ;;   # two entries: a take or a back-off in flight — wait
        *)
          age=$(( $(_now) - $(_mtime "$LOCK/$kids") ))
          if [ "$age" -gt "$LOCK_STALE_S" ]; then
            _lock_pause
            claim="$STATE_DIR/pwt-post-push-confirm.reclaim.$tok"
            if mv "$LOCK/$kids" "$claim" 2>/dev/null; then
              rmdir "$claim" 2>/dev/null || rm -rf "$claim" 2>/dev/null
              rmdir "$LOCK" 2>/dev/null   # only when empty; then take it fresh
              continue
            fi
          fi ;;
      esac
    fi
    i=$((i + 1))
    [ "$i" -ge "$tries" ] && return 1
    sleep 0.2
  done
}
_lock_still_ours() { [ "$LOCK_HELD" = "1" ] && [ -d "$LOCK/$LOCK_TOKEN" ]; }
_lock_drop() {
  [ "$LOCK_HELD" = "1" ] || return 0
  # The dir goes only with our token: a reclaimed-then-retaken lock is not ours.
  rmdir "$LOCK/$LOCK_TOKEN" 2>/dev/null && rmdir "$LOCK" 2>/dev/null
  LOCK_HELD=0
  LOCK_TOKEN=""
  return 0
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

# _head_digest <root> — the watched-set digest of <root>'s committed HEAD tree.
_head_digest() {
  local globs man d=""
  globs="$(_watched_globs "$1")"
  [ -n "$globs" ] || return 1
  man=$(mktemp -t pwt-post-push-man.XXXXXX 2>/dev/null) || return 1
  if pwt_rt_manifest "$1" head "$globs" > "$man" 2>/dev/null; then
    d=$(pwt_rt_digest "$man" 2>/dev/null || echo "")
  fi
  rm -f "$man"
  pwt_rt_is_hex64 "$d" || return 1
  printf '%s\n' "$d"
}

# _head_subject_digest <root> — the SUBJECT digest (the retest lib's wider
# `.claude/**` + `tests/**` manifest, the one a full verdict records as
# subject_digest) of <root>'s committed HEAD tree. The roots and excludes are the
# lib's own variables, read rather than copied. The lib's subject helper offers
# worktree/staged only; head mode reads `case` patterns (`*` matches `/`), not
# pathspecs, so each root `R` becomes `R/*` — the same files `git ls-files -- R`
# lists, so a clean tree hashes the same in all three modes.
_head_subject_digest() {
  local roots man d=""
  [ -n "${PWT_RT_SUBJECT_ROOTS:-}" ] || return 1
  roots=$(printf '%s\n' "$PWT_RT_SUBJECT_ROOTS" | sed -e '/^$/d' -e 's|/*$|/*|')
  [ -n "$roots" ] || return 1
  man=$(mktemp -t pwt-post-push-subj.XXXXXX 2>/dev/null) || return 1
  if pwt_rt_manifest "$1" head "$roots" "${PWT_RT_SUBJECT_EXCLUDES:-}" > "$man" 2>/dev/null; then
    d=$(pwt_rt_digest "$man" 2>/dev/null || echo "")
  fi
  rm -f "$man"
  pwt_rt_is_hex64 "$d" || return 1
  printf '%s\n' "$d"
}

_load_lib() {  # the retest lib: this script's sibling first, then the root's copy
  local l
  for l in "$SCRIPT_DIR/plan-w-team-retest-lib.sh" "$1/.claude/scripts/plan-w-team-retest-lib.sh"; do
    if [ -f "$l" ]; then
      # shellcheck source=/dev/null
      . "$l" && return 0
    fi
  done
  return 1
}

_default_branch_ref() {  # _default_branch_ref <repo> — e.g. origin/main
  local r
  r=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo "")
  if [ -n "$r" ]; then printf '%s\n' "$r"; return 0; fi
  for r in origin/main origin/master; do
    if git -C "$1" rev-parse -q --verify "refs/remotes/$r" >/dev/null 2>&1; then printf '%s\n' "$r"; return 0; fi
  done
  return 1
}

# _pushed_recently <repo> <origin/x> — did a push move the ref just now?
#   0 yes · 1 no · 2 unknown (no reflog: core.logAllRefUpdates=false)
_pushed_recently() {
  local line ts msg
  line=$(git -C "$1" log -g -n 1 --date=unix --format='%gd%x09%gs' "refs/remotes/$2" 2>/dev/null | head -1)
  [ -n "$line" ] || return 2
  ts=$(printf '%s\n' "$line" | sed -n 's/^[^@]*@{\([0-9][0-9]*\)}.*/\1/p')
  msg=${line#*	}
  case "$msg" in "update by push"*) ;; *) return 1 ;; esac
  case "$ts" in ''|*[!0-9]*) return 2 ;; esac
  [ $(( $(_now) - ts )) -le "$PUSH_WINDOW_S" ]
}

# _push_dir <command> <base-dir> — print the dir the first git-push segment runs
# in (its `git -C` dirs, or a preceding `cd`, resolved against base; an EMPTY
# line when that dir is unknowable, e.g. after `cd -`); return 1 when the
# parser finds no git-push segment. Splitting on & | ; and blanks is deliberately
# crude: it only proposes candidate (a). The caller falls back when it is not a
# work tree — and ALSO when the parser finds nothing (a form it does not model,
# e.g. `xargs git push`), because the hook only calls with a command its own
# pre-filter matched. Git state decides whether anything moved.
_resolve_dir() {  # _resolve_dir <base> <path> — "" when base is unknown and path relative
  local p="$2" e1=$'\001' e2=$'\002' q1="'" q2='"'
  # Simple quoting: every ' and " is syntax, wherever it sits (`./"a b"`), except
  # an escaped \' or \" (the `'it'\''s'` idiom), which is a literal quote.
  p=${p//\\\'/$e1}; p=${p//\\\"/$e2}
  p=${p//\"/}; p=${p//\'/}
  p=${p//$e1/$q1}; p=${p//$e2/$q2}
  case "$p" in
    "~")   printf '%s\n' "${HOME:-}" ;;
    "~/"*) printf '%s\n' "${HOME:-}/${p#\~/}" ;;
    /*)    printf '%s\n' "$p" ;;
    *)     if [ -n "$1" ]; then printf '%s\n' "$1/$p"; else printf '\n'; fi ;;
  esac
}
# _words <text> — split on blanks into the W array, re-joining the words that an
# open ' or " spans, wherever in a word the quote opens: `-C "/a b"`,
# `VAR="ssh -o X=1"`, `-c k="a b"` each stay one word. Quote state is tracked
# over each word's quote characters in order (a " inside '…' and a ' inside "…"
# are literal; \" and \' are escapes, not quotes), so the cost per word is its
# handful of quote characters, not its length. Simple quoting: no nesting, no
# $(…). The quotes stay on; _resolve_dir strips them. The caller has set -f.
_words() {
  local w t qs c q="" acc="" IFS_SAVE="$IFS"
  W=()
  IFS=" 	"
  # shellcheck disable=SC2086  # word-splitting the segment is the point
  set -- $1
  IFS="$IFS_SAVE"
  for w in "$@"; do
    t=${w//\\\\/}; t=${t//\\\"/}; t=${t//\\\'/}
    qs=${t//[^\"\']/}
    while [ -n "$qs" ]; do
      c=${qs:0:1}; qs=${qs#?}
      if [ -z "$q" ]; then q="$c"; elif [ "$c" = "$q" ]; then q=""; fi
    done
    if [ -n "$acc" ]; then acc="$acc $w"; else acc="$w"; fi
    if [ -z "$q" ]; then W[${#W[@]}]="$acc"; acc=""; fi
  done
  [ -z "$acc" ] || W[${#W[@]}]="$acc"
  return 0
}
_push_dir() {
  local cmd="$1" cur="$2" seg w n i base dir sub closes depth=0 found=""
  local -a stack
  set -f
  while IFS= read -r seg; do
    # `(` opens a subshell — its cd ends at the matching `)`; `{ … }` does not.
    while :; do
      case "$seg" in
        [\ \	]*) seg=${seg#?} ;;
        \(*) seg=${seg#?}; stack[depth]="$cur"; depth=$((depth + 1)) ;;
        \{*) seg=${seg#?} ;;
        *) break ;;
      esac
    done
    closes=0
    while :; do
      case "$seg" in
        *[\ \	]) seg=${seg%?} ;;
        *\)) seg=${seg%?}; closes=$((closes + 1)) ;;
        *\}) seg=${seg%?} ;;
        *) break ;;
      esac
    done
    _words "$seg"
    n=${#W[@]}; i=0; base="$cur"
    # Prefixes that still run the command in this shell's cwd: shell keywords
    # (`if git push; then`, `do git push`, `! git push`), a group opened after
    # one (`if (cd x && git push); then` — a `(` scopes its cd like one at the
    # segment start), VAR=value assignments and wrappers, each with its own
    # options (and timeout's duration). `env -C dir` does move it.
    while [ "$i" -lt "$n" ]; do
      case "${W[i]}" in
        if|then|else|elif|do|while|until|\!) i=$((i + 1)) ;;
        \{) i=$((i + 1)) ;;
        \(*)
          stack[depth]="$cur"; depth=$((depth + 1))
          W[i]=${W[i]#\(}
          [ -n "${W[i]}" ] || i=$((i + 1)) ;;
        [A-Za-z_]*=*) i=$((i + 1)) ;;
        env)
          i=$((i + 1))
          while [ "$i" -lt "$n" ]; do
            case "${W[i]}" in
              -u|--unset) i=$((i + 2)) ;;
              -C|--chdir) base=$(_resolve_dir "$base" "${W[i + 1]:-}"); i=$((i + 2)) ;;
              --chdir=*) base=$(_resolve_dir "$base" "${W[i]#--chdir=}"); i=$((i + 1)) ;;
              --) i=$((i + 1)); break ;;
              -*|[A-Za-z_]*=*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done ;;
        command|builtin|exec|noglob|nohup|time)
          i=$((i + 1))
          while [ "$i" -lt "$n" ]; do
            case "${W[i]}" in
              --) i=$((i + 1)); break ;;
              -a) i=$((i + 2)) ;;           # exec -a <name>
              -*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done ;;
        nice)
          i=$((i + 1))
          case "${W[i]:-}" in
            -n|--adjustment) i=$((i + 2)) ;;
            -n*|--adjustment=*|-[0-9]*) i=$((i + 1)) ;;
          esac
          [ "${W[i]:-}" = "--" ] && i=$((i + 1)) ;;
        timeout|gtimeout)
          i=$((i + 1))
          while [ "$i" -lt "$n" ]; do
            case "${W[i]}" in
              -k|-s|--kill-after|--signal) i=$((i + 2)) ;;
              --) i=$((i + 1)); break ;;
              -*) i=$((i + 1)) ;;           # --foreground, -v, -k5, --signal=KILL …
              *) break ;;
            esac
          done
          i=$((i + 1)) ;;                   # the duration
        stdbuf)
          i=$((i + 1))
          while [ "$i" -lt "$n" ]; do
            case "${W[i]}" in
              -i|-o|-e) i=$((i + 2)) ;;
              --) i=$((i + 1)); break ;;
              -*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done ;;
        *) break ;;
      esac
    done
    if [ "$i" -lt "$n" ]; then
      case "${W[i]}" in
        cd|pushd|chdir)
          i=$((i + 1))
          while [ "$i" -lt "$n" ]; do
            case "${W[i]}" in --) i=$((i + 1)); break ;; -?*) i=$((i + 1)) ;; *) break ;; esac
          done
          if [ "$i" -ge "$n" ]; then cur="${HOME:-}"
          elif [ "${W[i]}" = "-" ]; then cur=""          # OLDPWD: unknowable here
          else cur=$(_resolve_dir "$base" "${W[i]}")
          fi ;;
        popd) cur="" ;;
        git|*/git)
          dir="$base"; sub=""; i=$((i + 1))
          while [ "$i" -lt "$n" ]; do
            w="${W[i]}"; i=$((i + 1))
            case "$w" in
              -C) if [ "$i" -lt "$n" ]; then dir=$(_resolve_dir "$dir" "${W[i]}"); i=$((i + 1)); fi ;;
              -c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix) i=$((i + 1)) ;;
              -*) ;;
              *) sub="$w"; break ;;
            esac
          done
          if [ "$sub" = "push" ]; then found=1; break; fi ;;
      esac
    fi
    while [ "$closes" -gt 0 ] && [ "$depth" -gt 0 ]; do
      depth=$((depth - 1)); cur="${stack[depth]}"; closes=$((closes - 1))
    done
  done <<EOF
$(printf '%s\n' "$cmd" | tr '&|;' '\n\n\n')
EOF
  set +f
  [ -n "$found" ] || return 1
  printf '%s\n' "$dir"
  return 0
}

# _note <root> <text> — one dated line in <root>'s confirm log, only when <root>
# already has a state dir: a launch that falls back or skips says why, without
# littering a checkout that never ran a confirm.
_note() {
  [ -d "$1/.claude/state" ] || return 0
  printf '%s launch: %s\n' "$(date '+%Y-%m-%d %I:%M:%S%p %Z')" "$2" \
    >> "$1/.claude/state/pwt-post-push-confirm.log" 2>/dev/null || true
  return 0
}

_notify_red() {
  [ "${PWT_POST_PUSH_CONFIRM_NOTIFY:-1}" = "0" ] && return 0
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"$(printf '%s' "$1" | tr '"' "'")\" with title \"Post-push suite RED\" sound name \"Basso\"" >/dev/null 2>&1 || true
  return 0
}

# _record_age_s — seconds since the record's `started` stamp (empty if unknown).
_record_age_s() {
  local st ep
  st=$(_rec '.started')
  [ -n "$st" ] || return 1
  ep=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$st" +%s 2>/dev/null \
       || date -u -d "$st" +%s 2>/dev/null) || return 1
  case "$ep" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' $(( $(_now) - ep ))
}

# _reap_worktree <path> — remove a leftover confirm worktree (its --run was
# SIGKILLed, so no trap ran). Only a path shaped like one this script creates is
# considered, and `git worktree remove` itself refuses anything that is not a
# worktree registered with this repo; the parent is only ever rmdir'd (empty).
_reap_worktree() {
  local wt="${1:-}"
  case "$wt" in /*/pwt-post-push.*/wt) ;; *) return 0 ;; esac
  case "$wt" in *..*) return 0 ;; esac
  git -C "$ROOT" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rmdir "$(dirname "$wt")" 2>/dev/null || true
  git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
}

# ─── resolve the state root ─────────────────────────────────────────────────
# --launch: the push repo decides; --run/--surface: R (or CLAUDE_PROJECT_DIR).
BASE="${ROOT:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
if [ "$MODE" = "launch" ]; then
  command -v git >/dev/null 2>&1 || exit 0
  [ -n "$HOOK_CWD" ] || HOOK_CWD="$BASE"
  HOOK_ABS="$(cd "$HOOK_CWD" 2>/dev/null && pwd)" || HOOK_ABS=""
  PARSE_MISS=0
  if [ -n "$PUSH_CMD" ]; then
    # (a) where the command's push ran, resolved against the hook cwd. That cwd
    # is the one AFTER the command ran, so a relative `cd sub && git push`
    # resolves to …/sub/sub here — which is why (a) is only the first candidate.
    if ! CMD_DIR=$(_push_dir "$PUSH_CMD" "${HOOK_ABS:-$HOOK_CWD}"); then
      # The parser found no git-push segment. The hook only calls here with a
      # command its pre-filter matched, so this is a form the parser does not
      # model (`xargs git push`, a quoting it cannot follow), NOT "nothing was
      # pushed": drop (a) and go on — git state decides, as it always does.
      # Never a silent exit (the first 2.53.0 drafts exited 0 here).
      CMD_DIR=""; PARSE_MISS=1
    fi
  else
    CMD_DIR="$HOOK_ABS"   # a caller that names no command (manual / relaunch)
  fi
  PUSH_TOP=""
  USED=""
  for cand in "$CMD_DIR" "$HOOK_ABS" "${CLAUDE_PROJECT_DIR:-}" "$ROOT"; do
    [ -n "$cand" ] || continue
    if PUSH_TOP=$(git -C "$cand" rev-parse --show-toplevel 2>/dev/null) && [ -n "$PUSH_TOP" ]; then
      USED="$cand"
      break
    fi
    PUSH_TOP=""
  done
  if [ -z "$PUSH_TOP" ]; then
    # Nowhere to confirm. Say so wherever a confirm log can already live.
    for cand in "${CLAUDE_PROJECT_DIR:-}" "$ROOT" "$HOOK_ABS"; do
      [ -n "$cand" ] && [ -d "$cand/.claude/state" ] || continue
      _note "$cand" "skipped — no candidate is a git work tree (push dir '${CMD_DIR:-unknown}'$([ "$PARSE_MISS" = "1" ] && printf ' (unparsed)'), hook cwd '${HOOK_ABS:-$HOOK_CWD}', project dir '${CLAUDE_PROJECT_DIR:-}', root '${ROOT}')"
      break
    done
    exit 0
  fi
  # The note names directories, never the command text: a push command can carry
  # a credential (`git -c http.extraHeader=… push`, a token URL).
  PWT_LAUNCH_NOTE=""
  if [ "$PARSE_MISS" = "1" ]; then
    PWT_LAUNCH_NOTE="no git-push segment could be parsed from the command (a form the parser does not model); used '$USED' — git state decides"
  elif [ -n "$PUSH_CMD" ] && [ "$USED" != "$CMD_DIR" ]; then
    PWT_LAUNCH_NOTE="the push dir '${CMD_DIR:-unknown}' from the command is not a git work tree (the hook cwd is the cwd AFTER the command ran); used '$USED' instead"
  elif [ -z "$PUSH_CMD" ] && [ "$USED" != "$CMD_DIR" ]; then
    PWT_LAUNCH_NOTE="the cwd '${CMD_DIR:-unknown}' is not a git work tree; used '$USED' instead"
  fi
  ROOT=$(_main_tree "$PUSH_TOP") || exit 0
else
  BASE="$(cd "$BASE" 2>/dev/null && pwd)" || exit 0
  ROOT=$(_main_tree "$BASE" 2>/dev/null) || ROOT="$BASE"
fi
STATE_DIR="$ROOT/.claude/state"
RECORD="$STATE_DIR/pwt-post-push-confirm.json"
CONFIRM_LOG="$STATE_DIR/pwt-post-push-confirm.log"
LOCK="$STATE_DIR/pwt-post-push-confirm.lock"

# ─── --surface ──────────────────────────────────────────────────────────────
if [ "$MODE" = "surface" ]; then
  [ -f "$RECORD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  st=$(_rec '.status'); sha=$(_rec '.sha'); short="${sha:0:10}"
  why=$(_rec '.reason' | tr -cd 'a-z0-9-' | cut -c1-48)
  rerun=".claude/scripts/plan-w-team-post-push-confirm.sh --launch --relaunch"
  case "$st" in
    red)
      echo ""
      echo "⚠ POST-PUSH CONFIRM RED — the full skill suite failed on pushed ${short} (${why}); log: $(_rec '.log_path')"
      echo "   the default branch is red: fix it before building on it (details: docs/operations/post-push-confirm.md)" ;;
    error|died|skipped-disk)
      echo ""
      echo "⚠ post-push confirm could not run (${st}: ${why:-unknown}) for pushed ${short} — nothing was verified; it retries on the next push, or now: ${rerun}" ;;
    running)
      if ! _pid_alive "$(_rec '.pid')"; then
        echo ""
        echo "⚠ post-push confirm could not run (died before finishing — its process is gone) for pushed ${short}; relaunch: ${rerun}"
      else
        age=$(_record_age_s 2>/dev/null || echo "")
        if [ -n "$age" ] && [ "$age" -gt "$STALE_AFTER_S" ]; then
          echo ""
          echo "⚠ post-push confirm for ${short} is still running after $((age / 60))m (stale past $((STALE_AFTER_S / 60))m) — the next push relaunches it"
        fi
      fi ;;
  esac
  exit 0
fi

# ─── --launch ───────────────────────────────────────────────────────────────
if [ "$MODE" = "launch" ]; then
  _have_harness "$PUSH_TOP" || exit 0
  if [ -n "$PWT_LAUNCH_NOTE" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null
    _note "$ROOT" "$PWT_LAUNCH_NOTE"
  fi
  command -v jq >/dev/null 2>&1 || exit 0
  command -v shasum >/dev/null 2>&1 || exit 0
  _load_lib "$PUSH_TOP" || exit 0

  DEF_REF=$(_default_branch_ref "$PUSH_TOP") || exit 0
  TARGET=$(git -C "$PUSH_TOP" rev-parse -q --verify "refs/remotes/$DEF_REF^{commit}" 2>/dev/null || echo "")
  [ -n "$TARGET" ] || exit 0
  HEAD_SHA=$(git -C "$PUSH_TOP" rev-parse -q --verify HEAD 2>/dev/null || echo "")

  if [ "$RELAUNCH" != "1" ]; then
    _pushed_recently "$PUSH_TOP" "$DEF_REF"
    case $? in
      0) ;;
      1) exit 0 ;;
      *) [ "$HEAD_SHA" = "$TARGET" ] || exit 0 ;;   # no reflog: the old heuristic
    esac
  fi

  # Everything from the coverage check to the record write is one critical
  # section: two hooks racing (two pushes, or a push beside a --run catch-up)
  # must yield ONE spawn.
  _lock_take 10 || exit 0
  trap '_lock_drop' EXIT

  if [ -f "$RECORD" ]; then
    r_sha=$(_rec '.sha'); r_st=$(_rec '.status'); r_pid=$(_rec '.pid')
    if [ "$r_st" = "running" ]; then
      r_age=$(_record_age_s 2>/dev/null || echo "")
      if _pid_alive "$r_pid"; then
        # Live and within its bound: it catches up on the newest push when it ends.
        if [ -z "$r_age" ] || [ "$r_age" -le "$STALE_AFTER_S" ]; then exit 0; fi
        # Stale: never kill a pid that may have been reused — just stop deferring.
        _record_set '.status = "died" | .reason = $r' --arg r "stale-after-${r_age}s" || true
      else
        _reap_worktree "$(_rec '.worktree')"
        _record_set '.status = "died" | .reason = "process-gone"' || true
      fi
    elif [ "$r_sha" = "$TARGET" ] && { [ "$r_st" = "green" ] || [ "$r_st" = "red" ]; }; then
      exit 0
    fi
  fi

  # Does a full green verdict already describe exactly what was pushed? Only
  # decidable here when the push repo's HEAD is TARGET (the manifest reads HEAD);
  # otherwise run — a spare confirm is cheap, a missed one is not.
  if [ "$HEAD_SHA" = "$TARGET" ]; then
    DIRS="$PUSH_TOP/.claude/state"
    [ "$STATE_DIR" = "$DIRS" ] || DIRS="$DIRS
$STATE_DIR"
    NEWEST=""
    while IFS= read -r d; do
      for f in "$d"/plan-w-team-test-green-*.json; do
        [ -f "$f" ] || continue
        if [ -z "$NEWEST" ] || [ "$f" -nt "$NEWEST" ]; then NEWEST="$f"; fi
      done
    done <<EOF
$DIRS
EOF
    NEWEST_MODE=""
    [ -n "$NEWEST" ] && NEWEST_MODE=$(jq -r '.mode // ""' "$NEWEST" 2>/dev/null || echo "")
    if [ "$NEWEST_MODE" != "retest" ]; then
      TARGET_DIGEST=$(_head_digest "$PUSH_TOP" 2>/dev/null || echo "")
      if [ -n "$TARGET_DIGEST" ]; then
        TARGET_SUBJ=""   # computed once, only when a verdict carries subject_digest
        while IFS= read -r d; do
          for f in "$d"/plan-w-team-test-green-*.json; do
            [ -f "$f" ] || continue
            if jq -e --arg d "$TARGET_DIGEST" --arg c "$PWT_RT_DEFAULT_SUITE_CMD" \
                 '.green == true and .mode == "full" and .suite_cmd == $c and .tree_digest == $d' \
                 "$f" >/dev/null 2>&1; then
              # A verdict that records the suite's SUBJECT (the harness files the
              # suite runs) covers TARGET only when that subject is TARGET's too;
              # an older verdict without the key keeps the tree-digest-only rule.
              if jq -e 'has("subject_digest")' "$f" >/dev/null 2>&1; then
                [ -n "$TARGET_SUBJ" ] || TARGET_SUBJ=$(_head_subject_digest "$PUSH_TOP" 2>/dev/null) || TARGET_SUBJ=""
                [ -n "$TARGET_SUBJ" ] || TARGET_SUBJ="-"
                jq -e --arg s "$TARGET_SUBJ" '.subject_digest == $s' "$f" >/dev/null 2>&1 || continue
              fi
              exit 0
            fi
          done
        done <<EOF
$DIRS
EOF
      fi
    fi
  fi

  SHORT="${TARGET:0:10}"
  SLUG="post-push-$SHORT"
  # Test seam: a holder stalled between its decision and its spawn.
  case "${PWT_POST_PUSH_CONFIRM_TEST_HOLD_S:-}" in ''|*[!0-9.]*) ;; *) sleep "$PWT_POST_PUSH_CONFIRM_TEST_HOLD_S" ;; esac
  # Re-check the lock is still ours: a holder stalled past LOCK_STALE_S may have
  # been reclaimed, and the reclaimer then owns the decision to spawn.
  if ! _lock_still_ours; then
    LOCK_HELD=0
    _note "$ROOT" "lock lost before spawn (held past ${LOCK_STALE_S}s and reclaimed) — not spawning; the reclaimer decides"
    exit 0
  fi
  if [ -n "${PWT_POST_PUSH_CONFIRM_CMD:-}" ]; then
    nohup nice -n 10 sh -c "$PWT_POST_PUSH_CONFIRM_CMD" >/dev/null 2>&1 < /dev/null &
  else
    nohup nice -n 10 bash "$SELF" --run "$TARGET" --root "$ROOT" >/dev/null 2>&1 < /dev/null &
  fi
  PID=$!
  _record_set '{sha:$sha, slug:$slug, started:$started, status:"running", pid:$pid, repo:$repo}' \
    --arg sha "$TARGET" --arg slug "$SLUG" --arg repo "$PUSH_TOP" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson pid "$PID" || true
  _lock_drop
  trap - EXIT
  echo "→ post-push confirm: full skill suite for ${SHORT} (${DEF_REF}) started in the background (non-blocking; a red or could-not-run result surfaces at the next session start)"
  exit 0
fi

# ─── --run ──────────────────────────────────────────────────────────────────
if [ "$MODE" = "run" ]; then
  case "$RUN_SHA" in ""|*[!0-9a-f]*) echo "--run needs a commit sha" >&2; exit 2 ;; esac
  command -v jq >/dev/null 2>&1 || exit 2
  SHORT="${RUN_SHA:0:10}"
  SLUG="post-push-$SHORT"
  TMP_PARENT=""
  WT=""
  SUITE_PID=""
  FINISHED=0
  WD_KIND="none"   # set before any _fail: the record names the watchdog used

  # _finish <status> <suite_exit|null> <reason> <log> — under the lock, and never
  # over a record that a newer live run now owns.
  _finish() {
    local o_sha o_st o_pid
    _lock_take 50 || true
    o_sha=$(_rec '.sha'); o_st=$(_rec '.status'); o_pid=$(_rec '.pid')
    if [ -n "$o_sha" ] && [ "$o_sha" != "$RUN_SHA" ] && [ "$o_st" = "running" ] \
       && [ "$o_pid" != "$$" ] && _pid_alive "$o_pid"; then
      _lock_drop
      return 0
    fi
    _record_set '.sha = $sha | .slug = $slug | .status = $st | .finished = $fin
                 | .suite_exit = $ex | .reason = $reason | .log_path = $log
                 | .watchdog = $wd | del(.worktree)' \
      --arg sha "$RUN_SHA" --arg slug "$SLUG" --arg st "$1" --arg wd "${WD_KIND:-none}" \
      --arg fin "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ex "$2" \
      --arg reason "$3" --arg log "$4" || true
    _lock_drop
    FINISHED=1
  }

  # Kill the suite's process groups: the watchdog runner (verify-run / timeout)
  # leads one group, and verify-run's own children lead theirs — snapshot them
  # BEFORE the runner dies, or they are re-parented and lost.
  _kill_suite() {
    local kids="" k sig
    [ -n "$SUITE_PID" ] || return 0
    command -v pgrep >/dev/null 2>&1 && kids=$(pgrep -P "$SUITE_PID" 2>/dev/null || true)
    for sig in TERM KILL; do
      for k in $kids; do kill -"$sig" -"$k" 2>/dev/null || kill -"$sig" "$k" 2>/dev/null; done
      kill -"$sig" -"$SUITE_PID" 2>/dev/null || kill -"$sig" "$SUITE_PID" 2>/dev/null
      [ "$sig" = "TERM" ] && sleep 1
    done
    SUITE_PID=""
  }

  _cleanup_wt() {
    if [ -n "$WT" ]; then
      git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
      git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
      WT=""
    fi
    if [ -n "$TMP_PARENT" ] && [ -d "$TMP_PARENT" ]; then
      case "$(basename "$TMP_PARENT")" in
        pwt-post-push.*) rm -rf "$TMP_PARENT" 2>/dev/null || true ;;
      esac
    fi
    TMP_PARENT=""
  }

  _on_signal() {
    trap - EXIT TERM HUP INT
    _kill_suite
    _cleanup_wt
    [ "$FINISHED" = "1" ] || _finish died null "signal-$1" ""
    exit 3
  }
  _on_exit() {
    [ "$FINISHED" = "1" ] && return 0
    _kill_suite
    _cleanup_wt
    _finish died null "exited-early" ""
  }
  trap '_on_signal term' TERM
  trap '_on_signal hup' HUP
  trap '_on_signal int' INT
  trap '_on_exit' EXIT

  _fail() {  # _fail <status> <reason> — could not run; nothing verified
    _cleanup_wt
    _finish "$1" null "$2" ""
    trap - EXIT
    exit 2
  }

  # Disk preflight BEFORE anything is created: a full checkout in TMPDIR on a
  # nearly full disk is how the 2026-05-29 ENOSPC incident started. Low disk is
  # skipped-disk, never red — nothing was tested.
  if [ "$MIN_FREE_GB" -gt 0 ] && [ -f "$SCRIPT_DIR/disk-budget.sh" ]; then
    DISK_JSON=$(PWT_DISK_PATH="${TMPDIR:-/tmp}" PWT_DISK_MIN_FREE_GB="$MIN_FREE_GB" \
                PWT_DISK_MIN_FREE_GB_BUILD="$MIN_FREE_GB" PWT_DISK_DIRECTIVE="" \
                bash "$SCRIPT_DIR/disk-budget.sh" 2>/dev/null || echo "")
    if [ "$(printf '%s' "$DISK_JSON" | jq -r '.recommended_action // ""' 2>/dev/null)" = "BLOCK" ]; then
      FREE=$(printf '%s' "$DISK_JSON" | jq -r '.free_gb // "?"' 2>/dev/null | tr -cd '0-9')
      _fail skipped-disk "free-${FREE:-unknown}-tenths-gb-below-${MIN_FREE_GB}gb"
    fi
  fi

  TMP_PARENT=$(mktemp -d -t pwt-post-push.XXXXXX 2>/dev/null) || { TMP_PARENT=""; _fail error mktemp-failed; }
  TMP_PARENT=$(cd "$TMP_PARENT" && pwd -P) || _fail error mktemp-failed
  if ! git -C "$ROOT" worktree add --detach "$TMP_PARENT/wt" "$RUN_SHA" >/dev/null 2>&1; then
    _fail error worktree-add-failed
  fi
  WT="$TMP_PARENT/wt"
  # Record where the worktree lives so a later --launch can reap it if this
  # process is SIGKILLed (no trap runs then).
  if _lock_take 50; then
    o_sha=$(_rec '.sha')
    if [ -z "$o_sha" ] || [ "$o_sha" = "$RUN_SHA" ]; then
      _record_set '.worktree = $wt' --arg wt "$WT" || true
    fi
    _lock_drop
  fi
  _have_harness "$WT" || _fail error no-harness-at-sha
  _load_lib "$WT" || _fail error no-retest-lib
  EXPECT_DIGEST=$(_head_digest "$WT" 2>/dev/null || echo "")

  # The vendored bats-core is gitignored: copy it (a symlink would show up as an
  # untracked watched path) so the suite never needs a network clone. node_modules
  # sits outside the watched set, so a symlink is fine there.
  if [ -d "$ROOT/tests/skill/.bats" ] && [ ! -e "$WT/tests/skill/.bats" ]; then
    cp -R "$ROOT/tests/skill/.bats" "$WT/tests/skill/.bats" 2>/dev/null || true
  fi
  if [ -d "$ROOT/node_modules" ] && [ ! -e "$WT/node_modules" ]; then
    ln -s "$ROOT/node_modules" "$WT/node_modules" 2>/dev/null || true
  fi

  # The suite sees an ALLOWLISTED environment, not the hook's. Scrubbing named
  # leaks one at a time (2.51.4 did PROJECT_ROOT/CONFIG_FILE) loses to the next
  # one: a SKILL_SKIP_*=1, a PWT_TEST_GREEN_* seam, a kill switch exported by the
  # session. `env -i` + a short list closes the class.
  ENVV=()
  for v in PATH HOME USER LOGNAME SHELL TMPDIR LANG TERM; do
    [ -n "${!v+x}" ] && ENVV[${#ENVV[@]}]="$v=${!v}"
  done
  for v in $(env | sed -n 's/^\(LC_[A-Za-z0-9_]*\)=.*/\1/p'); do
    [ -n "${!v+x}" ] && ENVV[${#ENVV[@]}]="$v=${!v}"
  done
  for v in $(printf '%s' "${PWT_POST_PUSH_CONFIRM_ENV_PASS:-}" | tr ',' ' '); do
    case "$v" in ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;; esac
    [ -n "${!v+x}" ] && ENVV[${#ENVV[@]}]="$v=${!v}"
  done
  ENVV[${#ENVV[@]}]="CLAUDE_PROJECT_DIR=$WT"
  ENVV[${#ENVV[@]}]="PWT_PROJECT_ROOT_OVERRIDE=$WT"

  # Wall-clock bound, reusing the house runner (process-group reaping, orphan
  # count) when it is here; else coreutils timeout; else the poll loop below.
  TG="$WT/.claude/scripts/plan-w-team-test-green.sh"
  WD_KIND="none"
  if [ "$TIMEOUT_S" -gt 0 ]; then
    if [ -f "$SCRIPT_DIR/plan-w-team-verify-run.sh" ]; then WD_KIND="verify-run"
    elif command -v timeout >/dev/null 2>&1; then WD_KIND="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then WD_KIND="gtimeout"
    else WD_KIND="inline"
    fi
  fi
  set -m 2>/dev/null
  case "$WD_KIND" in
    verify-run)
      ( cd "$WT" && exec env -i "${ENVV[@]}" bash "$SCRIPT_DIR/plan-w-team-verify-run.sh" \
          --slug "$SLUG" --step confirm --timeout "$TIMEOUT_S" -- bash "$TG" --slug "$SLUG" ) \
        >/dev/null 2>&1 < /dev/null & ;;
    timeout|gtimeout)
      ( cd "$WT" && exec env -i "${ENVV[@]}" "$WD_KIND" -k 10 "$TIMEOUT_S" bash "$TG" --slug "$SLUG" ) \
        >/dev/null 2>&1 < /dev/null & ;;
    *)
      ( cd "$WT" && exec env -i "${ENVV[@]}" bash "$TG" --slug "$SLUG" ) \
        >/dev/null 2>&1 < /dev/null & ;;
  esac
  SUITE_PID=$!
  set +m 2>/dev/null
  # Poll in 1 s slices rather than one `wait`: a trapped TERM/HUP/INT then runs
  # within a second, and the inline bound needs the loop anyway.
  TIMED_OUT=0
  ELAPSED=0
  while _pid_alive "$SUITE_PID"; do
    if [ "$WD_KIND" = "inline" ] && [ "$ELAPSED" -ge "$TIMEOUT_S" ]; then
      TIMED_OUT=1
      _kill_suite
      break
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
  done
  RUN_RC=0
  if [ -n "$SUITE_PID" ]; then wait "$SUITE_PID" 2>/dev/null; RUN_RC=$?; fi
  SUITE_PID=""
  case "$WD_KIND:$RUN_RC" in
    verify-run:10|verify-run:12|timeout:124|gtimeout:124|timeout:137|gtimeout:137) TIMED_OUT=1 ;;
  esac

  # ── classify ─────────────────────────────────────────────────────────────
  # green needs ALL of: green, full mode, the default suite command, and the
  # digest of exactly the pushed tree. red needs a full-mode verdict whose suite
  # exited non-zero. Anything else did not verify the push: error, with a reason.
  V="$WT/.claude/state/plan-w-team-test-green-${SLUG}.json"
  STATUS="error"; EXITV="null"; REASON="no-verdict"; LOG_OUT=""
  if [ "$TIMED_OUT" = "1" ]; then
    REASON="timeout-${TIMEOUT_S}s"
  elif [ -f "$V" ] && jq -e . "$V" >/dev/null 2>&1; then
    V_MODE=$(jq -r '.mode // ""' "$V" | tr -cd 'a-z0-9-' | cut -c1-20)
    V_CMD=$(jq -r '.suite_cmd // ""' "$V")
    V_GREEN=$(jq -r 'if .green == true then "true" else "false" end' "$V")
    V_DIGEST=$(jq -r '.tree_digest // ""' "$V")
    EXITV=$(jq -r 'if (.suite_exit|type) == "number" then (.suite_exit|tostring) else "null" end' "$V")
    case "$EXITV" in null) ;; *[!0-9]*) EXITV="null" ;; esac
    V_REASON=$(jq -r '.reason // "?"' "$V" | tr -cd 'a-z0-9-' | cut -c1-40)
    if [ "$V_MODE" != "full" ]; then
      REASON="not-full-mode-${V_MODE:-none}"
    elif [ "$V_CMD" != "$PWT_RT_DEFAULT_SUITE_CMD" ]; then
      REASON="suite-cmd-substituted"
    elif [ "$EXITV" != "null" ] && [ "$EXITV" != "0" ]; then
      STATUS="red"; REASON="$V_REASON"
    elif [ "$V_GREEN" = "true" ] && pwt_rt_is_hex64 "$EXPECT_DIGEST" && [ "$V_DIGEST" = "$EXPECT_DIGEST" ]; then
      STATUS="green"; REASON="$V_REASON"
    elif [ "$V_GREEN" = "true" ]; then
      REASON="digest-mismatch"
    else
      REASON="not-green-${V_REASON}"
    fi
    SRC_LOG=$(jq -r '.log_path // ""' "$V")
    # The suite log replaces the previous one; the newest launch notes (a
    # fallback push dir, a skip, a lost lock) are carried over on top.
    if [ -n "$SRC_LOG" ] && [ -f "$SRC_LOG" ] \
       && { grep ' launch: ' "$CONFIRM_LOG" 2>/dev/null | tail -n 20; cat "$SRC_LOG"; } > "$CONFIRM_LOG.tmp.$$" 2>/dev/null \
       && mv "$CONFIRM_LOG.tmp.$$" "$CONFIRM_LOG" 2>/dev/null; then
      LOG_OUT="$CONFIRM_LOG"
    else
      rm -f "$CONFIRM_LOG.tmp.$$" 2>/dev/null
    fi
  fi

  _cleanup_wt
  _finish "$STATUS" "$EXITV" "$REASON" "$LOG_OUT"
  trap - EXIT TERM HUP INT
  case "$STATUS" in
    green) RC=0 ;;
    red)
      _notify_red "The full skill suite failed on pushed ${SHORT} (${REASON}). The default branch is red."
      RC=1 ;;
    *) RC=2 ;;
  esac
  # origin/<default> may have moved while this ran: compare it with what was
  # confirmed and catch up directly (coverage still applies; no reflog test).
  DEF_REF=$(_default_branch_ref "$ROOT" 2>/dev/null || echo "")
  if [ -n "$DEF_REF" ]; then
    NOW_TIP=$(git -C "$ROOT" rev-parse -q --verify "refs/remotes/$DEF_REF^{commit}" 2>/dev/null || echo "")
    if [ -n "$NOW_TIP" ] && [ "$NOW_TIP" != "$RUN_SHA" ]; then
      bash "$SELF" --launch --relaunch --root "$ROOT" >/dev/null 2>&1 || true
    fi
  fi
  exit "$RC"
fi

exit 0
