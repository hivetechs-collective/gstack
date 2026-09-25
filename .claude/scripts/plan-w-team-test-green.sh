#!/usr/bin/env bash
# .claude/scripts/plan-w-team-test-green.sh
#
# Deterministic "is the skill suite green?" verdict for /plan-w-team (spec T1/R2:
# docs/specs/bottom-line-loops-hardening.md).
#
# WHY THIS EXISTS
#   `make test-skill` outlives the Bash tool's 600s cap. A caller that backgrounds the
#   SUITE and greps its log sees a TRUNCATED log and can mistake it for green (memory:
#   project_test_skill_exceeds_bash_timeout — a bg run truncated mid-bats yet notified
#   "exit 0"). This wrapper inverts the contract:
#     - the WRAPPER owns the run synchronously, so callers background the WRAPPER;
#     - green requires the LITERAL trailing `SUITE_EXIT=0` marker run.sh emits (R1),
#       so a killed/truncated log is RED by construction — never green.
#
# MODES
#   (default)            run the suite, evaluate, write a verdict artifact
#   --log <path>         evaluate an EXISTING log, skip the run (fixture seam for the
#                        bats corpus; also the recovery path for an external log)
#   --check [--slug S]   read the latest verdict artifact, print one line, never run
#   --retest --slug S    rerun ONLY the failing + affected files against the full
#                        verdict S (the "base"), writing …-S--retest.json. The rerun
#                        set, caps and NEED-FULL rules live in
#                        plan-w-team-retest-lib.sh, which the commit gate sources
#                        too — docs/operations/test-green-retest.md.
#
# A FULL run (the default mode) is also hardened (2.51.0):
#   P1  make's own `make: *** [test-skill] Error N` trailer after SUITE_EXIT=N no
#       longer erases the exit code (it used to read as marker-absent); green still
#       needs the literal last line SUITE_EXIT=0.
#   P2  the watched-set manifest is hashed BEFORE and AFTER the run; any edit made
#       while the suite ran makes the verdict red (tree-changed-during-run) — the
#       digest used to be taken after the run and stamp untested edits as tested.
#   P3  the verdict records `mode` (run.sh's SUITE_MODE line) and `suite_cmd`, so the
#       gate can refuse a one-file, SKILL_SKIP_*, or substituted-command green.
#   The exact `path:blob` lines hashed are kept in …-S.manifest, so
#   sha256(manifest) == tree_digest and a retest can compute what changed since.
#   2.53.0: the wider SUBJECT manifest (tracked .claude/** + tests/**, runtime paths
#   excluded) is frozen the same way into …-S.subject-manifest / `subject_digest`; a
#   retest reruns what an unwatched change affects, and only a verdict carrying a
#   subject_digest can be a retest base. Mode/failure rows are read from the log's
#   final trailer block only (a row above it is `rows-outside-trailer`, red), and
#   TERM/INT/HUP reap the suite's process tree and release the lock (exit 128+n);
#   the suite stays in the caller's process group, so a group kill reaches it too.
#
# EXIT CODES (registry — keep in sync with tests/skill/cases/test-green-wrapper.bats)
#   0  green     (--check: latest artifact is green; --retest: also "nothing to
#                retest", the full verdict already covers this exact tree)
#   1  red       (--check: latest artifact is red)
#   2  usage     (--check: no artifact to read)
#   3  NO-SUITE  this repo carries no skill suite — no artifact written (consumers)
#   4  busy      another run holds this checkout's lock
#   5  NEED-FULL --retest only: no retest can be trusted here (no/stale/tampered
#                base, a base without subject_digest, harness or gate files changed,
#                a red base with no watched change and no PWT_TEST_RETEST_ALLOW_FLAKY,
#                rerun set over the cap, chain cap reached) — run the full suite. No
#                artifact written.
#   129/130/143  interrupted by HUP/INT/TERM — the suite was reaped, the lock
#                released, no artifact written.
#
# bash 3.2 (mac-mini /bin/bash): no `declare -A`, no `${v,,}`, no mapfile.

set -uo pipefail

STATE_FILE_PREFIX="plan-w-team-test-green"
LOCK_NAME="${STATE_FILE_PREFIX}.lock"

usage() {
  cat >&2 <<'EOF'
usage: plan-w-team-test-green.sh --slug <slug> [--log <path>]
       plan-w-team-test-green.sh --slug <slug> --retest
       plan-w-team-test-green.sh --check [--slug <slug>]

  --slug <slug>   names the verdict artifact (required unless --check); a slug
                  ending in --retest is reserved for retest verdicts
  --log <path>    evaluate an existing suite log instead of running the suite
  --retest        rerun only the failing + affected files against the full verdict
                  for <slug>; exit 5 NEED-FULL when a full run is required
  --check         print the latest verdict and exit 0 green / 1 red / 2 no-artifact

env:
  PWT_TEST_GREEN_SUITE_CMD         suite command (default: make test-skill; any
                                   other value is recorded and never gate-accepted)
  PWT_TEST_GREEN_RETEST_CMD        retest command (default: tests/skill/run.sh
                                   --retest "$PWT_RETEST_LIST"; same rule)
  PWT_TEST_RETEST_MAX_FILES        rerun-set cap (default 40)
  PWT_TEST_RETEST_MAX_CHAIN        green retests per full base (default 3)
  PWT_TEST_RETEST_BASE_MAX_AGE_S   base age cap (default PWT_TEST_GREEN_MAX_AGE_S, 86400)
EOF
  exit 2
}

# ─── ROOT RESOLUTION ────────────────────────────────────────────────────────
# Mirrors pwt-goal.sh's __pwt_main_repo_root: --git-common-dir resolves the MAIN
# checkout correctly even from inside a worktree, where --show-toplevel would return
# the caller's worktree instead.
__tg_main_repo_root() {
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

# The checkout this invocation runs in (a worktree, or main). Same precedence as
# pwt-goal.sh's GUARD_PROJECT_ROOT.
__tg_current_root() {
  printf '%s\n' "${CLAUDE_PROJECT_DIR:-${PWT_PROJECT_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
}

# Every state dir a reader might resolve, deduped, newline-separated. This is the
# dual-write set __pwt_emit_goal_state uses (worker worktree + canonical main), so the
# evaluator finds the verdict on EITHER resolution path.
__tg_state_dirs() {
  local cur main
  cur="$(__tg_current_root)"
  main="$(__tg_main_repo_root)"
  printf '%s\n' "$cur/.claude/state"
  [ "$main" != "$cur" ] && printf '%s\n' "$main/.claude/state"
  return 0
}

# Slug sanitizer. The slug reaches a FILENAME and (jq-absent) a JSON string built by
# printf, so it must never carry a quote, a brace, or a path separator. Not
# __pwt_safe_slug: that DERIVES a slug from free request text (and appends a hash) —
# here the caller already has one and the name must round-trip for --check --slug.
__tg_safe_slug() {
  printf '%s' "${1:-}" | tr -d '\n\r' | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//' | cut -c1-80
}

# ─── ARG PARSE ──────────────────────────────────────────────────────────────
SLUG=""
LOG_IN=""
CHECK=0
RETEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)   SLUG="${2:-}"; shift 2 || usage ;;
    --log)    LOG_IN="${2:-}"; shift 2 || usage ;;
    --check)  CHECK=1; shift ;;
    --retest) RETEST=1; shift ;;
    -h|--help) usage ;;
    *) echo "✗ unknown argument: $1" >&2; usage ;;
  esac
done

if [ -n "$SLUG" ]; then
  SLUG="$(__tg_safe_slug "$SLUG")"
  [ -n "$SLUG" ] || { echo "✗ --slug reduced to empty after sanitization" >&2; usage; }
  # `S--retest.json` is the retest verdict for base S. A full run under such a slug
  # would forge one (and a retest of it would nest), so the suffix is reserved.
  case "$SLUG" in
    *--retest) echo "✗ --slug may not end in --retest (reserved for retest verdicts)" >&2; usage ;;
  esac
fi
if [ "$RETEST" = "1" ] && { [ -n "$LOG_IN" ] || [ "$CHECK" = "1" ]; }; then
  echo "✗ --retest cannot be combined with --log or --check" >&2
  usage
