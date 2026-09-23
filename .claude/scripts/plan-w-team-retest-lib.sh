#!/usr/bin/env bash
# .claude/scripts/plan-w-team-retest-lib.sh
#
# Shared logic for the targeted-retest mode of the /plan-w-team commit gate
# (docs/operations/test-green-retest.md). SOURCED, never executed, by exactly two
# callers — and the point of the file is that there are only two:
#
#   .claude/scripts/plan-w-team-test-green.sh   the WRITER: runs the full suite or a
#                                               retest and archives the verdict;
#   .claude/hooks/pre-commit-quality.sh         the READER: the commit gate, which
#                                               RECOMPUTES the rerun set itself and
#                                               requires it to be a subset of what the
#                                               retest log says actually ran.
#
# If the writer and the gate each carried their own copy of "which files must a
# retest cover", the two would drift and the gate would corroborate a set it never
# computed. One lib, two callers, no second definition.
#
# Every function is safe under the caller's `set -e` / `set -u`: each does its work
# in a subshell with `set +e`, prints to stdout, and reports through its return code.
# Nothing here writes a file the caller did not name, and nothing reads the network.
#
# bash 3.2 (mac-mini /bin/bash): no `declare -A`, no `mapfile`, no `${v,,}`, no
# `local -n`. Set work is done on sorted newline lists (sort / comm / grep -Fx -f).

# ─── CONSTANTS ──────────────────────────────────────────────────────────────
# The ONLY suite commands a gate-acceptable verdict may have been produced by. A
# substituted PWT_TEST_GREEN_SUITE_CMD / PWT_TEST_GREEN_RETEST_CMD (a fixture seam)
# is recorded verbatim in `suite_cmd` and the gate refuses it (brief P3). Kept as
# constants here — never as literals in the hook — because the hook's own regression
# test forbids the inline-suite spelling anywhere in its code.
PWT_RT_DEFAULT_SUITE_CMD='make test-skill'
# shellcheck disable=SC2016  # expanded by `sh -c` at run time, recorded unexpanded
PWT_RT_DEFAULT_RETEST_CMD='tests/skill/run.sh --retest "$PWT_RETEST_LIST"'

PWT_RT_CHANGELOG_REL='.claude/commands/plan-w-team/CHANGELOG.md'
PWT_RT_ALWAYS_LIST_REL='tests/skill/retest-always.list'
PWT_RT_RUNNER_REL='tests/skill/run.sh'

