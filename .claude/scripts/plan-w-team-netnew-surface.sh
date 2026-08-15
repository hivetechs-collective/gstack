#!/usr/bin/env bash
# plan-w-team-netnew-surface.sh
#
# Gap A1/A6/C2 (1.33.0): a COMPLEMENTARY documentation scan that detects genuinely
# NEW public surface introduced by a diff and verifies each item maps to a doc
# target (or is explicitly waived). The Step-7 §7a basename-grep audit is blind to
# net-new surface — a brand-new script/hook/module/CLI-flag/env-var that no doc
# references yet produces ZERO candidates and is silently skipped. This scan closes
# that hole by enumerating ADDED files (`git diff --diff-filter=A`) plus added-line
# symbols / long-flags / env-vars, then mapping each to a doc that references it.
#
# It EXTENDS, never replaces, the existing §7a scan; it does not weaken any gate.
#
# Net-new surface kinds detected:
#   file   — a newly ADDED tracked file that is "public surface" (source/script/
#            hook/agent/config-reference). Hooks/scripts additionally REQUIRE a
#            docs/operations/* page that names them (gap A6).
#   env    — a NEW environment variable read in added lines (process.env.X,
#            os.environ/os.getenv, Deno.env.get, std::env::var, getenv("X")).
#   symbol — a NEW exported/public symbol in added lines (TS/JS export fn|const|
#            class|type|interface; py top-level def/class; rust pub fn|struct|enum;
#            go exported func).
#   flag   — a NEW long CLI option (--foo-bar) in added lines of non-doc files.
#
# A surface item is DOCUMENTED if any repo doc (*.md/*.rst/*.adoc, excluding
# vendored + docs/specs + the item's own file) references it; otherwise it is
# UNDOCUMENTED unless listed in the waiver file.
#
# Modes / options:
#   --range A..B        Explicit git range (default: $BASE..HEAD)
#   --base REF          Base ref for the default range (default: origin/<main>)
#   --slug SLUG         Locate the default waiver file for this run
#   --waive-file FILE   Override waiver file path
#   --json              Emit newline-delimited JSON per item
#   --quiet             Suppress the human summary (exit code still set)
#   --help
#
# Exit codes:
#   0  no UNDOCUMENTED residual (clean, or all waived)
#   1  one or more UNDOCUMENTED net-new surface items remain
#   2  bad arguments / environment error
#
# Waiver file format: one path-or-token per line; "#" starts a comment; blank
# lines ignored. A line of "*" waives everything (escape hatch — recorded).
#
# bash 3.2 compatible (mac-mini /bin/bash): no `declare -A`, no `${var^^}`,
# zsh-array-safe loops.

set -u
set -o pipefail

RANGE=""
BASE=""
SLUG=""
WAIVE_FILE=""
JSON_OUT=false
QUIET=false

usage() { sed -n '2,/^# bash 3.2/p' "$0" | sed -E 's|^#[[:space:]]?||'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --range) RANGE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --base) BASE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --slug) SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --waive-file) WAIVE_FILE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --json) JSON_OUT=true; shift ;;
    --quiet) QUIET=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "git required" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo" >&2; exit 2; }

# Resolve the diff range.
#
# BASE_UNRESOLVED marks "we never found a real base to diff against". The old
# fallback was BASE="HEAD", i.e. the range HEAD..HEAD, which is always EMPTY and
# therefore always reports "clean — all net-new surface is documented" — a
# fail-OPEN indistinguishable from a genuinely clean run. It fires on the
# pipeline's DEFAULT path (no --range/--base) in any repo whose default branch is
# not `main` and which has no remote: a consumer checkout on `master`, a detached
# CI checkout, a fresh clone before the first fetch. Reported by the row-12
# re-audit fan-out and reproduced: default path → "clean" rc=0, while the same
# commit with an explicit range flags the undocumented script.
BASE_UNRESOLVED=0
if [ -z "$RANGE" ]; then
  if [ -z "$BASE" ]; then
    DEFBR="${BASE_BRANCH:-main}"
    if git rev-parse --verify --quiet "origin/$DEFBR" >/dev/null 2>&1; then
      BASE="origin/$DEFBR"
    elif git rev-parse --verify --quiet "$DEFBR" >/dev/null 2>&1; then
      BASE="$DEFBR"
    else
      BASE="HEAD"
      BASE_UNRESOLVED=1
    fi
  fi
  RANGE="${BASE}..HEAD"
fi

if [ "$BASE_UNRESOLVED" = "1" ]; then
  $QUIET || echo "[netnew-surface] could not resolve a base ref (no --range/--base, no origin/${DEFBR:-main}, no ${DEFBR:-main}) — REVIEW REQUIRED, cannot prove the surface is documented." >&2
  exit 2
fi

