#!/usr/bin/env bash
# claude-pattern-pull.sh — consumer-initiated, atomic sync FROM claude-pattern.
#
# WHY (2.39.0, 2026-09-03): the session-start auto-sync used to REGENERATE the
# sync files in place inside a consumer whenever a sibling claude-pattern checkout
# was newer than the consumer's origin ("author path"). In a PR-gated follower
# (cleanscale) that left five uncommitted tracked files on main, so its
# ff-only self-update timer skipped as "dirty", lane worktrees piled up behind
# a checkout nobody could fast-forward, and pushes queued behind the pre-push
# gate lock. The consumer must PULL the latest claude-pattern instead, and the
# pull must never leave its primary checkout dirty or diverged.
#
# HOW: everything happens away from the primary checkout.
#   1. A bare cache of claude-pattern (~/.cache/claude-pattern/source.git) is
#      cloned once and fetched afterwards; a clean SNAPSHOT of one commit is
#      checked out into a temp dir (so the retired-path pass sees a clean,
#      committed source — the same gate the manual sync applies).
#   2. The consumer gets a TEMPORARY LINKED WORKTREE on a fresh branch
#      (chore/claude-pattern-<sha>) cut from its freshly fetched origin/<default>.
#   3. The SNAPSHOT's own sync-to-project.sh runs against that worktree (so the
#      sync logic and the files it ships come from the same commit), and the
#      snapshot's sync-commit-lib.sh makes the scoped sync commit (never
#      .claude/state; refuses to bundle foreign work — trivially true in a fresh
#      worktree). The commit message names the source SHA and skill VERSION.
#      Before that commit, every path the sync changed, added or removed is
#      checked again against .sync-exclude (the primary's list and origin's,
#      joined, read by the newest matcher in the cache). An opted-out path goes
#      back to origin's version, and a pull that cannot put one back stops
#      before the commit (2.60.0, from cleanscale #5257).
#   4. Delivery (--deliver / .claude/.sync-policy). The push runs the consumer's
#      own pre-push hook; the pull grants itself no exemption from it.
#        direct — push the commit straight to origin/<default>; on rejection
#                 fall back to `pr` (if gh is available) else `branch`.
#        pr     — push the branch and open a PR with gh.
#        branch — push the branch only.
#   5. The worktree and snapshot are removed. The PRIMARY checkout is touched by
#      exactly one operation, and only when it is on its default branch, has no
#      index.lock, and its TRACKED tree is clean: a `git pull --ff-only` so the
#      files land there too (the same ff-only step the hook has always done).
#      Anything else about the primary is left alone — a dirty primary is
#      reported, never repaired.
#
# --refresh-ignored-corpus (2.58.0) covers the one thing a PR delivery cannot
# carry. The primary only fast-forwards, so a synced file that the consumer's
# .gitignore keeps out of git never reaches it. That is the test corpus under
# tests/skill/, plus the *.test.sh files under .claude/scripts and .claude/hooks.
# Those files stay as the last in-place sync left them (cleanscale: 83 files
# unchanged since 2026-09-03). This mode runs steps 1 and 3 without a commit: the
# snapshot's sync writes into a temporary --shared clone of the consumer, which
# fetches origin/<default> itself and checks it out. So the candidates are
# exactly the files that sync ships, under those three roots, that the clone
# ignores. The clone takes the primary's info/exclude and core.excludesFile, as a
# pull's linked worktree shares them. For each one that the primary also ignores and does not track, and whose
# content or executable bit differs, it prints `new|changed <sha256> <path>`. Only
# --apply writes them. Other rules:
#   - It never commits, pushes or writes a stamp. The only file it removes is one it
#     has just written through a link that appeared during the write.
#   - It never touches a path the primary tracks, compared without regard to case
#     (a case-insensitive filesystem opens the tracked file). Those come through
#     the sync PR. A shipped file the primary does not ignore yet is only counted:
#     once the primary has the .gitignore rule, a second refresh writes it.
#   - It never writes through a symlink, or into a submodule or nested checkout.
#   - An opt-out in the primary's .sync-exclude or in origin's binds. The joined
#     list is applied twice: by the snapshot's sync, and again by the newest
#     matcher in the source cache (an older --ref's sync can predate `../` lines).
#   - A test of a script the consumer froze is held (2.60.0). A new or changed
#     file that names the file name of a script .sync-exclude keeps is printed
#     as `HOLD` and never written: the frozen copy predates the test. Port the
#     script and its tests together, by hand.
#   - The primary's refs, worktree list and hooks are left alone: the clone does
#     the fetch, is its own repository, and takes the sync's hook installer. A
#     file is written through a temp file in the primary's git directory, which
#     git status never shows.
# It is manual only: content that skips the PR also skips the consumer's review,
# so nothing runs it automatically. --ref picks the claude-pattern version to
# match, and a warning says when it differs from the primary's .sync-version.
#
# Idempotent: a (consumer, source-sha) pair is delivered once (stamp under the
# cache dir); an origin whose .sync-version already equals the source's is a
# no-op; a source whose stamp is OLDER than origin's is refused (never syncs
# backwards — cleanscale #1943). One run per consumer at a time (mkdir lock).
#
# Usage:
#   claude-pattern-pull.sh [<consumer-root>] [options]
#     --ref <ref>            source ref in the cache (default: policy ref, else main)
#     --remote <url>         claude-pattern remote (default: policy/env/sibling/canonical)
#     --deliver <mode>       direct | pr | branch  (default: policy, else pr)
#     --profile <name>       sync profile passed to sync-to-project.sh
#     --dry-run              report versions + the plan; write nothing
#     --auto                 hook mode: honour the cooldown, quiet no-ops
#     --force                ignore the delivered stamp / equal-version no-op
#     --no-ff-primary        never touch the primary checkout at all
#     --refresh-ignored-corpus  list each ignored corpus file the sync ships that
#                            differs in the primary (see above); writes nothing
#     --apply                with --refresh-ignored-corpus: write the listed files
#     --cache <dir>          cache dir (default: $CLAUDE_PATTERN_PULL_CACHE or ~/.cache/claude-pattern)
#
# Policy file (consumer-authored, never synced over): <root>/.claude/.sync-policy
#   mode=pull|regen        (read by session-start.sh; this script ignores it)
#   deliver=direct|pr|branch
#   auto_merge=false       (2.60.0) the pull never merges. With deliver=pr or branch,
#                          any auto_merge value but empty, 0, false, no or off is
#                          refused (exit 8): a sync PR is merged through the
#                          consumer's own review and gate.
#   profile=<name>
#   remote=<url>
#   ref=<ref>
#   branch_prefix=<prefix> (default chore/claude-pattern)
#
# Env: CLAUDE_PATTERN_REMOTE, CLAUDE_PATTERN_ROOT (sibling checkout, remote
#      resolution only), CLAUDE_PATTERN_PULL_CACHE, CLAUDE_PATTERN_PULL_DELIVER,
#      CLAUDE_PATTERN_PULL_COOLDOWN_S (--auto, default 600).
#
# Exit codes:
#   0 delivered / nothing to do     2 usage        3 source unreachable
#   4 consumer prerequisites        5 sync failed  6 delivery failed (branch kept locally)
#   (4 also = an unreadable .sync-exclude or a matcher that could not be loaded;
#    5 also = an opted-out path the sync changed could not be put back)
#   (--refresh-ignored-corpus: 4 also = git could not list the primary;
#    5 = the sync or an --apply write failed)
#   7 another run holds the lock    8 policy refused (deliver=pr|branch + auto_merge)
#
# bash 3.2 compatible (mac-mini). Never prints tokens; never uses --force on git.

