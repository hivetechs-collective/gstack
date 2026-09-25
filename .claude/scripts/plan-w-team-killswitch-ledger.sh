#!/usr/bin/env bash
# plan-w-team-killswitch-ledger.sh — family-wide kill-switch bypass ledger.
#
# WHY (recursive-followup row 27, pwt-grounding-eval residual #4): a kill-switched
# gate exits 0 with at most a transcript notice. Nothing reached .claude/state, the
# retro never saw it, and because pwt-goal.sh runs `env $LAUNCH_ENV claude` the
# operator's exported environment flows into every unattended worker — so an
# exported switch silently weakened every gate in exactly the runs nobody watches.
# This script keeps a durable per-run ledger of that activity, scored at retro
# (07-retro.md §8j-octies-bis) the way §8j-octies scores the stage-file bypass log.
#
#   snapshot  — called by plan-w-team-surface-status.sh at every stage. The first
#               call of a run writes one `init` row and, once that row is on disk,
#               an init marker beside the ledger; the init row is never minted again
#               for that run (and never by the retro, which passes --no-init), so a
#               ledger that later vanishes scores `missing`, never a clean 5. Also
#               one `env` row per family switch active in the session environment.
#               Family membership is by NAME PATTERN, so switches added later are
#               covered with no edit.
#   record    — called from a gate's kill-switch branch: one `hit` row. Catches the
#               inline one-shot the environment snapshot cannot see.
#   score     — the retro signal: ledger rows plus the caller's live environment,
#               minus sanctioned switches (built-in list ∪ the consumer sidecar as
#               COMMITTED on the default branch at the commit the run's init marker
#               pinned — never a working copy the run could edit, nor a ref it moved
#               later; a working copy that differs is reported as sidecar drift, or as
#               stale-base when it is just the copy its checkout's base commit carries).
#   sanctioned — prints the built-in sanctioned list (test-locked for equality
#               against the launcher's spawn environment).
#
# A row is written only for an EXPLICIT slug (--slug, or the basename of a
# `--spec .../docs/specs/<slug>.md` argument) whose workflow lock exists in the
# resolved state dir. No inference from "the only lock present": stale locks make
# that wrong in both directions. Operator contract, sanctioning sidecar and honest
# limits: docs/operations/killswitch-bypass-ledger.md.
#
# Fail-open by design: every path exits 0, and every gate / surface-status call
# discards the output, so the ledger can never change a gate's or a stage's
# outcome (only the retro consumes `score`'s JSON). It deliberately has no off
# switch of its own — an audit the audited environment can turn off is
# self-defeating (documented exception to "one kill switch per behaviour").
#
# Usage:
#   plan-w-team-killswitch-ledger.sh record   --switch NAME --site SITE
#                                             [--slug S] [--state-dir D] [--root R] [-- <gate argv>]
#   plan-w-team-killswitch-ledger.sh snapshot --slug S [--state-dir D] [--root R] [--site SITE] [--no-init]
#   plan-w-team-killswitch-ledger.sh score    --slug S [--state-dir D] [--root R]
#   plan-w-team-killswitch-ledger.sh sanctioned
#
# bash 3.2 compatible; needs only grep/sed/sort/wc/tr/cut/head/date/basename/dirname/env
# (plus git, optionally, for state-dir resolution and the committed sidecar — without
# git the sidecar is `unverified` and only the built-in list is sanctioned). No jq.
# Exit: always 0.
set -u

# Switches claude-pattern's own launcher sets for worker correctness (the DS2
# cascade guard). Consumers add their own via the sidecar, never here.
SANCTIONED_BUILTIN="PLAN_W_TEAM_DISABLE_PROMPT_ROUTE"
FAMILY_RE='^(PLAN_W_TEAM|PWT)_([A-Z0-9_]*_)?(DISABLE|FORCE_SPAWN)(_[A-Z0-9_]+)?$'
SIDECAR_NAME="killswitch-sanctioned.local.conf"

SUB="${1:-}"
[ $# -gt 0 ] && shift

SLUG=""; STATE_DIR=""; ROOT=""; SWITCH=""; SITE=""; NO_INIT=0
PT_SLUG=""; PT_SPEC=""; PT_ROOT=""
# Our own flags up to `--`; after `--` is the calling gate's argv, SCANNED (never
# executed) for --slug/--spec/--root. The LAST occurrence wins, exactly as the
# gates' own parsers resolve a repeated flag, so the ledger attributes the same
# slug the gate acted on. Our own flags beat anything in the passthrough.
# One-step shifts only: a trailing value-less flag cannot hang the loop.
PASSTHRU=0
while [ $# -gt 0 ]; do
  if [ "$PASSTHRU" = "1" ]; then
    case "$1" in
      --slug) [ $# -gt 1 ] && PT_SLUG="$2" ;;
      --spec) [ $# -gt 1 ] && PT_SPEC="$2" ;;
      --root) [ $# -gt 1 ] && PT_ROOT="$2" ;;
    esac
    shift
    continue
  fi
  case "$1" in
    --)          PASSTHRU=1 ;;
    --slug)      if [ $# -gt 1 ]; then SLUG="$2"; shift; fi ;;
    --state-dir) if [ $# -gt 1 ]; then STATE_DIR="$2"; shift; fi ;;
    --root)      if [ $# -gt 1 ]; then ROOT="$2"; shift; fi ;;
    --switch)    if [ $# -gt 1 ]; then SWITCH="$2"; shift; fi ;;
    --site)      if [ $# -gt 1 ]; then SITE="$2"; shift; fi ;;
    --no-init)   NO_INIT=1 ;;
  esac
  shift