# Default waiver file from slug.
if [ -z "$WAIVE_FILE" ] && [ -n "$SLUG" ]; then
  WAIVE_FILE=".claude/state/plan-w-team-docs-waived-${SLUG}.txt"
fi

# Load waiver tokens.
WAIVE_ALL=false
WAIVED=()
if [ -n "$WAIVE_FILE" ] && [ -f "$WAIVE_FILE" ]; then
  while IFS= read -r raw; do
    entry="${raw%%#*}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -z "$entry" ] && continue
    [ "$entry" = "*" ] && { WAIVE_ALL=true; continue; }
    WAIVED+=("$entry")
  done < "$WAIVE_FILE"
fi

is_waived() {
  $WAIVE_ALL && return 0
  local needle="$1" w
  for w in "${WAIVED[@]:-}"; do
    [ "$w" = "$needle" ] && return 0
  done
  return 1
}

# All docs that can satisfy a reference. Exclude vendored, docs/specs (prose specs,
# not operational docs — same convention as §7a), and node_modules/agents.
ALL_DOCS=$(git ls-files '*.md' '*.rst' '*.adoc' 2>/dev/null \
  | grep -Ev '^(node_modules|vendor|\.claude/agents|docs/specs)/' || true)

# docs/operations subset (for the A6 hook/script requirement).
OPS_DOCS=$(printf '%s\n' "$ALL_DOCS" | grep -E '^docs/operations/' || true)

# Does any doc in $2 (newline list) reference literal token $1 (excluding $3 self)?
doc_refs() {
  local token="$1" docs="$2" self="${3:-}"
  [ -z "$token" ] && return 1
  local d
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    [ "$d" = "$self" ] && continue
    if grep -qF -- "$token" "$d" 2>/dev/null; then
      return 0
    fi
  done <<EOF
$docs
EOF
  return 1
}

FINDINGS=0          # UNDOCUMENTED residual count
emit() {            # status kind item note
  local status="$1" kind="$2" item="$3" note="${4:-}"
  if [ "$status" = "UNDOCUMENTED" ]; then FINDINGS=$((FINDINGS+1)); fi
  $QUIET && return 0
  if $JSON_OUT; then
    printf '{"status":"%s","kind":"%s","item":"%s","note":"%s"}\n' "$status" "$kind" "$item" "$note"
  else
    printf '%-12s %-7s %s%s\n' "$status" "$kind" "$item" "${note:+  ($note)}"
  fi
}