set -u

CANONICAL_REMOTE="git@github.com:veronelazio/claude-pattern.git"
ROOT_ARG=""; REF=""; REMOTE=""; DELIVER=""; PROFILE=""; DRY_RUN=0; AUTO=0; FORCE=0
REFRESH=0; APPLY=0
FF_PRIMARY=1; CACHE="${CLAUDE_PATTERN_PULL_CACHE:-$HOME/.cache/claude-pattern}"

usage() { sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --remote) REMOTE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --deliver) DELIVER="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --profile) PROFILE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --cache) CACHE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --auto) AUTO=1; shift ;;
    --force) FORCE=1; shift ;;
    --no-ff-primary) FF_PRIMARY=0; shift ;;
    --refresh-ignored-corpus) REFRESH=1; shift ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "claude-pattern-pull: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) if [ -z "$ROOT_ARG" ]; then ROOT_ARG="$1"; shift; else echo "claude-pattern-pull: too many arguments" >&2; exit 2; fi ;;
  esac
done
if [ "$APPLY" = 1 ] && [ "$REFRESH" = 0 ]; then
  echo "claude-pattern-pull: --apply needs --refresh-ignored-corpus" >&2; exit 2
fi
if [ "$REFRESH" = 1 ] && [ "$AUTO" = 1 ]; then
  echo "claude-pattern-pull: --refresh-ignored-corpus is manual only; it does not take --auto" >&2; exit 2
fi
if [ "$APPLY" = 1 ] && [ "$DRY_RUN" = 1 ]; then
  echo "claude-pattern-pull: --apply and --dry-run contradict each other" >&2; exit 2
fi