done
[ -z "$ROOT" ] && ROOT="$PT_ROOT"

is_family() { printf '%s' "$1" | grep -Eq "$FAMILY_RE"; }

# A slug becomes part of a filename: the characters real slugs use, no leading
# dot, no path separator, no `..`.
valid_slug() {
  case "$1" in ''|*..*|*/*) return 1 ;; esac
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$'
}

# Explicit slug only: --slug, else the gate's --slug, else a --spec whose file sits
# DIRECTLY in a docs/specs directory (relative `docs/specs/<slug>.md`, the stage
# files' shape, or any `<root>/docs/specs/<slug>.md`). A spec anywhere else — or
# in a subdirectory of docs/specs — is not a run's spec and attributes nothing.
resolve_slug() {
  [ -n "$SLUG" ] && return 0
  if [ -n "$PT_SLUG" ]; then SLUG="$PT_SLUG"; return 0; fi
  if [ -n "$PT_SPEC" ]; then
    case "$PT_SPEC" in *.md) ;; *) return 1 ;; esac
    case "$(dirname "$PT_SPEC")" in
      docs/specs|*/docs/specs)
        SLUG="$(basename "$PT_SPEC" .md)"
        return 0 ;;
    esac
  fi
  return 1
}

# State dir: explicit --state-dir, else the first candidate root that holds this
# slug's workflow lock (the same lock-holding rule surface-status applies), so a
# gate, surface-status and the retro all land on one directory. The candidates
# include surface-status's own fallback root (the repo this script lives in) so
# the two lookups cannot diverge when CLAUDE_PROJECT_DIR is unset. LOCK_FOUND is
# set when the chosen dir holds the lock.
# git with the repository-location variables removed, so `-C <tree>` DISCOVERS the
# repository instead of obeying the caller's environment. An inherited GIT_DIR makes
# any directory — even one outside every repo — report its toplevel as itself and
# the common dir of the repo GIT_DIR names; GIT_COMMON_DIR redirects even a plain
# main checkout; GIT_WORK_TREE moves the toplevel. git itself exports GIT_DIR (and
# GIT_INDEX_FILE) into the processes its hooks spawn, so none of this is exotic.
# Scrubbing them means no exported variable can point the state-dir candidate, the
# sidecar lookup or the committed-copy read at another repository. EVERY git call in
# this script goes through here (static-pinned by the test suite).
git_scrubbed() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git "$@"
}

LOCK_FOUND=0
resolve_state_dir() {
  local cand top self first=""
  if [ -n "$STATE_DIR" ]; then
    [ -d "$STATE_DIR/plan-w-team-workflow-${SLUG}.lock" ] && LOCK_FOUND=1
    return 0
  fi
  # Scrubbed like every other git call: an exported GIT_DIR + GIT_WORK_TREE would
  # otherwise make the cwd's "toplevel" another repository, whose lock would then
  # receive this caller's rows.
  top="$(git_scrubbed rev-parse --show-toplevel 2>/dev/null || echo "")"
  self="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd || echo "")"
  for cand in "$ROOT" "$PWD" "$top" "${CLAUDE_PROJECT_DIR:-}" "$self"; do
    [ -n "$cand" ] || continue
    [ -z "$first" ] && [ -d "$cand/.claude/state" ] && first="$cand/.claude/state"
    if [ -d "$cand/.claude/state/plan-w-team-workflow-${SLUG}.lock" ]; then
      STATE_DIR="$cand/.claude/state"
      LOCK_FOUND=1
      return 0
    fi
  done
  STATE_DIR="$first"
  return 0
}

ledger_path() { printf '%s/plan-w-team-killswitch-ledger-%s.jsonl' "$STATE_DIR" "$SLUG"; }

# Refuse to read or append through anything but a plain file (or nothing yet):
# a FIFO planted at the ledger path would hang every surface-status call and gate
# kill branch; a symlink would redirect appends to an arbitrary file.
ledger_usable() {
  [ -L "$1" ] && return 1
  [ -e "$1" ] && [ ! -f "$1" ] && return 1
  return 0
}

