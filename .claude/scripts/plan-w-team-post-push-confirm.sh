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
#              a. the dir the command's first `git … push` ran in (_push_dir).
#                 The command is lexed quote-aware (single/double quotes,
#                 backslash escapes, $(…)/`…`/${…}, heredocs, comments), so
#                 `git -C "a;b" push` is dir `a;b`; then every cd / pushd /
#                 popd / `git -C` / `env -C` is replayed in order through
#                 ; && || | & and (…) / {…} / if / loops / case, so -C and cd
#                 anchor at the cwd in force AT the push. A cd need not have
#                 run (a missing dir, the other side of && / ||, an if or case
#                 arm, a loop body), so the replay walks WORLDS: each cd fails
#                 or moves, and each branch runs on the status its world gives
#                 it (_pd_pick). DIR — the hook input cwd — is where a world
#                 ENDED when the command exited 0 (the CLI runs `eval <cmd> &&
#                 pwd -P`), or where it STARTED when it ended non-zero or by
#                 exit/exec. Every world that pushes gives a reading against
#                 DIR, and the readings must name ONE existing dir: `if false;
#                 then cd ../r2; fi; git push` has one such world and resolves
#                 to DIR itself (how=after, no note); `cd r2 && git push;
#                 false` is read against DIR as the START (how=start, noted
#                 below). A -C path whose `..` leaves a named dir resolves
#                 physically, as git and env chdir() (a symlink's `..` is its
#                 target's parent). What the replay cannot follow (cd -, a popd
#                 past the command's own pushd, a $VAR / glob / {a,b} / $(…)
#                 path, `command cd` and `chdir` (the shells disagree), a
#                 `&`-backgrounded list whose cds bash and zsh leave in
#                 different places (`git push; cd a && true &`), a loop body
#                 whose iteration can end in another dir, CDPATH, a relative
#                 `cd -P`, a pushd option, cd after set -P / CHASE_LINKS, set
#                 -e / trap / return), readings that disagree, a push that
#                 precedes every cd (nothing anchors the start: known gap, (b)
#                 is then the post-cd dir) and a command over _PD_MAX_BYTES (the
#                 parse cost grows faster than the bytes) make (a) UNKNOWN,
#                 never a guess;
#              b. DIR, the hook input cwd;
#              c. CLAUDE_PROJECT_DIR, then R.
#            Taking (b) or (c) instead of (a) writes one note line to the
#            confirm log; so does an unknowable (a), a command the parser finds
#            no git-push in (there is no (a) then: the hook's pre-filter matched
#            it, so it is a form the parser does not model, never proof that
#            nothing was pushed), and "no candidate is a git work tree". An (a)
#            read against DIR as the START (how=start) is ALWAYS noted, even
#            when it is used: "used the push dir '<dir>' from the command (read
#            against the hook cwd as the START: …)". The command is ONLY parsed
#            for where; whether anything happened is read from git, so a wrong
#            or unknown (a) can only pick a candidate whose own git state then
#            decides — never a red on its own.
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
#     next --launch that finds TARGET uncovered — a hooked push while the push
#     is still inside the reflog window, a push that moves origin/<default>, or
#     a --launch --relaunch. DECIDED (R255): nothing retries on its own, not
#     even inside the window: the usual causes (disk, timeout, a kill) repeat on
#     a retry, each retry is a full suite, and the status is already surfaced.
#   pwt-post-push-confirm.log    the last run's suite log, plus one-line launch
#                                notes (a fallback push dir, an unknowable
#                                one, an unparsed command, a skip, a lost lock)
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
# subject_digest) of <root>'s committed HEAD tree. The
# lib's `pwt_rt_subject_manifest <root> head` owns the roots, the excludes and the
# roots-to-`case`-pattern conversion (R255 194(6)); this script keeps no copy. A
# lib too old to know head mode fails the call, the digest reads "-", and the
# verdict does not cover TARGET: one spare confirm run, never a missed one.
_head_subject_digest() {
  local man d=""
  man=$(mktemp -t pwt-post-push-subj.XXXXXX 2>/dev/null) || return 1
  if pwt_rt_subject_manifest "$1" head > "$man" 2>/dev/null; then
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

# ─── where the push ran: lex the command, replay its cds ────────────────────
# _push_dir <command> <hook-cwd> [<project-dir>] — where the command's FIRST
# `git … push` ran, as two lines, HOW then DIR:
#   after    DIR follows from the hook cwd as the cwd AFTER the command: the
#            CLI runs `eval <command> && pwd -P`, so a command that ended with
#            status 0 leaves the hook cwd at its end — `cd a && git push &&
#            cd ../b` ends in S/b, so the start S is the hook cwd less `b`, and
#            the push ran in S/a (a cwd outside the allowed dirs is reset to the
#            project dir: then S is unknown)
#   start    in every reading that places the push the command ended non-zero
#            or by `exit`/`exec` (the CLI then keeps the cwd it started in), so
#            DIR is resolved against the hook cwd as the START; the launch notes
#            it in the confirm log
#   unknown  DIR is empty: the readings disagree or cannot be placed (`cd -`
#            with no earlier cd, `git -C "$X"`, `git --git-dir …`, a cd that may
#            not have run — a missing dir, `2>/dev/null`, the right of `&&` —
#            before a push whose dir the end cannot anchor, a push that precedes
#            every cd — `git push && cd ../b` ends in S/../b, which names no S —,
#            `command cd`, `chdir`, errexit, `trap`, `return`, a case `;&`, a -C
#            path through a symlink that does not resolve on this host …)
#   long     DIR is empty: the command is over _PD_MAX_BYTES and is not parsed.
#            The lexer re-slices the rest of the command at every token and the
#            replay re-normalizes a cwd and a pushd stack that grow with every
#            cd, so the cost grows faster than the bytes: on bash 3.2 the worst
#            shapes found (a thousand cds or pushds in one command) take ≈ 7 s at
#            8 KB on a quiet host and 9–12 s at a load average of 30–40; at
#            16 KB, 47 s and 81 s. This runs inside the hook's 60 s timeout. The
#            cap still fits this repo's longest heredoc commit message (≈ 6 KB).
#            The world count (below) is bounded by token steps
#            (_PD_MAX_STEPS), so the longest commands get one walk and cost
#            what the one-walk replay did.
# Return 1 when no `git … push` command is found (a form it does not model —
# `xargs git push`, `sudo git push` — an unterminated quote, or $(…) / ${…}
# nested past _LX_MAX_DEPTH): the caller falls back to the other candidates,
# and git state decides.
#
# The command is LEXED, not split: '…', "…", \x, $'…', $(…), `…`, ${…}, <(…),
# comments and heredoc bodies are words or skipped text, so the `;` `&` `|` `'`
# of a quoted path or a heredoc commit message never split a command, and
# `git -C "a;b" push` pushes in `a;b`. The cds are then REPLAYED from an unknown
# start S (`.`): cd, pushd, popd, `git -C` (relative -C dirs stack), and
# `env -C`/`--chdir` for its one command (the last one, from where env started;
# `-Cdir` and bundles like `-iC dir` too). `cd` is logical (`..` drops a name)
# and `cd -P` physical: an absolute target is resolved on this host, a relative
# one that names a dir is unknown, and `-P` before `-L` is unknown (bash takes
# the last, zsh any -P). A cd option other than -L/-P, any pushd option but -n,
# and every cd/pushd/popd after `set -P`, `set -o physical`, zsh's `set -w` or
# a CHASE_LINKS/CHASE_DOTS setopt are unknown: the shells disagree. So are
# `command cd` (the builtin in bash, the external binary in zsh) and `chdir` (a
# zsh builtin bash does not have). The shell's rc-file options are invisible
# here. A cd is a BRANCH: it fails (no move, status 1) or it moves; and the
# replay is path-sensitive — `&&`/`||`, if/elif/else, case arms and loop bodies
# run on the statuses the world gives them, so each world is one way the
# command can have run (see _pd_pick). Scoping follows the shell where bash and
# zsh agree: a `( … )` subshell keeps its cds, and so does a pipeline element
# (the LAST element runs in this shell in zsh, not in bash: its cds merge to
# unknown wherever the two ways disagree). A `&`-backgrounded and-or list keeps
# its cds in bash, but zsh runs every pipeline of it but the last in this shell
# — `cd a && x &` moves zsh to a — so the state after it merges both and is
# unknown wherever they differ. `exit`/`exec <cmd>` end the shell (a subshell:
# only it); as a pipeline element or behind `&` the replay gives up. Every
# world gives readings (_pd_world): the readings must name one existing dir, or
# the dir is unknown — unknown is fine, a wrong dir is not. `set -e`, `trap`,
# `return`, `break N`, a case fall-through, a function body: it gives up too,
# and any push in the command is then unknown. Assignments it tracks:
# GIT_DIR/GIT_WORK_TREE (every later push is unknown), CDPATH (a relative cd
# is unknown), HOME (a bare `cd` or `cd ~` is unknown), OLDPWD, PWD. Bare `cd`
# and `cd ~` go to $HOME; `cd -` returns to the previous cd's dir, unknown when
# none happened in this command; pushd/popd follow the stack the command built,
# unknown beyond it; `cd` behind nohup/env/timeout/exec is the external binary —
# no move.
_NL=$'\n'; _TB=$'\t'; _E1=$'\001'; _US=$'\002'
_PD_MAX_BYTES=8192    # past this a command is `long`: see _push_dir above
_LX_MAX_DEPTH=64      # $(…) / ${…} nesting past this is a parse miss: see _lx_sub
_PD_MAX_REAL=16       # distinct physical lookups per command (cached); past this the dir is unknown
_PD_MAX_WORLDS=64     # worlds replayed per command (_pd_pick); past this the dir is unknown
_PD_MAX_STEPS=4096    # token steps over all the worlds; past this the dir is unknown. A
                      # walk costs more than linear in the cds it replays, so the cap
                      # holds the longest commands to one walk: the worst 8 KB shapes
                      # (a thousand cds or pushds) then cost what the one-walk replay
                      # did (bash 3.2, load ≈ 20: 4.6 s vs 4.2 s; at 8192, three
                      # walks of a pushd chain took 14 s)

# _lx_tok <kind> [value] [raw] [dynamic] — record a token (w word, o operator,
# r redirection: its target is the next word); nothing inside a $(…) body.
_lx_tok() {
  [ "$LX_LVL" -eq 0 ] || return 0
  TK[NT]=$1; TV[NT]=${2:-}; TR[NT]=${3:-${2:-}}; TX[NT]=${4:-0}; NT=$((NT + 1))
}
# _lx_sub — lex a $(…) / <(…) body at the head of $rest, through its ")".
# It and _lx_brace are the two places the lexer recurses, so both count the
# depth: past _LX_MAX_DEPTH they return 1 (a parse miss), before bash 3.2's
# stack gives out (a segfault near 800 nested `$(`). A failure aborts the whole
# lex, so only the success paths give the level back.
_lx_sub() {
  local rc
  [ "$LX_DEP" -lt "$_LX_MAX_DEPTH" ] || return 1
  LX_DEP=$((LX_DEP + 1)); LX_LVL=$((LX_LVL + 1)); _lx_list 0; rc=$?
  LX_LVL=$((LX_LVL - 1)); LX_DEP=$((LX_DEP - 1))
  return $rc
}
# _lx_dollar <in-dq> — consume the $-expansion at the head of $rest; the word
# becomes dynamic (WX=1).
_lx_dollar() {
  local n=${rest:1:1} nm sv=$WV
  case $n in
    '(') rest=${rest:2}; _lx_sub || return 1; WV="$sv\$(…)" ;;
    '{') rest=${rest:2}; _lx_brace || return 1; WV="$sv\${…}" ;;
    "'") if [ "$1" = 1 ]; then WV="$WV\$"; rest=${rest#?}
         else rest=${rest:2}; _lx_ansi || return 1; WV="$sv\$'…'"; fi ;;
    *) rest=${rest#?}
       nm=${rest%%[!A-Za-z0-9_]*}
       if [ -z "$nm" ]; then case $n in [@\*\#\?\$\!0-9-]) nm=$n ;; esac; fi
       rest=${rest:${#nm}}; WV="$WV\$$nm" ;;
  esac
  WX=1; WG=1
}
# _lx_brace — consume a ${…} body through its "}".
_lx_brace() {
  local run
  [ "$LX_DEP" -lt "$_LX_MAX_DEPTH" ] || return 1
  LX_DEP=$((LX_DEP + 1))
  while :; do
    run=${rest%%[\}\'\"\\\$\`]*}; rest=${rest:${#run}}
    case ${rest:0:1} in
      '') return 1 ;;
      '}') rest=${rest#?}; LX_DEP=$((LX_DEP - 1)); return 0 ;;
      "'") rest=${rest#?}; run=${rest%%\'*}; [ "$run" != "$rest" ] || return 1
           rest=${rest:${#run}+1} ;;
      '"') rest=${rest#?}; _lx_dq || return 1 ;;
      '\') rest=${rest:2} ;;
      '$') _lx_dollar 1 || return 1 ;;
      '`') _lx_bq || return 1 ;;
    esac
  done
}
# _lx_ansi — consume a $'…' body through its closing quote.
_lx_ansi() {
  local run
  while :; do
    run=${rest%%[\'\\]*}; rest=${rest:${#run}}
    case ${rest:0:1} in
      '') return 1 ;;
      "'") rest=${rest#?}; return 0 ;;
      *) rest=${rest:2} ;;
    esac
  done
}
# _lx_bq — consume the `…` substitution at the head of $rest.
_lx_bq() {
  local run
  rest=${rest#?}
  while :; do
    run=${rest%%[\`\\]*}; rest=${rest:${#run}}
    case ${rest:0:1} in
      '') return 1 ;;
      '`') rest=${rest#?}; return 0 ;;
      *) rest=${rest:2} ;;
    esac
  done
}
# _lx_dq — lex a "…" body (its opening quote consumed) onto WV.
_lx_dq() {
  local run n
  while :; do
    run=${rest%%[\"\\\$\`]*}; WV=$WV$run; rest=${rest:${#run}}
    case ${rest:0:1} in
      '') return 1 ;;
      '"') rest=${rest#?}; return 0 ;;
      '\') n=${rest:1:1}
           case $n in
             "$_NL") rest=${rest:2} ;;
             '"'|'\'|'$'|'`') WV=$WV$n; rest=${rest:2} ;;
             *) WV="$WV\\"; rest=${rest#?} ;;
           esac ;;
      '$') _lx_dollar 1 || return 1 ;;
      '`') WX=1; _lx_bq || return 1 ;;
    esac
  done
}
# _lx_word — lex the word at the head of $rest: WV its value (quotes removed,
# escapes applied), WX 1 when it is dynamic ($…, `…`, an unquoted glob or `{`),
# WG 1 when there is a word at all (`''` is one; a lone line continuation is
# not). Any unquoted `{` counts, not only a well-formed {a,b} / {1..3} brace
# expansion: over-flagging only makes a dir unknown, never a guess (the group
# keyword `{` is matched on its raw text, so the flag does not affect it).
_lx_word() {
  local run n
  WV=""; WX=0; WG=0
  while :; do
    run=${rest%%[\ $_TB$_NL\;\&\|\(\)\<\>\'\"\\\$\`]*}
    if [ -n "$run" ]; then
      case $run in *[\*\?\[\{]*) WX=1 ;; esac
      WV=$WV$run; WG=1; rest=${rest:${#run}}
    fi
    case ${rest:0:1} in
      "'") rest=${rest#?}; run=${rest%%\'*}; [ "$run" != "$rest" ] || return 1
           WV=$WV$run; WG=1; rest=${rest:${#run}+1} ;;
      '"') rest=${rest#?}; WG=1; _lx_dq || return 1 ;;
      '\') n=${rest:1:1}
           case $n in
             "$_NL") rest=${rest:2} ;;
             '') WV="$WV\\"; WG=1; rest="" ;;
             *) WV=$WV$n; WG=1; rest=${rest:2} ;;
           esac ;;
      '$') _lx_dollar 0 || return 1 ;;
      '`') WX=1; WG=1; _lx_bq || return 1 ;;
      *) return 0 ;;
    esac
  done
}
# _lx_delim — read a heredoc delimiter word into DELIM.
_lx_delim() {
  while :; do case ${rest:0:1} in ' '|"$_TB") rest=${rest#?} ;; *) break ;; esac; done
  _lx_word || return 1
  [ "$WG" = 1 ] || return 1
  DELIM=$WV
}
# _lx_bodies <owed> — skip the heredoc bodies owed at this newline, in order
# (each entry: a `-` (strip leading tabs) or ` ` flag, the delimiter, \001).
_lx_bodies() {
  local list="$1" e line
  while [ -n "$list" ]; do
    e=${list%%"$_E1"*}; list=${list:${#e}+1}
    while [ -n "$rest" ]; do
      line=${rest%%"$_NL"*}; rest=${rest:${#line}+1}
      if [ "${e:0:1}" = - ]; then
        while :; do case $line in "$_TB"*) line=${line#?} ;; *) break ;; esac; done
      fi
      [ "$line" = "${e#?}" ] && break
    done
  done
}
# _lx_list <top> — lex a command list: top=1 the whole command (return 0 at its
# end), top=0 a $(…) body (return 0 after its closing ")"). Return 1 on an
# unterminated quote, substitution or body, or nesting past _LX_MAX_DEPTH. A newline is a `;` operator; the
# case fall-throughs `;&` and `;;&` are `;&` (the replay gives up on it); `|&` is `|`; zsh's `&|` / `&!`
# are `&`; `&>`, `<<<`, `<&`
# … are redirections; an fd number glued to one (`2>&1`) is dropped. Inside a
# $(…) body, `case … in pat)` patterns do not close it.
_lx_list() {
  local top="$1" c3 run start raw d=0 cs=0 ci=0 pm=0 cmd=1 hd=""
  while :; do
    c3=${rest:0:3}
    case $c3 in
      '') [ "$top" = 1 ]; return ;;
      ' '*|"$_TB"*) rest=${rest#?}; continue ;;
      "$_NL"*) rest=${rest#?}; _lx_tok o ';'; cmd=1
               [ -z "$hd" ] || { _lx_bodies "$hd"; hd=""; }
               continue ;;
      '#'*) run=${rest%%"$_NL"*}; rest=${rest:${#run}}; continue ;;
      ';;&') rest=${rest:3}; _lx_tok o ';&'; [ "$cs" -gt 0 ] && pm=1; cmd=1; continue ;;
      ';;'*) rest=${rest:2}; _lx_tok o ';;'; [ "$cs" -gt 0 ] && pm=1; cmd=1; continue ;;
      ';&'*) rest=${rest:2}; _lx_tok o ';&'; [ "$cs" -gt 0 ] && pm=1; cmd=1; continue ;;
      ';'*) rest=${rest#?}; _lx_tok o ';'; cmd=1; continue ;;
      '&&'*) rest=${rest:2}; _lx_tok o '&&'; cmd=1; continue ;;
      '&>>') rest=${rest:3}; _lx_tok r; continue ;;
      '&>'*) rest=${rest:2}; _lx_tok r; continue ;;
      '&|'*|'&!'*) rest=${rest:2}; _lx_tok o '&'; cmd=1; continue ;;
      '&'*) rest=${rest#?}; _lx_tok o '&'; cmd=1; continue ;;
      '||'*) rest=${rest:2}; _lx_tok o '||'; cmd=1; continue ;;
      '|&'*) rest=${rest:2}; _lx_tok o '|'; cmd=1; continue ;;
      '|'*) rest=${rest#?}; _lx_tok o '|'; cmd=1; continue ;;
      '('*) rest=${rest#?}; _lx_tok o '('; [ "$pm" = 1 ] || d=$((d + 1)); cmd=1; continue ;;
      ')'*) rest=${rest#?}
            if [ "$pm" = 1 ]; then pm=0
            elif [ "$top" = 0 ] && [ "$d" -eq 0 ]; then return 0
            else d=$((d - 1)); fi
            _lx_tok o ')'; cmd=1; continue ;;
      '<<<') rest=${rest:3}; _lx_tok r; continue ;;
      '<<-') rest=${rest:3}; _lx_delim || return 1; hd="$hd-$DELIM$_E1"; continue ;;
      '<<'*) rest=${rest:2}; _lx_delim || return 1; hd="$hd $DELIM$_E1"; continue ;;
      '<('*|'>('*) rest=${rest:2}; _lx_sub || return 1; _lx_tok w '<(…)' '<(…)' 1; cmd=0; continue ;;
      '<&'*|'<>'*|'>>'*|'>&'*|'>|'*) rest=${rest:2}; _lx_tok r; continue ;;
      '<'*|'>'*) rest=${rest#?}; _lx_tok r; continue ;;
    esac
    start=$rest
    _lx_word || return 1
    [ "$WG" = 1 ] || continue
    raw=${start:0:$((${#start} - ${#rest}))}
    case $raw in *[!0-9]*) ;; *) case ${rest:0:1} in '<'|'>') continue ;; esac ;; esac
    case $raw in
      '~'|'~/'*) case ${HOME:-} in /*) WV=$HOME${WV#\~} ;; *) WX=1 ;; esac ;;
      '~'*) WX=1 ;;
    esac
    if [ "$raw" = "$WV" ]; then
      case $WV in
        'case') [ "$cmd" = 1 ] && { cs=$((cs + 1)); ci=1; } ;;
        'in') [ "$ci" = 1 ] && { ci=0; pm=1; } ;;
        'esac') [ "$cs" -gt 0 ] && { cs=$((cs - 1)); pm=0; } ;;
      esac
      case $WV in if|then|else|elif|fi|do|done|while|until|\{|\}|\!|esac) cmd=1 ;; *) cmd=0 ;; esac
    else
      cmd=0
    fi
    _lx_tok w "$WV" "$raw" "$WX"
  done
}

# Symbolic dirs: `.` is the start S, `./a/..`-free relative paths hang off it
# (`./a`, `./../x`), `/…` is absolute, `?` unknown. The state is the cwd, the
# OLDPWD and the pushd stack (entries each ended by \001, top first; `?` when
# unknown), serialized with \002 between them.
#
# The shell's own cd is LOGICAL: `cd lnk/..` drops `lnk` as text, so the cwd,
# OLDPWD and stack are kept normalized. `git -C` and `env -C` chdir() instead,
# and the kernel's `..` of a symlink is its TARGET's parent, so the push dir is
# kept as the raw join of the cwd and those -C paths, and it is only resolved
# once S is anchored (_sym_at): lexically when no `..` drops a named dir,
# otherwise physically on this host.
_sym_norm() {  # _sym_norm <path> — SYM_: lexical . and .. (a relative path keeps leading ..); SYM_POP 1 when a .. dropped a named dir
  local out="" seg abs=0 IFS=/
  SYM_POP=0
  case $1 in /*) abs=1 ;; esac
  for seg in $1; do
    case $seg in
      ''|.) ;;
      ..) case $out in
            ''|..|*/..) [ "$abs" = 1 ] || out=${out:+$out/}.. ;;
            */*) out=${out%/*}; SYM_POP=1 ;;
            *) out=""; SYM_POP=1 ;;
          esac ;;
      *) out=${out:+$out/}$seg ;;
    esac
  done
  if [ "$abs" = 1 ]; then SYM_=/$out; else SYM_=./$out; SYM_=${SYM_%/}; fi
}
_sym_split() {  # _sym_split <relative> — SPLIT_UP: its leading ..s (past any . and //), SPLIT_DN: the rest, as given
  local p=$1
  SPLIT_UP=0
  while [ -n "$p" ]; do
    case ${p%%/*} in
      ''|.) ;;
      ..) SPLIT_UP=$((SPLIT_UP + 1)) ;;
      *) break ;;
    esac
    case $p in */*) p=${p#*/} ;; *) p="" ;; esac
  done
  SPLIT_DN=$p
}
_sym_real() {  # _sym_real <absolute> — SYM_: its physical path on this host; `?` when it does not resolve, or past _PD_MAX_REAL lookups (each one forks)
  local e
  # cached per command (RCK: \001path\002result\001 …): every world asks again
  case $RCK in *"$_E1$1$_US"*) e=${RCK#*"$_E1$1$_US"}; SYM_=${e%%"$_E1"*}; return 0 ;; esac
  if [ "$RN" -ge "$_PD_MAX_REAL" ]; then SYM_='?'; RCAP=1; return 0; fi   # RCAP: the answer is unknown
  RN=$((RN + 1))
  SYM_=$(cd -P -- "$1" 2>/dev/null && pwd -P) || SYM_=""
  [ -n "$SYM_" ] || SYM_='?'
  RCK="$RCK$_E1$1$_US$SYM_$_E1"
}
_sym_at() {  # _sym_at <absolute> — SYM_: the dir a chdir() to it reaches: lexical, unless a .. drops a named dir (a symlink's .. is its target's parent), then physical
  _sym_norm "$1"
  [ "$SYM_POP" = 0 ] || _sym_real "$1"
}
_sym_climb() {  # _sym_climb <absolute> <n> — SYM_: the dir <n> levels up (stops at /)
  local d=$1 k=$2
  while [ "$k" -gt 0 ]; do
    case $d in /|'') d=/; break ;; esac
    d=${d%/*}; [ -n "$d" ] || d=/
    k=$((k - 1))
  done
  SYM_=$d
}
_pd_join() {  # _pd_join <base> <path> <dynamic> — JOIN_: <path> taken from <base>, not normalized
  if [ "$3" = 1 ]; then JOIN_='?'; return 0; fi
  case $2 in
    /*) JOIN_=$2 ;;
    *) if [ "$1" = '?' ]; then JOIN_='?'; else JOIN_=$1/$2; fi ;;
  esac
}
_pd_norm() {  # _pd_norm <joined> — SYM_: where a logical cd to it lands
  if [ "$1" = '?' ]; then SYM_='?'; else _sym_norm "$1"; fi
}
_pd_cdp() {  # _pd_cdp <joined> — SYM_: where `cd -P` to it lands: the physical path
  # itself for an absolute one; a relative one is kept only as a pure climb
  # (./../..), since the named dirs below S resolve only once S is known
  case $1 in
    '?') SYM_='?' ;;
    /*) _sym_real "$1" ;;
    *) _sym_norm "$1"
       if [ "$SYM_POP" = 1 ]; then SYM_='?'; return 0; fi
       _sym_split "$SYM_"; [ -z "$SPLIT_DN" ] || SYM_='?' ;;
  esac
}
_pd_target() {  # _pd_target <arg> — JOIN_: where cd/pushd <arg> goes, not normalized (CDPATH → unknown)
  case $1 in
    /*|.|./*|..|../*) _pd_join "$CUR" "$1" 0 ;;
    *) if [ -n "${CDPATH:-}" ] || [ "$CDX" = 1 ]; then JOIN_='?'; else _pd_join "$CUR" "$1" 0; fi ;;
  esac
}
_pd_st() { ST="$CUR$_US$PRV$_US$DS"; }
_pd_load() {  # _pd_load <state>
  local t=${1#*"$_US"}
  CUR=${1%%"$_US"*}; PRV=${t%%"$_US"*}; DS=${t#*"$_US"}
}
_pd_merge() {  # _pd_merge <state> — keep what it and the current state agree on, else unknown
  local c p d t=${1#*"$_US"}
  c=${1%%"$_US"*}; p=${t%%"$_US"*}; d=${t#*"$_US"}
  [ "$c" = "$CUR" ] || CUR='?'
  [ "$p" = "$PRV" ] || PRV='?'
  [ "$d" = "$DS" ] || DS='?'
}
_pd_unknown() { CUR='?'; PRV='?'; DS='?'; }
# ── worlds ──
# The CLI runs `… && eval <command> && pwd -P >| <cwd-file>`: the hook cwd F is
# where the command ended ONLY when it ended with status 0 and the shell was
# still there to run `pwd -P`. A non-zero end, `exit` or `exec` leaves F at the
# start S, and a cwd outside the session's allowed dirs is reset to the project
# dir. And a command's cds do not all run: a cd fails on a missing dir (and
# `2>/dev/null` hides it), `&&`/`||` sides, if/case arms and loop bodies run on
# a status. So the tokens are replayed once per WORLD: each cd/pushd/popd fails
# (no move, status 1) or succeeds, each status the replay cannot know is 0 or 1
# where something reads it, a loop body runs or not, a case arm matches or not.
# A walk takes its decisions from DV (one 0/1 per decision point, 0 past its
# end — the likely way first) and records them in DT; the next world flips DT's
# last 0 (a depth-first count). Past _PD_MAX_WORLDS worlds or _PD_MAX_STEPS
# token steps the dir is unknown. Each world that pushes gives READINGS
# (_pd_world); the answer is the one existing dir all of them name.
_pd_pick() {  # PICK_: this world's decision here, 0 or 1
  if [ "$DI" -lt "${#DV}" ]; then PICK_=${DV:$DI:1}; else PICK_=0; fi
  DI=$((DI + 1)); DT=$DT$PICK_
}
_pd_stat() { [ "$SS" != '?' ] || { _pd_pick; SS=$PICK_; }; }   # a status something reads
# Dead code: DK is why the tokens do not run (p the skipped side of &&/||, a an
# if/case arm not taken, f the rest of an if/case after an arm ran, l the rest
# of a loop body after break/continue or a body that never ran, s the rest of a
# subshell after exit, x everything after the shell's own exit/exec), DN the
# depth it applies at. Dead commands change nothing and decide nothing; the
# compound commands still open and close, and a push in them is still counted.
_pd_dead() { DK=$1; DN=$FN; }
# A pipeline's end: its last element runs in this shell in zsh and in a subshell
# in bash, so its moves merge with the state before the pipeline (whose status
# is then unknown — pipefail); a `!` flips the status.
_pd_endpipe() {
  if [ "$IP" = 1 ]; then
    [ -n "$DK" ] || { _pd_merge "$PS"; SS='?'; }
    IP=0
  fi
  if [ "$NEG" = 1 ]; then
    if [ -z "$DK" ]; then case $SS in 0) SS=1 ;; 1) SS=0 ;; esac; fi
    NEG=0
  fi
}
_pd_eol() {  # a list ends here: a skipped &&/|| side at this depth ends with it
  _pd_endpipe
  if [ "$DK" = p ] && [ "$DN" -eq "$FN" ]; then DK=""; fi
}
_pd_open() {  # _pd_open <sub|brace|if|loop|case> [while|until|for] — enter a compound command
  local n=$FN
  _pd_st
  FTY[n]=$1; FLK[n]=${2:-}; FS0[n]=$ST; FEP[n]=0; FTK[n]=0; FTH[n]=0; FBK[n]=0
  FLS[n]=$LS; FPS[n]=$PS; FIP[n]=$IP; FNG[n]=$NEG
  FMU[n]=$MUT; FMD[n]=$MUT; FPC[n]=$PSC
  FN=$((n + 1)); LS=$ST; PS=$ST; IP=0; NEG=0
}
_pd_close() {  # leave it: the enclosing list's bookkeeping comes back
  local n=$((FN - 1))
  LS=${FLS[n]}; PS=${FPS[n]}; IP=${FIP[n]}; NEG=${FNG[n]}; FN=$n; CP=0
  if [ -n "$DK" ] && [ "$DK" != x ] && [ "$FN" -lt "$DN" ]; then DK=""; fi
  if [ "$TP" = 1 ]; then
    if [ "$FN" -eq "$TPS" ]; then TP=0
    elif [ "$FN" -lt "$TPD" ]; then TPD=$FN; TPE=0; fi
  fi
}
_pd_list() {  # a new command list starts here
  _pd_st; LS=$ST; PS=$ST; CP=1
  if [ "$TP" = 1 ] && [ "$FN" -eq "$TPD" ]; then TPE=1; fi
}
# `&`: bash backgrounds the whole and-or list (the state is the one before it,
# LS); zsh runs every pipeline of it but the LAST in this shell (the state is
# the one before that last pipeline, PS): `cd a && cd b && x &` leaves zsh in
# a/b and bash where it was. The two merge: unknown wherever they differ.
_pd_bg() { _pd_load "$PS"; _pd_merge "$LS"; SS=0; }
# An exit (or exec) is pending while TP is 1: until the list holding it ends at
# depth TPD (TPE 1), a `&` or `|` there means it ran in a background or
# pipeline subshell after all — shell-dependent, so the replay gives up.
_pd_tpipe() { [ "$TP" = 1 ] && [ "$FN" -eq "$TPD" ] && [ "$TPE" = 0 ]; }
_pd_op() {  # _pd_op <operator>
  local t="" o=$1
  [ "$FN" -gt 0 ] && t=${FTY[FN-1]}
  case $o in
    ';') _pd_eol; _pd_list ;;
    '&') _pd_eol
         if _pd_tpipe; then LOST=1; return 0; fi
         [ -n "$DK" ] || _pd_bg
         _pd_list ;;
    '&&'|'||') _pd_eol
         if [ -z "$DK" ]; then
           _pd_stat
           if [ "$o" = '&&' ]; then [ "$SS" = 0 ] || _pd_dead p
           else [ "$SS" = 1 ] || _pd_dead p; fi
         fi
         _pd_st; PS=$ST; CP=1; AO=1 ;;
    '|') if _pd_tpipe; then LOST=1; return 0; fi
         [ -n "$DK" ] || _pd_load "$PS"
         IP=1; CP=1; AO=1 ;;
    ';;') [ "$t" = case ] || { LOST=1; return 0; }
          _pd_casearm ;;
    '(') if [ "$CP" = 1 ]; then _pd_open sub; CP=1; else LOST=1; fi ;;   # name ( ) is a function
    ')') [ "$t" = sub ] || { LOST=1; return 0; }
         _pd_eol; _pd_load "${FS0[FN-1]}"; _pd_close ;;
    *) LOST=1 ;;   # ;& / ;;& — a case fall-through
  esac
}
_pd_kw() {  # _pd_kw <word> — handle a reserved word in command position; 1 when not one
  local t="" n=$((FN - 1))
  [ "$FN" -gt 0 ] && t=${FTY[n]}
  case $1 in
    '!') [ -n "$DK" ] || NEG=$((1 - NEG)) ;;
    '{') _pd_open brace ;;
    '}') [ "$t" = brace ] || { LOST=1; return 0; }
         _pd_eol; _pd_close ;;
    if) _pd_open if ;;
    then) [ "$t" = if ] || { LOST=1; return 0; }
          _pd_eol; FTH[n]=1
          if [ -z "$DK" ]; then
            _pd_stat
            if [ "$SS" = 0 ]; then FTK[n]=1; else _pd_dead a; fi
          fi
          _pd_list ;;
    elif|else) [ "$t" = if ] && [ "${FTH[n]}" = 1 ] || { LOST=1; return 0; }
          _pd_eol
          if [ -z "$DK" ]; then _pd_dead f
          elif [ "$DK" = a ] && [ "$DN" -eq "$FN" ]; then DK=""; fi
          [ "$1" = else ] || FTH[n]=0
          _pd_list ;;
    fi) [ "$t" = if ] && [ "${FTH[n]}" = 1 ] || { LOST=1; return 0; }
        _pd_eol
        if [ "$DK" = a ] && [ "$DN" -eq "$FN" ]; then SS=0; DK=""       # no arm ran
        elif [ "$DK" = f ] && [ "$DN" -eq "$FN" ]; then DK=""; fi
        _pd_close ;;
    while|until) _pd_open loop "$1" ;;
    for|select) _pd_open loop for; SKIP=do ;;
    do) [ "$t" = loop ] || { LOST=1; return 0; }
        _pd_eol; _pd_do; _pd_list ;;
    done) [ "$t" = loop ] || { LOST=1; return 0; }
          _pd_eol; _pd_done ;;
    case) _pd_open case; SKIP=in ;;
    'esac') [ "$t" = case ] || { LOST=1; return 0; }
          _pd_esac ;;
    '[[') SKIP=']]' ;;
    function|coproc) LOST=1 ;;
    *) return 1 ;;
  esac
  return 0
}
_pd_do() {  # a loop body runs (this world's first iteration) or never does
  local n=$((FN - 1)) run=1
  FMD[n]=$MUT
  [ -z "$DK" ] || return 0
  case ${FLK[n]} in
    while) _pd_stat; [ "$SS" = 0 ] || run=0 ;;
    until) _pd_stat; [ "$SS" != 0 ] || run=0 ;;
    *) _pd_pick; [ "$PICK_" = 0 ] || run=0 ;;
  esac
  if [ "$run" = 0 ]; then FBK[n]=2; _pd_dead l; fi
}
# The end of a loop. No iteration: status 0. A break: the state it left. An
# iteration that ends (done / continue) may be followed by more: when the
# condition moves nothing and the body ends where the loop began, every later
# iteration replays one this count already walks; otherwise the state is
# unknown, and a push the loop holds but this world has not made yet could run
# in a later iteration from a state no world walks — the replay gives up.
_pd_done() {
  local n=$((FN - 1))
  if [ "$DK" = l ] && [ "$DN" -eq "$FN" ]; then DK=""; fi
  if [ -z "$DK" ]; then
    case ${FBK[n]} in
      2) SS=0 ;;
      1) SS='?' ;;
      *) _pd_st
         if [ "${FMD[n]}" != "${FMU[n]}" ] || [ "$ST" != "${FS0[n]}" ]; then
           [ -n "$PF" ] || [ "$PSC" = "${FPC[n]}" ] || LOST=1
           _pd_unknown
         fi
         SS='?' ;;
    esac
  fi
  _pd_close
}
_pd_casepat() {  # a case pattern's ")": this world takes the arm here or not (`*` always)
  local n=$((FN - 1))
  FEP[n]=0
  if [ -z "$DK" ]; then
    if [ "$CPS" = 1 ]; then FTK[n]=1
    else
      _pd_pick
      if [ "$PICK_" = 0 ]; then FTK[n]=1; else _pd_dead a; fi
    fi
  fi
  CPS=0
  _pd_list
}
_pd_casearm() {  # `;;`: after the arm that ran, the rest of the case is skipped
  local n=$((FN - 1))
  _pd_eol
  if [ -z "$DK" ]; then _pd_dead f
  elif [ "$DK" = a ] && [ "$DN" -eq "$FN" ]; then DK=""; fi
  FEP[n]=1; CPS=0
}
_pd_esac() {  # close a case: no arm matching is status 0
  local n=$((FN - 1))
  _pd_eol
  if [ "$DK" = a ] && [ "$DN" -eq "$FN" ]; then SS=0; DK=""
  elif [ "$DK" = f ] && [ "$DN" -eq "$FN" ]; then DK=""
  elif [ -z "$DK" ] && [ "${FTK[n]}" != 1 ]; then SS=0; fi
  _pd_close
}
# _pd_term — exit / exec <cmd>: this shell ends here, so the CLI never reads the
# cwd back and F is the start. In a ( … ) only the subshell ends. As a pipeline
# element (or inside a compound that is one) it is shell-dependent: give up.
_pd_term() {
  local k=$((FN - 1))
  if [ "$IP" = 1 ] || { [ "${TK[i]:-}" = o ] && [ "${TV[i]:-}" = '|' ]; }; then LOST=1; return 0; fi
  while [ "$k" -ge 0 ]; do
    if [ "${FTY[k]}" = sub ]; then
      DK=s; DN=$((k + 1)); SS='?'; TP=1; TPD=$FN; TPE=0; TPS=$k
      return 0
    fi
    [ "${FIP[k]}" = 0 ] || { LOST=1; return 0; }
    k=$((k - 1))
  done
  TM=1; TP=1; TPD=$FN; TPE=0; TPS=-1; DK=x; DN=-1
}
# _pd_brk <1 break|0 continue> <first-arg-index> — this iteration of the
# innermost loop ends here. `break 2`, one in a subshell or a pipeline: give up.
_pd_brk() {
  local j=$2 k=$((FN - 1))
  if [ "$j" -lt "${#CW[@]}" ] && { [ "${CX[j]}" = 1 ] || [ "${CW[j]}" != 1 ]; }; then LOST=1; return 0; fi
  if [ "$IP" = 1 ] || { [ "${TK[i]:-}" = o ] && { [ "${TV[i]}" = '|' ] || [ "${TV[i]}" = '&' ]; }; }; then
    LOST=1; return 0
  fi
  while [ "$k" -ge 0 ] && [ "${FTY[k]}" != loop ]; do
    if [ "${FTY[k]}" = sub ] || [ "${FIP[k]}" = 1 ]; then LOST=1; return 0; fi
    k=$((k - 1))
  done
  [ "$k" -ge 0 ] || { LOST=1; return 0; }
  [ "$1" = 0 ] || FBK[k]=1
  DK=l; DN=$((k + 1))
}
_pd_asg() {  # _pd_asg <name> — an assignment the replay must know about
  case $1 in
    GIT_DIR|GIT_WORK_TREE) GDX=1 ;;   # every later push names another repo
    CDPATH|cdpath) CDX=1 ;;            # a relative cd may go anywhere
    HOME) HMX=1 ;;                     # a bare cd / ~ may go anywhere
    OLDPWD) PRV='?' ;;
    PWD) _pd_unknown ;;
  esac
}
_pd_cd() {  # _pd_cd <first-arg-index> — cd in this shell (it succeeds in this world)
  local j=$1 n=${#CW[@]} old=$CUR fl="" to
  while [ "$j" -lt "$n" ] && [ "${CX[j]}" = 0 ]; do
    case ${CW[j]} in
      --) j=$((j + 1)); break ;;
      -[0-9]*|+[0-9]*) CUR='?'; PRV=$old; DS='?'; return 0 ;;   # zsh's stack forms
      -?*) fl=$fl${CW[j]#-}; j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  if [ "$j" -ge "$n" ]; then
    if [ "$HMX" = 1 ]; then to='?'; else case ${HOME:-} in /*) to=$HOME ;; *) to='?' ;; esac; fi
  elif [ $((n - j)) -gt 1 ] || [ "${CX[j]}" = 1 ] || [ -z "${CW[j]}" ]; then
    to='?'    # zsh's `cd old new`, an expansion, an empty arg
  elif [ "${CW[j]}" = - ]; then
    to=$PRV   # OLDPWD: known only when a cd earlier in this command set it
  elif [ "$HMX" = 1 ] && [ "${CR[j]:0:1}" = '~' ]; then
    to='?'    # ~ was read against this host's HOME, which the command changed
  else
    _pd_target "${CW[j]}"; to=$JOIN_
  fi
  # -L (the default) drops `..` as text, -P resolves the path physically. The
  # last of the two wins in bash, any -P wins in zsh, so a -P before a -L is
  # unknown. Any other option is one some shell refuses (bash 3.2 takes only
  # -L/-P, zsh adds -q/-s, bash 4.3+ adds -e/-@): an error there, and no move.
  case $fl in
    *[!LP]*) CUR='?'; [ "$PRV" = "$old" ] || PRV='?'; [ -z "$DS" ] || DS='?'; return 0 ;;
    *P) _pd_cdp "$to" ;;
    *P*) SYM_='?' ;;
    *) _pd_norm "$to" ;;
  esac
  CUR=$SYM_
  PRV=$old
  [ -z "$DS" ] || DS='?'   # zsh's AUTO_PUSHD would push it
}
_pd_pushd() {  # _pd_pushd <first-arg-index>
  local j=$1 n=${#CW[@]} old=$CUR
  while [ "$j" -lt "$n" ] && [ "${CX[j]}" = 0 ]; do
    case ${CW[j]} in
      --) j=$((j + 1)); break ;;
      -n) DS='?'; return 0 ;;                                   # stack only, no move
      -[0-9]*|+[0-9]*) CUR='?'; PRV=$old; DS='?'; return 0 ;;   # rotations
      -?*) _pd_unknown; return 0 ;;   # -q -s -L -P: zsh's (it moves, -P physically); bash's pushd refuses them
      *) break ;;
    esac
  done
  if [ "$j" -ge "$n" ]; then
    case $DS in   # swap with the stack top; an empty stack is an error (bash) or $HOME (zsh)
      ''|'?') CUR='?'; DS='?' ;;
      *) CUR=${DS%%"$_E1"*}; DS="$old$_E1${DS#*"$_E1"}" ;;
    esac
  elif [ $((n - j)) -gt 1 ] || [ "${CX[j]}" = 1 ] || [ -z "${CW[j]}" ] || [ "${CW[j]}" = - ]; then
    CUR='?'; DS='?'
  else
    _pd_target "${CW[j]}"; _pd_norm "$JOIN_"; CUR=$SYM_
    [ "$DS" = '?' ] || DS="$old$_E1$DS"
  fi
  PRV=$old
}
_pd_popd() {  # _pd_popd <first-arg-index> — any argument (-n, +N) → unknown
  local old=$CUR
  if [ "$1" -lt "${#CW[@]}" ]; then CUR='?'; DS='?'
  else
    case $DS in
      ''|'?') CUR='?'; DS='?' ;;
      *) CUR=${DS%%"$_E1"*}; DS=${DS#*"$_E1"} ;;
    esac
  fi
  PRV=$old
}
# _pd_git <first-arg-index> <dir> — git never moves the shell. The first push
# this world makes sets P (raw: see _sym_at) and status 0: a push that failed
# moved no ref, so which dir it ran in never matters to the confirm. With
# --git-dir / --work-tree (either spelling), `-c core.worktree=…`, or a
# GIT_DIR / GIT_WORK_TREE assignment the repo is not the dir: P is unknown. A
# push in dead code only counts (PSC).
_pd_git() {
  local j=$1 n=${#CW[@]} d=$2 w o=$GDX
  while [ "$j" -lt "$n" ]; do
    w=${CW[j]}; j=$((j + 1))
    case $w in
      -C) [ "$j" -lt "$n" ] || break
          # relative -C dirs stack; an empty one is ignored (git's own rules)
          if [ -n "${CW[j]}" ] || [ "${CX[j]}" = 1 ]; then _pd_join "$d" "${CW[j]}" "${CX[j]}"; d=$JOIN_; fi
          j=$((j + 1)) ;;
      --git-dir|--work-tree) o=1; j=$((j + 1)) ;;
      --git-dir=*|--work-tree=*) o=1 ;;
      -c|--config-env)
          case ${CW[j]:-} in [Cc][Oo][Rr][Ee].[Ww][Oo][Rr][Kk][Tt][Rr][Ee][Ee]*|[\$\`]*) o=1 ;; esac
          j=$((j + 1)) ;;
      --config-env=[Cc][Oo][Rr][Ee].[Ww][Oo][Rr][Kk][Tt][Rr][Ee][Ee]*) o=1 ;;
      --namespace|--super-prefix|--attr-source) j=$((j + 1)) ;;
      -*) ;;
      push) [ "${CX[j - 1]}" = 0 ] || break
            PSC=$((PSC + 1))
            [ -z "$DK" ] || return 0
            if [ -z "$PF" ]; then [ "$o" = 0 ] || d='?'; P=$d; PF=1; SS=0; else SS='?'; fi
            return 0 ;;
      *) break ;;
    esac
  done
  [ -n "$DK" ] || SS='?'
}
# _pd_cmd — one simple command (CW values, CX dynamic flags, CR raw words):
# assignments and wrappers first, then the command. Behind a wrapper that execs
# a program (nohup, env, nice, timeout, stdbuf, exec) `cd` is the external
# binary and moves nothing; `builtin`/`time` keep the builtin. `command cd` is
# the builtin in bash but the external binary in zsh, and `chdir` is a zsh
# builtin bash does not have: both are unknown. Status: true/: 0, false 1, a
# cd/pushd/popd 1 when it fails and 0 when it moves, the first push 0, anything
# else unknown until something reads it.
_pd_cmd() {
  local j=0 n=${#CW[@]} ext=0 cw=0 xc=0 base=$CUR eb ENVJ w k
  while [ "$j" -lt "$n" ]; do
    case ${CR[j]} in
      [A-Za-z_]*=*) w=${CR[j]%%=*}
        case $w in *[!A-Za-z0-9_+]*) ;; *) [ -n "$DK" ] || _pd_asg "${w%+}"; j=$((j + 1)); continue ;; esac ;;
    esac
    [ "${CX[j]}" = 0 ] || break          # a command name the replay cannot know
    case ${CW[j]} in
      command) cw=1; j=$((j + 1))
        while [ "$j" -lt "$n" ]; do
          case ${CW[j]} in
            -p) j=$((j + 1)) ;;
            -v|-V) [ -n "$DK" ] || SS='?'; return 0 ;;
            --) j=$((j + 1)); break ;;
            *) break ;;
          esac
        done ;;
      builtin|noglob|nocorrect) j=$((j + 1)) ;;
      time) j=$((j + 1)); [ "${CW[j]:-}" != -p ] || j=$((j + 1)) ;;
      exec) ext=1; j=$((j + 1))
        while [ "$j" -lt "$n" ]; do
          case ${CW[j]} in -a) j=$((j + 2)) ;; --) j=$((j + 1)); break ;; -*) j=$((j + 1)) ;; *) break ;; esac
        done
        [ "$j" -ge "$n" ] || xc=1 ;;
      nohup) ext=1; j=$((j + 1)); [ "${CW[j]:-}" != -- ] || j=$((j + 1)) ;;
      env) ext=1; j=$((j + 1)); eb=$base
        # env keeps one -C (the last, from where env started) and chdir()s once
        while [ "$j" -lt "$n" ]; do
          case ${CW[j]} in
            --chdir) _pd_join "$eb" "${CW[j + 1]:-}" "${CX[j + 1]:-0}"; base=$JOIN_; j=$((j + 2)) ;;
            --chdir=*) _pd_join "$eb" "${CW[j]#--chdir=}" "${CX[j]}"; base=$JOIN_; j=$((j + 1)) ;;
            --unset|--split-string) j=$((j + 2)) ;;
            --) j=$((j + 1)); break ;;
            -|--*) j=$((j + 1)) ;;
            -*) _pd_envopt "$eb"; j=$ENVJ ;;
            *=*) [ -n "$DK" ] || _pd_asg "${CW[j]%%=*}"; j=$((j + 1)) ;;
            *) break ;;
          esac
        done ;;
      nice) ext=1; j=$((j + 1))
        case ${CW[j]:-} in -n|--adjustment) j=$((j + 2)) ;; -n*|--adjustment=*|-[0-9]*) j=$((j + 1)) ;; esac
        [ "${CW[j]:-}" != -- ] || j=$((j + 1)) ;;
      timeout|gtimeout) ext=1; j=$((j + 1))
        while [ "$j" -lt "$n" ]; do
          case ${CW[j]} in
            -k|-s|--kill-after|--signal) j=$((j + 2)) ;;
            --) j=$((j + 1)); break ;;
            -*) j=$((j + 1)) ;;               # --foreground, -v, -k5, --signal=KILL …
            *) break ;;
          esac
        done
        j=$((j + 1)) ;;                       # the duration
      stdbuf) ext=1; j=$((j + 1))
        while [ "$j" -lt "$n" ]; do
          case ${CW[j]} in -i|-o|-e) j=$((j + 2)) ;; --) j=$((j + 1)); break ;; -*) j=$((j + 1)) ;; *) break ;; esac
        done ;;
      *) break ;;
    esac
  done
  if [ -n "$DK" ]; then   # dead: a push here only counts
    if [ "$j" -lt "$n" ] && [ "${CX[j]}" = 0 ]; then
      case ${CW[j]} in git|*/git) _pd_git $((j + 1)) "$base" ;; esac
    fi
    return 0
  fi
  if [ "$j" -ge "$n" ] || [ "${CX[j]}" = 1 ]; then
    SS='?'
    [ "$xc" = 0 ] || _pd_term    # exec of a program the replay cannot name still ends the shell
    return 0
  fi
  w=${CW[j]}
  case $w in
    cd|chdir|pushd|popd)
      if [ "$ext" = 1 ]; then SS='?'    # the external binary: no move
      else
        MUT=$((MUT + 1))
        if [ "$cw" = 1 ] || [ "$w" = chdir ] || [ "$PHY" = 1 ]; then
          _pd_unknown; SS='?'   # shell-dependent (after set -P / CHASE_LINKS a cd is physical in one shell only)
        else
          _pd_pick
          if [ "$PICK_" = 1 ]; then SS=1   # it failed: no move
          else
            case $w in cd) _pd_cd $((j + 1)) ;; pushd) _pd_pushd $((j + 1)) ;; *) _pd_popd $((j + 1)) ;; esac
            SS=0
          fi
        fi
      fi ;;
    eval|source|.) SS='?'; [ "$ext" = 1 ] || { MUT=$((MUT + 1)); _pd_unknown; } ;;
    set|setopt|unsetopt|shopt) SS='?'; [ "$ext" = 1 ] || _pd_set $((j + 1)) ;;
    export|declare|typeset|readonly|local)
      SS='?'
      if [ "$ext" = 0 ]; then
        k=$((j + 1))
        while [ "$k" -lt "$n" ]; do
          w=${CW[k]%%=*}
          case $w in
            -*|+*) ;;
            *[\$\`]*) GDX=1; CDX=1; HMX=1 ;;   # a name the replay cannot read
            *) _pd_asg "${w%+}" ;;
          esac
          k=$((k + 1))
        done
      fi ;;
    exit) if [ "$ext" = 1 ]; then SS='?'; elif [ "$cw" = 1 ]; then LOST=1; else _pd_term; fi ;;
    return|trap) if [ "$ext" = 1 ]; then SS='?'; else LOST=1; fi ;;
    break) if [ "$ext" = 1 ]; then SS='?'; else _pd_brk 1 $((j + 1)); fi ;;
    continue) if [ "$ext" = 1 ]; then SS='?'; else _pd_brk 0 $((j + 1)); fi ;;
    true|:) SS=0 ;;
    false) SS=1 ;;
    git|*/git) _pd_git $((j + 1)) "$base" ;;
    *) SS='?' ;;
  esac
  if [ "$xc" = 1 ] && [ -z "$DK" ] && [ "$LOST" = 0 ]; then _pd_term; fi
}
# _pd_envopt <env-start> — one env short-option word at CW[j] (a bundle like
# -iC dir or -Cdir): -C sets the dir from <env-start>; -C -u -P -S take the
# rest of the word, else the next word. ENVJ: the index after it.
_pd_envopt() {
  local w=${CW[j]#-} c a ax=${CX[j]}
  ENVJ=$((j + 1))
  while [ -n "$w" ]; do
    c=${w:0:1}; w=${w#?}
    case $c in
      C|u|P|S)
        if [ -n "$w" ]; then a=$w
        else a=${CW[ENVJ]:-}; ax=${CX[ENVJ]:-0}; ENVJ=$((ENVJ + 1)); fi
        if [ "$c" = C ]; then _pd_join "$1" "$a" "$ax"; base=$JOIN_; fi
        return 0 ;;
    esac
  done
}
# _pd_set <first-arg-index> — set/setopt/unsetopt/shopt. An option that makes cd
# physical in some shell (bash's set -P / -o physical, zsh's set -w and
# CHASE_LINKS / CHASE_DOTS, any case, any _) makes every later cd, pushd and
# popd in the command unknown; turning one off counts too. errexit (set -e,
# ERR_EXIT, ERR_RETURN) would end the shell at a failing command, and autocd /
# cdable_vars make a bare word or a variable name a cd: the replay gives up.
_pd_set() {
  local j=$1 n=${#CW[@]} w
  while [ "$j" -lt "$n" ]; do
    [ "${CX[j]}" = 0 ] || { LOST=1; return 0; }
    w=${CW[j]//_/}; j=$((j + 1))
    case $w in
      --) return 0 ;;
      *[Ee][Rr][Rr][Ee][Xx][Ii][Tt]*|*[Ee][Rr][Rr][Rr][Ee][Tt][Uu][Rr][Nn]*) LOST=1; return 0 ;;
      *[Aa][Uu][Tt][Oo][Cc][Dd]*|*[Cc][Dd][Aa][Bb][Ll][Ee]*) LOST=1; return 0 ;;
      *[Cc][Hh][Aa][Ss][Ee]*|*[Pp][Hh][Yy][Ss][Ii][Cc][Aa][Ll]*) PHY=1 ;;
      [-+][-+]*) ;;
      -*e*) LOST=1; return 0 ;;
      [-+]*[Pw]*) PHY=1 ;;
    esac
  done
}
# _pd_walk — replay the tokens for one world. Reserved words count only
# unquoted, in command position; a for/select header, a case word and a [[ … ]]
# are skipped whole. A newline right after && || | continues the list.
_pd_walk() {
  local i=0 n
  while [ "$i" -lt "$NT" ] && [ "$LOST" = 0 ]; do
    if [ "$AO" = 1 ] && [ "${TK[i]}" = o ] && [ "${TV[i]}" = ';' ]; then i=$((i + 1)); continue; fi
    AO=0
    if [ -n "$SKIP" ]; then
      if [ "${TK[i]}" = w ] && [ "${TR[i]}" = "$SKIP" ]; then
        case $SKIP in
          in) FEP[FN-1]=1; CPS=0 ;;
          do) _pd_kw do ;;
          *) CP=0; [ -n "$DK" ] || SS='?' ;;
        esac
        SKIP=""
      fi
      i=$((i + 1)); continue
    fi
    if [ "$FN" -gt 0 ] && [ "${FEP[FN-1]}" = 1 ]; then   # a case pattern, through its ")"
      if [ "${TK[i]}" = o ] && [ "${TV[i]}" = ')' ]; then _pd_casepat
      elif [ "${TK[i]}" = w ] && [ "${TR[i]}" = esac ]; then _pd_esac
      elif [ "${TK[i]}" = w ] && [ "${TR[i]}" = '*' ]; then CPS=1; fi
      i=$((i + 1)); continue
    fi
    case ${TK[i]} in
      o) _pd_op "${TV[i]}"; i=$((i + 1)); continue ;;
      r) i=$((i + 2)); continue ;;
    esac
    if [ "$CP" = 1 ] && [ "${TR[i]}" = "${TV[i]}" ] && _pd_kw "${TV[i]}"; then
      i=$((i + 1)); continue
    fi
    CW=(); CX=(); CR=()
    while [ "$i" -lt "$NT" ]; do
      case ${TK[i]} in
        o) break ;;
        r) i=$((i + 2)); continue ;;
      esac
      n=${#CW[@]}; CW[n]=${TV[i]}; CX[n]=${TX[i]}; CR[n]=${TR[i]}
      i=$((i + 1))
    done
    CP=0
    _pd_cmd
  done
}
_pd_walk1() {  # one world, from the start S (`.`)
  PHY=0; GDX=0; CDX=0; HMX=0; FN=0; CUR=.; PRV='?'; DS=""; P=""; PF=""; LOST=0; SKIP=""; CP=1; IP=0
  NEG=0; SS=0; DK=""; DN=0; TM=0; TP=0; TPD=0; TPE=0; TPS=-1; AO=0; MUT=0; PSC=0; CPS=0
  DI=0; DT=""
  _pd_st; LS=$ST; PS=$ST
  _pd_walk
  _pd_eol
}
# ── readings ──
# _pd_world — where this world's push ran, as seen from the hook cwd F:
#   start  the command ended non-zero or by exit/exec, so F is S itself;
#   after  it ended with status 0, so F is S plus the end state CUR. A relative
#          CUR of ./../../a/b puts S two levels below F less a/b — checked
#          physically (the CLI reports `pwd -P`); a world whose cds cannot end
#          at F is not this command's world and gives no reading, unless F is
#          the project dir O and the CLI may have reset a cwd that left the
#          allowed dirs (a climb, or a check that fails) — then S is unknown.
#   veto   it ended non-zero, but a CLI that read the cwd back anyway would
#          have reported S plus CUR: that reading may only make the answer
#          unknown (when it names another existing dir), never be it.
# An unknown status gives start and after. A push dir that cannot be placed
# (relative while S is unknown, a push that climbs past what anchors S)
# poisons the answer: unknown, never a guess.
_pd_world() {
  local key="$P$_US$CUR$_US$SS$_US$TM"
  case $WK in *"$_E1$key$_E1"*) return 0 ;; esac
  WK="$WK$key$_E1"
  [ "$TM" = 0 ] || { _pd_place s "$FA" 0; return 0; }   # the shell is gone: nothing read the cwd back
  case $SS in
    0) _pd_after a ;;
    1) _pd_place s "$FA" 0; _pd_after v ;;
    *) _pd_place s "$FA" 0; _pd_after a ;;
  esac
}
_pd_after() {  # _pd_after <a|v>
  local fu fd g t
  case $CUR in
    '?') _pd_place "$1" "" 0 ;;
    /*) _sym_real "$CUR"
        if [ -n "$FP" ] && [ "$SYM_" = "$FP" ]; then _pd_place "$1" "" 0; else _pd_reset "$1"; fi ;;
    *) if [ -z "$FA" ]; then _pd_place "$1" "" 0; return 0; fi
       _sym_split "$CUR"; fu=$SPLIT_UP; fd=$SPLIT_DN; g=$FA
       if [ -n "$fd" ]; then
         t=${fd//[!\/]/}; _sym_climb "$FA" $((${#t} + 1)); g=$SYM_
         _sym_real "$g/$fd"
         if [ -z "$FP" ] || [ "$SYM_" != "$FP" ]; then _pd_reset "$1"; return 0; fi
       fi
       [ "$fu" = 0 ] || _pd_reset "$1"
       _pd_place "$1" "$g" "$fu" ;;
  esac
}
_pd_reset() { [ "$RS" = 0 ] || _pd_place "$1" "" 0; }   # F is O after a reset: S is unknown
_pd_place() {  # _pd_place <a|s|v> <dir> <n> — P, when S less its last <n> names is <dir> ("" unknown)
  case $P in
    '?') PZ=1 ;;
    /*) _sym_at "$P"; _pd_cand "$1" "$SYM_" ;;
    *) if [ -z "$2" ]; then PZ=1; return 0; fi
       _sym_split "$P"
       if [ "$SPLIT_UP" -lt "$3" ]; then PZ=1; return 0; fi
       _sym_climb "$2" $((SPLIT_UP - $3)); _sym_at "$SYM_/$SPLIT_DN"; _pd_cand "$1" "$SYM_" ;;
  esac
}
_pd_cand() {  # _pd_cand <a|s|v> <dir> — one reading; one that did not resolve (`?`) is unknown
  if [ "$2" = '?' ]; then PZ=1; else CANDS="$CANDS$1$2$_E1"; fi
}
# _pd_answer — the one existing dir the start/after readings name (how: after
# when any `after` reading names it), else unknown; a veto reading that names
# another existing dir makes it unknown too. A reading that names no existing
# dir comes from a world that cannot have run (its push would have run there)
# and is dropped; with none left the dir is unknown — never a dir that is not
# there.
_pd_answer() {
  local l e h d one="" da="" ds="" pass=1
  while :; do
    l=$CANDS
    while [ -n "$l" ]; do
      e=${l%%"$_E1"*}; l=${l#*"$_E1"}
      h=${e:0:1}; d=${e#?}
      case $pass$h in 1v|2a|2s) continue ;; esac
      _sym_real "$d"
      [ "$SYM_" != '?' ] || continue
      if [ -z "$one" ]; then one=$SYM_
      elif [ "$one" != "$SYM_" ]; then printf 'unknown\n\n'; return 0; fi
      case $h in
        a) [ -n "$da" ] || da=$d ;;
        s) [ -n "$ds" ] || ds=$d ;;
      esac
    done
    [ "$pass" = 1 ] && [ -n "$one" ] || break
    pass=2
  done
  if [ "$RCAP" = 1 ]; then printf 'unknown\n\n'
  elif [ -n "$da" ]; then printf 'after\n%s\n' "$da"
  elif [ -n "$ds" ]; then printf 'start\n%s\n' "$ds"
  else printf 'unknown\n\n'; fi
}
_pd_anypush() {  # 0 when some command in the tokens reads as `git … push` (a static scan)
  local k=0 g=0
  while [ "$k" -lt "$NT" ]; do
    case ${TK[k]} in
      o) g=0 ;;
      w) if [ "${TX[k]}" = 0 ]; then
           case ${TV[k]} in
             git|*/git) g=1 ;;
             push) [ "$g" = 0 ] || return 0 ;;
           esac
         fi ;;
    esac
    k=$((k + 1))
  done
  return 1
}
_push_dir() {
  local rest LX_LVL=0 LX_DEP=0 WV="" WX=0 WG=0 DELIM="" SYM_="" SYM_POP=0 JOIN_="" RN=0 RCK="" RCAP=0
  local SPLIT_UP=0 SPLIT_DN="" ST="" PICK_=0 NT=0 FA="" FP="" RS=0
  local DV="" DI=0 DT="" NW=0 WK="$_E1" CANDS="" PZ=0 ANYP=0 PSA=0 GIVEUP=0
  local PHY=0 GDX=0 CDX=0 HMX=0 FN=0 CUR=. PRV='?' DS="" P="" PF="" LOST=0 SKIP="" CP=1 LS="" PS="" IP=0
  local NEG=0 SS=0 DK="" DN=0 TM=0 TP=0 TPD=0 TPE=0 TPS=-1 AO=0 MUT=0 PSC=0 CPS=0
  local -a TK TV TR TX FTY FLK FS0 FEP FTK FTH FBK FLS FPS FIP FNG FMU FMD FPC CW CX CR
  LC_ALL=C   # byte-wise: every split is on ASCII, and this runs in $(…)
  set -f
  if [ "${#1}" -gt "$_PD_MAX_BYTES" ]; then printf 'long\n\n'; return 0; fi
  rest=$1
  _lx_list 1 || return 1
  case ${2:-} in /*) _sym_norm "$2"; FA=$SYM_; FP=$(cd -P -- "$FA" 2>/dev/null && pwd -P) || FP="" ;; esac
  # the CLI resets a cwd that left the allowed dirs to the project dir: only
  # possible when F is that dir
  case ${3:-} in
    /*) if [ -n "$FP" ] && [ "$(cd -P -- "$3" 2>/dev/null && pwd -P)" = "$FP" ]; then RS=1; fi ;;
  esac
  while :; do
    if [ "$NW" -ge "$_PD_MAX_WORLDS" ] || { [ "$NW" -gt 0 ] && [ $(((NW + 1) * NT)) -gt "$_PD_MAX_STEPS" ]; }; then
      GIVEUP=1; break
    fi
    NW=$((NW + 1))
    _pd_walk1
    # a function body, an unclosed compound, a construct the replay gives up on
    if [ "$LOST" = 1 ] || [ "$FN" -gt 0 ] || [ -n "$SKIP" ]; then GIVEUP=1; break; fi
    [ "$PSC" = 0 ] || PSA=1
    if [ -n "$PF" ]; then ANYP=1; _pd_world; fi
    case $DT in *0*) DV=${DT%0*}1 ;; *) break ;; esac
  done
  if [ "$GIVEUP" = 1 ]; then
    _pd_anypush || return 1
    printf 'unknown\n\n'; return 0
  fi
  if [ "$ANYP" = 0 ]; then
    [ "$PSA" = 1 ] || return 1
    printf 'unknown\n\n'; return 0   # every push it holds is in code no world runs
  fi
  if [ "$PZ" = 1 ] || [ -z "$CANDS" ]; then printf 'unknown\n\n'; return 0; fi
  _pd_answer
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
  PD_HOW=""
  if [ -n "$PUSH_CMD" ]; then
    # (a) where the command's push ran. The hook cwd is where the command
    # ended (status 0) or started (a non-zero end, exit, exec), so _push_dir
    # replays the command's cds once per world and reads each world against it:
    # `cd sub && git push` from S reports S/sub, and the push dir is that S/sub.
    # The project dir tells it when the CLI may have reset a cwd that left the
    # allowed dirs (the hook cwd is then the project dir, not the command's end).
    if PD_OUT=$(_push_dir "$PUSH_CMD" "${HOOK_ABS:-$HOOK_CWD}" "${CLAUDE_PROJECT_DIR:-}"); then
      PD_HOW=${PD_OUT%%"$_NL"*}
      case $PD_OUT in *"$_NL"*) CMD_DIR=${PD_OUT#*"$_NL"} ;; *) CMD_DIR="" ;; esac
    else
      # The parser found no git-push command. The hook only calls here with a
      # command its pre-filter matched, so this is a form the parser does not
      # model (`xargs git push`, an unterminated quote), NOT "nothing was
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
      _note "$cand" "skipped — no candidate is a git work tree (push dir '${CMD_DIR:-unknown}'$([ "$PARSE_MISS" = "1" ] && printf ' (unparsed)')$([ "$PD_HOW" = "unknown" ] && printf ' (unknowable)')$([ "$PD_HOW" = "long" ] && printf ' (command too long to parse)'), hook cwd '${HOOK_ABS:-$HOOK_CWD}', project dir '${CLAUDE_PROJECT_DIR:-}', root '${ROOT}')"
      break
    done
    exit 0
  fi
  # The note names directories, never the command text: a push command can carry
  # a credential (`git -c http.extraHeader=… push`, a token URL).
  PWT_LAUNCH_NOTE=""
  # how=start: every reading of the command that places the push ended non-zero
  # or by exit/exec, so the hook cwd is where it STARTED. Always noted.
  PD_START_WHY=" (read against the hook cwd as the START: the command ended non-zero or by exit/exec in every reading that places the push, so the CLI kept the cwd it started in)"
  if [ "$PARSE_MISS" = "1" ]; then
    PWT_LAUNCH_NOTE="no git-push segment could be parsed from the command (a form the parser does not model); used '$USED' — git state decides"
  elif [ "$PD_HOW" = "unknown" ]; then
    PWT_LAUNCH_NOTE="the push dir is unknowable from the command (a cd, -C, --git-dir or pushd/popd the replay cannot follow, a cd that may not have run, readings that disagree, or a push that precedes every cd); used '$USED' — git state decides"
  elif [ "$PD_HOW" = "long" ]; then
    PWT_LAUNCH_NOTE="the push dir is unknowable: the command is over $_PD_MAX_BYTES bytes and is not parsed; used '$USED' — git state decides"
  elif [ -n "$PUSH_CMD" ] && [ "$USED" != "$CMD_DIR" ]; then
    PD_WHY=""
    [ "$PD_HOW" = "start" ] && PD_WHY=$PD_START_WHY
    PWT_LAUNCH_NOTE="the push dir '${CMD_DIR:-unknown}' from the command${PD_WHY} is not a git work tree; used '$USED' instead"
  elif [ -n "$PUSH_CMD" ] && [ "$PD_HOW" = "start" ]; then
    PWT_LAUNCH_NOTE="used the push dir '$USED' from the command${PD_START_WHY}"
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
              # TARGET's subject is a committed tree, and subject_digest also hashes
              # the untracked .claude/ and tests/ files the run's tree held. A push
              # without them does not match, so it gets its own run: on purpose
              # (R255 194(5)), since the suite may have needed any of them and only
              # that run shows the pushed tree is green without them (the retest
              # lib's pwt_rt_untracked comment). No tracked-paths-only digest is
              # accepted. Only a 64-hex TARGET digest can match: "-" (not
              # computable) never covers, whatever a verdict holds.
              if jq -e 'has("subject_digest")' "$f" >/dev/null 2>&1; then
                [ -n "$TARGET_SUBJ" ] || TARGET_SUBJ=$(_head_subject_digest "$PUSH_TOP" 2>/dev/null) || TARGET_SUBJ=""
                [ -n "$TARGET_SUBJ" ] || TARGET_SUBJ="-"
                jq -e --arg s "$TARGET_SUBJ" \
                   '($s | test("^[0-9a-f]{64}$")) and .subject_digest == $s' \
                   "$f" >/dev/null 2>&1 || continue
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