# Caps (env-tunable; validated numeric by pwt_rt_int).
#   MAX_FILES — a rerun set larger than this is not "targeted" any more: run full.
#   MAX_CHAIN — green retests allowed against ONE full base before a full run is due.
pwt_rt_int() {  # pwt_rt_int <value> <default> — echo value if a non-negative int, else default
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
PWT_RT_MAX_FILES="$(pwt_rt_int "${PWT_TEST_RETEST_MAX_FILES:-}" 40)"
PWT_RT_MAX_CHAIN="$(pwt_rt_int "${PWT_TEST_RETEST_MAX_CHAIN:-}" 3)"

# ─── SMALL UTILITIES ────────────────────────────────────────────────────────
pwt_rt_file_mtime() {  # portable mtime (macOS stat -f, GNU stat -c); 0 on failure
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

pwt_rt_sha256_file() {  # sha256 of a file's bytes; empty on failure
  [ -r "$1" ] || return 1
  shasum -a 256 < "$1" 2>/dev/null | awk '{print $1}'
}

pwt_rt_is_hex64() {
  case "${1:-}" in
    ""|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

pwt_rt_is_safe_slug() {  # a slug that may be turned into a file name
  case "${1:-}" in
    ""|*[!A-Za-z0-9._-]*|.*) return 1 ;;
  esac
  return 0
}

# ─── MANIFEST ───────────────────────────────────────────────────────────────
# pwt_rt_manifest <root> <worktree|staged|head> <globs>
#
# Prints the watched-set manifest: one `path:blob` line per file, sorted by PATH
# (LC_ALL=C), which is byte-for-byte the input the pre-2.51.0 tree_digest hashed —
# so `pwt_rt_digest` of this output equals every digest recorded before the lib
# existed. <globs> is the newline-separated PWT_WATCHED_GLOBS block, passed IN by
# the caller so the two symmetry-locked copies stay where they are.
#
#   worktree  working-tree content (untracked-not-ignored included; a deleted
#             tracked file falls back to its HEAD blob, else `-`)
#   staged    as worktree, but a staged file (ACMR) contributes its INDEX blob —
#             what is about to be committed
#   head      the committed tree at HEAD only (git ls-tree), for the post-push
#             confirm's "does a full verdict describe what was pushed?"
#
# Prints nothing (and returns 1) on any failure OR on an empty watched set: shasum
# of nothing is a well-formed hash, so an empty enumeration must never be allowed to
# corroborate itself.
pwt_rt_manifest() {
  local root="$1" mode="$2" globs_text="$3"
  (
    set +e
    set -f   # globs are pathspecs / case patterns here, never filesystem globs
    cd "$root" 2>/dev/null || exit 1
    globs=()
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      globs+=("$g")
    done <<EOF
$globs_text
EOF
    [ "${#globs[@]}" -gt 0 ] || exit 1
    tab="$(printf '\t')"
    tmpd=$(mktemp -d -t pwt-rt-man.XXXXXX) || exit 1
    trap 'rm -rf "$tmpd" 2>/dev/null' EXIT

    if [ "$mode" = "head" ]; then
      # `git ls-tree` does not honour glob pathspecs, so list the whole tree and
      # filter with the same `case` reading the hook applies (`*` matches `/`).
      git ls-tree -r HEAD 2>/dev/null > "$tmpd/tree" || exit 1
      while IFS="$tab" read -r meta path; do
        [ -n "$path" ] || continue
        set -- $meta
        [ "${2:-}" = "blob" ] || continue
        for g in "${globs[@]}"; do
          # shellcheck disable=SC2254  # the glob IS the pattern
          case "$path" in $g) printf '%s%s%s\n' "$path" "$tab" "$3"; break ;; esac
        done
      done < "$tmpd/tree" > "$tmpd/pairs"
    else
      git ls-files --cached --others --exclude-standard -- "${globs[@]}" 2>/dev/null \
        | LC_ALL=C sort -u > "$tmpd/files"
      [ -s "$tmpd/files" ] || exit 1
      : > "$tmpd/staged"
      if [ "$mode" = "staged" ]; then
        git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | LC_ALL=C sort -u > "$tmpd/staged"
      fi
      : > "$tmpd/pairs"
      : > "$tmpd/present"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -s "$tmpd/staged" ] && grep -qFx -- "$f" "$tmpd/staged" 2>/dev/null; then
          h=$(git rev-parse ":$f" 2>/dev/null)
          if [ -n "$h" ]; then printf '%s%s%s\n' "$f" "$tab" "$h" >> "$tmpd/pairs"; continue; fi
        fi
        if [ -f "$f" ]; then
          printf '%s\n' "$f" >> "$tmpd/present"
        else
          h=$(git rev-parse -q --verify "HEAD:$f" 2>/dev/null)
          [ -n "$h" ] || h="-"
          printf '%s%s%s\n' "$f" "$tab" "$h" >> "$tmpd/pairs"
        fi
      done < "$tmpd/files"
      if [ -s "$tmpd/present" ]; then
        # One git process for the whole set (~400 files: 25 ms vs 2 s per-file).
        # --stdin-paths applies each path's own filters, exactly like
        # `git hash-object --path f -- f`. A count mismatch (an unreadable file
        # aborts the batch) falls back to the per-file form rather than
        # mis-pairing paths and blobs.
        git hash-object --stdin-paths < "$tmpd/present" > "$tmpd/blobs" 2>/dev/null
        np=$(wc -l < "$tmpd/present" | tr -d ' ')
        nb=$(wc -l < "$tmpd/blobs" 2>/dev/null | tr -d ' ')
        if [ "$np" = "$nb" ]; then
          paste -d "$tab" "$tmpd/present" "$tmpd/blobs" >> "$tmpd/pairs"
        else
          while IFS= read -r f; do
            h=$(git hash-object --path "$f" -- "$f" 2>/dev/null)
            [ -n "$h" ] || h="-"
            printf '%s%s%s\n' "$f" "$tab" "$h" >> "$tmpd/pairs"
          done < "$tmpd/present"
        fi
      fi
    fi

    [ -s "$tmpd/pairs" ] || exit 1
    # Sort by the PATH field, not the whole line: `foo` and `foo.bats` order
    # differently once `:blob` is appended, and the digest must match the
    # historical path-sorted form.
    LC_ALL=C sort -t "$tab" -k1,1 "$tmpd/pairs" | tr "$tab" ':'
  )
}