# The init marker lives BESIDE the ledger, never inside the workflow-lock dir: that dir
# can be deleted and re-created (the documented manual override; before row 191 the
# pre-flight did it on every --resume / --ship-only, because the pid it recorded was a
# transient Bash-tool shell's), and a marker kept there vanished with it and let the
# next stage re-mint a clean `init` row over a deleted ledger. Once this marker exists
# an `init` row is never minted again: a ledger deleted mid-run stays `missing` at
# retro. It shares the ledger's `plan-w-team-killswitch-ledger-` prefix, so the
# janitor's PER_SLUG_REAP_PREFIXES reaps it with the run's family. Since R255 it also
# PINS the default branch: `ref=<full ref>` and `sha=<commit>` as they resolved when
# the init row was written (see read_pin). An empty marker (a 2.52.0 carry-forward, or
# no default branch at init) pins nothing. Residual: the marker lives in the run's own
# state dir, so a run that REWRITES it with a well-formed pin — a ref the writer could
# have produced, still the default, at a commit that ref still descends from — is
# trusted; a pin on any other ref reads as damaged and a re-pointed default reads
# `ref_moved`. A lane-guard deny on writes to this path (deferred) closes the rest.
init_marker() { printf '%s/plan-w-team-killswitch-ledger-%s.init' "$STATE_DIR" "$SLUG"; }
# Where 2.52.0 put the marker. A run that started under 2.52.0 still carries it there
# and it still suppresses a re-mint (carried forward to init_marker on first sight).
legacy_init_marker() { printf '%s/plan-w-team-workflow-%s.lock/killswitch-ledger.init' "$STATE_DIR" "$SLUG"; }

# Anything at the path counts as present — a dangling symlink included — so a
# marker path is never created, truncated or written through when something is there.
path_present() { [ -e "$1" ] || [ -L "$1" ]; }

# Create the marker if nothing is at its path (noclobber: no truncation, no race
# with a concurrent snapshot). Best-effort, like every write here. `mark_init pin`
# (the init row's own snapshot) records the default ref and its commit as they
# resolve NOW, so a ref the run rewrites later (`git update-ref`, a retargeted
# origin/HEAD, its own landing) cannot change what the retro reads as sanctioned. The
# carry-forward of a 2.52.0 marker pins nothing: that run's init time is unknown.
mark_init() {
  local m pin=""
  m="$(init_marker)"
  path_present "$m" && return 0
  if [ "${1:-}" = "pin" ] && command -v git >/dev/null 2>&1 && [ -d "$(dirname "$STATE_DIR")" ]; then
    resolve_default_ref "$(dirname "$STATE_DIR")"
    # Only a pin read_pin will accept is written; any other ref pins nothing.
    pin_valid "$DEFAULT_REF" "$DEFAULT_SHA" \
      && pin="$(printf 'ref=%s\nsha=%s' "$DEFAULT_REF" "$DEFAULT_SHA")"
  fi
  if [ -n "$pin" ]; then
    ( set -C; printf '%s\n' "$pin" > "$m" ) 2>/dev/null || true
  else
    ( set -C; : > "$m" ) 2>/dev/null || true
  fi
}

# The pin the init marker recorded. Sets PIN_STATE:
#   none — no marker, or an empty one: nothing pinned (score reads the current default)
#   ok   — PIN_REF / PIN_SHA hold a well-formed full ref and a commit id
#   bad  — anything else at the marker path (a symlink, a directory, a malformed or
#          extra line): the pin was damaged, so score reads no committed copy at all
PIN_STATE="none"; PIN_REF=""; PIN_SHA=""
read_pin() {
  local m body r s
  PIN_STATE="none"; PIN_REF=""; PIN_SHA=""
  [ -n "$STATE_DIR" ] || return 0
  m="$(init_marker)"
  path_present "$m" || return 0
  if [ -L "$m" ] || [ ! -f "$m" ]; then PIN_STATE="bad"; return 0; fi
  [ -s "$m" ] || return 0
  PIN_STATE="bad"
  # At most 512 bytes, read by the shell itself (no external `head`: score also runs
  # with a bare PATH, and a large or endless file must not be slurped).
  body=""
  IFS= read -r -d '' -n 512 body < "$m" 2>/dev/null || true
  [ "$(printf '%s\n' "$body" | sed '/^$/d' | wc -l | tr -d ' ')" = "2" ] || return 0
  r="$(printf '%s\n' "$body" | sed -n 's/^ref=//p')"
  s="$(printf '%s\n' "$body" | sed -n 's/^sha=//p')"
  pin_valid "$r" "$s" || return 0
  PIN_REF="$r"; PIN_SHA="$s"; PIN_STATE="ok"
}