fi

# The shared retest/manifest logic. Sourced (not executed) — the commit gate sources
# the same file, so the writer and the gate can never disagree on a manifest, a
# delta, or a rerun set. --check needs none of it.
RETEST_LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/plan-w-team-retest-lib.sh"
if [ "$CHECK" != "1" ]; then
  if [ ! -f "$RETEST_LIB" ]; then
    echo "✗ missing $RETEST_LIB — it ships beside this script (sync-to-project.sh copies both)" >&2
    exit 2
  fi
  # shellcheck source=plan-w-team-retest-lib.sh
  . "$RETEST_LIB"
fi

# ─── --check ────────────────────────────────────────────────────────────────
# Never runs the suite. Resolves across the same dual locations the writer uses; with
# no --slug, the NEWEST artifact by mtime wins.
if [ "$CHECK" = "1" ]; then
  LATEST=""
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    for f in "$dir/${STATE_FILE_PREFIX}-"*.json; do
      [ -f "$f" ] || continue
      if [ -n "$SLUG" ] && [ "$(basename "$f")" != "${STATE_FILE_PREFIX}-${SLUG}.json" ]; then
        continue
      fi
      if [ -z "$LATEST" ] || [ "$f" -nt "$LATEST" ]; then
        LATEST="$f"
      fi
    done
  done <<EOF
$(__tg_state_dirs)
EOF

  if [ -z "$LATEST" ]; then
    echo "test-green: no verdict artifact${SLUG:+ for slug $SLUG} — suite has not been run" >&2
    exit 2
  fi

  if command -v jq >/dev/null 2>&1; then
    C_SLUG=$(jq -r '.slug // "?"' "$LATEST" 2>/dev/null || echo "?")
    C_GREEN=$(jq -r '.green // false' "$LATEST" 2>/dev/null || echo "false")
    C_EXIT=$(jq -r '.suite_exit // "null"' "$LATEST" 2>/dev/null || echo "null")
    C_REASON=$(jq -r '.reason // "?"' "$LATEST" 2>/dev/null || echo "?")
    C_TS=$(jq -r '.ts // "?"' "$LATEST" 2>/dev/null || echo "?")
    C_MODE=$(jq -r '.mode // "legacy"' "$LATEST" 2>/dev/null | tr -cd 'a-z' | cut -c1-12)
  else
    # Malformed/unreadable without jq → treat as red rather than inventing green.
    C_SLUG=$(basename "$LATEST" .json); C_SLUG="${C_SLUG#"${STATE_FILE_PREFIX}-"}"
    C_GREEN=$(sed -n 's/.*"green":[[:space:]]*\([a-z]*\).*/\1/p' "$LATEST" 2>/dev/null | head -1)
    [ -n "$C_GREEN" ] || C_GREEN="false"
    C_EXIT="?"; C_REASON="?"; C_TS="?"; C_MODE="?"
  fi

  if [ "$C_GREEN" = "true" ]; then
    echo "test-green: GREEN  slug=$C_SLUG mode=${C_MODE:-?} suite_exit=$C_EXIT ts=$C_TS"
    exit 0
  fi
  echo "test-green: RED    slug=$C_SLUG mode=${C_MODE:-?} suite_exit=$C_EXIT reason=$C_REASON ts=$C_TS"
  exit 1
fi

# ─── NO-SUITE GUARD ─────────────────────────────────────────────────────────
# Consumer repos carry the skill without the source's bats harness. They must be
# UNAFFECTED: exit 3, no artifact, so every downstream reader no-ops (fail-open).
# RUN mode only — --log evaluates a log someone else produced, which is exactly the
# recovery path a repo without a runnable suite would use.
CUR_ROOT="$(__tg_current_root)"
if [ -z "$LOG_IN" ]; then
  HAVE_RUNNER=0
  HAVE_TARGET=0
  [ -f "$CUR_ROOT/tests/skill/run.sh" ] && HAVE_RUNNER=1
  if [ -f "$CUR_ROOT/Makefile" ] && grep -qE '^test-skill:' "$CUR_ROOT/Makefile" 2>/dev/null; then
    HAVE_TARGET=1
  fi
  if [ "$HAVE_RUNNER" = "0" ] || [ "$HAVE_TARGET" = "0" ]; then
    echo "NO-SUITE: no /plan-w-team skill suite in $CUR_ROOT (tests/skill/run.sh + Makefile test-skill target) — nothing to verify"
    exit 3
  fi
fi

[ -n "$SLUG" ] || { echo "✗ --slug is required" >&2; usage; }

