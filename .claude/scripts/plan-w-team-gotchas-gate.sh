#!/usr/bin/env bash
# plan-w-team-gotchas-gate.sh  (GOT — Gotchas reach gate)
#
# Makes the gotchas catalog (.claude/commands/plan-w-team/shared/gotchas.md)
# REACHED by the pipeline instead of shelved. Recursive-followup row 32 (Cherny
# audit 2026-07-15, GAP-2): the catalog was advertised once in the manifest and
# read by no stage, so humans restated its entries (bash 3.2, the sync
# allowlist) in brief after brief. A pointer does not close that class; a stage
# that deterministically selects the applicable entries does.
#
# Each catalog entry (`## G<N> — <title>`) carries two lines
#   **Applies to**: `<pattern>`, `<pattern>`, ...     (or the bare word: runtime)
#   **Scope**: `fleet` | `skill-source`
# Patterns are shell `case` patterns matched against repo-relative paths; `*`
# matches across `/`. `runtime` marks a behavioral entry no path selects. An
# entry with neither applies to nothing (UNREACHABLE) and fails --lint.
# `skill-source` entries are live only in the skill-source repo (claude-pattern):
# PWT_GOTCHAS_SCOPE=source|fleet, else the origin URL, else the main checkout name.
#
# MODES
#   --select [--spec <spec>] [--paths "<p> <p>..."]
#       Print every gotcha whose patterns match any given path: id, title, the
#       matched path(s), the first "Do instead" paragraph, and a source pointer.
#       No match (or no paths) prints the canonical line
#         No catalogued gotcha applies to these paths.
#       Exits 0 (2 on a usage error or a named spec that does not exist).
#       Step 3-4 pastes this block into each builder brief.
#
#   --check --spec <spec> [--phase spec]         (Step-1 freeze pre-condition)
#       Paths = the spec's `## Files to Create/Modify` section (what the run says
#       it will change) — or, only when that section is absent, every path-like
#       token OUTSIDE its Gotchas Ledger and Grounding Ledger sections — plus any
#       --paths. The spec must carry a
#       non-blank section whose heading contains "gotchas ledger", and every
#       applicable gotcha needs a disposition row:
#         | G<N> | HONORED or N/A | <non-blank reason> |
#       (columns in that order; the id cell may carry trailing text). When
#       nothing applies, the section must say "No catalogued gotcha applies";
#       that phrase never stands in for rows that are required.
#
#   --check --phase review --diff-base <ref> [--spec <spec>]   (Step 5 §5a-quater)
#       Paths = `git diff --name-only <ref>..HEAD`, plus any --paths. Prints the
#       full block for every applicable gotcha, each marked [consulted] (HONORED
#       in the spec), [N/A at spec — re-verify against the diff], or
#       [UNCONSULTED]. A missing spec, or one with no Gotchas Ledger (pre-GOT),
#       counts every applicable gotcha as UNCONSULTED. ADVISORY: never exits 1.
#
#   --lint
#       Exit 1 on a missing catalog, zero parsed entries, a `## G<N>` heading
#       that does not parse, an entry with no Applies-to item, or no valid Scope.
#
# EXIT CODES
#   0   pass / nothing to report / kill switch / catalog missing (fail-open, LOUD)
#   1   spec phase: refuse the freeze.  lint: a catalog problem.
#   2   spec not found, or a usage error
#   11  review phase: unconsulted gotchas, or N/A claims the diff contradicts (advisory)
#   12  review phase: COULD NOT VERIFY (bad/option-like base, not a git repo,
#       empty diff, missing catalog). Never "clean".
#
# A missing catalog — or one that parses to zero entries — prints
# `gotchas-gate: catalog-missing <path>` to stdout and stderr; --select and the
# spec phase then exit 0: the catalog ships with the skill, so its absence is a
# sync problem, not the lead's spec defect. The line is grep-able on purpose.
#
# Env: PWT_GOTCHAS_MAX_PATHS (default 400) caps the path list, LOUDLY.
#
# Kill switch: PLAN_W_TEAM_DISABLE_GOTCHAS_GATE=1 -> exit 0 in every mode, and a
# `hit` row in the run's kill-switch ledger.
#
# Usage:
#   plan-w-team-gotchas-gate.sh --select --paths ".claude/scripts/foo.sh docs/x.md"
#   plan-w-team-gotchas-gate.sh --check --spec docs/specs/<slug>.md
#   plan-w-team-gotchas-gate.sh --check --slug <slug>        # -> docs/specs/<slug>.md
#   plan-w-team-gotchas-gate.sh --check --phase review --slug <slug> --diff-base origin/main
#   plan-w-team-gotchas-gate.sh --lint
# Common: --catalog <path> (default: <script dir>/../commands/plan-w-team/shared/gotchas.md)
#         --root <dir>    (default: git toplevel, else $PWD)
#
# Paths containing whitespace are not supported (they are split on whitespace).
# bash 3.2 compatible (no associative arrays, no mapfile, no ${x^^}).