# 0 when $1 is a ref the writer can produce — origin's remote-tracking branch (the
# target of origin/HEAD), refs/heads/main or refs/heads/master; see
# resolve_default_ref — in a plain character set, and $2 a full commit id (SHA-1 or
# SHA-256 hex). Shared by the writer and the reader, so a pin is only ever written in
# a form that reads back as one, and a pin naming any other ref (a run's own
# refs/heads/<lane>, a tag) reads as damaged: the run cannot anchor the sanctioned set
# on a branch it owns.
pin_valid() {
  case "$1" in refs/heads/main|refs/heads/master|refs/remotes/origin/?*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9._/-]*|*..*|*//*|*/) return 1 ;; esac
  case "$2" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#2}" -eq 40 ] || [ "${#2}" -eq 64 ]
}

# 0 when this run's `init` row was already minted (marker at either location).
init_minted() {
  path_present "$(init_marker)" && return 0
  if path_present "$(legacy_init_marker)"; then
    mark_init   # carry forward, so a later lock-dir reclaim cannot lose it
    return 0
  fi
  return 1
}

sanitize_site() {
  printf '%s' "${1:-unknown}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c1-64
}

# ONE definition of a ledger row, shared by dedup and score: a line in the exact
# fixed format append_row writes. A line that merely parses as JSON (a partial or
# reordered object, a bare {"source":"init"}) is NOT a row — so a planted
# look-alike can neither suppress a real row at write time nor be counted at
# score time, and the result never depends on whether jq is installed.
VALID_ROW_RE='^\{"ts":"[^"]*","slug":"[^"]*","switch":"[A-Z0-9_]*","source":"(init|env|hit)","site":"[A-Za-z0-9._-]*","sid":"[0-9a-f]*"\}$'
valid_rows() {
  [ -f "$1" ] && ledger_usable "$1" || return 0
  grep -E "$VALID_ROW_RE" "$1" 2>/dev/null || true
}

already_recorded() {   # $1 switch  $2 source  $3 site
  local ledger
  ledger="$(ledger_path)"
  [ -f "$ledger" ] || return 1
  case "$2" in
    hit) valid_rows "$ledger" | grep -Fq "\"switch\":\"$1\",\"source\":\"hit\",\"site\":\"$3\"" ;;
    *)   valid_rows "$ledger" | grep -Fq "\"switch\":\"$1\",\"source\":\"$2\"" ;;
  esac
}

append_row() {   # $1 switch ("" for init)  $2 source  $3 site (sanitized)
  local sid ts
  ledger_usable "$(ledger_path)" || return 0
  already_recorded "$1" "$2" "$3" && return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sid="$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | cut -c1-8 | LC_ALL=C tr 'A-F' 'a-f' | LC_ALL=C tr -cd '0-9a-f')"
  printf '{"ts":"%s","slug":"%s","switch":"%s","source":"%s","site":"%s","sid":"%s"}\n' \
    "$ts" "$SLUG" "$1" "$2" "$3" "$sid" >> "$(ledger_path)" 2>/dev/null || true
}

cmd_record() {
  [ -n "$SWITCH" ] || return 0
  is_family "$SWITCH" || return 0
  resolve_slug || return 0
  valid_slug "$SLUG" || return 0
  resolve_state_dir
  [ "$LOCK_FOUND" = "1" ] || return 0
  append_row "$SWITCH" hit "$(sanitize_site "$SITE")"
}

# Family switches whose value is exactly "1" in THIS process's environment — the
# family's own convention (every gate tests `= "1"` / `!= "1"`). Names come from
# bash's own exported-variable list and values by indirect expansion, never by
# parsing `env` output: a multi-line value elsewhere in the environment could
# otherwise forge a `NAME=1` line and plant a switch that is not set.
live_family_switches() {
  local name
  for name in $(compgen -e 2>/dev/null); do
    case "$name" in PLAN_W_TEAM_*|PWT_*) ;; *) continue ;; esac
    [ "${!name:-}" = "1" ] || continue
    is_family "$name" && printf '%s\n' "$name"
  done | LC_ALL=C sort -u
}

cmd_snapshot() {
  local site name
  [ -n "$SLUG" ] || return 0
  valid_slug "$SLUG" || return 0
  resolve_state_dir
  [ "$LOCK_FOUND" = "1" ] || return 0
  site="$(sanitize_site "${SITE:-snapshot}")"
  # The init row is minted once per run, by a stage emission — never by the retro
  # (--no-init), and never again once the init marker exists.
  if [ "$NO_INIT" = "0" ] && ! init_minted; then
    append_row "" init "$site"
    # Mark only once the init row is provably in the ledger. append_row is silent
    # when it refuses the path (a FIFO, symlink or directory) and when the write
    # fails (ENOSPC, a read-only file): a marker with no row behind it would pin
    # the run at `missing` for good, while no marker just lets the next stage retry.
    already_recorded "" init "$site" && mark_init pin
  fi
  for name in $(live_family_switches); do
    append_row "$name" env "$site"
  done
}