# ── 1. Net-new ADDED files ───────────────────────────────────────────────────
ADDED_FILES=$(git diff --diff-filter=A --name-only "$RANGE" 2>/dev/null || true)
while IFS= read -r f; do
  [ -z "$f" ] && continue
  # Skip non-public-surface adds: docs themselves, specs, state, tests, lockfiles,
  # vendored, dotfile fixtures. (A doc/test/state file is not "public surface".)
  case "$f" in
    *.md|*.rst|*.adoc) continue ;;
    docs/specs/*) continue ;;
    .claude/state/*) continue ;;
    *.test.sh|*.test.ts|*.test.js|*.spec.ts|*.spec.js|*.bats) continue ;;
    tests/*|test/*) continue ;;
    node_modules/*|vendor/*) continue ;;
    *.lock|*lock.json|*lock.yaml) continue ;;
  esac
  base="$(basename "$f")"
  stem="${base%.*}"
  is_hook_or_script=false
  case "$f" in
    .claude/hooks/*|.claude/scripts/*|scripts/*) is_hook_or_script=true ;;
  esac
  if is_waived "$f" || is_waived "$base"; then
    emit "WAIVED" "file" "$f"; continue
  fi
  if $is_hook_or_script; then
    # A6: a newly-built hook/script REQUIRES a docs/operations/* page naming it.
    if doc_refs "$base" "$OPS_DOCS" "$f" || doc_refs "$f" "$OPS_DOCS" "$f"; then
      emit "DOCUMENTED" "file" "$f" "docs/operations"
    else
      emit "UNDOCUMENTED" "file" "$f" "hook/script → needs a docs/operations entry"
    fi
  else
    if doc_refs "$f" "$ALL_DOCS" "$f" || doc_refs "$base" "$ALL_DOCS" "$f" \
       || { [ "$stem" != "$base" ] && doc_refs "$stem" "$ALL_DOCS" "$f"; }; then
      emit "DOCUMENTED" "file" "$f"
    else
      emit "UNDOCUMENTED" "file" "$f" "new public file referenced by no doc"
    fi
  fi
done <<EOF
$ADDED_FILES
EOF

# ── 2. Added-line surface (env vars, symbols, flags) ─────────────────────────
# Pull added lines (+) from the unified diff, excluding doc/spec/test files.
DIFF=$(git diff --diff-filter=ACM "$RANGE" 2>/dev/null || true)

# Collect into newline-deduped token lists.
ENV_TOKENS=""
SYM_TOKENS=""
FLAG_TOKENS=""
cur_file=""
in_doc=false
while IFS= read -r line; do
  case "$line" in
    '+++ '*)
      cur_file="${line#+++ }"; cur_file="${cur_file#b/}"
      in_doc=false
      case "$cur_file" in
        *.md|*.rst|*.adoc|docs/specs/*|*.test.*|*.spec.*|*.bats|tests/*|test/*) in_doc=true ;;
      esac
      continue ;;
    '--- '*) continue ;;
    '+'*) : ;;
    *) continue ;;
  esac
  $in_doc && continue
  added="${line#+}"
  # env vars
  for m in \
    $(printf '%s\n' "$added" | grep -oE '(process\.env\.[A-Z_][A-Z0-9_]+|process\.env\[['"'"'"][A-Z_][A-Z0-9_]+|os\.environ(\.get)?\[?['"'"'"][A-Z_][A-Z0-9_]+|os\.getenv\(['"'"'"][A-Z_][A-Z0-9_]+|Deno\.env\.get\(['"'"'"][A-Z_][A-Z0-9_]+|std::env::var\(["][A-Z_][A-Z0-9_]+|getenv\(["][A-Z_][A-Z0-9_]+)' 2>/dev/null); do
    tok=$(printf '%s\n' "$m" | grep -oE '[A-Z_][A-Z0-9_]{2,}$')
    [ -n "$tok" ] && ENV_TOKENS="${ENV_TOKENS}${tok}
"
  done
  # exported / public symbols
  sym=$(printf '%s\n' "$added" | grep -oE '(export[[:space:]]+(async[[:space:]]+)?(function|const|class|type|interface|enum)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*|^[[:space:]]*(def|class)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*|pub[[:space:]]+(async[[:space:]]+)?(fn|struct|enum|trait)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*|func[[:space:]]+[A-Z][A-Za-z0-9_]*)' 2>/dev/null | awk '{print $NF}')
  if [ -n "$sym" ]; then
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      case "$s" in _*) continue ;; esac   # skip private (leading underscore)
      SYM_TOKENS="${SYM_TOKENS}${s}
"
    done <<EOF2
$sym
EOF2
  fi
  # long CLI flags
  for fl in $(printf '%s\n' "$added" | grep -oE '\-\-[a-z][a-z0-9]+(-[a-z0-9]+)+' 2>/dev/null); do
    FLAG_TOKENS="${FLAG_TOKENS}${fl}
"
  done
done <<EOF
$DIFF
EOF

# True when the token ALREADY existed in the tree at the range's base — i.e. it is
# not net-new surface at all, it was merely re-mentioned in an added line.
#
# WHY (row-12 re-audit, 2026-08-14): token extraction reads ADDED lines only, so any
# pre-existing flag/env-var/symbol that reappears in an added line — a comment that
# names an existing option, a moved or reindented line, a refactor, a doc-string —
# was classified as brand-new and, finding no doc that "introduces" it, reported
# UNDOCUMENTED. That is not cosmetic: §6c-quater is an ENFORCING ship gate on this
# output, so a phantom item BLOCKS a legitimate ship. Found by this very run — adding
# a comment mentioning the pre-existing `--diff-file` option to
# access-control-content-scan.sh produced "UNDOCUMENTED flag --diff-file". A gate
# that fails on correct work teaches operators to reach for PLAN_W_TEAM_NETNEW_DISABLE
# or a `*` waiver, which is how an enforcing gate quietly becomes decorative.
RANGE_BASE="${RANGE%%..*}"
pre_exists() {
  local t="$1"
  [ -n "$RANGE_BASE" ] || return 1
  [ "$RANGE_BASE" = "HEAD" ] && return 1   # base==HEAD ⇒ empty range; never suppress
  git grep -qF -e "$t" "$RANGE_BASE" -- . >/dev/null 2>&1
}

scan_tokens() {  # kind tokens
  local kind="$1" tokens="$2" t
  tokens=$(printf '%s\n' "$tokens" | sed '/^$/d' | sort -u)
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    pre_exists "$t" && continue
    if is_waived "$t"; then emit "WAIVED" "$kind" "$t"; continue; fi
    if doc_refs "$t" "$ALL_DOCS"; then
      emit "DOCUMENTED" "$kind" "$t"
    else
      emit "UNDOCUMENTED" "$kind" "$t" "new $kind referenced by no doc"
    fi
  done <<EOF
$tokens
EOF
}

scan_tokens "env" "$ENV_TOKENS"
scan_tokens "symbol" "$SYM_TOKENS"
scan_tokens "flag" "$FLAG_TOKENS"

if [ "$FINDINGS" -gt 0 ]; then
  $QUIET || echo "[netnew-surface] $FINDINGS UNDOCUMENTED net-new surface item(s)." >&2
  exit 1
fi
$QUIET || echo "[netnew-surface] clean — all net-new surface is documented or waived." >&2
exit 0