set -u
# No pathname expansion anywhere in this script. Paths and patterns come from an
# LLM-authored spec and from the catalog; an unquoted word split of a token such
# as `.claude/hooks/*` must never turn into files on disk (or walk the
# filesystem for `/*/*/*`). Patterns are only ever used inside `case`.
set -f

PROG="plan-w-team-gotchas-gate"
NONE_LINE="No catalogued gotcha applies to these paths."
# Record separator for internal rows: ASCII unit separator, NOT a tab — a tab
# is IFS whitespace, so an empty middle field would collapse and shift columns.
US=$(printf '\037')
# safe <text> — the text with control bytes removed, for echoing a caller-supplied
# value (an argument, a diff base) into a transcript or a builder prompt.
safe() { printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177'; }

# ── Kill switch ──────────────────────────────────────────────────────────────
if [ "${PLAN_W_TEAM_DISABLE_GOTCHAS_GATE:-}" = "1" ]; then
  echo "[$PROG] PLAN_W_TEAM_DISABLE_GOTCHAS_GATE=1 — gotchas gate disabled (exit 0)"
  if ! "$(dirname "$0")/plan-w-team-killswitch-ledger.sh" record \
    --switch PLAN_W_TEAM_DISABLE_GOTCHAS_GATE --site gotchas-gate -- ${1+"$@"} >/dev/null 2>&1; then
    # The ledger itself is fail-open (exit 0 on every path), so this fires only
    # when it is missing or unrunnable — the bypass must not vanish unrecorded.
    echo "[$PROG] ⚠ kill-switch ledger write failed — this bypass is NOT recorded" >&2
  fi
  exit 0
fi

# ── Arg parsing ──────────────────────────────────────────────────────────────
# `--flag) V="${2:-}"; shift; [ $# -gt 0 ] && shift ;;` is mandatory
# (argparse-shift2-lint.test.sh): a bare `shift 2` on a value-less trailing flag
# shifts nothing and spins forever.
MODE=""
SPEC=""
SLUG=""
ROOT=""
PHASE="spec"
DIFF_BASE=""
CATALOG=""
PATHS_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --select) MODE="select"; shift ;;
    --check)  MODE="check"; shift ;;
    --lint)   MODE="lint"; shift ;;
    --spec)      SPEC="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --slug)      SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --root)      ROOT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --phase)     PHASE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --diff-base) DIFF_BASE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --catalog)   CATALOG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --paths)     PATHS_ARG="${PATHS_ARG} ${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -75; exit 0 ;;
    *) echo "[$PROG] ✗ unknown argument: $(safe "$1")" >&2; exit 2 ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "[$PROG] ✗ pass --select, --check or --lint" >&2
  exit 2
fi
# --paths accepts Step 2's files_touched value verbatim — e.g.
#   [".claude/scripts/x.sh (create)", "docs/y.md (modify)"]
# — so the JSON punctuation and the (create)/(modify) annotations are removed
# before splitting; otherwise `[".claude/scripts/x.sh` would miss every
# prefix-anchored pattern (G11, G12) without a word.
PATHS_ARG=$(printf '%s' "$PATHS_ARG" | sed -E 's/\((create|modify|delete|rename)\)/ /g' | tr '[]",'"'" '     ')
if [ "$PHASE" != "spec" ] && [ "$PHASE" != "review" ]; then
  echo "[$PROG] ✗ --phase must be 'spec' or 'review' (got: $(safe "$PHASE"))" >&2
  exit 2
fi

if [ -z "$ROOT" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
if [ -z "$CATALOG" ]; then
  CATALOG="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/../commands/plan-w-team/shared/gotchas.md"
fi

# Missing catalog: fail-open for --select and the spec phase (the lead's spec is
# not at fault), but never "clean" for --lint (1) or the review phase (12).
catalog_missing_exit() {
  echo "gotchas-gate: catalog-missing $CATALOG${1:+ ($1)}"
  echo "[$PROG] ⚠ gotchas-gate: catalog-missing $CATALOG${1:+ — $1} — cannot evaluate (re-sync the skill)" >&2
  case "$MODE:$PHASE" in
    lint:*) exit 1 ;;
    check:review) exit 12 ;;
    *) exit 0 ;;
  esac
}
[ -f "$CATALOG" ] || catalog_missing_exit