# The MAIN checkout's root when $1 is the top of a LINKED git worktree; nothing
# otherwise (the main checkout itself, a subdirectory of a checkout, no git, a
# submodule, a bare or separate-git-dir layout). The main checkout is taken to be the
# parent of the common git dir ONLY when that dir is named `.git` (the standard
# `<main>/.git`): a submodule's common dir is `<super>/.git/modules/<name>` and a
# bare or separate git dir is usually `<name>.git`, so neither yields a "main
# checkout". The exception is a bare repository or separate git dir that is itself
# named `.git` (`/X/.git`): for every tree using it other than `/X` — worktrees of a
# bare `/X/.git`, and a `--separate-git-dir=/X/.git` checkout and its worktrees —
# `/X` is treated as the main checkout and its working-copy sidecar is compared for
# drift (never sanctioned from). Harmless: `/X` is the operator's own directory
# holding the repository. Same git-common-dir idiom as the lane guard's
# __main_root_of, compared physically (`pwd -P`) because git reports resolved paths
# (/tmp vs /private/tmp on macOS).
main_checkout_of() {
  local tree top cdir main
  command -v git >/dev/null 2>&1 || return 0
  tree="$(cd "$1" 2>/dev/null && pwd -P)" || return 0
  top="$(git_scrubbed -C "$tree" rev-parse --show-toplevel 2>/dev/null)" || return 0
  top="$(cd "$top" 2>/dev/null && pwd -P)" || return 0
  [ "$top" = "$tree" ] || return 0
  cdir="$(git_scrubbed -C "$tree" rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$cdir" in
    '') return 0 ;;
    /*) ;;
    *)  cdir="$tree/$cdir" ;;
  esac
  [ "$(basename "$cdir")" = ".git" ] || return 0
  main="$(cd "$(dirname "$cdir")" 2>/dev/null && pwd -P)" || return 0
  [ "$main" = "$tree" ] && return 0
  printf '%s' "$main"
}

# WORKING-COPY sidecar files, deduplicated, one "<role> <path>" line each — compared
# against the committed copy to report drift, never a source of sanctioned names:
#   own  <tree>/.claude/killswitch-sanctioned.local.conf, <tree> being the checkout
#        that holds STATE_DIR — the run's own tree;
#   main when <tree> is a linked worktree, the same file in the MAIN checkout — where
#        an operator's uncommitted edit would sit.
sidecar_files() {
  local own main
  [ -n "$STATE_DIR" ] || return 0
  own="$(dirname "$STATE_DIR")/$SIDECAR_NAME"
  printf 'own %s\n' "$own"
  main="$(main_checkout_of "$(dirname "$(dirname "$STATE_DIR")")")"
  [ -n "$main" ] || return 0
  [ "$main/.claude/$SIDECAR_NAME" = "$own" ] && return 0
  printf 'main %s\n' "$main/.claude/$SIDECAR_NAME"
}

# The ONE sidecar parser, for the committed copy and every working copy alike: one
# name per line, `#` starts a comment, only the first word counts, anything that is
# not a family name is ignored. The first word is taken by parameter expansion (never
# an unquoted word-split, which would glob-expand a line like `PWT_DISABLE_*` against
# the cwd); CRLF-edited files are tolerated by dropping the carriage return.
sidecar_names() {   # sidecar text on stdin → family names, one per line
  local line name
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//')"
    name="${line%%[[:space:]]*}"
    [ -n "$name" ] || continue
    is_family "$name" && printf '%s\n' "$name"
  done
  return 0
}

# The default branch, as a FULL ref name and the commit it names: the target of
# refs/remotes/origin/HEAD, else refs/heads/main, else refs/heads/master. Full names
# only, each read with `show-ref --verify` (an exact ref, never rev-parse's short-name
# search, which tries refs/tags/<name> before refs/heads/<name> — a tag named `main`
# must not stand in for the branch), then peeled to a commit. The committed read uses
# that commit id, so nothing is resolved twice. $1 = a directory inside the repo.
# Sets DEFAULT_REF / DEFAULT_SHA; both empty when no default branch resolves.
DEFAULT_REF=""; DEFAULT_SHA=""
resolve_default_ref() {
  local head r sha
  DEFAULT_REF=""; DEFAULT_SHA=""
  head="$(git_scrubbed -C "$1" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || echo "")"
  case "$head" in refs/remotes/origin/?*) ;; *) head="" ;; esac
  for r in "$head" refs/heads/main refs/heads/master; do
    [ -n "$r" ] || continue
    sha="$(git_scrubbed -C "$1" show-ref --verify --hash "$r" 2>/dev/null | head -n 1)"
    [ -n "$sha" ] || continue
    sha="$(git_scrubbed -C "$1" rev-parse -q --verify "${sha}^{commit}" 2>/dev/null || echo "")"
    [ -n "$sha" ] || continue
    DEFAULT_REF="$r"; DEFAULT_SHA="$sha"
    return 0
  done
  return 0
}

# The committed sidecar's names at commit $2. $1 is the directory the sidecar sits in
# (<tree>/.claude), so the path resolves against it — a state dir nested below a
# checkout reads <sub>/.claude/<sidecar>, never the repository root's. Only a
# regular-file blob counts (a symlink, directory or submodule entry at that path is
# no sidecar). Returns 1 when the commit cannot be listed (reported `unverified`);
# no committed copy is simply no names.
committed_names() {
  local entry meta mode type sha tab
  tab="$(printf '\t')"
  entry="$(git_scrubbed -C "$1" ls-tree "$2" -- "$SIDECAR_NAME" 2>/dev/null)" || return 1
  entry="$(printf '%s\n' "$entry" | head -n 1)"
  [ -n "$entry" ] || return 0
  meta=${entry%%$tab*}   # "<mode> <type> <object>" — everything before the TAB
  mode="${meta%% *}"; meta="${meta#* }"
  type="${meta%% *}"; sha="${meta#* }"
  case "$mode" in 100644|100755) ;; *) return 0 ;; esac
  [ "$type" = "blob" ] || return 0
  git_scrubbed -C "$1" cat-file blob "$sha" 2>/dev/null | sidecar_names
  return 0
}

# Names in exactly one of two newline lists (sorted, unique).
names_xor() {
  { printf '%s\n' "$1" | sed '/^$/d' | grep -vxF -f <(printf '%s\n' "$2") || true
    printf '%s\n' "$2" | sed '/^$/d' | grep -vxF -f <(printf '%s\n' "$1") || true
  } | LC_ALL=C sort -u
}

# The names committed at the BASE of the checkout a working copy sits in — the copy
# that checkout carries when nothing in it changed the sidecar. $1 role, $2 the dir the
# sidecar sits in, $3 the anchor commit. For the run's own tree the base is where its
# HEAD meets the anchor (merge-base), so the run's own commits are never base: a copy it
# committed is still drift. For the main checkout it is that checkout's HEAD — the
# operator's branch, which the run does not commit to — so only an uncommitted edit
# there is drift. Returns 1 when no base resolves (the copy then counts as drift).
base_names() {
  local head base
  head="$(git_scrubbed -C "$2" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || echo "")"
  [ -n "$head" ] || return 1
  if [ "$1" = "own" ]; then
    base="$(git_scrubbed -C "$2" merge-base "$head" "$3" 2>/dev/null | head -n 1)"
  else
    base="$head"
  fi
  [ -n "$base" ] || return 1
  committed_names "$2" "$base"
}

# The sidecar half of the sanctioned set comes from the default branch's COMMITTED
# copy only, read at the ANCHOR commit: the commit the init marker pinned when the
# run's init row was written, or — with no pin (a run whose init predates R255, or an
# empty marker) — the commit the default ref names now. A pin that does not parse
# anchors nothing (unverified): a damaged pin never widens the sanctioned set. A
# working copy — the run's own tree's, or the main checkout's — is something the run
# itself (or an uncommitted edit) can change, so it never sanctions; when its names
# differ from the anchor copy's, that is reported. Sets:
#   SIDECAR_STATE  match      — the anchor copy was read; every working copy agrees
#                  drift      — the anchor copy was read; a working copy disagrees and
#                               is not its checkout's base copy (see base_names)
#                  stale-base — the anchor copy was read; every working copy that
#                               disagrees is exactly its checkout's base copy: the
#                               checkout was cut before, or sits beside, the anchor
#                               (an operator committed on the default branch since,
#                               or the main checkout is on another branch)
#                  unverified — no anchor copy could be read (no git, not a
#                               repository, no default branch, a damaged pin or a
#                               pinned commit that is gone): only the built-in list
#                               is sanctioned
#   SIDECAR_REF    the anchor's ref ("" when unverified)
#   SIDECAR_SHA    the anchor commit ("" when unverified)
#   SIDECAR_ANCHOR pinned | current | invalid — what the marker says to read from,
#                  whether or not git could read it
#   SIDECAR_MOVED  true when a pinned ref no longer resolves to the pinned commit or a
#                  descendant of it (rewound, force-pushed, deleted or re-pointed), or
#                  the default branch now resolves to a different ref than the pinned
#                  one (a retargeted origin/HEAD); the sanctioned set is still read at
#                  the pin
#   SIDECAR_SANC   the anchor copy's names (sorted, unique)
#   SIDECAR_DRIFT  names on which a drifting working copy and the anchor copy disagree,
#                  either way (sorted, unique). An absent working copy is not drift;
#                  a present one is compared by the names it sanctions, not its bytes.
#                  With no anchor, every working copy's names are listed here.
#   SIDECAR_STALE  the same, for the stale-base copies
SIDECAR_STATE="unverified"; SIDECAR_REF=""; SIDECAR_SHA=""; SIDECAR_ANCHOR=""
SIDECAR_MOVED="false"; SIDECAR_SANC=""; SIDECAR_DRIFT=""; SIDECAR_STALE=""
sidecar_eval() {
  local dir committed="" verified=0 line role conf wnames bnames diff drift="" stale=""
  local a_ref="" a_sha="" cur=""
  SIDECAR_STATE="unverified"; SIDECAR_REF=""; SIDECAR_SHA=""; SIDECAR_ANCHOR=""
  SIDECAR_MOVED="false"; SIDECAR_SANC=""; SIDECAR_DRIFT=""; SIDECAR_STALE=""
  [ -n "$STATE_DIR" ] || return 0
  dir="$(dirname "$STATE_DIR")"
  read_pin
  case "$PIN_STATE" in
    ok)  SIDECAR_ANCHOR="pinned" ;;
    bad) SIDECAR_ANCHOR="invalid" ;;
    *)   SIDECAR_ANCHOR="current" ;;
  esac
  if command -v git >/dev/null 2>&1 && [ -d "$dir" ]; then
    case "$PIN_STATE" in
      ok)
        a_ref="$PIN_REF"
        a_sha="$(git_scrubbed -C "$dir" rev-parse -q --verify "${PIN_SHA}^{commit}" 2>/dev/null || echo "")"
        if [ -n "$a_sha" ]; then
          cur="$(git_scrubbed -C "$dir" show-ref --verify --hash "$PIN_REF" 2>/dev/null | head -n 1)"
          [ -n "$cur" ] && cur="$(git_scrubbed -C "$dir" rev-parse -q --verify "${cur}^{commit}" 2>/dev/null || echo "")"
          if [ -z "$cur" ] || ! git_scrubbed -C "$dir" merge-base --is-ancestor "$a_sha" "$cur" 2>/dev/null; then
            SIDECAR_MOVED="true"
          fi
          # The writer pins the default ref as it resolves; when the default now
          # resolves to another ref (origin/HEAD retargeted, created or removed, main
          # created beside a master pin), the pinned ref is no longer the default.
          resolve_default_ref "$dir"
          [ "$DEFAULT_REF" = "$PIN_REF" ] || SIDECAR_MOVED="true"
        fi ;;
      bad) ;;
      *)
        resolve_default_ref "$dir"
        a_ref="$DEFAULT_REF"; a_sha="$DEFAULT_SHA" ;;
    esac
    if [ -n "$a_sha" ] && committed="$(committed_names "$dir" "$a_sha")"; then
      verified=1
      SIDECAR_REF="$a_ref"; SIDECAR_SHA="$a_sha"
      SIDECAR_SANC="$(printf '%s\n' "$committed" | sed '/^$/d' | LC_ALL=C sort -u)"
    fi
  fi
  while IFS= read -r line; do
    role="${line%% *}"; conf="${line#* }"
    [ -n "$conf" ] && [ -f "$conf" ] && [ -r "$conf" ] || continue
    wnames="$(sidecar_names < "$conf" | LC_ALL=C sort -u)"
    diff="$(names_xor "$wnames" "$SIDECAR_SANC")"
    [ -n "$diff" ] || continue
    if [ "$verified" = "1" ] && bnames="$(base_names "$role" "$(dirname "$conf")" "$SIDECAR_SHA")" \
       && [ "$wnames" = "$(printf '%s\n' "$bnames" | sed '/^$/d' | LC_ALL=C sort -u)" ]; then
      stale="$(printf '%s\n%s\n' "$stale" "$diff")"
    else
      drift="$(printf '%s\n%s\n' "$drift" "$diff")"
    fi
  done <<EOF
$(sidecar_files)
EOF
  SIDECAR_DRIFT="$(printf '%s\n' "$drift" | sed '/^$/d' | LC_ALL=C sort -u)"
  SIDECAR_STALE="$(printf '%s\n' "$stale" | sed '/^$/d' | LC_ALL=C sort -u)"
  if [ "$verified" = "1" ]; then
    if [ -n "$SIDECAR_DRIFT" ]; then SIDECAR_STATE="drift"
    elif [ -n "$SIDECAR_STALE" ]; then SIDECAR_STATE="stale-base"
    else SIDECAR_STATE="match"; fi
  fi
  return 0
}

# Built-in sanctioned list plus the committed sidecar's names (the caller dedupes;
# sidecar_eval must have run).
sanctioned_set() {
  printf '%s\n' $SANCTIONED_BUILTIN
  [ -n "$SIDECAR_SANC" ] && printf '%s\n' "$SIDECAR_SANC"
  return 0
}

json_array() {   # newline list on stdin → JSON string array (names are [A-Z0-9_] only)
  local out="" name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    out="${out:+$out,}\"$name\""
  done
  printf '[%s]' "$out"
}

cmd_score() {
  local ledger="" source="none" status="missing" lock="missing"
  local init=0 hits=0 envn=0 names="" all_names sanc distinct_list sanc_list distinct score valid

  if [ -n "$SLUG" ] && valid_slug "$SLUG"; then
    resolve_state_dir
    [ "$LOCK_FOUND" = "1" ] && lock="present"
    [ -n "$STATE_DIR" ] && ledger="$(ledger_path)"
  fi

  if [ -n "$ledger" ] && [ -f "$ledger" ]; then
    source="$ledger"
    valid="$(valid_rows "$ledger")"
    # An init row carries an empty switch; env/hit rows must name a family switch.
    init="$(printf '%s\n' "$valid" | grep -c '"switch":"","source":"init"' || true)"
    valid="$(printf '%s\n' "$valid" | grep -v '"source":"init"' \
             | while IFS= read -r row; do
                 n="$(printf '%s' "$row" | sed -n 's/.*"switch":"\([A-Z0-9_]*\)".*/\1/p')"
                 is_family "$n" && printf '%s\n' "$row"
               done)"
    hits="$(printf '%s\n' "$valid" | grep -c '"source":"hit"' || true)"
    envn="$(printf '%s\n' "$valid" | grep -c '"source":"env"' || true)"
    names="$(printf '%s\n' "$valid" | sed -n 's/.*"switch":"\([A-Z0-9_]*\)".*/\1/p')"
  fi
  case "$init" in ''|*[!0-9]*) init=0 ;; esac
  case "$hits" in ''|*[!0-9]*) hits=0 ;; esac
  case "$envn" in ''|*[!0-9]*) envn=0 ;; esac
  [ "$init" -gt 0 ] && status="ok"

  # Ledger rows ∪ the caller's live environment: a run whose lock or ledger went
  # missing still has its exported switches counted at retro.
  all_names="$( { printf '%s\n' "$names"; live_family_switches; } | sed '/^$/d' | LC_ALL=C sort -u)"
  sidecar_eval
  sanc="$(sanctioned_set | sed '/^$/d' | LC_ALL=C sort -u)"
  distinct_list="$(printf '%s\n' "$all_names" | sed '/^$/d' | grep -vxF -f <(printf '%s\n' "$sanc") || true)"
  sanc_list="$(printf '%s\n' "$all_names" | sed '/^$/d' | grep -xF -f <(printf '%s\n' "$sanc") || true)"
  distinct="$(printf '%s\n' "$distinct_list" | sed '/^$/d' | wc -l | tr -d ' ')"
  case "$distinct" in ''|*[!0-9]*) distinct=0 ;; esac

  if [ "$status" != "ok" ]; then score="null"
  elif [ "$distinct" -le 0 ]; then score=5
  elif [ "$distinct" -eq 1 ]; then score=4
  elif [ "$distinct" -eq 2 ]; then score=3
  elif [ "$distinct" -eq 3 ]; then score=2
  else                             score=1
  fi

  printf '{"status":"%s","lock":"%s","distinct":%d,"hits":%d,"env":%d,"switches":%s,"sanctioned_active":%s,"sidecar":"%s","sidecar_ref":"%s","sidecar_sha":"%s","sidecar_anchor":"%s","sidecar_ref_moved":%s,"sidecar_drift":%s,"sidecar_stale":%s,"score":%s,"source":"%s"}\n' \
    "$status" "$lock" "$distinct" "$hits" "$envn" \
    "$(printf '%s\n' "$distinct_list" | json_array)" \
    "$(printf '%s\n' "$sanc_list" | json_array)" \
    "$SIDECAR_STATE" "$(printf '%s' "$SIDECAR_REF" | sed 's/["\\]/_/g')" \
    "$(printf '%s' "$SIDECAR_SHA" | LC_ALL=C tr -cd '0-9a-f')" "$SIDECAR_ANCHOR" "$SIDECAR_MOVED" \
    "$(printf '%s\n' "$SIDECAR_DRIFT" | json_array)" \
    "$(printf '%s\n' "$SIDECAR_STALE" | json_array)" \
    "$score" "$(printf '%s' "$source" | sed 's/["\\]/_/g')"
}

case "$SUB" in
  record)     cmd_record ;;
  snapshot)   cmd_snapshot ;;
  score)      cmd_score ;;
  sanctioned) printf '%s\n' $SANCTIONED_BUILTIN ;;
  *)          echo "usage: plan-w-team-killswitch-ledger.sh {record|snapshot|score|sanctioned} [opts]" >&2 ;;
esac
exit 0