STATE_DIR="$CUR_ROOT/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# ─── WATCHED-TREE DIGEST (content anchor for the commit gate) ───────────────
# The verdict alone only says "a suite run ended green at time T". It says nothing
# about WHAT was tested, so a gate that trusts it would happily wave through content
# edited after the run. `tree_digest` closes that: a content hash of every file in
# the watched set, so the gate can prove the suite saw exactly what is being
# committed. Content-based and therefore clock-free — the age window is belt, this
# is the braces.
#
# The glob list below is SYMMETRY-LOCKED against the identical anchored block in
# .claude/hooks/pre-commit-quality.sh (which needs it as `case` patterns to decide
# whether to consult, while this file needs it as git pathspecs). Drift would mean
# the digest covers a different file set than the trigger — asserted byte-identical
# by tests/skill/cases/pre-commit-hook-timeout.bats. If you edit one, edit both.
# BEGIN pwt-watched-globs
PWT_WATCHED_GLOBS='.claude/commands/plan-w-team*
.claude/scripts/plan-w-team-*
.claude/scripts/pwt-*
.claude/hooks/pre-commit-quality*
.claude/agents/team/*
.claude/agents/implementation/react-typescript-specialist.md
.claude/agents/implementation/rust-backend-specialist.md
.claude/scripts/secret-scan.sh
.claude/scripts/secret-doc-sync.sh
tests/skill/*'
# END pwt-watched-globs

# Digest of WORKING-TREE content over the watched set: the sha256 of the manifest
# (`«path»:«git blob hash»` per file, sorted by path, LC_ALL=C) that
# pwt_rt_manifest builds in the shared lib — byte-for-byte the input this function
# hashed before the lib existed, so older digests still compare equal.
# `--others --exclude-standard` includes untracked-but-not-ignored files, so a brand
# new test file the suite just ran is covered too — without it, `git add`ing that
# file after the run would change the file LIST and mismatch every time.
# An EMPTY watched set produces NO digest: shasum of nothing is a perfectly
# well-formed hash, and the gate would recompute that same hash from its own empty
# enumeration and call it a match — a broken glob list would corroborate itself.
# __tg_manifest <root> — the manifest itself, for the before/after freeze (P2).
__tg_manifest() {
  pwt_rt_manifest "$1" worktree "$PWT_WATCHED_GLOBS"
}
# Prints an empty string on any failure; the caller validates the shape.
__tg_tree_digest() {
  __tg_manifest "$1" | pwt_rt_digest
}

# ─── LOCK (repo-root-keyed, not slug-keyed) ─────────────────────────────────
# The suite mutates shared PER-CHECKOUT resources (tests/skill/results/latest.json,
# the .bats tmp tree, the R6 state-leak bracket), so two runs in one checkout corrupt
# each other's verdict regardless of slug. mkdir is the atomic primitive (same idiom as
# 05-ship.md's PUSH_LOCK_DIR). --log takes no lock: it runs nothing.
LOCK_HELD=0
if [ -z "$LOG_IN" ]; then
  LOCK_DIR="$STATE_DIR/$LOCK_NAME"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "✗ another test-green run holds the lock for this checkout: $LOCK_DIR" >&2
    echo "  the skill suite mutates per-checkout resources; wait for it or remove a stale lock." >&2
    exit 4
  fi
  LOCK_HELD=1
  printf 'pid=%s\nstarted=%s\nslug=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SLUG" \
    > "$LOCK_DIR/holder" 2>/dev/null || true
fi

TG_TMP=""
cleanup() {
  if [ "$LOCK_HELD" = "1" ] && [ -n "${LOCK_DIR:-}" ]; then
    rm -f "$LOCK_DIR/holder" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=0
  fi
  [ -n "$TG_TMP" ] && rm -rf "$TG_TMP" 2>/dev/null
  return 0
}

# ─── SIGNALS (retro row 185) ────────────────────────────────────────────────
# The suite runs as a background job that this script `wait`s on, so a TERM / INT /
# HUP is handled at once: the suite's whole process TREE is reaped (TERM, a grace
# period, then KILL), then the per-checkout lock and the temp dir are released, and
# the script exits 128+n WITHOUT writing a verdict. Before this, `trap cleanup … INT
# TERM` ran cleanup and RETURNED: bash defers a trap until a foreground child exits,
# so a killed wrapper left the suite running unowned, and when the trap did fire it
# released the lock mid-run while the script carried on and wrote a verdict with no
# lock held.
#
# The job stays in THIS script's process group (no `set -m`). Whoever owns the
# wrapper's group can still take the suite down with it: plan-w-team-verify-run.sh's
# `kill -KILL -PGID` after its grace period, `timeout -s KILL`, a tool hard-kill, a
# terminal's Ctrl-C. A private suite group (the first 2.53.0 draft) survived every
# one of those, orphaning a 15-minute suite on a host the F2 host-load protection
# was trying to relieve. The trap therefore reaps by TREE (`pgrep -P`), never by
# group: the group may hold the caller too, and a group some test created for itself
# below the suite is still in the tree.
#
# PWT_DISABLE_TEST_GREEN_SIGNAL_REAP=1 runs the suite in the foreground as before
# (no trap-time reap: the signal waits for the suite); the lock is still released.
__TG_CHILD=""
__TG_REAP_GRACE_S="$(pwt_rt_int "${PWT_TEST_GREEN_REAP_GRACE_S:-}" 5)"

# __tg_tree <pid>... — every given pid that is still alive, each followed by its
# descendants (a depth-first `pgrep -P` walk; plain recursion, bash 3.2). Without
# pgrep the walk degrades to the given pids alone.
__tg_tree() {
  local p
  for p in "$@"; do
    kill -0 "$p" 2>/dev/null || continue
    printf '%s\n' "$p"
    # shellcheck disable=SC2046  # pids are digits; the word splitting is the point
    __tg_tree $(pgrep -P "$p" 2>/dev/null)
  done
}

__tg_reap_child() {
  local c="$__TG_CHILD" pids i=0
  __TG_CHILD=""
  [ -n "$c" ] || return 0
  # Snapshot the WHOLE tree before the first signal: a parent that dies first hands
  # its children to init, where a walk from here could no longer find them.
  pids=$(__tg_tree "$c" | LC_ALL=C sort -un)
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086  # a list of pids
  kill -TERM $pids 2>/dev/null
  while :; do
    # Walk again from every pid still alive: an orphaned subtree is reached from its
    # own root, and anything forked since the TERM (a cleanup trap) joins the set.
    # (A pid that died and was reused inside this few-second window is the accepted
    # residual; a pid space does not wrap that fast.)
    # shellcheck disable=SC2086
    pids=$(__tg_tree $pids | LC_ALL=C sort -un)
    [ -n "$pids" ] || return 0
    [ "$i" -lt "$__TG_REAP_GRACE_S" ] || break
    sleep 1
    i=$((i + 1))
  done
  # shellcheck disable=SC2086
  kill -KILL $pids 2>/dev/null
  return 0
}
__tg_on_signal() {  # __tg_on_signal <NAME> <exit code>
  trap '' INT TERM HUP
  echo "✗ test-green: interrupted by SIG$1 — reaping the suite and releasing the lock; no verdict written" >&2
  __tg_reap_child
  cleanup
  exit "$2"
}
trap cleanup EXIT
trap '__tg_on_signal INT 130' INT
trap '__tg_on_signal TERM 143' TERM
trap '__tg_on_signal HUP 129' HUP

# The suite's SIGINT / SIGQUIT go back to their defaults before it starts. POSIX
# starts a background job of a shell without job control with both IGNORED, bash
# 3.2 cannot undo that inside the job's subshell (`trap - INT` keeps the inherited
# ignore), and no shell below can trap a signal ignored on entry. Without this, a
# corpus case that interrupts its own child, or a runner's own Ctrl-C handler, would
# behave differently under the wrapper than under a plain `make test-skill`. perl is
# the exec shim (macOS and Debian's base system both ship it). On a host without
# perl, python3 does the same two resets and then os.execvp (R255 195(4)). With
# neither, the suite runs with both ignored, as it did before the shim; the wrapper
# says so once on stderr, and this script's trap still reaps the suite on INT.
#
# python3 must also undo what CPython itself changes, or the suite inherits it
# through the exec, where the perl shim and a plain `sh -c` change nothing:
# - CPython ignores SIGPIPE and SIGXFSZ at startup, and exec keeps an ignored
#   disposition. A suite with SIGPIPE ignored sees `yes | head -1` exit 1 with
#   "Broken pipe" instead of 141, and a shell loop writing into `head` never ends.
#   The shim sets both back to their defaults.
# - Under the C/POSIX locale CPython coerces LC_CTYPE (PEP 538) and exports it,
#   so everything it execs runs with LC_CTYPE=C.UTF-8. PYTHONCOERCECLOCALE=0 turns
#   that off, and the shim then puts the caller's own PYTHONCOERCECLOCALE back
#   (argv[1] says whether it was set, argv[2] holds its value).
# macOS's /usr/bin/python3 adds variables of its own (SDKROOT, …), but macOS ships
# perl, so it never gets here.
# shellcheck disable=SC2016  # perl code, expanded by perl
__TG_SIGDFL_PL='$SIG{INT} = $SIG{QUIT} = "DEFAULT"; exec { $ARGV[0] } @ARGV or exit 127;'
__TG_SIGDFL_PY='import os, signal, sys
for n in ("SIGINT", "SIGQUIT", "SIGPIPE", "SIGXFSZ"):
    if hasattr(signal, n):
        signal.signal(getattr(signal, n), signal.SIG_DFL)
if sys.argv[1]:
    os.environ["PYTHONCOERCECLOCALE"] = sys.argv[2]
else:
    os.environ.pop("PYTHONCOERCECLOCALE", None)
try:
    os.execvp(sys.argv[3], sys.argv[3:])
except OSError:
    sys.exit(127)'
__TG_SIGDFL_SHIM=""   # perl | python3 | none: chosen once, in this shell, by __tg_pick_shim
# __tg_pick_shim — choose the exec shim BEFORE the job starts, so the job's
# subshell (whose stderr is the suite log) never has to decide, and the "neither"
# warning reaches the operator once. python3 is taken only when it actually runs:
# macOS ships a /usr/bin/python3 stub that exits non-zero without the developer
# tools, and exec'ing that would lose the whole suite.
__tg_pick_shim() {
  [ -z "$__TG_SIGDFL_SHIM" ] || return 0
  if command -v perl >/dev/null 2>&1; then
    __TG_SIGDFL_SHIM="perl"
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import os, signal, sys' >/dev/null 2>&1; then
    __TG_SIGDFL_SHIM="python3"
  else
    __TG_SIGDFL_SHIM="none"
    echo "⚠ test-green: neither perl nor python3 is available — the suite runs with SIGINT and SIGQUIT ignored, so a case that traps them behaves differently than under a plain make test-skill" >&2
  fi
  return 0
}
__tg_exec_suite() {  # __tg_exec_suite <command> — (the job's subshell only) exec `sh -c`
  # python3's arguments expand BEFORE its prefix assignment applies, on purpose:
  # they carry the caller's PYTHONCOERCECLOCALE for the shim to restore.
  # shellcheck disable=SC2097,SC2098
  case "$__TG_SIGDFL_SHIM" in
    perl)    exec perl -e "$__TG_SIGDFL_PL" -- sh -c "$1" ;;
    python3) PYTHONCOERCECLOCALE=0 exec python3 -c "$__TG_SIGDFL_PY" \
               "${PYTHONCOERCECLOCALE+1}" "${PYTHONCOERCECLOCALE-}" sh -c "$1" ;;
  esac
  exec sh -c "$1"
}

# __tg_run <log> <command> [retest_list] — run <command> (`sh -c`, from CUR_ROOT)
# with stdout+stderr to <log> as a background job in this script's process group,
# and wait for it. Returns the command's raw exit code (never the verdict — the log
# decides that). stdin is /dev/null, as it is for any background job of a shell
# without job control (and a bg worker's stdin is /dev/null anyway).
__tg_run() {
  local log="$1" cmd="$2" list="${3:-}" rc
  if [ "${PWT_DISABLE_TEST_GREEN_SIGNAL_REAP:-0}" = "1" ]; then
    if [ -n "$list" ]; then
      ( cd "$CUR_ROOT" && PWT_RETEST_LIST="$list" sh -c "$cmd" ) > "$log" 2>&1
    else
      ( cd "$CUR_ROOT" && sh -c "$cmd" ) > "$log" 2>&1
    fi
    return $?
  fi
  __tg_pick_shim
  if [ -n "$list" ]; then
    ( cd "$CUR_ROOT" && PWT_RETEST_LIST="$list" __tg_exec_suite "$cmd" ) < /dev/null > "$log" 2>&1 &
  else
    ( cd "$CUR_ROOT" && __tg_exec_suite "$cmd" ) < /dev/null > "$log" 2>&1 &
  fi
  __TG_CHILD=$!
  wait "$__TG_CHILD"
  rc=$?
  __TG_CHILD=""
  return "$rc"
}
TG_TMP=$(mktemp -d -t pwt-test-green.XXXXXX 2>/dev/null) || TG_TMP=""

# ─── LOAD ANNOTATION (F5, 2026-08-19 incident) ──────────────────────────────
# `duration_s` alone cannot distinguish "this suite is slow" from "this host was
# saturated when the suite ran". The incident measured the SAME battery command
# at 229 / 252 / 302 / 454 seconds purely by load, and every one of those numbers
# was recorded without the context needed to read it. Record the load beside the
# duration so an over-budget verdict can be annotated `load-suspect` instead of
# being mistaken for a performance regression.
#
# OBSERVABILITY ONLY — this changes no gate. `green` is still decided solely by
# the trailing SUITE_EXIT marker. Shared by the full and the retest verdicts.
__tg_load_annotation() {
  LOAD_1M="null"; NCPU="null"; LOAD_SUSPECT="null"
  if [ "${PWT_DISABLE_LOAD_ANNOTATION:-0}" != "1" ]; then
    HH="$CUR_ROOT/.claude/scripts/plan-w-team-host-health.sh"
    [ -x "$HH" ] || HH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/plan-w-team-host-health.sh"
    if [ -x "$HH" ] && command -v jq >/dev/null 2>&1; then
      HH_JSON=$("$HH" --repo-root "$CUR_ROOT" 2>/dev/null || echo "")
      if [ -n "$HH_JSON" ]; then
        # NOT `// "null"`: jq's alternative operator fires on `false` as well as
        # `null`, so `.load_suspect // "null"` rewrites every honest `false` into
        # `null` — silently deleting the "this run was NOT load-suspect" evidence,
        # which is precisely the reading this annotation exists to support.
        LOAD_1M=$(printf '%s' "$HH_JSON"      | jq -r 'if .load_1m == null then "null" else .load_1m end' 2>/dev/null || echo "null")
        NCPU=$(printf '%s' "$HH_JSON"         | jq -r 'if .ncpu == null then "null" else .ncpu end' 2>/dev/null || echo "null")
        LOAD_SUSPECT=$(printf '%s' "$HH_JSON" | jq -r 'if .load_suspect == null then "null" else .load_suspect end' 2>/dev/null || echo "null")
      fi
    fi
    # Shape-guard every value: they are interpolated as BARE JSON below, so a
    # surprise string would produce a malformed artifact that every reader then
    # treats as "unreadable verdict".
    case "$LOAD_1M"      in ''|*[!0-9.]*) LOAD_1M="null" ;; esac
    case "$NCPU"         in ''|*[!0-9]*)  NCPU="null" ;; esac
    case "$LOAD_SUSPECT" in true|false) : ;; *) LOAD_SUSPECT="null" ;; esac
  fi
  return 0
}

# __tg_verdict_from_log <log> — sets SUITE_EXIT / JSON_EXIT / GREEN / REASON from
# the marker. Green ONLY on a literal last line `SUITE_EXIT=0` (strict). A red run
# whose log ends in make's own error trailer keeps its real exit code (P1: it used
# to read as marker-absent with a null suite_exit); SUITE_EXIT=0 followed by such a
# trailer is red (`marker-not-last`) — the run did not end at the gate.
__tg_verdict_from_log() {
  local m n kind
  m="$(pwt_rt_marker "$1" 2>/dev/null)"
  SUITE_EXIT=""
  if [ -z "$m" ]; then
    GREEN="false"; REASON="marker-absent"; JSON_EXIT="null"
    return 0
  fi
  n="${m%% *}"; kind="${m#* }"
  SUITE_EXIT="$n"; JSON_EXIT="$n"
  if [ "$n" -ne 0 ]; then
    GREEN="false"; REASON="suite-exit-nonzero"
  elif [ "$kind" = "strict" ]; then
    GREEN="true"; REASON="ok"
  else
    GREEN="false"; REASON="marker-not-last"
  fi
  return 0
}

# __tg_shape_mode <raw> — only the four modes run.sh emits are recorded verbatim;
# anything else from an imported log is `unknown`, and absence stays empty.
__tg_shape_mode() {
  case "${1:-}" in
    full|file|retest|partial) printf '%s\n' "$1" ;;
    "") printf '\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# __tg_json_list <file> — a JSON array of the file's non-empty lines (jq required).
__tg_json_list() {
  if [ -s "$1" ]; then
    grep -v '^$' "$1" | jq -R . | jq -s -c . 2>/dev/null || echo '[]'
  else
    echo '[]'
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# RETEST MODE — rerun only the failing + affected files against ONE full base.
# Every "is this retest honest?" rule lives in plan-w-team-retest-lib.sh, which the
# commit gate sources too and re-applies to the STAGED tree. Anything this branch
# cannot prove exits 5 NEED-FULL and writes nothing.
# ════════════════════════════════════════════════════════════════════════════
if [ "$RETEST" = "1" ]; then
  __need_full() {  # __need_full <reason> [hint line]
    echo "NEED-FULL: $1" >&2
    [ -n "${2:-}" ] && echo "  $2" >&2
    echo "  a targeted retest cannot be trusted here — run the full suite:" >&2
    echo "    .claude/scripts/plan-w-team-test-green.sh --slug $SLUG" >&2
    exit 5
  }
  command -v jq >/dev/null 2>&1 || __need_full "jq is required for a retest"
  command -v shasum >/dev/null 2>&1 || __need_full "shasum is required for a retest"
  [ -n "$TG_TMP" ] || __need_full "could not create a temp dir"

  BASE_JSON="$STATE_DIR/${STATE_FILE_PREFIX}-${SLUG}.json"
  RT_MAX_AGE="$(pwt_rt_int "${PWT_TEST_RETEST_BASE_MAX_AGE_S:-}" "$(pwt_rt_int "${PWT_TEST_GREEN_MAX_AGE_S:-}" 86400)")"
  # 1. the base: a full, witnessed, fresh, self-verifying run with attributable failures
  pwt_rt_check_base "$BASE_JSON" "$RT_MAX_AGE" || __need_full "$PWT_RT_ERR"

  # 2. the change set Δ since the base, frozen BEFORE the retest runs
  __tg_manifest "$CUR_ROOT" > "$TG_TMP/cur.man" 2>/dev/null
  [ -s "$TG_TMP/cur.man" ] || __need_full "the watched-set manifest could not be computed"
  pwt_rt_delta "$PWT_RT_BASE_MANIFEST" "$TG_TMP/cur.man" > "$TG_TMP/delta" \
    || __need_full "the change set since the base could not be computed"
  # 2b. the SUBJECT delta (review -1): tracked .claude/** + tests/** beyond the watched
  # globs. Its unwatched half feeds the rerun set exactly like a watched change.
  pwt_rt_subject_manifest "$CUR_ROOT" worktree > "$TG_TMP/cur.sman" 2>/dev/null
  [ -s "$TG_TMP/cur.sman" ] || __need_full "the subject manifest could not be computed"
  pwt_rt_delta "$PWT_RT_BASE_SUBJECT_MANIFEST" "$TG_TMP/cur.sman" > "$TG_TMP/sdelta" \
    || __need_full "the subject change set since the base could not be computed"
  pwt_rt_unwatched "$TG_TMP/sdelta" "$PWT_WATCHED_GLOBS" > "$TG_TMP/udelta" \
    || __need_full "the unwatched change set could not be computed"

  # 3. harness / gate machinery in Δ → a partial run never certifies its own gate
  if RT_OFFENDER="$(pwt_rt_needs_full "$TG_TMP/delta")"; then
    __need_full "the change set touches the harness or the gate machinery ($RT_OFFENDER)"
  fi

  pwt_rt_parse_failures "$PWT_RT_BASE_LOG" > "$TG_TMP/basefailed" \
    || __need_full "the base log has an unattributed or leak failure"

  # 6 (early). Nothing changed and nothing failed: the full verdict IS the verdict.
  if [ ! -s "$TG_TMP/delta" ] && [ ! -s "$TG_TMP/udelta" ] && [ ! -s "$TG_TMP/basefailed" ]; then
    echo "test-green --retest: nothing to retest — the green full verdict '$SLUG' already covers this exact tree"
    # An older retest verdict for this base (from a since-reverted tweak) would still be
    # the newest verdict by mtime and make the gate block this exact, fully-green tree.
    RT_STALE="$STATE_DIR/${STATE_FILE_PREFIX}-${SLUG}--retest.json"
    if [ -f "$RT_STALE" ]; then
      rm -f "$RT_STALE" "${RT_STALE%.json}.manifest" "${RT_STALE%.json}.subject-manifest" 2>/dev/null || true
      echo "test-green --retest: removed the superseded retest verdict for '$SLUG'"
    fi
    exit 0
  fi

  # 3b. a red base with NO watched change is a flaky pass, not a fix (review -3). The
  # gate is consulted only for watched paths, so an unwatched edit cannot be what a
  # watched-set commit is certified by: NEED-FULL unless the operator opts in, and the
  # verdict then records classification=flaky, which the gate refuses without the
  # same opt-in in ITS environment.
  RT_CLASS="fix"
  if [ "$PWT_RT_BASE_GREEN" != "true" ] && [ ! -s "$TG_TMP/delta" ]; then
    RT_CLASS="flaky"
    if [ "${PWT_TEST_RETEST_ALLOW_FLAKY:-0}" != "1" ]; then
      RT_WHY="the full run '$SLUG' is red and no watched file changed since — a pass now would be a flaky pass, not a fix"
      if [ -s "$TG_TMP/udelta" ]; then
        RT_WHY="$RT_WHY (only unwatched files changed: $(head -5 "$TG_TMP/udelta" | tr '\n' ' '))"
      fi
      __need_full "$RT_WHY" "to accept a flaky pass knowingly: PWT_TEST_RETEST_ALLOW_FLAKY=1 (the commit gate needs it too)"
    fi
  fi

  # 4. the rerun set R
  pwt_rt_required "$CUR_ROOT" "$TG_TMP/basefailed" "$TG_TMP/delta" "$PWT_RT_BASE_GREEN" \
      "$PWT_RT_BASE_MANIFEST" "$TG_TMP/cur.man" "$TG_TMP/udelta" \
    > "$TG_TMP/required" 2> "$TG_TMP/required.err"
  RT_RC=$?
  if [ "$RT_RC" -ne 0 ] || [ ! -s "$TG_TMP/required" ]; then
    __need_full "the rerun set could not be built: $(head -3 "$TG_TMP/required.err" 2>/dev/null | tr '\n' ' ')"
  fi

  # 5. caps
  RT_N="$(grep -c . "$TG_TMP/required")"
  if [ "$RT_N" -gt "$PWT_RT_MAX_FILES" ]; then
    __need_full "the rerun set has $RT_N files (> PWT_TEST_RETEST_MAX_FILES=$PWT_RT_MAX_FILES) — that is not a targeted retest any more"
  fi
  RT_PREV="$STATE_DIR/${STATE_FILE_PREFIX}-${SLUG}--retest.json"
  RT_PREV_CHAIN=0
  if [ -f "$RT_PREV" ] && jq -e . "$RT_PREV" >/dev/null 2>&1; then
    if [ "$(jq -r '.base.ts // ""' "$RT_PREV")" = "$PWT_RT_BASE_TS" ] \
       && [ "$(jq -r '.base.tree_digest // ""' "$RT_PREV")" = "$PWT_RT_BASE_DIGEST" ]; then
      RT_PREV_CHAIN="$(pwt_rt_int "$(jq -r '.chain // 0' "$RT_PREV" 2>/dev/null)" 0)"
    fi
  fi
  if [ "$RT_PREV_CHAIN" -ge "$PWT_RT_MAX_CHAIN" ]; then
    __need_full "$RT_PREV_CHAIN green retests already rest on the full run '$SLUG' (PWT_TEST_RETEST_MAX_CHAIN=$PWT_RT_MAX_CHAIN)"
  fi

  # 7. run
  RT_LIST="$STATE_DIR/${STATE_FILE_PREFIX}-${SLUG}--retest.list"
  RT_LOG="$STATE_DIR/${STATE_FILE_PREFIX}-${SLUG}--retest.log"
  RT_MANIFEST="$STATE_DIR/${STATE_FILE_PREFIX}-${SLUG}--retest.manifest"
  RT_SMANIFEST="$STATE_DIR/${STATE_FILE_PREFIX}-${SLUG}--retest.subject-manifest"
  cp "$TG_TMP/required" "$RT_LIST" 2>/dev/null || __need_full "could not write $RT_LIST"
  RT_CMD="${PWT_TEST_GREEN_RETEST_CMD:-$PWT_RT_DEFAULT_RETEST_CMD}"
  echo "→ test-green --retest: $RT_N file(s) against full run '$SLUG' (log: $RT_LOG)"
  sed 's/^/    /' "$TG_TMP/required"
  START_EPOCH=$(date +%s)
  __tg_run "$RT_LOG" "$RT_CMD" "$RT_LIST"
  echo "→ test-green --retest: finished (raw exit $?)"
  DURATION=$(( $(date +%s) - START_EPOCH ))

  # 8. freeze check — an edit while the retest ran means it tested something else.
  # Both manifests: an unwatched file the rerun set was built from counts too.
  __tg_manifest "$CUR_ROOT" > "$TG_TMP/after.man" 2>/dev/null
  pwt_rt_subject_manifest "$CUR_ROOT" worktree > "$TG_TMP/after.sman" 2>/dev/null
  RT_TREE_CHANGED=0
  cmp -s "$TG_TMP/cur.man" "$TG_TMP/after.man" || RT_TREE_CHANGED=1
  cmp -s "$TG_TMP/cur.sman" "$TG_TMP/after.sman" || RT_TREE_CHANGED=1

  # 9. decide
  __tg_verdict_from_log "$RT_LOG"
  RT_TRAILER_RC=0
  pwt_rt_trailer "$RT_LOG" >/dev/null 2>&1 || RT_TRAILER_RC=$?
  RT_MODE="$(__tg_shape_mode "$(pwt_rt_log_mode "$RT_LOG")")"
  pwt_rt_ran "$RT_LOG" > "$TG_TMP/ran"
  LC_ALL=C comm -23 "$TG_TMP/required" "$TG_TMP/ran" > "$TG_TMP/missing"
  if [ "$RT_TREE_CHANGED" = "1" ]; then
    GREEN="false"; REASON="tree-changed-during-run"
  elif [ "$GREEN" = "true" ] && [ "$RT_TRAILER_RC" = "2" ]; then
    GREEN="false"; REASON="rows-outside-trailer"
  elif [ "$GREEN" = "true" ] && [ "$RT_MODE" != "retest" ]; then
    GREEN="false"; REASON="mode-mismatch"
  elif [ "$GREEN" = "true" ] && [ -s "$TG_TMP/missing" ]; then
    GREEN="false"; REASON="required-not-run"
  fi

  RT_CHAIN="$RT_PREV_CHAIN"
  [ "$GREEN" = "true" ] && RT_CHAIN=$((RT_PREV_CHAIN + 1))
  # RT_CLASS was decided at 3b (flaky = red base, no watched change).
  RT_DIGEST=""
  RT_SDIGEST=""
  if [ "$RT_TREE_CHANGED" = "0" ]; then
    RT_DIGEST="$(pwt_rt_digest "$TG_TMP/cur.man")"
    pwt_rt_is_hex64 "$RT_DIGEST" || RT_DIGEST=""
    RT_SDIGEST="$(pwt_rt_digest "$TG_TMP/cur.sman")"
    pwt_rt_is_hex64 "$RT_SDIGEST" || RT_SDIGEST=""
  fi
  RT_MANIFEST_PATH=""
  if [ -n "$RT_DIGEST" ] && cp "$TG_TMP/cur.man" "$RT_MANIFEST" 2>/dev/null; then
    RT_MANIFEST_PATH="$RT_MANIFEST"
  else
    rm -f "$RT_MANIFEST" 2>/dev/null
  fi
  RT_SMANIFEST_PATH=""
  if [ -n "$RT_SDIGEST" ] && cp "$TG_TMP/cur.sman" "$RT_SMANIFEST" 2>/dev/null; then
    RT_SMANIFEST_PATH="$RT_SMANIFEST"
  else
    RT_SDIGEST=""
    rm -f "$RT_SMANIFEST" 2>/dev/null
  fi
  pwt_rt_parse_failures "$RT_LOG" > "$TG_TMP/rtfailed" 2>/dev/null || true
  # Bind the log to the verdict: the gate reads RETEST_RAN rows from this log, and
  # the log sits outside the lane guard's trusted-artifact json — only this hash
  # makes an appended row detectable (pwt_rt_log_bound).
  RT_LOG_SHA256="$(pwt_rt_sha256_file "$RT_LOG")"
  pwt_rt_is_hex64 "$RT_LOG_SHA256" || RT_LOG_SHA256=""
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  __tg_load_annotation

  # 10. the verdict — CURRENT checkout only. Never dual-written: a retest is
  # measured against this checkout's base and describes this checkout's tree.
  RT_FILE="$STATE_DIR/${STATE_FILE_PREFIX}-${SLUG}--retest.json"
  RT_TMPF="$RT_FILE.tmp.$$"
  if jq -n \
      --arg ts "$TS" \
      --arg slug "${SLUG}--retest" \
      --arg suite_cmd "$RT_CMD" \
      --arg reason "$REASON" \
      --arg log_path "$RT_LOG" \
      --arg log_sha256 "$RT_LOG_SHA256" \
      --arg tree_digest "$RT_DIGEST" \
      --arg manifest_path "$RT_MANIFEST_PATH" \
      --arg subject_digest "$RT_SDIGEST" \
      --arg subject_manifest_path "$RT_SMANIFEST_PATH" \
      --arg classification "$RT_CLASS" \
      --arg b_slug "$SLUG" \
      --arg b_ts "$PWT_RT_BASE_TS" \
      --arg b_digest "$PWT_RT_BASE_DIGEST" \
      --arg b_log "$PWT_RT_BASE_LOG" \
      --arg b_manifest "$PWT_RT_BASE_MANIFEST" \
      --arg b_sdigest "$PWT_RT_BASE_SUBJECT_DIGEST" \
      --arg b_smanifest "$PWT_RT_BASE_SUBJECT_MANIFEST" \
      --argjson b_green "$PWT_RT_BASE_GREEN" \
      --argjson suite_exit "$JSON_EXIT" \
      --argjson green "$GREEN" \
      --argjson duration_s "$DURATION" \
      --argjson chain "$RT_CHAIN" \
      --argjson required "$(__tg_json_list "$TG_TMP/required")" \
      --argjson retested "$(__tg_json_list "$TG_TMP/ran")" \
      --argjson delta "$(__tg_json_list "$TG_TMP/delta")" \
      --argjson delta_unwatched "$(__tg_json_list "$TG_TMP/udelta")" \
      --argjson failed "$(__tg_json_list "$TG_TMP/rtfailed")" \
      --argjson load_1m "$LOAD_1M" \
      --argjson ncpu "$NCPU" \
      --argjson load_suspect "$LOAD_SUSPECT" \
      '{ts:$ts, slug:$slug, mode:"retest", suite_cmd:$suite_cmd, suite_exit:$suite_exit,
        green:$green, reason:$reason, log_path:$log_path, log_sha256:$log_sha256,
        duration_s:$duration_s, tree_digest:$tree_digest, manifest_path:$manifest_path,
        subject_digest:$subject_digest, subject_manifest_path:$subject_manifest_path, chain:$chain,
        classification:$classification,
        base:{slug:$b_slug, ts:$b_ts, tree_digest:$b_digest, log_path:$b_log,
              manifest_path:$b_manifest, subject_digest:$b_sdigest,
              subject_manifest_path:$b_smanifest, green:$b_green},
        required:$required, retested:$retested, delta:$delta,
        delta_unwatched:$delta_unwatched, failed:$failed}
       + (if $load_suspect == null and $load_1m == null and $ncpu == null then {}
          else {load_1m:$load_1m, ncpu:$ncpu, load_suspect:$load_suspect} end)' \
      > "$RT_TMPF" 2>/dev/null && mv -f "$RT_TMPF" "$RT_FILE" 2>/dev/null; then
    echo "  test-green retest verdict:  $RT_FILE"
  else
    rm -f "$RT_TMPF" 2>/dev/null
    echo "✗ test-green --retest: could not write $RT_FILE" >&2
    exit 1
  fi

  if [ "$GREEN" = "true" ]; then
    echo "✓ test-green --retest: GREEN ($RT_N file(s), chain $RT_CHAIN/$PWT_RT_MAX_CHAIN, ${DURATION}s)"
    if [ "$RT_CLASS" = "flaky" ]; then
      echo "⚠ FLAKY (accepted via PWT_TEST_RETEST_ALLOW_FLAKY=1): no watched file changed since the full run '$SLUG' and its failing file(s) now pass:"
      sed 's/^/    /' "$TG_TMP/basefailed"
      echo "  the commit gate refuses this verdict unless PWT_TEST_RETEST_ALLOW_FLAKY=1 is set for it too."
      echo "  a flaky test is a defect — fix it now, not later."
    fi
    echo "  the push to the default branch still gets a full confirm run (post-push, detached)."
    exit 0
  fi
  case "$REASON" in
    tree-changed-during-run)
      echo "✗ test-green --retest: RED — watched or subject files changed while the retest ran; it tested something else. Re-run it on a still tree." >&2 ;;
    rows-outside-trailer)
      echo "✗ test-green --retest: RED — the log carries SUITE_MODE / RETEST_RAN / SUITE_FAILED / SUITE_SKIPPED rows outside its final trailer block (a test printed one, or the log was spliced): $RT_LOG" >&2 ;;
    required-not-run)
      echo "✗ test-green --retest: RED — required file(s) did not run (a TS [SKIP] counts as not run):" >&2
      sed 's/^/    /' "$TG_TMP/missing" >&2 ;;
    mode-mismatch)
      echo "✗ test-green --retest: RED — the log does not carry exactly one SUITE_MODE=retest (got '${RT_MODE:-<none>}')" >&2 ;;
    marker-absent|marker-not-last)
      echo "✗ test-green --retest: RED — the log does not end in a literal SUITE_EXIT=0 ($REASON): $RT_LOG" >&2 ;;
    *)
      echo "✗ test-green --retest: RED — the retest exited ${SUITE_EXIT:-?} (log: $RT_LOG)" >&2
      [ -s "$TG_TMP/rtfailed" ] && sed 's/^/    failing: /' "$TG_TMP/rtfailed" >&2 ;;
  esac
  exit 1
fi

# ════════════════════════════════════════════════════════════════════════════
# FULL RUN (default) / --log import
# ════════════════════════════════════════════════════════════════════════════

# ─── P2: freeze the watched tree BEFORE the run ─────────────────────────────
# RUN mode only. In --log mode this script never saw the tree the log came from, so
# it must not assert one — the empty digest makes the gate fail closed instead.
MANIFEST_PATH_OUT="$STATE_DIR/${STATE_FILE_PREFIX}-${SLUG}.manifest"
SMANIFEST_PATH_OUT="$STATE_DIR/${STATE_FILE_PREFIX}-${SLUG}.subject-manifest"
if [ -z "$LOG_IN" ] && [ -n "$TG_TMP" ]; then
  __tg_manifest "$CUR_ROOT" > "$TG_TMP/before.man" 2>/dev/null || : > "$TG_TMP/before.man"
  pwt_rt_subject_manifest "$CUR_ROOT" worktree > "$TG_TMP/before.sman" 2>/dev/null || : > "$TG_TMP/before.sman"
  # The tracked paths alone: beside before.sman it names the untracked files (R255 194(5)).
  pwt_rt_subject_manifest "$CUR_ROOT" tracked > "$TG_TMP/before.stman" 2>/dev/null || : > "$TG_TMP/before.stman"
fi

# ─── RUN (or adopt) THE LOG ─────────────────────────────────────────────────
START_EPOCH=$(date +%s)
SUITE_CMD=""
if [ -n "$LOG_IN" ]; then
  if [ ! -f "$LOG_IN" ]; then
    echo "✗ --log path is not a regular file: $LOG_IN" >&2
    exit 2
  fi
  LOG_PATH="$LOG_IN"
else
  LOG_PATH="$STATE_DIR/${STATE_FILE_PREFIX}-${SLUG}.log"
  SUITE_CMD="${PWT_TEST_GREEN_SUITE_CMD:-$PWT_RT_DEFAULT_SUITE_CMD}"
  echo "→ test-green: running '$SUITE_CMD' (log: $LOG_PATH)"
  # The VERDICT comes from the log, never from this pipeline's exit code — a killed
  # suite exits nonzero with no marker, and a marker-less log is red anyway.
  __tg_run "$LOG_PATH" "$SUITE_CMD"
  echo "→ test-green: suite finished (raw exit $?)"
fi
DURATION=$(( $(date +%s) - START_EPOCH ))

# ─── VERDICT ────────────────────────────────────────────────────────────────
__tg_verdict_from_log "$LOG_PATH"
MODE="$(__tg_shape_mode "$(pwt_rt_log_mode "$LOG_PATH" 2>/dev/null)")"
# Rows at column 0 above the trailer block (review -5): the witness cannot be told
# apart from test output, so the log certifies nothing — red, whatever its marker.
TRAILER_RC=0
pwt_rt_trailer "$LOG_PATH" >/dev/null 2>&1 || TRAILER_RC=$?
if [ "$GREEN" = "true" ] && [ "$TRAILER_RC" = "2" ]; then
  GREEN="false"; REASON="rows-outside-trailer"
fi
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
__tg_load_annotation

# ─── P2: freeze check + tree_digest ─────────────────────────────────────────
# The digest is the hash of the manifest taken BEFORE the run, and it is recorded
# only when the manifest AFTER the run is identical: an edit made while the suite
# ran (the suite saw a mix of old and new content) is red, never stamped as tested.
TREE_DIGEST=""
MANIFEST_PATH=""
SUBJECT_DIGEST=""
SMANIFEST_PATH=""
if [ -z "$LOG_IN" ]; then
  if [ -n "$TG_TMP" ] && [ -s "$TG_TMP/before.man" ]; then
    __tg_manifest "$CUR_ROOT" > "$TG_TMP/after.man" 2>/dev/null || : > "$TG_TMP/after.man"
    if cmp -s "$TG_TMP/before.man" "$TG_TMP/after.man"; then
      TREE_DIGEST="$(pwt_rt_digest "$TG_TMP/before.man")"
    else
      GREEN="false"; REASON="tree-changed-during-run"
      echo "✗ test-green: watched files changed WHILE the suite ran — the verdict is red and carries no digest:" >&2
      pwt_rt_delta "$TG_TMP/before.man" "$TG_TMP/after.man" 2>/dev/null | head -10 | sed 's/^/    /' >&2
    fi
  fi
  # Shape check with builtins only. A `printf ... | grep -q` form can return
  # non-zero because grep closed the pipe rather than because the value failed to
  # match, which would intermittently void a perfectly good digest.
  case "$TREE_DIGEST" in
    ""|*[!0-9a-f]*) TREE_DIGEST="" ;;
    *) [ "${#TREE_DIGEST}" -eq 64 ] || TREE_DIGEST="" ;;
  esac
  if [ -n "$TREE_DIGEST" ] && cp "$TG_TMP/before.man" "$MANIFEST_PATH_OUT" 2>/dev/null; then
    MANIFEST_PATH="$MANIFEST_PATH_OUT"
  fi
  if [ -z "$TREE_DIGEST" ] && [ "$REASON" != "tree-changed-during-run" ]; then
    echo "  test-green: tree_digest unavailable (no git/shasum, empty watched set, or not a work tree) — the commit gate will block until a digest-bearing verdict exists" >&2
  fi
  # The SUBJECT digest (review -1) is frozen the same way, but it never colours this
  # verdict: the full-mode gate governs the watched set only. A subject that moved
  # during the run (an unwatched edit) just leaves subject_digest empty, and a
  # verdict without one can never be a retest base — the next retest asks for a
  # full run instead of measuring against a tree nobody tested.
  if [ -n "$TREE_DIGEST" ] && [ -s "$TG_TMP/before.sman" ]; then
    pwt_rt_subject_manifest "$CUR_ROOT" worktree > "$TG_TMP/after.sman" 2>/dev/null || : > "$TG_TMP/after.sman"
    if cmp -s "$TG_TMP/before.sman" "$TG_TMP/after.sman"; then
      SUBJECT_DIGEST="$(pwt_rt_digest "$TG_TMP/before.sman")"
      pwt_rt_is_hex64 "$SUBJECT_DIGEST" || SUBJECT_DIGEST=""
      if [ -n "$SUBJECT_DIGEST" ] && cp "$TG_TMP/before.sman" "$SMANIFEST_PATH_OUT" 2>/dev/null; then
        SMANIFEST_PATH="$SMANIFEST_PATH_OUT"
      else
        SUBJECT_DIGEST=""
      fi
    else
      echo "  test-green: unwatched .claude/ or tests/ files changed while the suite ran — no subject_digest, so this verdict cannot be a retest base:" >&2
      pwt_rt_delta "$TG_TMP/before.sman" "$TG_TMP/after.sman" 2>/dev/null | head -5 | sed 's/^/    /' >&2
    fi
  fi
  # Untracked subject files (R255 194(5)). subject_digest also hashes every
  # untracked, non-ignored .claude/ or tests/ file of this tree, and no commit holds
  # one, so a push of this tree without them gets its own post-push confirm run.
  # That run is kept on purpose: the suite may have needed any of them, and only a
  # run of the pushed tree shows it is green without them (pwt_rt_untracked in the
  # retest lib says why no digest skips it). Naming them here, on a green run, lets
  # the operator commit them, or git-ignore a local note, before pushing. It is a
  # notice only: a list that cannot be taken changes nothing in the verdict.
  if [ "$GREEN" = "true" ] && [ -n "$TREE_DIGEST" ] \
     && [ -s "$TG_TMP/before.stman" ] && [ -s "$TG_TMP/before.sman" ]; then
    TG_UNT="$(pwt_rt_untracked "$TG_TMP/before.sman" "$TG_TMP/before.stman" 2>/dev/null)" || TG_UNT=""
    if [ -n "$TG_UNT" ]; then
      echo "  test-green: $(printf '%s\n' "$TG_UNT" | wc -l | tr -d ' ') untracked .claude/ or tests/ file(s) were in the tested tree. A commit holds none, so a push without them gets its own post-push confirm; commit them, or git-ignore a local note:" >&2
      printf '%s\n' "$TG_UNT" | head -5 | sed 's/^/    /' >&2
    fi
  fi
fi
# A manifest never outlives the verdict it belongs to.
[ -n "$MANIFEST_PATH" ] || rm -f "$MANIFEST_PATH_OUT" 2>/dev/null
[ -n "$SMANIFEST_PATH" ] || rm -f "$SMANIFEST_PATH_OUT" 2>/dev/null

# The log is the witness a later retest reads its base failures from, and it sits
# outside the lane guard's trusted-artifact json: record its hash so an edited log
# (a deleted SUITE_FAILED row shrinks the rerun set) is refused by pwt_rt_log_bound.
LOG_SHA256="$(pwt_rt_sha256_file "$LOG_PATH" 2>/dev/null)"
case "$LOG_SHA256" in
  ""|*[!0-9a-f]*) LOG_SHA256="" ;;
  *) [ "${#LOG_SHA256}" -eq 64 ] || LOG_SHA256="" ;;
esac

FAILED_JSON='[]'
if command -v jq >/dev/null 2>&1 && [ -n "$TG_TMP" ]; then
  pwt_rt_parse_failures "$LOG_PATH" > "$TG_TMP/failed" 2>/dev/null || true
  FAILED_JSON="$(__tg_json_list "$TG_TMP/failed")"
fi

# ─── ARTIFACT (dual-written, temp+rename) ───────────────────────────────────
# Same dual-write set as __pwt_emit_goal_state so both evaluator resolution paths
# (worker worktree, canonical main) find the verdict. temp+rename keeps a concurrent
# reader from ever seeing a half-written file.
write_artifact() {
  local dir="$1" file tmp
  [ -n "$dir" ] || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  file="$dir/${STATE_FILE_PREFIX}-${SLUG}.json"
  tmp="$file.tmp.$$"
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg ts "$TS" \
      --arg slug "$SLUG" \
      --arg reason "$REASON" \
      --arg log_path "$LOG_PATH" \
      --arg log_sha256 "$LOG_SHA256" \
      --arg tree_digest "$TREE_DIGEST" \
      --arg mode "$MODE" \
      --arg suite_cmd "$SUITE_CMD" \
      --arg manifest_path "$MANIFEST_PATH" \
      --arg subject_digest "$SUBJECT_DIGEST" \
      --arg subject_manifest_path "$SMANIFEST_PATH" \
      --argjson failed "$FAILED_JSON" \
      --argjson suite_exit "$JSON_EXIT" \
      --argjson green "$GREEN" \
      --argjson duration_s "$DURATION" \
      --argjson load_1m "$LOAD_1M" \
      --argjson ncpu "$NCPU" \
      --argjson load_suspect "$LOAD_SUSPECT" \
      '{ts:$ts, slug:$slug, suite_exit:$suite_exit, green:$green, reason:$reason, log_path:$log_path, log_sha256:$log_sha256, duration_s:$duration_s, tree_digest:$tree_digest,
        mode:$mode, suite_cmd:$suite_cmd, manifest_path:$manifest_path,
        subject_digest:$subject_digest, subject_manifest_path:$subject_manifest_path, failed:$failed}
       + (if $load_suspect == null and $load_1m == null and $ncpu == null then {}
          else {load_1m:$load_1m, ncpu:$ncpu, load_suspect:$load_suspect} end)' \
      > "$tmp" 2>/dev/null || return 0
  else
    # jq-absent fallback: every interpolated value is PROGRAM-CONTROLLED — $TS/$REASON/
    # $GREEN/$JSON_EXIT/$DURATION/$MODE are literals this script chose (MODE passed
    # __tg_shape_mode), $SLUG passed __tg_safe_slug, and $LOG_PATH / $MANIFEST_PATH
    # are emitted only when they are likewise safe derived paths. $SUITE_CMD is
    # operator text (an env seam), so it is emitted only when it is the default;
    # anything else is recorded as "<substituted>" — which the gate refuses anyway.
    # No user text is ever printf'd into JSON (the injection rule from the done-when
    # parser: jq --arg or nothing). `failed` is omitted rather than guessed: a retest
    # reads failures from the log, never from this field.
    local safe_log="" safe_man="" safe_cmd="" safe_sman="" safe_sdig=""
    case "$LOG_PATH" in
      *'"'*|*'\'*|*$'\n'*) safe_log="" ;;
      *) safe_log="$LOG_PATH" ;;
    esac
    case "$MANIFEST_PATH" in
      *'"'*|*'\'*|*$'\n'*) safe_man="" ;;
      *) safe_man="$MANIFEST_PATH" ;;
    esac
    # The subject pair is emitted together or not at all: a digest whose manifest
    # path had to be dropped could never be verified, so it must not be recorded.
    case "$SMANIFEST_PATH" in
      *'"'*|*'\'*|*$'\n'*) safe_sman="" ;;
      *) safe_sman="$SMANIFEST_PATH" ;;
    esac
    [ -n "$safe_sman" ] && safe_sdig="$SUBJECT_DIGEST"
    if [ -z "$SUITE_CMD" ] || [ "$SUITE_CMD" = "$PWT_RT_DEFAULT_SUITE_CMD" ]; then
      safe_cmd="$SUITE_CMD"
    else
      safe_cmd="<substituted>"
    fi
    # $TREE_DIGEST and $LOG_SHA256 are 64 lowercase hex or empty — validated above,
    # never user text.
    # The load fields are likewise shape-guarded numerics/booleans/null, so they
    # are safe to interpolate bare. Omitted entirely when annotation is off, so
    # the jq-absent artifact keeps the same shape as the jq one.
    local load_frag=""
    if [ "$LOAD_1M" != "null" ] || [ "$NCPU" != "null" ] || [ "$LOAD_SUSPECT" != "null" ]; then
      load_frag=$(printf ',"load_1m":%s,"ncpu":%s,"load_suspect":%s' "$LOAD_1M" "$NCPU" "$LOAD_SUSPECT")
    fi
    printf '{"ts":"%s","slug":"%s","suite_exit":%s,"green":%s,"reason":"%s","log_path":"%s","log_sha256":"%s","duration_s":%s,"tree_digest":"%s","mode":"%s","suite_cmd":"%s","manifest_path":"%s","subject_digest":"%s","subject_manifest_path":"%s"%s}\n' \
      "$TS" "$SLUG" "$JSON_EXIT" "$GREEN" "$REASON" "$safe_log" "$LOG_SHA256" "$DURATION" "$TREE_DIGEST" "$MODE" "$safe_cmd" "$safe_man" "$safe_sdig" "$safe_sman" "$load_frag" \
      > "$tmp" 2>/dev/null || return 0
  fi
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  echo "  test-green verdict:  $file"
}

while IFS= read -r d; do
  write_artifact "$d"
done <<EOF
$(__tg_state_dirs)
EOF

if [ "$GREEN" = "true" ]; then
  echo "✓ test-green: GREEN (SUITE_EXIT=0, mode=${MODE:-?}, ${DURATION}s)"
  exit 0
fi
case "$REASON" in
  marker-absent)
    echo "✗ test-green: RED — no trailing SUITE_EXIT marker in $LOG_PATH" >&2
    echo "  the suite was killed, truncated, or aborted before its final gate." >&2
    echo "  a marker-less log is RED by construction — it is never treated as green." >&2 ;;
  marker-not-last)
    echo "✗ test-green: RED — SUITE_EXIT=0 is not the literal last line of $LOG_PATH" >&2 ;;
  tree-changed-during-run)
    echo "✗ test-green: RED — the watched tree changed during the run; re-run on a still tree." >&2 ;;
  rows-outside-trailer)
    echo "✗ test-green: RED — $LOG_PATH carries SUITE_MODE / RETEST_RAN / SUITE_FAILED / SUITE_SKIPPED rows outside its final trailer block (a test printed one, or the log was spliced)." >&2 ;;
  *)
    echo "✗ test-green: RED — suite exited $SUITE_EXIT (log: $LOG_PATH)" >&2
    if [ -n "$TG_TMP" ] && [ -s "$TG_TMP/failed" ]; then
      sed 's/^/    failing: /' "$TG_TMP/failed" >&2
      echo "  after fixing, a targeted retest is enough for the COMMIT gate:" >&2
      echo "    .claude/scripts/plan-w-team-test-green.sh --slug $SLUG --retest" >&2
    fi ;;
esac
exit 1
