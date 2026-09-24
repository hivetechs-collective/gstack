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
#               minus sanctioned switches (built-in list ∪ the consumer sidecar, read
#               from the run's own tree and, for a linked worktree, the main checkout).
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
# bash 3.2 compatible; needs only grep/sed/sort/wc/tr/cut/date/basename/dirname/env
# (plus git, optionally, for state-dir and main-checkout resolution). No jq.
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
LOCK_FOUND=0
resolve_state_dir() {
  local cand top self first=""
  if [ -n "$STATE_DIR" ]; then
    [ -d "$STATE_DIR/plan-w-team-workflow-${SLUG}.lock" ] && LOCK_FOUND=1
    return 0
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
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

# The init marker lives BESIDE the ledger, never inside the workflow-lock dir: the
# pre-flight reclaims that dir (rm -rf + mkdir) whenever its recorded pid is dead —
# which is every --resume / --ship-only re-acquire, because the pid is a transient
# Bash-tool shell's — so a marker kept there vanished mid-run and let the next stage
# re-mint a clean `init` row over a deleted ledger. Once this marker exists an `init`
# row is never minted again: a ledger deleted mid-run stays `missing` at retro. It
# shares the ledger's `plan-w-team-killswitch-ledger-` prefix, so the janitor's
# PER_SLUG_REAP_PREFIXES reaps it with the run's family.
init_marker() { printf '%s/plan-w-team-killswitch-ledger-%s.init' "$STATE_DIR" "$SLUG"; }
# Where 2.52.0 put the marker. A run that started under 2.52.0 still carries it there
# and it still suppresses a re-mint (carried forward to init_marker on first sight).
legacy_init_marker() { printf '%s/plan-w-team-workflow-%s.lock/killswitch-ledger.init' "$STATE_DIR" "$SLUG"; }

# Anything at the path counts as present — a dangling symlink included — so a
# marker path is never created, truncated or written through when something is there.
path_present() { [ -e "$1" ] || [ -L "$1" ]; }

# Create the marker if nothing is at its path (noclobber: no truncation, no race
# with a concurrent snapshot). Best-effort, like every write here.
mark_init() {
  local m
  m="$(init_marker)"
  path_present "$m" && return 0
  ( set -C; : > "$m" ) 2>/dev/null || true
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
    already_recorded "" init "$site" && mark_init
  fi
  for name in $(live_family_switches); do
    append_row "$name" env "$site"
  done
}

# git with the repository-location variables removed, so `-C <tree>` DISCOVERS the
# repository instead of obeying the caller's environment. An inherited GIT_DIR makes
# any directory — even one outside every repo — report its toplevel as itself and
# the common dir of the repo GIT_DIR names; GIT_COMMON_DIR redirects even a plain
# main checkout; GIT_WORK_TREE moves the toplevel. git itself exports GIT_DIR (and
# GIT_INDEX_FILE) into the processes its hooks spawn, so none of this is exotic.
# Scrubbing them means no exported variable can point the sidecar lookup at another
# repository's file.
git_scrubbed() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git "$@"
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
# `/X` is treated as the main checkout and its sidecar is read. Harmless: `/X` is the
# operator's own directory holding the repository (whoever can write there can
# replace the repository itself). Same git-common-dir idiom as the lane guard's
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

# Sidecar files in lookup order, deduplicated:
#   1. <tree>/.claude/killswitch-sanctioned.local.conf, <tree> being the checkout
#      that holds STATE_DIR — the run's own tree, so a COMMITTED sidecar reaches
#      every worktree lane;
#   2. when <tree> is a linked worktree, the same file in the MAIN checkout — so an
#      operator's uncommitted .local.conf in the primary checkout also covers the
#      worktree lanes, which never see an untracked file otherwise.
sidecar_files() {
  local own main
  [ -n "$STATE_DIR" ] || return 0
  own="$(dirname "$STATE_DIR")/$SIDECAR_NAME"
  printf '%s\n' "$own"
  main="$(main_checkout_of "$(dirname "$(dirname "$STATE_DIR")")")"
  [ -n "$main" ] || return 0
  [ "$main/.claude/$SIDECAR_NAME" = "$own" ] && return 0
  printf '%s\n' "$main/.claude/$SIDECAR_NAME"
}

# Built-in sanctioned list plus valid names from every sidecar (union; the caller
# dedupes): one name per line, `#` starts a comment, anything that is not a family
# name is ignored — identically for each file.
sanctioned_set() {
  local conf line name
  printf '%s\n' $SANCTIONED_BUILTIN
  sidecar_files | while IFS= read -r conf; do
    [ -n "$conf" ] && [ -f "$conf" ] && [ -r "$conf" ] || continue
    # First word of each line, taken by parameter expansion (never an unquoted
    # word-split, which would glob-expand a line like `PWT_DISABLE_*` against the
    # cwd). CRLF-edited files are tolerated by dropping the carriage return.
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//')"
      name="${line%%[[:space:]]*}"
      [ -n "$name" ] || continue
      is_family "$name" && printf '%s\n' "$name"
    done < "$conf"
  done
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
  sanc="$(sanctioned_set | LC_ALL=C sort -u)"
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

  printf '{"status":"%s","lock":"%s","distinct":%d,"hits":%d,"env":%d,"switches":%s,"sanctioned_active":%s,"score":%s,"source":"%s"}\n' \
    "$status" "$lock" "$distinct" "$hits" "$envn" \
    "$(printf '%s\n' "$distinct_list" | json_array)" \
    "$(printf '%s\n' "$sanc_list" | json_array)" \
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