# ── Catalog parse ────────────────────────────────────────────────────────────
# One record per entry, tab-separated:
#   id <TAB> title <TAB> patterns (space-sep) <TAB> scope
# patterns: the backticked items after `**Applies to**:` (a pattern may not
#   contain whitespace or a backtick); the literal word `runtime` with no
#   backticked item yields the sentinel "@runtime" (a behavioral entry no path
#   selects); no line / no item yields "" (UNREACHABLE).
# scope: `fleet` or `skill-source` from `**Scope**:`; "" when absent/invalid.
parse_catalog() {
  awk '
    function flush() {
      if (id != "") printf "%s\037%s\037%s\037%s\n", id, title, pats, scope
      id = ""; title = ""; pats = ""; scope = ""
    }
    function grab(text,   p) {
      while (match(text, /`[^` \t]+`/)) {
        p = substr(text, RSTART + 1, RLENGTH - 2)
        pats = (pats == "" ? p : pats " " p)
        text = substr(text, RSTART + RLENGTH)
        n++
      }
    }
    /^## G[0-9]+[[:space:]]/ {
      flush(); inapp = 0
      line = $0
      sub(/^## /, "", line)
      id = line; sub(/[[:space:]].*$/, "", id)
      title = line; sub(/^G[0-9]+[[:space:]]+(—|-)+[[:space:]]*/, "", title)
      gsub(/\t/, " ", title)
      next
    }
    # ANY other heading ends the entry: a `### G15 — …` must never be absorbed
    # into the entry above it (its patterns and Scope would be credited there).
    /^#{1,6}[[:space:]]/ { flush(); inapp = 0; next }
    id != "" && /^\*\*Applies to\*\*:/ {
      rest = $0
      sub(/^\*\*Applies to\*\*:/, "", rest)
      n = 0
      grab(rest)
      if (n == 0 && $0 ~ /^\*\*Applies to\*\*:[[:space:]]*runtime[[:space:]]*(\(|$)/) pats = "@runtime"
      inapp = 1
      next
    }
    # A wrapped Applies-to line (a formatter broke it) keeps its patterns: the
    # continuation runs until a blank line or the next **Field**: line.
    inapp && (/^[[:space:]]*$/ || /^\*\*/) { inapp = 0 }
    inapp { if (pats == "@runtime") pats = ""; grab($0); next }
    id != "" && /^\*\*Scope\*\*:/ {
      s = $0
      sub(/^\*\*Scope\*\*:[[:space:]]*/, "", s)
      gsub(/`/, "", s)
      sub(/[[:space:]].*$/, "", s)
      if (s == "fleet" || s == "skill-source") scope = s
      next
    }
    END { flush() }
  ' < "$CATALOG"
}

CATALOG_ROWS=$(parse_catalog)
ENTRIES=$(printf '%s\n' "$CATALOG_ROWS" | grep -c . || true)
# Headings that look like an entry but do not parse as one (`## G14: x`,
# `### G15 — …`). Reported by --lint as a failure and, in every other mode, as a
# stderr warning — such an entry is otherwise silently absent.
MALFORMED=$(grep -nE -- '^#{1,6}[[:space:]]*G[0-9]' < "$CATALOG" | grep -vE '^[0-9]+:## G[0-9]+[[:space:]]' || true)
if [ -n "$MALFORMED" ] && [ "$MODE" != "lint" ]; then
  echo "[$PROG] ⚠ catalog heading(s) that look like an entry but do not parse — those entries are NOT checked:" >&2
  printf '%s\n' "$MALFORMED" | sed 's/^/[gotchas]     /' >&2
fi

# A catalog that parses to ZERO entries is treated exactly like a missing one:
# heading drift (`### G7`) or a wrong --catalog must never read as "nothing
# applies" (that would be a silent clean).
[ "${ENTRIES:-0}" -eq 0 ] && catalog_missing_exit "0 '## G<N> — <title>' entries parsed"

# Warn once per unreachable entry (every mode — the warning IS the reach signal
# for a catalog maintainer).
UNREACHABLE=$(printf '%s\n' "$CATALOG_ROWS" | awk -F"$US" 'NF && $3 == "" { print $1 }')
NOSCOPE=$(printf '%s\n' "$CATALOG_ROWS" | awk -F"$US" 'NF && $4 == "" { print $1 }')
if [ -n "$UNREACHABLE" ]; then
  for u in $UNREACHABLE; do
    echo "[$PROG] ⚠ $u has no **Applies to** pattern — UNREACHABLE (no stage will surface it)" >&2
  done
fi

if [ "$MODE" = "lint" ]; then
  RC=0
  if [ -n "$MALFORMED" ]; then
    echo "[$PROG] ✗ lint: heading(s) that look like an entry but do not parse (use '## G<N> — <title>'):" >&2
    printf '%s\n' "$MALFORMED" | sed 's/^/[gotchas]     /' >&2
    RC=1
  fi
  if [ -n "$UNREACHABLE" ]; then
    echo "[$PROG] ✗ lint: entries without an **Applies to** pattern (or the word runtime): $(printf '%s' "$UNREACHABLE" | tr '\n' ' ')" >&2
    RC=1
  fi
  if [ -n "$NOSCOPE" ]; then
    echo "[$PROG] ✗ lint: entries without a valid **Scope** (fleet | skill-source): $(printf '%s' "$NOSCOPE" | tr '\n' ' ')" >&2
    RC=1
  fi
  [ "$RC" -eq 0 ] && echo "[$PROG] ✓ lint: all $ENTRIES catalog entries carry an **Applies to** line and a **Scope**"
  exit "$RC"
fi

# ── Scope: which entries are live in THIS repo ───────────────────────────────
# `skill-source` entries describe claude-pattern's own machinery (its sync
# allowlist, its CHANGELOG convention, its spawn scripts). In a consumer repo
# they would only add N/A rows, so they are live only in the skill-source repo.
# Identity, in order: PWT_GOTCHAS_SCOPE (source|fleet) → origin URL ends in
# claude-pattern(.git) → the main checkout directory is named claude-pattern.
# (A file marker does not work: many consumers carry sync-to-project.sh.)
# Sets REPO_SCOPE (source|fleet) and SCOPE_VIA (env|origin|dirname|default); the
# result is printed in every header line, so a mis-detected scope — which hides
# every skill-source entry — is visible, not silent.
detect_scope() {
  local url common main
  case "${PWT_GOTCHAS_SCOPE:-}" in
    source) REPO_SCOPE=source; SCOPE_VIA=env; return ;;
    fleet)  REPO_SCOPE=fleet; SCOPE_VIA=env; return ;;
    "") ;;
    *) echo "[$PROG] ⚠ ignoring PWT_GOTCHAS_SCOPE=$(safe "$PWT_GOTCHAS_SCOPE") (want source|fleet) — auto-detecting" >&2 ;;
  esac
  url=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
  url="${url%/}"
  case "$url" in
    */claude-pattern|*/claude-pattern.git|*:claude-pattern|*:claude-pattern.git)
      REPO_SCOPE=source; SCOPE_VIA=origin; return ;;
  esac
  common=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null || true)
  case "$common" in
    "") main="$ROOT" ;;
    /*) main=$(dirname "$common") ;;
    *)  main=$(cd "$ROOT" 2>/dev/null && cd "$(dirname "$common")" 2>/dev/null && pwd || echo "$ROOT") ;;
  esac
  if [ "$(basename "$main")" = "claude-pattern" ]; then
    REPO_SCOPE=source; SCOPE_VIA=dirname; return
  fi
  REPO_SCOPE=fleet; SCOPE_VIA=default
}
REPO_SCOPE=fleet; SCOPE_VIA=default
detect_scope
SCOPE_NOTE="scope: $REPO_SCOPE via $SCOPE_VIA"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Print the first "Do instead" paragraph of entry $1, joined to one line.
do_instead() {
  awk -v want="$1" '
    /^#{1,6}[[:space:]]/ {
      if (grab) exit
      line = $0; sub(/^## /, "", line); sub(/[[:space:]].*$/, "", line)
      inent = (line == want)
      next
    }
    inent && /^\*\*Do instead\*\*:/ { grab = 1; t = $0; sub(/^\*\*Do instead\*\*:[[:space:]]*/, "", t); out = t; next }
    grab && /^[[:space:]]*$/ { exit }
    grab { gsub(/^[[:space:]]+/, "", $0); out = out " " $0 }
    END {
      # Cap so a long entry cannot swamp a builder brief; the source has the rest.
      if (length(out) > 600) out = substr(out, 1, 600) " … (full text at the source)"
      print out
    }
  ' < "$CATALOG"
}

