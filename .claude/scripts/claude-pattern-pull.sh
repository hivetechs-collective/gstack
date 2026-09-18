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
#   4. Delivery (--deliver / .claude/.sync-policy):
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
#     --cache <dir>          cache dir (default: $CLAUDE_PATTERN_PULL_CACHE or ~/.cache/claude-pattern)
#
# Policy file (consumer-authored, never synced over): <root>/.claude/.sync-policy
#   mode=pull|regen        (read by session-start.sh; this script ignores it)
#   deliver=direct|pr|branch
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
#   7 another run holds the lock
#
# bash 3.2 compatible (mac-mini). Never prints tokens; never uses --force on git.

set -u

CANONICAL_REMOTE="git@github.com:veronelazio/claude-pattern.git"
ROOT_ARG=""; REF=""; REMOTE=""; DELIVER=""; PROFILE=""; DRY_RUN=0; AUTO=0; FORCE=0
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
    -h|--help) usage; exit 0 ;;
    -*) echo "claude-pattern-pull: unknown option $1" >&2; usage >&2; exit 2 ;;
    *) if [ -z "$ROOT_ARG" ]; then ROOT_ARG="$1"; shift; else echo "claude-pattern-pull: too many arguments" >&2; exit 2; fi ;;
  esac
done

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
git -C "$ROOT" fetch --quiet --prune origin 2>/dev/null || warn "fetch of consumer origin failed — using last known refs"
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
SNAP_PARENT=""; WT=""; BR=""
cleanup() {
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
    git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
  fi
  [ -n "$SNAP_PARENT" ] && [ -d "$SNAP_PARENT" ] && rm -rf "$SNAP_PARENT"
  rm -rf "$LOCK"
}
trap cleanup EXIT INT TERM
date +%s > "$COOLDOWN_FILE"

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

if [ "$FORCE" = 0 ]; then
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

if [ "$DRY_RUN" = 1 ]; then
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
WT="$CACHE/wt/$KEY-$SRC_SHORT"
if [ -d "$WT" ]; then git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"; fi
git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
if ! git -C "$ROOT" worktree add --quiet -B "$BR" "$WT" "$ORIGIN_SHA" >/dev/null 2>&1; then
  WT=""; die "cannot create worktree on $BR (branch checked out elsewhere?)" 5
fi
log "   worktree: $WT ($BR from origin/$DEFAULT $(printf '%s' "$ORIGIN_SHA" | cut -c1-8))"

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
: > "$LOGF"
if ! CLAUDE_PATTERN_ROOT="$SNAP" PWT_SYNC_BUNDLE_COMMIT=0 "$SYNC" "$WT" ${PROFILE:+--profile "$PROFILE"} >> "$LOGF" 2>&1; then
  warn "sync-to-project.sh failed — see $LOGF"; tail -20 "$LOGF" >&2; exit 5
fi
if grep -q '^🛑 SKIP' "$LOGF" 2>/dev/null; then
  warn "sync-to-project.sh refused the fresh worktree as dirty — see $LOGF"; exit 5
fi
# The snapshot stamps .sync-version itself; belt-and-braces so the origin
# equality check above is exact on the next run.
printf '%s\n' "$SRC_STAMP" > "$WT/.claude/.sync-version"

# ── scoped commit via the snapshot's shared lib ─────────────────────────────
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
# The sync commit touches only sync-owned paths; the consumer's application
# pre-push gate (cleanscale: a 45-minute make test-all) is not the arbiter of a
# skill sync, and a queue of pushes behind that gate lock is exactly the failure
# this script replaces. PWT_SKIP_PRE_PUSH_TEST is the documented standing grant.
export PWT_SKIP_PRE_PUSH_TEST=1
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