# pwt_rt_digest [file] — sha256 of a manifest (stdin when no file). Empty input →
# empty output: an empty manifest never has a digest.
pwt_rt_digest() {
  (
    set +e
    if [ $# -gt 0 ]; then
      [ -s "$1" ] || exit 1
      shasum -a 256 < "$1" 2>/dev/null | awk '{print $1}'
    else
      data=$(cat)
      [ -n "$data" ] || exit 1
      printf '%s\n' "$data" | shasum -a 256 2>/dev/null | awk '{print $1}'
    fi
  )
}

# pwt_rt_delta <base_manifest> <current_manifest> — the paths added, removed or
# changed between two manifests, one per line, sorted, deduplicated. The blob is
# split off at the LAST colon (a blob never contains one; a path might).
pwt_rt_delta() {
  (
    set +e
    [ -r "$1" ] && [ -r "$2" ] || exit 1
    LC_ALL=C comm -3 <(LC_ALL=C sort "$1") <(LC_ALL=C sort "$2") \
      | while IFS= read -r l; do
          l="${l#"$(printf '\t')"}"
          [ -n "$l" ] || continue
          printf '%s\n' "${l%:*}"
        done \
      | LC_ALL=C sort -u
  )
}

# pwt_rt_needs_full <delta_file> — returns 0 (and prints the first offending path)
# when the delta touches the harness or the gate machinery, which a partial run can
# never certify: everything under tests/skill/ except a corpus `.bats` file
# (run.sh, helpers/, *.bash, the always-list, fixtures…), the wrapper, this lib,
# and the gate hook. Returns 1 when a retest may proceed.
pwt_rt_needs_full() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      tests/skill/cases/*.bats|tests/skill/scenarios/*.bats|tests/skill/scenarios.local/*.bats) ;;
      tests/skill/*|\
      .claude/scripts/plan-w-team-test-green.sh|\
      .claude/scripts/plan-w-team-retest-lib.sh|\
      .claude/hooks/pre-commit-quality*)
        printf '%s\n' "$p"
        return 0 ;;
    esac
  done < "$1"
  return 1
}

# ─── LOG READERS (run.sh's machine-readable rows are the witness) ───────────
# pwt_rt_log_mode <log> — the SUITE_MODE value when the log carries EXACTLY one
# SUITE_MODE= line; nothing otherwise (absent = legacy, two = spliced logs).
pwt_rt_log_mode() {
  (
    set +e
    [ -r "$1" ] || exit 1
    n=$(grep -c '^SUITE_MODE=' "$1" 2>/dev/null)
    [ "$n" = "1" ] || exit 1
    grep '^SUITE_MODE=' "$1" | head -1 | tr -d '\r' | sed 's/^SUITE_MODE=//'
  )
}

# pwt_rt_parse_failures <log> — `kind rel` for every attributed failing file.
# Returns 1 when the log carries an `unattributed` or `leak` row: a failure the
# runner could not tie to a file cannot be retested by file, so it needs a full run.
pwt_rt_parse_failures() {
  (
    set +e
    [ -r "$1" ] || exit 1
    grep -E '^SUITE_FAILED (unattributed|leak)( |$)' "$1" >/dev/null 2>&1 && bad=1 || bad=0
    grep -E '^SUITE_FAILED (bats|shell|ts) .' "$1" 2>/dev/null | tr -d '\r' \
      | sed 's/^SUITE_FAILED //' | LC_ALL=C sort -u
    [ "$bad" = "0" ]
  )
}

# pwt_rt_ran <log> — `kind rel` for every file the retest log says it ran.
pwt_rt_ran() {
  (
    set +e
    [ -r "$1" ] || exit 1
    grep -E '^RETEST_RAN (bats|shell|ts) .' "$1" 2>/dev/null | tr -d '\r' \
      | sed 's/^RETEST_RAN //' | LC_ALL=C sort -u
  )
}

# pwt_rt_marker <log> — prints `<N> strict` when the literal last line is
# `SUITE_EXIT=N`; `<N> lenient` when the last line(s) are make's own error trailer
# (`make: *** [test-skill] Error 1`, P1) and the line before them is `SUITE_EXIT=N`;
# nothing otherwise. Only `0 strict` is ever green — lenient exists so a red run
# records its real exit code instead of `marker-absent`.
pwt_rt_marker() {
  (
    set +e
    [ -r "$1" ] || exit 1
    tail -n 50 "$1" 2>/dev/null | tr -d '\r' | awk '
      { line[NR] = $0 }
      END {
        i = NR; lenient = 0
        while (i > 0 && line[i] ~ /^make(\[[0-9]+\])?: \*\*\* /) { i--; lenient = 1 }
        if (i < 1) exit 1
        if (line[i] !~ /^SUITE_EXIT=[0-9]+$/) exit 1
        sub(/^SUITE_EXIT=/, "", line[i])
        print line[i] " " (lenient ? "lenient" : "strict")
      }'
  )
}

# ─── LOG BINDING ────────────────────────────────────────────────────────────
# pwt_rt_log_bound <verdict_json> <log> — returns 0 only when the verdict records a
# `log_sha256` and the log's bytes hash to it. The log is the WITNESS every retest
# rule reads (the base's SUITE_FAILED rows build R; the retest's RETEST_RAN rows must
# cover it), while only the json sits behind the lane guard's trusted-artifact wall.
# Without this binding, deleting one SUITE_FAILED row from the base log shrank R and
# minted a green retest over a still-broken file. On failure PWT_RT_ERR says why.
pwt_rt_log_bound() {
  local f="$1" log="$2" want have
  PWT_RT_ERR=""
  want=$(jq -r '.log_sha256 // ""' "$f" 2>/dev/null)
  if ! pwt_rt_is_hex64 "$want"; then
    PWT_RT_ERR="the verdict records no log_sha256, so its log cannot be tied to it"; return 1
  fi
  have=$(pwt_rt_sha256_file "$log")
  if [ "$have" != "$want" ]; then
    PWT_RT_ERR="the suite log does not hash to the verdict's log_sha256 (edited or replaced after the run)"; return 1
  fi
  return 0
}

# ─── BASE (full) VERDICT CHECK ──────────────────────────────────────────────
# pwt_rt_check_base <base_json> <max_age_s>
#
# The one definition of "a full verdict a retest may be measured against", used by
# the wrapper before a retest runs and by the gate before it accepts one. On success
# returns 0 and sets PWT_RT_BASE_{SLUG,TS,DIGEST,LOG,MANIFEST,GREEN,EXIT}. On
# failure returns 1 with the reason in PWT_RT_ERR. Requires jq + shasum.
pwt_rt_check_base() {
  local f="$1" max now mt age mode cmd reason man_sha
  # Normalize the cap: a non-numeric value (e.g. a "24h" typo) must not turn the age
  # comparison into a test error that reads as "not stale" (fail open).
  max="$(pwt_rt_int "$2" 86400)"
  PWT_RT_ERR=""
  PWT_RT_BASE_SLUG=""; PWT_RT_BASE_TS=""; PWT_RT_BASE_DIGEST=""; PWT_RT_BASE_LOG=""
  PWT_RT_BASE_MANIFEST=""; PWT_RT_BASE_GREEN=""; PWT_RT_BASE_EXIT=""
  if [ ! -f "$f" ]; then PWT_RT_ERR="no full verdict at $f"; return 1; fi
  if ! command -v jq >/dev/null 2>&1; then PWT_RT_ERR="jq is required"; return 1; fi
  if ! jq -e . "$f" >/dev/null 2>&1; then PWT_RT_ERR="the full verdict is not valid JSON"; return 1; fi
  mode=$(jq -r '.mode // ""' "$f" 2>/dev/null)
  cmd=$(jq -r '.suite_cmd // ""' "$f" 2>/dev/null)
  reason=$(jq -r '.reason // ""' "$f" 2>/dev/null)
  PWT_RT_BASE_SLUG=$(jq -r '.slug // ""' "$f" 2>/dev/null)
  PWT_RT_BASE_TS=$(jq -r '.ts // ""' "$f" 2>/dev/null)
  PWT_RT_BASE_DIGEST=$(jq -r '.tree_digest // ""' "$f" 2>/dev/null)
  PWT_RT_BASE_LOG=$(jq -r '.log_path // ""' "$f" 2>/dev/null)
  PWT_RT_BASE_MANIFEST=$(jq -r '.manifest_path // ""' "$f" 2>/dev/null)
  PWT_RT_BASE_GREEN=$(jq -r 'if .green == true then "true" else "false" end' "$f" 2>/dev/null)
  PWT_RT_BASE_EXIT=$(jq -r 'if .suite_exit == null then "" else (.suite_exit|tostring) end' "$f" 2>/dev/null)
  if [ "$mode" != "full" ]; then PWT_RT_ERR="the base verdict is not a full run (mode=${mode:-<none>})"; return 1; fi
  if [ "$cmd" != "$PWT_RT_DEFAULT_SUITE_CMD" ]; then PWT_RT_ERR="the base verdict ran a substituted suite command"; return 1; fi
  case "$reason" in
    ok|suite-exit-nonzero) ;;
    *) PWT_RT_ERR="the base verdict's reason is '${reason:-?}' (only ok / suite-exit-nonzero can be retested)"; return 1 ;;
  esac
  if ! pwt_rt_is_hex64 "$PWT_RT_BASE_DIGEST"; then PWT_RT_ERR="the base verdict carries no tree_digest"; return 1; fi
  if [ -z "$PWT_RT_BASE_LOG" ] || [ ! -r "$PWT_RT_BASE_LOG" ]; then PWT_RT_ERR="the base run's log is missing or unreadable"; return 1; fi
  if ! pwt_rt_log_bound "$f" "$PWT_RT_BASE_LOG"; then PWT_RT_ERR="the base log is not bound to the base verdict: $PWT_RT_ERR"; return 1; fi
  if [ "$(pwt_rt_log_mode "$PWT_RT_BASE_LOG")" != "full" ]; then PWT_RT_ERR="the base log does not carry exactly one SUITE_MODE=full"; return 1; fi
  # Defense in depth beside the hash: the failing set R is built from must be exactly
  # the one the (lane-guard-protected) verdict recorded at archive time.
  if ! jq -e '.failed | type == "array"' "$f" >/dev/null 2>&1; then
    PWT_RT_ERR="the base verdict records no failed[] list"; return 1
  fi
  if [ "$(jq -r '.failed[] | tostring' "$f" 2>/dev/null | tr -d '\r' | LC_ALL=C sort -u)" \
       != "$(pwt_rt_parse_failures "$PWT_RT_BASE_LOG" 2>/dev/null)" ]; then
    PWT_RT_ERR="the base log's SUITE_FAILED set differs from the base verdict's failed[]"; return 1
  fi
  if [ -z "$PWT_RT_BASE_MANIFEST" ] || [ ! -r "$PWT_RT_BASE_MANIFEST" ]; then PWT_RT_ERR="the base run's manifest is missing or unreadable"; return 1; fi
  man_sha=$(pwt_rt_sha256_file "$PWT_RT_BASE_MANIFEST")
  if [ "$man_sha" != "$PWT_RT_BASE_DIGEST" ]; then PWT_RT_ERR="the base manifest does not hash to the base tree_digest (tampered or replaced)"; return 1; fi
  now=$(date +%s 2>/dev/null || echo 0)
  mt=$(pwt_rt_file_mtime "$f")
  if [ "$now" -le 0 ] || [ "$mt" -le 0 ] 2>/dev/null; then PWT_RT_ERR="the base verdict's age could not be determined"; return 1; fi
  age=$(( now - mt ))
  if [ "$age" -lt 0 ]; then PWT_RT_ERR="the base verdict's mtime is in the future"; return 1; fi
  if [ "$age" -gt "$max" ]; then PWT_RT_ERR="the base verdict is stale (${age}s > ${max}s)"; return 1; fi
  if ! pwt_rt_parse_failures "$PWT_RT_BASE_LOG" >/dev/null; then
    PWT_RT_ERR="the base log has an unattributed or leak failure — only a full run can clear it"; return 1
  fi
  if [ "$PWT_RT_BASE_GREEN" != "true" ] && [ -z "$(pwt_rt_parse_failures "$PWT_RT_BASE_LOG")" ]; then
    PWT_RT_ERR="the base run is red but names no failing file"; return 1
  fi
  return 0
}

# ─── CHANGELOG SHA-BACKFILL DETECTION ────────────────────────────────────────
# pwt_rt_manifest_blob <manifest> <rel> — the blob a manifest records for <rel>.
pwt_rt_manifest_blob() {
  (
    set +e
    [ -r "$1" ] || exit 1
    b=$(awk -v r="$2" 'substr($0, 1, length(r) + 1) == r ":" { print substr($0, length(r) + 2); exit }' "$1" 2>/dev/null)
    case "$b" in ""|*[!0-9a-f]*) exit 1 ;; esac
    [ "${#b}" -eq 40 ] || [ "${#b}" -eq 64 ] || exit 1
    printf '%s\n' "$b"
  )
}

# pwt_rt_changelog_is_backfill <root> <base_manifest> <current_manifest>
#
# Returns 0 ONLY when the plan-w-team CHANGELOG differs between the two manifests by
# nothing but SHA backfills: every changed line is a `## [x.y.z] … (PENDING_SHA) …`
# release header in the base whose `(PENDING_SHA)` became `(<7–40 hex>)`, with the
# line count and every other line byte-identical. Content is read from the object
# store by blob (the base blob, and a staged blob, are there); a current blob that is
# not (a worktree edit not yet added) is read from the file on disk and accepted only
# when that file hashes to the manifest's blob. ANY doubt — unreadable blob, filter
# drift, a reworded or deleted entry — returns 1, and the caller builds the normal R,
# whose name-mention pass reruns every case that pins CHANGELOG content.
pwt_rt_changelog_is_backfill() {
  local root="$1" bman="$2" cman="$3"
  (
    set +e
    rel="$PWT_RT_CHANGELOG_REL"
    bb=$(pwt_rt_manifest_blob "$bman" "$rel") || exit 1
    cb=$(pwt_rt_manifest_blob "$cman" "$rel") || exit 1
    [ "$bb" != "$cb" ] || exit 1
    cd "$root" 2>/dev/null || exit 1
    tmpd=$(mktemp -d -t pwt-rt-cl.XXXXXX) || exit 1
    trap 'rm -rf "$tmpd" 2>/dev/null' EXIT
    git cat-file blob "$bb" > "$tmpd/base" 2>/dev/null || exit 1
    [ -s "$tmpd/base" ] || exit 1
    if ! git cat-file blob "$cb" > "$tmpd/cur" 2>/dev/null; then
      [ -f "$rel" ] || exit 1
      [ "$(git hash-object --path "$rel" -- "$rel" 2>/dev/null)" = "$cb" ] || exit 1
      cat -- "$rel" > "$tmpd/cur" 2>/dev/null || exit 1
    fi
    [ -s "$tmpd/cur" ] || exit 1
    awk '
      NR == FNR { a[FNR] = $0; na = FNR; next }
      { b[FNR] = $0; nb = FNR }
      END {
        if (na != nb) exit 1
        changed = 0
        for (i = 1; i <= na; i++) {
          if (a[i] == b[i]) continue
          if (a[i] !~ /^## \[[0-9][0-9.]*\]/) exit 1
          k = index(a[i], "(PENDING_SHA)")
          if (k == 0) exit 1
          pre = substr(a[i], 1, k - 1)
          post = substr(a[i], k + length("(PENDING_SHA)"))
          lb = length(b[i]); lp = length(pre); lq = length(post)
          if (lb < lp + lq + 9) exit 1
          if (substr(b[i], 1, lp) != pre) exit 1
          if (substr(b[i], lb - lq + 1) != post) exit 1
          mid = substr(b[i], lp + 1, lb - lp - lq)
          if (mid !~ /^\([0-9a-f]+\)$/) exit 1
          n = length(mid) - 2
          if (n < 7 || n > 40) exit 1
          changed++
        }
        exit (changed > 0 ? 0 : 1)
      }' "$tmpd/base" "$tmpd/cur" 2>/dev/null
  )
}

# ─── THE RERUN SET ──────────────────────────────────────────────────────────
# pwt_rt_required <root> <base_failed_file> <delta_file> <base_green> [<base_manifest> <current_manifest>]
#
# Prints R — `kind rel`, sorted, deduplicated — the files a retest against this
# base MUST rerun. Returns 3 (NEED-FULL, reason on stderr) when R cannot be built
# honestly. R is the union of:
#   1. the base run's failing files (a failing file that left the corpus → NEED-FULL);
#   2. changed corpus files that still exist;
#   3. the sibling test of a changed source (X.sh → X.test.sh, X.ts → X.test.ts);
#   4. every corpus file naming a changed non-corpus file (its stem, or its full
#      basename when the stem is under 6 characters) — one `grep -lF -f` pass;
#   5. every entry in tests/skill/retest-always.list (missing/empty/stale → NEED-FULL).
# Special case: a GREEN base whose delta is exactly the plan-w-team CHANGELOG AND whose
# CHANGELOG change is nothing but `(PENDING_SHA)` → `(<sha>)` header backfills
# (pwt_rt_changelog_is_backfill, checked against the two manifests' blobs) needs only
# (1) ∪ (5): a backfill cannot change any entry a case pins. Any other CHANGELOG edit —
# a reworded, added or deleted entry — takes the normal path, whose name-mention pass
# reruns every case that asserts CHANGELOG content (opus48-uplift.bats,
# model-tiering-v3.bats, the changelog-sha / doc-ship-gate / version-uplift tests).
# Without both manifests the special case never applies.
pwt_rt_required() {
  local root="$1" basefailed="$2" delta="$3" base_green="$4" bman="${5:-}" cman="${6:-}"
  (
    set +e
    set -f
    tmpd=$(mktemp -d -t pwt-rt-req.XXXXXX) || { echo "cannot create a temp dir" >&2; exit 3; }
    trap 'rm -rf "$tmpd" 2>/dev/null' EXIT
    runner="$root/$PWT_RT_RUNNER_REL"
    if [ ! -f "$runner" ]; then echo "no $PWT_RT_RUNNER_REL in $root" >&2; exit 3; fi
    bash "$runner" --list > "$tmpd/corpus" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$tmpd/corpus" ]; then
      echo "run.sh --list failed (exit $rc) — cannot enumerate the corpus" >&2; exit 3
    fi
    cut -d' ' -f2- "$tmpd/corpus" | LC_ALL=C sort -u > "$tmpd/corpus.rel"
    : > "$tmpd/req"

    # corpus_line <rel> — the `kind rel` corpus line for a path, if any.
    corpus_line() { awk -v r="$1" 'substr($0, index($0, " ") + 1) == r { print; exit }' "$tmpd/corpus"; }

    # (1) base failures
    if [ -s "$basefailed" ]; then
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        if grep -qFx -- "$l" "$tmpd/corpus"; then
          printf '%s\n' "$l" >> "$tmpd/req"
        else
          echo "base failure '$l' is no longer in the corpus — a deleted or moved failing test needs a full run" >&2
          exit 3
        fi
      done < "$basefailed"
    fi

    only_changelog=0
    if [ "$base_green" = "true" ] && [ -s "$delta" ] \
       && [ "$(grep -c . "$delta")" = "1" ] && grep -qFx -- "$PWT_RT_CHANGELOG_REL" "$delta" \
       && [ -n "$bman" ] && [ -n "$cman" ] \
       && pwt_rt_changelog_is_backfill "$root" "$bman" "$cman"; then
      only_changelog=1
    fi

    if [ "$only_changelog" = "0" ] && [ -s "$delta" ]; then
      : > "$tmpd/patterns"
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        # (2) a changed corpus file
        cl=$(corpus_line "$p")
        if [ -n "$cl" ]; then
          printf '%s\n' "$cl" >> "$tmpd/req"
          continue
        fi
        # (3) sibling test of a changed source
        sib=""
        case "$p" in
          *.test.sh|*.test.ts) ;;
          *.sh) sib="${p%.sh}.test.sh" ;;
          *.ts) sib="${p%.ts}.test.ts" ;;
        esac
        if [ -n "$sib" ]; then
          cl=$(corpus_line "$sib")
          [ -n "$cl" ] && printf '%s\n' "$cl" >> "$tmpd/req"
        fi
        # (4) name-mention pattern
        b="${p##*/}"
        s="${b%.*}"
        [ -n "$s" ] && [ "${#s}" -ge 6 ] || s="$b"
        [ -n "$s" ] && printf '%s\n' "$s" >> "$tmpd/patterns"
      done < "$delta"
      if [ -s "$tmpd/patterns" ]; then
        (
          cd "$root" 2>/dev/null || exit 0
          # shellcheck disable=SC2046
          tr '\n' '\0' < "$tmpd/corpus.rel" | xargs -0 grep -lF -f "$tmpd/patterns" -- 2>/dev/null
        ) | while IFS= read -r hit; do
              [ -n "$hit" ] || continue
              corpus_line "$hit"
            done >> "$tmpd/req"
      fi
    fi

    # (5) the always-list
    al="$root/$PWT_RT_ALWAYS_LIST_REL"
    if [ ! -f "$al" ]; then echo "$PWT_RT_ALWAYS_LIST_REL is missing" >&2; exit 3; fi
    n_al=0
    while IFS= read -r l; do
      l="${l%%#*}"
      l=$(printf '%s' "$l" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')
      [ -n "$l" ] || continue
      if ! grep -qFx -- "$l" "$tmpd/corpus"; then
        echo "$PWT_RT_ALWAYS_LIST_REL names '$l', which is not in the corpus" >&2
        exit 3
      fi
      printf '%s\n' "$l" >> "$tmpd/req"
      n_al=$((n_al + 1))
    done < "$al"
    if [ "$n_al" -eq 0 ]; then echo "$PWT_RT_ALWAYS_LIST_REL is empty" >&2; exit 3; fi

    LC_ALL=C sort -u "$tmpd/req" | sed '/^$/d'
    exit 0
  )
}