# Normalize a whitespace-separated path list: one per line, leading ./ stripped,
# non-printable bytes dropped (a diff path is echoed back into a transcript and
# a builder prompt), each path capped at 300 chars, deduplicated, sorted, and
# the whole list capped at PWT_GOTCHAS_MAX_PATHS (default 400) with a LOUD
# notice — a pathological spec must not make the gate crawl.
MAX_PATHS="${PWT_GOTCHAS_MAX_PATHS:-400}"
# A cap of 0 (or a non-number) would silently drop every path — fall back.
case "$MAX_PATHS" in ''|0|*[!0-9]*) MAX_PATHS=400 ;; esac
MAX_PATH_LEN=1024
normalize_all() {
  printf '%s\n' "$1" | tr '[:space:]' '\n' | LC_ALL=C tr -cd '[:print:]\n' \
    | sed -e 's#^\./##' -e '/^$/d' | LC_ALL=C sort -u
}
# cap_paths <all> — sets PLIST and CAPPED (0|1) in the CALLER'S shell, so each mode
# decides what an incomplete list means for its verdict: a list that was not
# fully checked may never read as "clean". Two limits, both LOUD:
#   - a path longer than MAX_PATH_LEN is dropped, never truncated (a cut path
#     loses its suffix, so `*.sh` would silently stop matching);
#   - the list is capped at MAX_PATHS.
CAPPED=0
cap_paths() {
  local n long
  CAPPED=0
  PLIST="$1"
  [ -z "$PLIST" ] && return 0
  long=$(printf '%s\n' "$PLIST" | awk -v m="$MAX_PATH_LEN" 'length($0) > m' | grep -c . || true)
  if [ "${long:-0}" -gt 0 ]; then
    CAPPED=1
    echo "[$PROG] ⚠ $long path(s) longer than $MAX_PATH_LEN characters were NOT checked" >&2
    PLIST=$(printf '%s\n' "$PLIST" | awk -v m="$MAX_PATH_LEN" 'length($0) <= m')
  fi
  n=$(printf '%s\n' "$PLIST" | grep -c . || true)
  if [ "${n:-0}" -gt "$MAX_PATHS" ]; then
    CAPPED=1
    echo "[$PROG] ⚠ path list capped at $MAX_PATHS of $n — the rest were NOT checked (raise PWT_GOTCHAS_MAX_PATHS to widen)" >&2
    PLIST=$(printf '%s\n' "$PLIST" | head -n "$MAX_PATHS")
  fi
}