log()  { printf '%s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit "${2:-1}"; }

# ── consumer root ───────────────────────────────────────────────────────────
ROOT="${ROOT_ARG:-$PWD}"
ROOT="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" || die "not a git checkout: ${ROOT_ARG:-$PWD}" 4
# From a linked worktree, act on the MAIN checkout (the one the policy and stamp belong to).
_common="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)"
case "$_common" in /*) ;; *) _common="$ROOT/$_common" ;; esac
_main="$(cd "$_common/.." 2>/dev/null && pwd -P)"
if [ -n "$_main" ] && [ "$(cd "$ROOT" && pwd -P)" != "$_main" ] && [ -d "$_main/.git" ]; then ROOT="$_main"; fi
CLAUDE_DIR="$ROOT/.claude"

# Refuse to run on claude-pattern itself.
if [ -f "$ROOT/.claude/commands/plan-w-team/VERSION" ] && [ -f "$ROOT/.claude/scripts/sync-commit-lib.sh" ]; then
  log "claude-pattern-pull: $ROOT is the source repo — nothing to pull"; exit 0
fi

# ── policy file ─────────────────────────────────────────────────────────────
policy_get() {  # policy_get <key>
  [ -f "$CLAUDE_DIR/.sync-policy" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CLAUDE_DIR/.sync-policy" | tail -1 | sed 's/[[:space:]]*$//'
}
[ -n "$DELIVER" ] || DELIVER="${CLAUDE_PATTERN_PULL_DELIVER:-$(policy_get deliver)}"
[ -n "$DELIVER" ] || DELIVER="pr"
case "$DELIVER" in direct|pr|branch) ;; *) die "--deliver must be direct|pr|branch (got '$DELIVER')" 2 ;; esac
# A sync PR or branch is reviewed and merged through the consumer's own gate, like any
# other change, and this script never merges. A policy that asks it to merge is refused
# rather than ignored, so nobody believes a merge happened (cleanscale #5257). Only a
# plain "off" value passes, so a quoted or misspelt "true" is refused too. A direct
# push is unreviewed by definition, so deliver=direct never reads auto_merge.
if [ "$REFRESH" = 0 ]; then
  case "$DELIVER" in pr|branch)
    _am="$(policy_get auto_merge | tr '[:upper:]' '[:lower:]')"
    case "$_am" in ''|0|false|no|off) ;; *)
      die ".sync-policy: deliver=$DELIVER with auto_merge=$_am is refused — a sync PR or branch is merged through the consumer's own review and merge gate, never by the puller" 8 ;;
    esac ;;
  esac
fi
[ -n "$PROFILE" ] || PROFILE="$(policy_get profile)"
[ -n "$REF" ] || REF="$(policy_get ref)"
[ -n "$REF" ] || REF="main"
BRANCH_PREFIX="$(policy_get branch_prefix)"; [ -n "$BRANCH_PREFIX" ] || BRANCH_PREFIX="chore/claude-pattern"

# ── remote resolution ───────────────────────────────────────────────────────
if [ -z "$REMOTE" ]; then REMOTE="${CLAUDE_PATTERN_REMOTE:-$(policy_get remote)}"; fi
if [ -z "$REMOTE" ]; then
  _sib="${CLAUDE_PATTERN_ROOT:-$(dirname "$ROOT")/claude-pattern}"
  [ -d "$_sib/.git" ] && REMOTE="$(git -C "$_sib" remote get-url origin 2>/dev/null || true)"
fi
[ -n "$REMOTE" ] || REMOTE="$CANONICAL_REMOTE"

# ── consumer prerequisites ──────────────────────────────────────────────────
git -C "$ROOT" remote get-url origin >/dev/null 2>&1 || die "$ROOT has no 'origin' remote — nothing to deliver to" 4
# A refresh fetches into its temporary clone instead (below), so it moves no ref here.
if [ "$REFRESH" = 0 ]; then
  git -C "$ROOT" fetch --quiet --prune origin 2>/dev/null || warn "fetch of consumer origin failed — using last known refs"
fi
DEFAULT="$(git -C "$ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
if [ -z "$DEFAULT" ]; then
  for b in main master; do
    if git -C "$ROOT" rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null; then DEFAULT="$b"; break; fi
  done
fi
[ -n "$DEFAULT" ] || die "cannot determine the default branch of origin (set origin/HEAD: git remote set-head origin -a)" 4
ORIGIN_SHA="$(git -C "$ROOT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT^{commit}")" || die "origin/$DEFAULT not found" 4
ORIGIN_STAMP="$(git -C "$ROOT" show "origin/$DEFAULT:.claude/.sync-version" 2>/dev/null || true)"

# ── cache layout + lock ─────────────────────────────────────────────────────
mkdir -p "$CACHE/stamps" "$CACHE/locks" "$CACHE/logs" "$CACHE/wt" || die "cannot create cache dir $CACHE" 1
KEY="$(basename "$ROOT")-$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1)"
LOCK="$CACHE/locks/$KEY.lock"
COOLDOWN_FILE="$CACHE/stamps/$KEY.last-check"
STAMP_FILE="$CACHE/stamps/$KEY.delivered"

if [ "$AUTO" = 1 ] && [ "$FORCE" = 0 ] && [ -f "$COOLDOWN_FILE" ]; then
  _cool="${CLAUDE_PATTERN_PULL_COOLDOWN_S:-600}"
  _now="$(date +%s)"; _then="$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)"
  case "$_then" in ''|*[!0-9]*) _then=0 ;; esac
  if [ $(( _now - _then )) -lt "$_cool" ]; then exit 0; fi
fi

if ! mkdir "$LOCK" 2>/dev/null; then
  _lpid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$_lpid" ] && kill -0 "$_lpid" 2>/dev/null; then
    [ "$AUTO" = 1 ] && exit 0
    die "another claude-pattern-pull run (pid $_lpid) holds $LOCK" 7
  fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || die "cannot take lock $LOCK" 7
fi
echo $$ > "$LOCK/pid"
SNAP_PARENT=""; WT=""; BR=""; RTMP=""; REFRESH_TMP=""; EXCLUDE_MATCHER=0; REFRESH_GITDIR=""; REFRESH_ROOT_P=""
cleanup() {
  # A second signal must not cut the cleanup short and leave the lock behind.
  trap '' INT TERM HUP
  [ -n "$REFRESH_TMP" ] && rm -f "$REFRESH_TMP"
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if [ "$REFRESH" = 1 ]; then
      rm -rf "$WT"   # the refresh's own clone; the primary's worktree list is not touched
    else
      git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
      git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
    fi
  fi
  [ -n "$SNAP_PARENT" ] && [ -d "$SNAP_PARENT" ] && rm -rf "$SNAP_PARENT"
  [ -n "$RTMP" ] && [ -d "$RTMP" ] && rm -rf "$RTMP"
  rm -rf "$LOCK"
}
# A signal ends the run: cleanup once, then the same signal again, so a caller's loop
# sees a signalled child and stops too. Listing INT and TERM in the EXIT trap only ran
# cleanup and then carried on, without the lock and still writing. The exit after the
# kill is a fallback in case the re-raised signal does not end the shell.
_on_signal() {
  cleanup
  trap - EXIT "$1"
  kill -s "$1" $$
  exit "$2"
}
trap cleanup EXIT
trap '_on_signal INT 130' INT
trap '_on_signal TERM 143' TERM
trap '_on_signal HUP 129' HUP
[ "$REFRESH" = 1 ] || date +%s > "$COOLDOWN_FILE"

# ── source cache: bare clone once, fetch afterwards ─────────────────────────
SRC="$CACHE/source.git"
if [ -d "$SRC" ] && git -C "$SRC" rev-parse --is-bare-repository >/dev/null 2>&1; then
  _cur="$(git -C "$SRC" remote get-url origin 2>/dev/null || true)"
  [ "$_cur" = "$REMOTE" ] || git -C "$SRC" remote set-url origin "$REMOTE" 2>/dev/null || true
  if ! git -C "$SRC" fetch --quiet --prune origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' 2>/dev/null; then
    warn "fetch of $REMOTE failed — using the cached source as of last fetch"
  fi
else
  rm -rf "$SRC"
  git clone --quiet --bare "$REMOTE" "$SRC" 2>/dev/null || die "cannot clone $REMOTE into $SRC" 3
fi
SRC_SHA="$(git -C "$SRC" rev-parse --verify --quiet "$REF^{commit}")" || die "ref '$REF' not found in $REMOTE" 3
SRC_SHORT="$(printf '%s' "$SRC_SHA" | cut -c1-8)"
SRC_STAMP="$(git -C "$SRC" show "$SRC_SHA:.claude/.sync-version" 2>/dev/null || true)"
SRC_VERSION="$(git -C "$SRC" show "$SRC_SHA:.claude/commands/plan-w-team/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
[ -n "$SRC_STAMP" ] || die "source $SRC_SHORT carries no .claude/.sync-version" 3
BR="$BRANCH_PREFIX-$SRC_SHORT"

log "claude-pattern-pull: $(basename "$ROOT") ← $REMOTE @ $SRC_SHORT (/plan-w-team ${SRC_VERSION:-?}, stamp $SRC_STAMP)"
log "   origin/$DEFAULT stamp: ${ORIGIN_STAMP:-<none>}   deliver: $DELIVER"

# ── --refresh-ignored-corpus ────────────────────────────────────────────────
# See the header. The preflight runs here. The comparison runs after the snapshot's
# sync has written into the temporary clone (below), so it sees what that sync ships.
_sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -c1-64; }
# Every directory on the path below $ROOT must be a real directory: not a symlink,
# not a file, and not another repository (a submodule or a nested checkout).
_refresh_path_safe() {
  local d="$ROOT" rest="$1"
  while :; do
    case "$rest" in */*) ;; *) return 0 ;; esac
    d="$d/${rest%%/*}"; rest="${rest#*/}"
    [ ! -L "$d" ] || return 1
    [ -e "$d" ] || return 0
    { [ -d "$d" ] && [ ! -e "$d/.git" ]; } || return 1
  done
}
refresh_preflight() {
  local ex="$CLAUDE_DIR/.sync-exclude" inst
  if [ -e "$ex" ] || [ -L "$ex" ]; then
    { [ -f "$ex" ] && [ -r "$ex" ]; } || die "$ex exists but is not a readable file — nothing listed" 4
  fi
  REFRESH_GITDIR="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null)" && [ -d "$REFRESH_GITDIR" ] \
    || die "cannot find the git directory of $ROOT" 4
  REFRESH_ROOT_P="$(cd "$ROOT" 2>/dev/null && pwd -P)" && [ -n "$REFRESH_ROOT_P" ] \
    || die "cannot resolve the physical path of $ROOT" 4
  inst="$(tr -d '[:space:]' < "$CLAUDE_DIR/.sync-version" 2>/dev/null || true)"
  if [ "$inst" != "$SRC_STAMP" ]; then
    warn "the primary's sync stamp is ${inst:-<none>} and $SRC_SHORT's is $SRC_STAMP, so the corpus may not match the scripts the primary runs; --ref <sha> picks the claude-pattern commit to match"
  fi
  if [ "$APPLY" = 1 ]; then
    log "   ignored corpus @ $SRC_SHORT → $ROOT (apply)"
  else
    log "   ignored corpus @ $SRC_SHORT → $ROOT (dry run)"
  fi
}
# ── .sync-exclude: the joined list and the newest matcher ───────────────────
# An opt-out in either list binds: the primary's list (what it runs) and origin's (what
# the primary will run once it catches up). A refresh and a pull's commit both read the
# union, CRs stripped, so a --ref whose sync predates CRLF lists reads it too. Neither
# list has negation, so joining them only adds opt-outs. The newest matcher in the cache
# reads it, because each newer matcher only opts more paths out. Returns 1 when neither
# list exists. $1 says what a bad list stops ("nothing listed", "nothing committed").
exclude_join() {
  local ex="$CLAUDE_DIR/.sync-exclude" wx="$WT/.claude/.sync-exclude" have="" mref
  if [ -z "$RTMP" ]; then
    RTMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-pull.XXXXXX")" || die "cannot create a temp dir" 5
  fi
  mkdir -p "$RTMP/x" || die "cannot create a temp dir" 5
  : > "$RTMP/x/.sync-exclude"
  if [ -e "$ex" ] || [ -L "$ex" ]; then
    { [ -f "$ex" ] && [ -r "$ex" ]; } || die "$ex exists but is not a readable file — $1" 4
  fi
  if [ -e "$wx" ] || [ -L "$wx" ]; then
    { [ -f "$wx" ] && [ ! -L "$wx" ] && [ -r "$wx" ]; } \
      || die "origin/$DEFAULT's .claude/.sync-exclude is not a regular file — $1" 4
    { tr -d '\r' < "$wx"; printf '\n'; } >> "$RTMP/x/.sync-exclude"; have=1
  fi
  if [ -f "$ex" ]; then
    { tr -d '\r' < "$ex"; printf '\n'; } >> "$RTMP/x/.sync-exclude"; have=1
  fi
  [ -n "$have" ] || return 1
  # HEAD is resolved to a commit, so a dangling HEAD falls back to the ref being pulled.
  mref="$(git -C "$SRC" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" || mref="$SRC_SHA"
  eval "$(git -C "$SRC" show "$mref:.claude/scripts/sync-to-project.sh" 2>/dev/null \
    | sed -n -e '/^retired_paths_sync_excluded()/,/^}/p' -e '/^retired_paths_glob_match()/,/^}/p')"
  command -v retired_paths_sync_excluded >/dev/null 2>&1 && command -v retired_paths_glob_match >/dev/null 2>&1 \
    || die "a .sync-exclude is present but the source's matcher could not be loaded — $1" 4
  EXCLUDE_MATCHER=1
}
# A refresh also hands the joined list to the snapshot's sync, so the sync itself skips
# what either list opts out; the filter after it catches what an older sync misses.
refresh_align_exclude() {
  local ex="$CLAUDE_DIR/.sync-exclude" wx="$WT/.claude/.sync-exclude"
  exclude_join "nothing listed" || return 0
  if [ ! -f "$ex" ]; then
    log "   .sync-exclude: the primary has none; origin/$DEFAULT's applies"
  elif [ ! -f "$wx" ]; then
    log "   .sync-exclude: origin/$DEFAULT has none; the primary's applies"
  elif ! cmp -s "$ex" "$wx"; then
    log "   .sync-exclude: the primary's differs from origin/$DEFAULT's; opt-outs from both apply"
  fi
  # Origin's committed list, with no CR and nothing to add, is already what the sync reads.
  if [ -f "$wx" ] && ! grep -q "$(printf '\r')" "$wx" && { [ ! -f "$ex" ] || cmp -s "$ex" "$wx"; }; then
    return 0
  fi
  { rm -f "$wx" && mkdir -p "$WT/.claude" && cp "$RTMP/x/.sync-exclude" "$wx"; } \
    || die "cannot write the joined .sync-exclude into $WT" 5
  # The clone's .claude/ now differs from its commit, and the sync refuses a dirty
  # .claude/ unless told otherwise. The clone is removed after the comparison.
  export PWT_SYNC_ALLOW_DIRTY=1
}
# Write one file through a temp file in the primary's git directory, where git status
# never shows it. A missing directory is made one level at a time, each checked, so none
# is made through a link. The path is checked again just before the move, and after it
# the directory's physical path must still be the one below the primary. A link swapped
# in on the way, or at the destination, is reported, and what landed through it is
# removed: the temp name inside a destination that became a directory, or the written
# file where a parent resolved outside the primary.
refresh_write() {
  local p="$1" mode="$2" dest="$ROOT/$1" dir d rest want now
  dir="$(dirname "$dest")"
  _refresh_path_safe "$p" || return 1
  d="$ROOT"; rest="$p"
  while :; do
    case "$rest" in */*) ;; *) break ;; esac
    d="$d/${rest%%/*}"; rest="${rest#*/}"
    [ -d "$d" ] || mkdir "$d" 2>/dev/null || return 1
    { [ ! -L "$d" ] && [ -d "$d" ]; } || return 1
  done
  want="$REFRESH_ROOT_P/${p%/*}"
  now="$(cd "$dir" 2>/dev/null && pwd -P)" && [ "$now" = "$want" ] || return 1
  REFRESH_TMP="$(mktemp "$REFRESH_GITDIR/cp-refresh.XXXXXX" 2>/dev/null)" || { REFRESH_TMP=""; return 1; }
  if cp "$WT/$p" "$REFRESH_TMP" 2>/dev/null && chmod "$mode" "$REFRESH_TMP" \
     && _refresh_path_safe "$p" && [ ! -L "$dest" ] && { [ ! -e "$dest" ] || [ -f "$dest" ]; } \
     && mv -f "$REFRESH_TMP" "$dest" 2>/dev/null; then
    now="$(cd "$dir" 2>/dev/null && pwd -P)" || now=""
    if [ "$now" = "$want" ] && [ -f "$dest" ] && [ ! -L "$dest" ] && [ ! -e "$REFRESH_TMP" ]; then
      REFRESH_TMP=""; return 0
    fi
    [ -d "$dest" ] && rm -f "$dest/$(basename "$REFRESH_TMP")"
    if [ -n "$now" ] && [ "$now" != "$want" ] && [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$WT/$p" "$dest"; then
      rm -f "$dest"
    fi
  fi
  rm -f "$REFRESH_TMP"; REFRESH_TMP=""
  return 1
}
refresh_ignored_corpus() {
  local p arg dest state sha rc grc sx dx held frozen_re nl=$'\n' cr=$'\r' tab=$'\t'
  local n_new=0 n_chg=0 n_same=0 n_opt=0 n_skip=0 n_fail=0 n_unign=0 n_hold=0
  { [ -n "$RTMP" ] && [ -d "$RTMP" ]; } || die "no temp dir for the refresh" 5
  # The clone started with no untracked files, so each file listed here came from the sync.
  git -C "$WT" ls-files -z --others --ignored --exclude-standard -- tests/skill .claude/scripts .claude/hooks \
    > "$RTMP/wt" 2>/dev/null || die "cannot list the ignored files the sync wrote into $WT" 5
  git -C "$ROOT" ls-files -z > "$RTMP/tracked0" 2>/dev/null || die "cannot list the files $ROOT tracks — nothing listed" 4
  tr '\0' '\n' < "$RTMP/tracked0" > "$RTMP/tracked"
  : > "$RTMP/safe"
  while IFS= read -r -d '' p; do
    case "$p" in *[\"\\]*|*"$nl"*|*"$cr"*|*"$tab"*)
      n_skip=$((n_skip + 1)); log "  skip    $(printf '%q' "$p") (unusual path)"; continue ;;
    esac
    case "/$p/" in */../*|*/./*) n_skip=$((n_skip + 1)); log "  skip    $p (unusual path)"; continue ;; esac
    if [ -L "$WT/$p" ] || [ ! -f "$WT/$p" ]; then
      n_skip=$((n_skip + 1)); log "  skip    $p (not a regular file in the synced tree)"; continue
    fi
    case "$p" in .claude/*) arg="$p" ;; *) arg="../$p" ;; esac
    if [ "$EXCLUDE_MATCHER" = 1 ] && retired_paths_sync_excluded "$arg" "$RTMP/x"; then
      n_opt=$((n_opt + 1)); log "  SKIP    $arg — matched by .sync-exclude"; continue
    fi
    if ! _refresh_path_safe "$p"; then
      n_skip=$((n_skip + 1)); log "  skip    $p (a symlink, a non-directory or another repository is on its path)"; continue
    fi
    printf '%s\n' "$p" >> "$RTMP/safe"
  done < "$RTMP/wt"
  # A path the primary tracks, in any case, or one below a tracked path (a submodule)
  # is never a candidate. git check-ignore compares case-sensitively, so it would
  # report a case variant of a tracked file as ignored.
  : > "$RTMP/trk"; : > "$RTMP/keep"
  awk -v trk="$RTMP/trk" -v keep="$RTMP/keep" '
    FILENAME == ARGV[1] { t[tolower($0)] = 1; next }
    { l = tolower($0); hit = (l in t)
      while (!hit && (i = match(l, /\/[^\/]*$/)) > 0) { l = substr(l, 1, i - 1); if (l in t) hit = 1 }
      if (hit) print > trk; else print > keep }' "$RTMP/tracked" "$RTMP/safe"
  while IFS= read -r p; do
    n_skip=$((n_skip + 1)); log "  skip    $p (tracked in the primary, ignoring case, or below a tracked path)"
  done < "$RTMP/trk"
  : > "$RTMP/cand"
  if [ -s "$RTMP/keep" ]; then
    git -C "$ROOT" -c core.quotePath=false check-ignore --stdin < "$RTMP/keep" > "$RTMP/cand" 2> "$RTMP/err"
    rc=$?
    [ "$rc" -le 1 ] || die "git check-ignore failed in $ROOT (exit $rc: $(head -1 "$RTMP/err")) — nothing listed" 4
  fi
  # The clone ignores these but the primary does not: its .gitignore lacks a rule that
  # origin has or that the sync adds, and the sync PR carries that rule and the file.
  awk 'FILENAME == ARGV[1] { c[$0] = 1; next } !($0 in c)' "$RTMP/cand" "$RTMP/keep" > "$RTMP/unign"
  while IFS= read -r p; do
    n_unign=$((n_unign + 1))
    [ "$n_unign" -le 20 ] && log "  skip    $p (not ignored in the primary)"
  done < "$RTMP/unign"
  [ "$n_unign" -le 20 ] || log "  skip    … $((n_unign - 20)) more not ignored in the primary"
  # A test of a script the consumer froze is held back: the frozen copy predates it, so
  # it would fail there (cleanscale froze pwt-goal.sh and the goal evaluator, and the
  # 2.59.1 tests of both would have gone red on it). The frozen names are the file names
  # of the source's scripts that the joined list opts out; a corpus file that names one,
  # standing as a whole name, is held. A test file is not a frozen name, and a name
  # shared by two scripts holds both, which errs toward keeping the consumer's copy.
  : > "$RTMP/frozen"
  if [ "$EXCLUDE_MATCHER" = 1 ]; then
    git -C "$SNAP" ls-files -z > "$RTMP/src0" 2>/dev/null || die "cannot list the snapshot's files — nothing listed" 5
    while IFS= read -r -d '' p; do
      case "$p" in *.test.*|*.bats) continue ;; *.sh|*.bash|*.py|*.js|*.mjs|*.cjs|*.ts) ;; *) continue ;; esac
      case "${p##*/}" in *[!A-Za-z0-9_.-]*) continue ;; esac
      case "$p" in .claude/*) arg="$p" ;; *) arg="../$p" ;; esac
      if retired_paths_sync_excluded "$arg" "$RTMP/x"; then printf '%s\n' "${p##*/}" >> "$RTMP/frozen"; fi
    done < "$RTMP/src0"
  fi
  frozen_re=""
  if [ -s "$RTMP/frozen" ]; then
    frozen_re="(^|[^[:alnum:]_.-])($(sort -u "$RTMP/frozen" | sed 's/\./\\./g' | paste -sd'|' -))([^[:alnum:]_.-]|\$)"
  fi
  while IFS= read -r p; do
    dest="$ROOT/$p"
    if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
      n_skip=$((n_skip + 1)); log "  skip    $p (a symlink or a non-file is at the destination)"; continue
    fi
    sx=644; [ -x "$WT/$p" ] && sx=755
    state=new
    if [ -f "$dest" ]; then
      dx=644; [ -x "$dest" ] && dx=755
      if [ "$sx" = "$dx" ] && cmp -s "$WT/$p" "$dest"; then n_same=$((n_same + 1)); continue; fi
      state=changed
    fi
    if [ -n "$frozen_re" ]; then
      grc=0; grep -a -E -o -m1 "$frozen_re" "$WT/$p" > "$RTMP/held" 2>/dev/null || grc=$?
      if [ "$grc" -gt 1 ]; then   # unread is not clean: the file is not written
        n_skip=$((n_skip + 1)); log "  skip    $p (could not be checked for the scripts .sync-exclude keeps)"; continue
      fi
      if [ "$grc" = 0 ]; then
        held="$(head -1 "$RTMP/held" | sed -e 's/^[^[:alnum:]_.-]//' -e 's/[^[:alnum:]_.-]$//')"
        n_hold=$((n_hold + 1)); log "  HOLD    $p — names $held, which .sync-exclude keeps"; continue
      fi
    fi
    if [ "$state" = new ]; then n_new=$((n_new + 1)); else n_chg=$((n_chg + 1)); fi
    sha="$(_sha256 < "$WT/$p")"
    log "  $(printf '%-7s' "$state") $sha  $p"
    [ "$APPLY" = 1 ] || continue
    refresh_write "$p" "$sx" || { n_fail=$((n_fail + 1)); warn "could not write $p"; }
  done < "$RTMP/cand"
  log "   $n_new new, $n_chg changed, $n_same identical, $n_opt opted out, $n_skip skipped, $n_unign not ignored in the primary"
  if [ "$n_unign" -gt 0 ]; then
    log "   the primary's .gitignore does not ignore $n_unign shipped file(s) yet; once it has the .gitignore rule (merge the sync PR, fast-forward), refresh again"
  fi
  if [ "$n_hold" -gt 0 ]; then
    log "   $n_hold held: each names a script .sync-exclude keeps, and the consumer keeps its copy; port the script and its tests together"
  fi
  if [ "$APPLY" = 0 ]; then
    log "   dry run — nothing written; rerun with --apply to write the new and changed files"
  elif [ "$n_fail" -gt 0 ]; then
    die "$n_fail of $((n_new + n_chg)) file(s) could not be written" 5
  else
    log "   ✓ wrote $((n_new + n_chg)) file(s); tracked files and git status are unchanged"
  fi
}
if [ "$REFRESH" = 1 ]; then refresh_preflight; fi