# match_entries <paths-newline-list> → lines "id<TAB>title<TAB>matched-paths(space-sep)"
# Patterns are expanded ONLY inside `case` (never as a glob on disk): set -f
# guards the unquoted word split of the pattern list against pathname expansion.
match_entries() {
  local plist="$1" id title pats scope p pat matched
  [ -z "$plist" ] && return 0
  printf '%s\n' "$CATALOG_ROWS" | while IFS="$US" read -r id title pats scope; do
    [ -z "$id" ] && continue
    [ -z "$pats" ] && continue
    [ "$pats" = "@runtime" ] && continue
    [ "$scope" = "skill-source" ] && [ "$REPO_SCOPE" != "source" ] && continue
    matched=""
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      for pat in $pats; do
        # shellcheck disable=SC2254  # the pattern IS meant to be a case pattern
        case "$p" in
          $pat) matched="${matched:+$matched }$p"; break ;;
        esac
      done
    done <<EOF_P
$plist
EOF_P
    [ -n "$matched" ] && printf '%s\037%s\037%s\n' "$id" "$title" "$matched"
  done
}

# print_block <matches> [mark <honored-ids> <na-ids>]
# With "mark", each entry is annotated [consulted] (HONORED in the spec),
# [N/A at spec — re-verify] or [UNCONSULTED].
print_block() {
  local matches="$1" mark="${2:-}" honored="${3:-}" na="${4:-}" id title mp shown status di
  printf '%s\n' "$matches" | while IFS="$US" read -r id title mp; do
    [ -z "$id" ] && continue
    status=""
    if [ "$mark" = "mark" ]; then
      if printf '%s\n' "$honored" | grep -qx "$id"; then status=" [consulted]"
      elif printf '%s\n' "$na" | grep -qx "$id"; then status=" [N/A at spec — re-verify against the diff]"
      else status=" [UNCONSULTED]"; fi
    fi
    shown=$(printf '%s' "$mp" | tr ' ' '\n' | head -n 3 | tr '\n' ' ' | sed 's/ $//')
    [ "$(printf '%s' "$mp" | tr ' ' '\n' | grep -c .)" -gt 3 ] && shown="$shown …"
    di=$(do_instead "$id")
    printf '%s — %s%s\n' "$id" "$title" "$status"
    printf '  matched: %s\n' "$shown"
    [ -n "$di" ] && printf '  do instead: %s\n' "$di"
    printf '  source: .claude/commands/plan-w-team/shared/gotchas.md (%s)\n' "$id"
  done
}

# has_heading <file> <awk-regex> → 0 when a heading OUTSIDE any ``` / ~~~ fence
# has lowercase text matching the regex. The ONE existence check, so it cannot
# disagree with section_body (which skips fenced headings): a spec whose only
# `## Files to Create/Modify` sits inside a fenced example must take the loud
# whole-spec fallback, not read an empty section and report "none applies".
has_heading() {
  awk -v re="$2" '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    !fence && /^#{1,6}[[:space:]]/ && tolower($0) ~ re { found = 1; exit }
    END { exit !found }
  ' < "$1"
}

# The ONE pattern for "this heading is the spec's Files section" — shared by the
# existence check and the reader so the two can never disagree (a heading that
# merely MENTIONS "files to modify", e.g. "## Notes on files to modify later",
# once read as the section and passed an empty body).
FILES_HEADING_RE='^#+[[:space:]]+files to (create|modify|change)'

# Body of EVERY section whose heading (lowercased) matches $2 (awk regex), each
# up to (excluding) the next heading of the SAME OR HIGHER level, concatenated.
# - Subheadings stay inside: a `## Files to Create/Modify` split into
#   `### Create` / `### Modify` must not read as empty (that failed open — the
#   none-applies phrase would then pass the freeze).
# - Sibling sections are all read: `### Files to Create` + `### Files to Modify`
#   is one path source, not just the first of the two.
# - Lines inside ``` / ~~~ fences are never headings (a `# comment` in a bash
#   block must not end a section, and a fenced example heading must not start one).
section_body() {
  awk -v re="$2" '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; if (insec) print; next }
    !fence && /^#{1,6}[[:space:]]/ {
      match($0, /^#+/); lvl = RLENGTH
      if (insec && lvl <= seclvl) insec = 0
      if (!insec && tolower($0) ~ re) { insec = 1; seclvl = lvl; next }
    }
    insec { print }
  ' < "$1"
}