# ── .sync-exclude binds the commit, whatever the snapshot's sync did ────────
# The snapshot's sync honours .sync-exclude, but it is the sync of the pulled --ref, and
# older ones missed paths (the required scripts before 2.57.0, `../` lines and CRLF lists
# before 2.57.1, a `.claude/` prefix before 2.60.0). It also reads origin's list only.
# So each path the sync changed, added or removed is checked again, by the newest
# matcher, against the joined list. An opted-out path goes back to origin's version, or
# is removed when origin has none, before the commit. A path that cannot be put back
# stops the pull, so an opted-out path never reaches a sync commit. Upstreamed from
# cleanscale #5257.
# The listing takes the working tree and the index, each against origin, and every
# untracked file, ignored ones included: putting back an opted-out .gitignore can
# un-ignore a file the sync wrote, and the commit would then stage it. A second listing
# after the loop must find nothing opted out, or the pull stops. The sync must not
# commit either; a HEAD that moved off origin stops the pull.
_sync_changed_list() {  # $1 = output file: NUL-separated, sorted, unique
  { git -C "$WT" diff --name-only -z --no-renames "$ORIGIN_SHA" -- \
      && git -C "$WT" diff --cached --name-only -z --no-renames "$ORIGIN_SHA" -- \
      && git -C "$WT" ls-files -z --others; } > "$1.raw" \
    && sort -z -u "$1.raw" > "$1"
}
_sync_excluded_arg() {  # $1 = repo-relative path; true when the joined list opts it out
  local arg
  case "$1" in .claude/*) arg="$1" ;; *) arg="../$1" ;; esac
  retired_paths_sync_excluded "$arg" "$RTMP/x"
}
sync_exclude_enforce() {
  local p arg n=0 head
  [ "$EXCLUDE_MATCHER" = 1 ] || return 0
  head="$(git -C "$WT" rev-parse --verify --quiet 'HEAD^{commit}')" || head=""
  [ "$head" = "$ORIGIN_SHA" ] \
    || die "the sync moved HEAD in $WT off origin/$DEFAULT — nothing committed" 5
  _sync_changed_list "$RTMP/changed" || die "cannot list what the sync changed in $WT — nothing committed" 5
  while IFS= read -r -d '' p; do
    [ "$p" = .claude/.sync-version ] && continue   # the pull's own stamp, written next
    _sync_excluded_arg "$p" || continue
    case "$p" in .claude/*) arg="$p" ;; *) arg="../$p" ;; esac
    if git -C "$WT" cat-file -e "$ORIGIN_SHA:$p" 2>/dev/null; then
      git -C "$WT" --literal-pathspecs checkout --quiet "$ORIGIN_SHA" -- "$p" >/dev/null 2>&1 \
        || die "could not put back $p, which .sync-exclude opts out — nothing committed" 5
      log "   ↺ $arg — matched by .sync-exclude; origin's version kept"
    else
      { git -C "$WT" --literal-pathspecs rm --quiet --cached --ignore-unmatch -- "$p" >/dev/null 2>&1 \
          && rm -f "$WT/$p"; } \
        || die "could not remove $p, which .sync-exclude opts out — nothing committed" 5
      log "   ↺ $arg — matched by .sync-exclude; origin has none, removed"
    fi
    n=$((n + 1))
  done < "$RTMP/changed"
  _sync_changed_list "$RTMP/left" || die "cannot list what the sync changed in $WT — nothing committed" 5
  while IFS= read -r -d '' p; do
    [ "$p" = .claude/.sync-version ] && continue
    if _sync_excluded_arg "$p"; then
      die "$p is still changed after it was put back, and .sync-exclude opts it out — nothing committed" 5
    fi
  done < "$RTMP/left"
  [ "$n" = 0 ] || log "   .sync-exclude: $n path(s) the sync wrote were put back before the commit"
}

# ── ff the primary checkout when origin already carries the version ─────────
# The only operation this script ever performs on the primary checkout.
ff_primary() {
  [ "$FF_PRIMARY" = 1 ] || return 0
  local cur clean
  cur="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [ "$cur" != "$DEFAULT" ]; then log "   primary: on '$cur', not $DEFAULT — left alone"; return 0; fi
  if [ -f "$ROOT/.git/index.lock" ]; then log "   primary: index.lock present — left alone"; return 0; fi
  clean="$(git -C "$ROOT" status --porcelain -uno 2>/dev/null)"
  if [ -n "$clean" ]; then
    log "   primary: tracked tree is dirty — left alone (a dirty primary is reported, never repaired):"
    printf '%s\n' "$clean" | head -5 | sed 's/^/      /'
    return 0
  fi
  if git -C "$ROOT" merge-base --is-ancestor "refs/remotes/origin/$DEFAULT" HEAD 2>/dev/null; then
    log "   primary: already at or ahead of origin/$DEFAULT"; return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then log "   primary: would fast-forward to origin/$DEFAULT (dry-run)"; return 0; fi
  if git -C "$ROOT" merge --ff-only --quiet "refs/remotes/origin/$DEFAULT" >/dev/null 2>&1; then
    log "   primary: fast-forwarded to origin/$DEFAULT ($(git -C "$ROOT" rev-parse --short HEAD))"
  else
    log "   primary: not fast-forwardable (local commits on $DEFAULT?) — left alone"
  fi
}

if [ "$FORCE" = 0 ] && [ "$REFRESH" = 0 ]; then
  if [ -n "$ORIGIN_STAMP" ] && [ "$ORIGIN_STAMP" = "$SRC_STAMP" ]; then
    log "   ✓ origin/$DEFAULT already carries stamp $SRC_STAMP — nothing to deliver"
    ff_primary; exit 0
  fi
  if [ -n "$ORIGIN_STAMP" ] && [[ "$SRC_STAMP" < "$ORIGIN_STAMP" ]]; then
    log "   ⚠ source stamp $SRC_STAMP is BEHIND origin/$DEFAULT ($ORIGIN_STAMP) — refusing to sync backwards"
    ff_primary; exit 0
  fi
  if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE" 2>/dev/null)" = "$SRC_SHA" ]; then
    log "   ✓ $SRC_SHORT already delivered (branch $BR) — awaiting merge into $DEFAULT"
    ff_primary; exit 0
  fi
  if git -C "$ROOT" rev-parse --verify --quiet "refs/remotes/origin/$BR" >/dev/null; then
    log "   ✓ origin already has $BR — awaiting merge into $DEFAULT (use --force to redo)"
    printf '%s' "$SRC_SHA" > "$STAMP_FILE"; ff_primary; exit 0
  fi
fi

if [ "$DRY_RUN" = 1 ] && [ "$REFRESH" = 0 ]; then
  log "   plan: snapshot $SRC_SHORT → worktree on $BR from origin/$DEFAULT ($(printf '%s' "$ORIGIN_SHA" | cut -c1-8)) → sync${PROFILE:+ --profile $PROFILE} → commit → deliver=$DELIVER"
  ff_primary; exit 0
fi

# ── clean snapshot of the source commit ─────────────────────────────────────
SNAP_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/claude-pattern-snap.XXXXXX")"
SNAP="$SNAP_PARENT/claude-pattern"
git clone --quiet --no-checkout "$SRC" "$SNAP" 2>/dev/null || die "cannot snapshot $SRC" 3
git -C "$SNAP" checkout --quiet --detach "$SRC_SHA" 2>/dev/null || die "cannot check out $SRC_SHORT" 3
SYNC="$SNAP/.claude/scripts/sync-to-project.sh"
COMMIT_LIB="$SNAP/.claude/scripts/sync-commit-lib.sh"
[ -f "$SYNC" ] || die "snapshot $SRC_SHORT has no sync-to-project.sh" 3
[ -f "$COMMIT_LIB" ] || die "snapshot $SRC_SHORT has no sync-commit-lib.sh" 3
chmod +x "$SYNC" 2>/dev/null || true

# ── temporary linked worktree of the consumer on a fresh branch ─────────────
if [ "$REFRESH" = 1 ]; then
  # A refresh needs no branch. A --shared clone borrows the consumer's objects, has
  # its own .git (hooks, config), and leaves no worktree entry behind.
  WT="$CACHE/wt/$KEY-$SRC_SHORT-refresh"
  [ -e "$WT" ] && rm -rf "$WT"
  git clone --quiet --shared --no-checkout "$ROOT" "$WT" >/dev/null 2>&1 || die "cannot clone $ROOT into $WT" 5
  # Origin is fetched here, into the clone's own objects and FETCH_HEAD, so the primary's
  # refs do not move and none of its hooks run. A relative local URL is the primary's.
  _ourl="$(git -C "$ROOT" remote get-url origin 2>/dev/null)"
  case "$_ourl" in /*|*:*) ;; *) _ourl="$ROOT/$_ourl" ;; esac
  if GIT_TERMINAL_PROMPT=0 git -C "$WT" fetch --quiet --no-tags "$_ourl" "refs/heads/$DEFAULT" >/dev/null 2>&1 \
     && _fsha="$(git -C "$WT" rev-parse --verify --quiet 'FETCH_HEAD^{commit}')"; then
    ORIGIN_SHA="$_fsha"
  else
    warn "fetch of the consumer's origin failed — using the primary's last known origin/$DEFAULT"
  fi
  GIT_LFS_SKIP_SMUDGE=1 git -C "$WT" checkout --quiet --detach "$ORIGIN_SHA" >/dev/null 2>&1 \
    || die "cannot check out origin/$DEFAULT into $WT" 5
  # A pull's linked worktree shares the primary's info/exclude and config, so a file
  # ignored only there never reaches a sync PR. The clone takes both, or it would not
  # see that file as ignored and the refresh would never list it.
  _pex="$(git -C "$ROOT" rev-parse --git-path info/exclude 2>/dev/null)" || _pex=""
  case "$_pex" in /*|"") ;; *) _pex="$ROOT/$_pex" ;; esac
  if [ -n "$_pex" ] && [ -f "$_pex" ]; then
    { mkdir -p "$WT/.git/info" && cp "$_pex" "$WT/.git/info/exclude"; } \
      || die "cannot copy the primary's info/exclude into $WT" 5
  fi
  _pxf="$(git -C "$ROOT" config --path --get core.excludesFile 2>/dev/null)" || _pxf=""
  if [ -n "$_pxf" ]; then
    case "$_pxf" in /*) ;; *) _pxf="$ROOT/$_pxf" ;; esac
    git -C "$WT" config core.excludesFile "$_pxf" || die "cannot set core.excludesFile in $WT" 5
  fi
  log "   temp clone: $WT (origin/$DEFAULT $(printf '%s' "$ORIGIN_SHA" | cut -c1-8))"
else
WT="$CACHE/wt/$KEY-$SRC_SHORT"
if [ -d "$WT" ]; then git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"; fi
git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
if ! git -C "$ROOT" worktree add --quiet -B "$BR" "$WT" "$ORIGIN_SHA" >/dev/null 2>&1; then
  WT=""; die "cannot create worktree on $BR (branch checked out elsewhere?)" 5
fi
log "   worktree: $WT ($BR from origin/$DEFAULT $(printf '%s' "$ORIGIN_SHA" | cut -c1-8))"
fi

# The shared commit lib's dirty check is the contract every sync commit passes
# (never bundle foreign work); in a fresh worktree it is trivially true, but it
# runs BEFORE the sync so the sync's own side effects can't trip it.
# shellcheck source=/dev/null
. "$COMMIT_LIB"
if ! DIRTY_DIAG="$(sync_commit_dirty_check "$WT")"; then
  warn "unexpected pre-existing work in the fresh worktree:"; printf '%s\n' "$DIRTY_DIAG" >&2; exit 5
fi

# ── run the SNAPSHOT's sync against the worktree ────────────────────────────
LOGF="$CACHE/logs/$KEY-$SRC_SHORT.log"
if [ "$REFRESH" = 1 ]; then
  LOGF="$CACHE/logs/$KEY-$SRC_SHORT.refresh.log"; refresh_align_exclude
else
  exclude_join "nothing committed" || true   # read before the sync, from origin's checkout
fi
: > "$LOGF"
if ! CLAUDE_PATTERN_ROOT="$SNAP" PWT_SYNC_BUNDLE_COMMIT=0 "$SYNC" "$WT" ${PROFILE:+--profile "$PROFILE"} >> "$LOGF" 2>&1; then
  warn "sync-to-project.sh failed — see $LOGF"; tail -20 "$LOGF" >&2; exit 5
fi
if grep -q '^🛑 SKIP' "$LOGF" 2>/dev/null; then
  warn "sync-to-project.sh refused the fresh worktree as dirty — see $LOGF"; exit 5
fi
[ "$REFRESH" = 1 ] || sync_exclude_enforce
# The snapshot stamps .sync-version itself; belt-and-braces so the origin
# equality check above is exact on the next run.
printf '%s\n' "$SRC_STAMP" > "$WT/.claude/.sync-version"
if [ "$REFRESH" = 1 ]; then refresh_ignored_corpus; exit 0; fi

# ── scoped commit via the snapshot's shared lib ─────────────────────────────
# The subject and the Claude-Pattern-Source trailer are a contract with consumers:
# cleanscale finds sync commits by them (its fork-regression lint, #7605). Change
# either only together with every consumer that reads it; the pull tests pin both.
COMMIT_MSG="chore: sync Claude Code updates from claude-pattern@$SRC_SHORT

Source: $REMOTE @ $SRC_SHA
Skill: /plan-w-team ${SRC_VERSION:-?} (sync stamp $SRC_STAMP)
Produced by claude-pattern-pull.sh in a temporary worktree on $BR;
the primary checkout was not written to. Log: $LOGF

Claude-Pattern-Source: $SRC_SHA"
commit_rc=0
sync_commit_stage_and_commit "$WT" "$COMMIT_MSG" >> "$LOGF" 2>&1 || commit_rc=$?
case "$commit_rc" in
  0) log "   committed $(git -C "$WT" rev-parse --short HEAD) on $BR" ;;
  2) log "   ✓ tree already matches $SRC_SHORT — nothing to deliver"; printf '%s' "$SRC_SHA" > "$STAMP_FILE"; ff_primary; exit 0 ;;
  *) warn "commit failed — see $LOGF"; tail -20 "$LOGF" >&2; exit 5 ;;
esac

# ── delivery ────────────────────────────────────────────────────────────────
# The push runs the consumer's own pre-push hook, like any other push: a sync is
# machinery, and the pull grants itself no exemption from the consumer's gates. A
# consumer that wants sync branches to push quickly makes its hook cheap for branch
# pushes and runs its suites when the PR merges (cleanscale #4133). Up to 2.59.1 the
# pull exported PWT_SKIP_PRE_PUSH_TEST=1 here, which also let a direct push to the
# default branch skip testing (cleanscale #5257).
push_branch() { git -C "$WT" push --quiet -u origin "$BR" >> "$LOGF" 2>&1; }
open_pr() {
  command -v gh >/dev/null 2>&1 || return 1
  local url
  url="$(git -C "$WT" -c core.pager=cat log -1 --format=%s)"
  if gh pr view "$BR" --repo "$(git -C "$ROOT" remote get-url origin)" >/dev/null 2>&1; then
    log "   PR for $BR already open"; return 0
  fi
  url="$(cd "$WT" && gh pr create --base "$DEFAULT" --head "$BR" \
      --title "chore: sync Claude Code updates from claude-pattern@$SRC_SHORT" \
      --body "Automated consumer pull of claude-pattern \`$SRC_SHA\` (/plan-w-team ${SRC_VERSION:-?}, stamp $SRC_STAMP).

Produced by \`claude-pattern-pull.sh\` in a temporary worktree; the primary checkout was never written to. Only sync-owned paths under \`.claude/\` (and the sync writer set) change.

🤖 Generated with [Claude Code](https://claude.com/claude-code)" 2>>"$LOGF")" || return 1
  log "   PR opened: $url"
}

delivered=""
case "$DELIVER" in
  direct)
    if git -C "$WT" push --quiet origin "HEAD:refs/heads/$DEFAULT" >> "$LOGF" 2>&1; then
      delivered="direct"; log "   ✓ pushed to origin/$DEFAULT ($(git -C "$WT" rev-parse --short HEAD))"
    else
      warn "direct push to origin/$DEFAULT rejected (protected? non-ff?) — falling back"
      if push_branch; then
        if open_pr; then delivered="pr"; else delivered="branch"; log "   branch $BR pushed — open a PR from it"; fi
      fi
    fi ;;
  pr)
    if push_branch; then
      if open_pr; then delivered="pr"; else delivered="branch"; log "   branch $BR pushed (gh unavailable or PR create failed) — open a PR from it"; fi
    fi ;;
  branch)
    if push_branch; then delivered="branch"; log "   ✓ branch $BR pushed to origin"; fi ;;
esac

if [ -z "$delivered" ]; then
  warn "delivery failed — the commit is on local branch $BR (worktree removed); see $LOGF"
  tail -10 "$LOGF" >&2
  # keep the local branch for the operator; drop the worktree via trap
  exit 6
fi
printf '%s' "$SRC_SHA" > "$STAMP_FILE"

# Drop the temp worktree now (trap would too) and the local branch — origin has it.
git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"; WT=""
git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
git -C "$ROOT" branch -D "$BR" >/dev/null 2>&1 || true
git -C "$ROOT" fetch --quiet origin "$DEFAULT" 2>/dev/null || true

case "$delivered" in
  direct) ff_primary ;;
  *) log "   primary: left alone until $BR is merged into $DEFAULT" ;;
esac
exit 0