# The spec with its Gotchas Ledger and Grounding Ledger sections removed (each
# up to the next heading of the same or higher level; fence-aware, as above).
spec_minus_ledgers() {
  awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; if (!skip) print; next }
    !fence && /^#{1,6}[[:space:]]/ {
      match($0, /^#+/); lvl = RLENGTH
      if (skip && lvl <= skiplvl) skip = 0
      if (!skip) {
        low = tolower($0)
        if (low ~ /gotchas ledger/ || low ~ /grounding ledger/ || low ~ /existing-system grounding/) {
          skip = 1; skiplvl = lvl; next
        }
      }
    }
    !skip { print }
  ' < "$1"
}

# Path-like tokens: contain "/" or end in a known extension. URL fragments
# (anything that was part of a `scheme://` token) are dropped first.
extract_paths() {
  sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:])>`"]*##g' \
    | grep -oE '[A-Za-z0-9_.@*/-]+' | sed -e 's#^\./##' -e 's#[.]*$##' \
    | grep -E '/|\.(sh|bash|bats|md|json|yml|yaml|ts|tsx|js|mjs|py|rs|go|toml|txt)$' \
    | grep -vE '^/+$' | LC_ALL=C sort -u
}

# The spec text applicability is read from. Primary source: the
# `## Files to Create/Modify` section (what the run says it will change) — the
# rest of the spec cites far more paths than it touches (evidence, deferred
# items, diagrams), and disposing gotchas for those trains leads to rubber-stamp
# N/A rows. Fallback, only when that section is absent: the whole spec minus its
# Gotchas Ledger and Grounding Ledger sections. Paths a spec never names are the
# Step-5 diff re-check's job.
spec_path_source() {
  local body
  if has_heading "$1" "$FILES_HEADING_RE"; then
    body=$(section_body "$1" "$FILES_HEADING_RE")
    # A Files section that names no path (prose such as "see the task
    # breakdown") must not become an empty path list that "none applies" can
    # pass: fall back, loudly, exactly as when the section is absent.
    if [ -n "$(printf '%s\n' "$body" | extract_paths)" ]; then
      printf '%s\n' "$body"
      return 0
    fi
    echo "[$PROG] ⚠ the 'Files to Create/Modify' section names no paths — reading paths from the whole spec (minus ledgers)" >&2
  else
    echo "[$PROG] ⚠ no 'Files to Create/Modify' section — reading paths from the whole spec (minus ledgers)" >&2
  fi
  spec_minus_ledgers "$1"
}

# Disposed ids from a Gotchas Ledger body: rows | G<N>… | HONORED|N/A | reason |
# Optional $2 restricts to one disposition (HONORED or N/A).
disposed_ids() {
  printf '%s\n' "$1" | awk -F'|' -v only="${2:-}" '
    /^[[:space:]]*\|/ {
      idc = $2; disp = $3; why = $4
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", idc)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", disp)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", why)
      if (idc !~ /^G[0-9]+([^0-9]|$)/) next
      if (disp != "HONORED" && disp != "N/A") next
      if (only != "" && disp != only) next
      if (why == "") next
      # A template placeholder (`<how honored …>`) is not a reason: a spec that
      # keeps the template rows must not read as having consulted them.
      if (why ~ /^<.*>$/) next
      id = idc; sub(/[^G0-9].*$/, "", id)
      print id
    }
  ' | LC_ALL=C sort -u
}

# ── --select ─────────────────────────────────────────────────────────────────
if [ "$MODE" = "select" ]; then
  SEL_SPEC_PATHS=""
  if [ -n "$SPEC" ] || [ -n "$SLUG" ]; then
    [ -z "$SPEC" ] && SPEC="docs/specs/${SLUG}.md"
    [ ! -f "$SPEC" ] && [ -f "$ROOT/$SPEC" ] && SPEC="$ROOT/$SPEC"
    if [ ! -f "$SPEC" ]; then
      echo "[$PROG] ✗ spec file not found: $SPEC" >&2
      exit 2
    fi
    SEL_SPEC_PATHS=$(spec_path_source "$SPEC" | extract_paths)
  fi
  cap_paths "$(normalize_all "$SEL_SPEC_PATHS $PATHS_ARG")"
  if [ -z "$PLIST" ]; then
    # No paths is "nothing evaluated", never "nothing applies": an unfilled
    # placeholder or an empty files_touched must not paste a clean result into a
    # builder brief.
    echo "gotchas-gate: no paths given — nothing evaluated"
    exit 2
  fi
  MATCHES=$(match_entries "$PLIST")
  if [ -z "$MATCHES" ]; then
    if [ "$CAPPED" = 1 ]; then
      echo "⚠ gotchas-gate: path list capped at $MAX_PATHS — no match among the paths checked; the rest were NOT checked"
    else
      echo "$NONE_LINE ($SCOPE_NOTE)"
    fi
  else
    echo "Catalogued gotchas that apply to these paths (shared/gotchas.md; $SCOPE_NOTE) — treat each as a hard rule:"
    print_block "$MATCHES"
    [ "$CAPPED" = 1 ] && echo "⚠ gotchas-gate: path list capped at $MAX_PATHS — paths beyond the cap were NOT checked"
  fi
  exit 0
fi

# ── --check: resolve the spec ────────────────────────────────────────────────
if [ -z "$SPEC" ] && [ -n "$SLUG" ]; then
  SPEC="docs/specs/${SLUG}.md"
fi
if [ -n "$SPEC" ] && [ ! -f "$SPEC" ] && [ -f "$ROOT/$SPEC" ]; then
  SPEC="$ROOT/$SPEC"
fi

if [ "$PHASE" = "spec" ]; then
  if [ -z "$SPEC" ]; then
    echo "[$PROG] ✗ no --spec or --slug given" >&2
    exit 2
  fi
  if [ ! -f "$SPEC" ]; then
    echo "[$PROG] ✗ spec file not found: $SPEC" >&2
    echo "[$PROG]   author the spec (Step 1) before the gotchas gate runs." >&2
    exit 2
  fi
  SPEC_PATHS=$(spec_path_source "$SPEC" | extract_paths)
  cap_paths "$(normalize_all "$SPEC_PATHS $PATHS_ARG")"
  if [ "$CAPPED" = 1 ]; then
    # Fail closed: a freeze cannot pass on a path list it did not fully check.
    echo "[$PROG] ✗ the spec names more than $MAX_PATHS paths — the gate cannot check them all: $SPEC" >&2
    echo "[$PROG]   narrow the 'Files to Create/Modify' section (split the run), or raise PWT_GOTCHAS_MAX_PATHS." >&2
    exit 1
  fi
  MATCHES=$(match_entries "$PLIST")
  APPLICABLE=$(printf '%s\n' "$MATCHES" | awk -F"$US" 'NF { print $1 }')

  if ! has_heading "$SPEC" "gotchas ledger"; then
    echo "[$PROG] ✗ spec has no 'Gotchas Ledger' section: $SPEC" >&2
    echo "[$PROG]   add the mandatory section (01-specification.md template)." >&2
    [ -n "$MATCHES" ] && { echo "[$PROG]   gotchas that apply to the paths this spec names:" >&2; print_block "$MATCHES" >&2; }
    exit 1
  fi
  BODY=$(section_body "$SPEC" "gotchas ledger")
  if [ -z "$(printf '%s' "$BODY" | tr -d '[:space:]')" ]; then
    echo "[$PROG] ✗ Gotchas Ledger section present but BLANK: $SPEC" >&2
    exit 1
  fi

  if [ -z "$APPLICABLE" ]; then
    if printf '%s' "$BODY" | grep -qiF 'No catalogued gotcha applies'; then
      echo "[$PROG] ✓ Gotchas Ledger: no catalogued gotcha applies to the paths this spec names — gate passes (spec)"
      exit 0
    fi
    DISPOSED=$(disposed_ids "$BODY")
    if [ -n "$DISPOSED" ]; then
      echo "[$PROG] ✓ Gotchas Ledger present; nothing applies beyond the rows given — gate passes (spec)"
      exit 0
    fi
    echo "[$PROG] ✗ Gotchas Ledger has neither disposition rows nor the statement" >&2
    echo "[$PROG]   'No catalogued gotcha applies': $SPEC" >&2
    exit 1
  fi

  DISPOSED=$(disposed_ids "$BODY")
  MISSING=""
  for id in $APPLICABLE; do
    printf '%s\n' "$DISPOSED" | grep -qx "$id" || MISSING="${MISSING}${id} "
  done
  if [ -n "$MISSING" ]; then
    echo "[$PROG] ✗ Gotchas Ledger does not dispose these applicable gotchas" >&2
    echo "[$PROG]   (add a row: | G<N> | HONORED or N/A | <how honored / why N/A> |):" >&2
    for id in $MISSING; do
      print_block "$(printf '%s\n' "$MATCHES" | awk -F"$US" -v id="$id" '$1 == id')" >&2
    done
    exit 1
  fi
  N=$(printf '%s\n' "$APPLICABLE" | grep -c .)
  echo "[$PROG] ✓ Gotchas Ledger disposes all $N applicable gotcha(s) — gate passes (spec)"
  exit 0
fi

# ── --check --phase review ───────────────────────────────────────────────────
DIFF_PATHS=""
if [ -n "$DIFF_BASE" ]; then
  # The base must resolve to a commit BEFORE it reaches `git diff`: a value such
  # as `--output=/tmp/x` would otherwise be parsed as a git option.
  case "$DIFF_BASE" in
    -*) echo "gotchas-recheck: could-not-verify (diff base looks like an option: $(safe "$DIFF_BASE"))"; exit 12 ;;
  esac
  if ! git -C "$ROOT" rev-parse --verify --quiet "${DIFF_BASE}^{commit}" >/dev/null 2>&1; then
    echo "gotchas-recheck: could-not-verify (diff base does not resolve to a commit in $(safe "$ROOT"): $(safe "$DIFF_BASE"))"
    exit 12
  fi
  # -z + quotePath=false: a filename with odd bytes arrives raw (not C-quoted, so
  # it can match a pattern); normalize_paths then drops non-printable bytes.
  # Two-dot, matching the other Step-5 diff consumers (`"$BASE_SHA"..HEAD`).
  # The exit status is taken from a separate call, because the capture below must
  # be a pipeline: bash silently DROPS NUL bytes from a command substitution, so
  # `-z` output held in a variable fuses every changed path into one token and
  # the re-check would report "none applies" on any multi-file diff. The NULs
  # therefore become newlines inside the pipe, before bash ever holds the bytes.
  if ! git -C "$ROOT" diff --name-only "${DIFF_BASE}..HEAD" >/dev/null 2>&1; then
    echo "gotchas-recheck: could-not-verify (diff $(safe "$DIFF_BASE")..HEAD failed in $(safe "$ROOT"))"
    exit 12
  fi
  DIFF_PATHS=$(git -C "$ROOT" -c core.quotePath=false diff --name-only -z "${DIFF_BASE}..HEAD" 2>/dev/null | tr '\0' '\n')
  # An empty diff at review time means the base drifted (e.g. re-recorded to
  # HEAD before fix agents) — it must never read as "nothing applies".
  # Checked on the diff ALONE: extra --paths must not mask a drifted base.
  if [ -z "$(printf '%s' "$DIFF_PATHS" | tr -d '[:space:]')" ]; then
    echo "gotchas-recheck: could-not-verify (diff-empty: $(safe "$DIFF_BASE")..HEAD names no files — pin the Step-4 merge base)"
    exit 12
  fi
elif [ -z "$(printf '%s' "$PATHS_ARG" | tr -d '[:space:]')" ]; then
  echo "gotchas-recheck: could-not-verify (no --diff-base and no --paths)"
  exit 12
fi
cap_paths "$(normalize_all "$DIFF_PATHS $PATHS_ARG")"
PARTIAL_NOTE=""
[ "$CAPPED" = 1 ] && PARTIAL_NOTE=" (PARTIAL: path list incomplete — see the notice above)"
MATCHES=$(match_entries "$PLIST")
if [ -z "$MATCHES" ]; then
  if [ "$CAPPED" = 1 ]; then
    # A truncated diff that matched nothing has not been shown clean.
    echo "gotchas-recheck: could-not-verify (path list capped at $MAX_PATHS — no match among the paths checked; the rest were NOT checked)"
    exit 12
  fi
  echo "gotchas-recheck: $NONE_LINE ($SCOPE_NOTE)"
  exit 0
fi

# A gotcha disposed HONORED at spec time is "consulted". One disposed N/A whose
# patterns match a file the diff ACTUALLY touches is a self-attested claim the
# diff now contradicts on its face, so it is reported for re-verification rather
# than trusted.
HONORED_IDS=""
NA_IDS=""
if [ -n "$SPEC" ] && [ ! -f "$SPEC" ]; then
  # A spec that was NAMED but is not there (a mistyped path, an unset $SLUG) is
  # a broken call, not a pre-GOT spec: never fold it into the legacy grace.
  echo "gotchas-recheck: could-not-verify (spec not found: $(safe "$SPEC"))"
  exit 12
fi
if [ -n "$SPEC" ] && has_heading "$SPEC" "gotchas ledger"; then
  GBODY=$(section_body "$SPEC" "gotchas ledger")
  HONORED_IDS=$(disposed_ids "$GBODY" HONORED)
  NA_IDS=$(disposed_ids "$GBODY" "N/A")
else
  echo "[$PROG] ⚠ no Gotchas Ledger in the spec (absent or pre-GOT) — every applicable gotcha counts as UNCONSULTED" >&2
fi

echo "Catalogued gotchas that apply to this diff ($SCOPE_NOTE) — verify the diff honors each:"
print_block "$MATCHES" mark "$HONORED_IDS" "$NA_IDS"
UNCONS=0
REVERIFY=0
TOTAL=0
for id in $(printf '%s\n' "$MATCHES" | awk -F"$US" 'NF { print $1 }'); do
  TOTAL=$((TOTAL + 1))
  if printf '%s\n' "$HONORED_IDS" | grep -qx "$id"; then
    :
  elif printf '%s\n' "$NA_IDS" | grep -qx "$id"; then
    REVERIFY=$((REVERIFY + 1))
  else
    UNCONS=$((UNCONS + 1))
  fi
done
echo "gotchas-recheck: ${TOTAL} applicable, ${UNCONS} unconsulted, ${REVERIFY} n/a-to-reverify${PARTIAL_NOTE}"
[ $((UNCONS + REVERIFY)) -gt 0 ] && exit 11
if [ "$CAPPED" = 1 ]; then
  # Everything checked was consulted, but not everything was checked.
  echo "gotchas-recheck: could-not-verify (path list incomplete — see the cap notice above)"
  exit 12
fi
exit 0
