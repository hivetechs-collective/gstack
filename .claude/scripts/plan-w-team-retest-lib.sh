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
#
# Every text tool here (tr, sed, awk, cut, grep, paste, comm, sort, wc, xargs) runs
# as `LC_ALL=C <tool>`, and a lint in test-green-retest.bats holds that. Manifest
# lines, deltas and log rows carry a path's raw bytes, and a path can hold a byte
# that is not valid UTF-8: APFS refuses such a name on disk, but the index, a commit
# made on Linux and a Linux worktree can all hold one. Under a UTF-8 locale (the
# usual macOS shell) macOS tr, sed, cut and paste stop at that byte, and BSD grep
# refuses a pattern that holds one. A manifest came out truncated, or a rerun set
# quietly lost its name-mention hits (R255 R1). In the C locale every tool reads
# bytes as bytes on every host. Bash's own `case` and `${v#…}` matching keeps the
# caller's locale, which is how the commit gate's trigger reads a path; bash falls
# back to bytes on a sequence it cannot decode.

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
  shasum -a 256 < "$1" 2>/dev/null | LC_ALL=C awk '{print $1}'
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
# pwt_rt_esc <path> — sets PWT_RT_ESC to the manifest spelling of <path>: the
# path's own bytes, except `\` → `\\`, TAB → `\t` and LF → `\n`. A manifest is one
# `path:blob` line per file, sorted on a TAB-separated key, so those two bytes
# cannot appear raw, and escaping `\` keeps the spelling one-to-one. A path with
# none of the three bytes is spelled unchanged. Sets a variable instead of printing
# because it runs once per file, and a `$( )` would fork each time.
pwt_rt_esc() {
  local t=$'\t' n=$'\n'
  PWT_RT_ESC="$1"
  case "$1" in *\\*|*"$t"*|*"$n"*) ;; *) return 0 ;; esac
  PWT_RT_ESC="${PWT_RT_ESC//\\/\\\\}"
  PWT_RT_ESC="${PWT_RT_ESC//$t/\\t}"
  PWT_RT_ESC="${PWT_RT_ESC//$n/\\n}"
  return 0
}

# pwt_rt_manifest <root> <worktree|tracked|staged|head> <globs> [excludes]
#
# Prints the watched-set manifest: one `path:blob` line per file, sorted by PATH
# (LC_ALL=C), which is byte-for-byte the input the pre-2.51.0 tree_digest hashed —
# so `pwt_rt_digest` of this output equals every digest recorded before the lib
# existed. <globs> is the newline-separated PWT_WATCHED_GLOBS block, passed IN by
# the caller so the two symmetry-locked copies stay where they are. [excludes] is an
# optional newline-separated list of `case` patterns dropped from the enumeration
# (the subject manifest's runtime paths); the watched manifest passes none.
#
#   worktree  working-tree content: every cached path plus untracked-not-ignored
#             files, hashed from disk. A tracked path missing from disk records `-`
#             — never its HEAD blob, which let a run with the file deleted mint the
#             digest of a tree that still had it (review -2). A symlink records the
#             blob of its link text and a gitlink its commit, the objects git itself
#             stores for them, so a clean tree hashes the same in all four modes.
#   tracked   worktree mode over the INDEX's paths only (`--cached`, no untracked
#             file): working-tree content of every tracked path. Set beside
#             worktree mode it names the untracked files a run's tree held, which
#             no commit holds (pwt_rt_untracked, R255 194(5)).
#   staged    the INDEX only: `git ls-files -s` blobs for every cached path — what
#             is about to be committed. Untracked files are not in it; the gate
#             refuses a commit while the index and the working tree disagree on a
#             watched path or an untracked watched file exists, so on every path it
#             accepts, staged == worktree for the same tree (review -2).
#   head      the committed tree at HEAD only (git ls-tree), for the post-push
#             confirm's "does a full verdict describe what was pushed?"
#
# Every enumeration reads git's NUL-delimited output (-z), so a path arrives as its
# own bytes whatever core.quotePath says (R255 195(2)). The line forms C-quote any
# path holding a byte above 0x7f, a `"`, a `\` or a control character
# (`"tests/t\303\251st.bats"`). Worktree mode then found no such file and recorded
# `-`, so an edit to it never moved the digest. Staged mode recorded the quoted
# spelling, so the gate's two sides disagreed on it for good. Head mode dropped the
# path, because `tests/*` does not match `"tests/…`. Paths are matched against
# <globs> and [excludes] raw and written through pwt_rt_esc, so a tree of ordinary
# paths hashes exactly as it always has.
#
# Prints nothing (and returns 1) on any failure OR on an empty watched set: shasum
# of nothing is a well-formed hash, so an empty enumeration must never be allowed to
# corroborate itself. An unknown <mode> is a failure too.
pwt_rt_manifest() {
  local root="$1" mode="$2" globs_text="$3" excl_text="${4:-}"
  (
    set +e
    set -f   # globs are pathspecs / case patterns here, never filesystem globs
    cd "$root" 2>/dev/null || exit 1
    case "$mode" in worktree|tracked|staged|head) ;; *) exit 1 ;; esac
    globs=()
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      globs+=("$g")
    done <<EOF
$globs_text
EOF
    [ "${#globs[@]}" -gt 0 ] || exit 1
    excl=()
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      excl+=("$g")
    done <<EOF
$excl_text
EOF
    tab="$(printf '\t')"
    nl='
'
    cr="$(printf '\r')"
    tmpd=$(mktemp -d -t pwt-rt-man.XXXXXX) || exit 1
    trap 'rm -rf "$tmpd" 2>/dev/null' EXIT

    # __excluded <path> — 0 when an [excludes] pattern matches (`*` matches `/`).
    __excluded() {
      [ "${#excl[@]}" -gt 0 ] || return 1
      for x in "${excl[@]}"; do
        # shellcheck disable=SC2254  # the pattern IS the glob
        case "$1" in $x) return 0 ;; esac
      done
      return 1
    }
    # __rec <record> — split one `<meta><TAB><path>` record of `ls-files -s -z` /
    # `ls-tree -z` at its FIRST tab (the path may hold one) into META and RPATH;
    # 1 when the record has no tab or an empty path.
    __rec() {
      RPATH="${1#*"$tab"}"
      META="${1%%"$tab"*}"
      [ "$RPATH" != "$1" ] && [ -n "$RPATH" ]
    }

    if [ "$mode" = "head" ]; then
      # `git ls-tree` does not honour glob pathspecs, so list the whole tree and
      # filter with the same `case` reading the hook applies (`*` matches `/`).
      git ls-tree -r -z HEAD 2>/dev/null > "$tmpd/tree" || exit 1
      while IFS= read -r -d '' rec; do
        __rec "$rec" || continue
        # shellcheck disable=SC2086  # `<mode> <type> <object>`, split on purpose
        set -- $META
        # A blob (file or symlink) or a commit (gitlink) — the same entries the
        # staged and worktree modes record, so the modes agree on one tree.
        case "${2:-}" in blob|commit) ;; *) continue ;; esac
        __excluded "$RPATH" && continue
        for g in "${globs[@]}"; do
          # shellcheck disable=SC2254  # the glob IS the pattern
          case "$RPATH" in
            $g) pwt_rt_esc "$RPATH"; printf '%s%s%s\n' "$PWT_RT_ESC" "$tab" "$3"; break ;;
          esac
        done
      done < "$tmpd/tree" > "$tmpd/pairs"
    elif [ "$mode" = "staged" ]; then
      # `<mode> <blob> <stage><TAB><path>`. A conflicted path (stage 1-3) cannot be
      # committed, so it records `-` once instead of either side's blob.
      git ls-files -s -z -- "${globs[@]}" 2>/dev/null > "$tmpd/index" || exit 1
      while IFS= read -r -d '' rec; do
        __rec "$rec" || continue
        __excluded "$RPATH" && continue
        # shellcheck disable=SC2086  # `<mode> <blob> <stage>`, split on purpose
        set -- $META
        pwt_rt_esc "$RPATH"
        if [ "${3:-}" = "0" ]; then
          printf '%s%s%s\n' "$PWT_RT_ESC" "$tab" "$2"
        else
          printf '%s%s-\n' "$PWT_RT_ESC" "$tab"
        fi
      done < "$tmpd/index" | LC_ALL=C sort -u > "$tmpd/pairs"
    else
      if [ "$mode" = "tracked" ]; then
        git ls-files --cached -z -- "${globs[@]}" 2>/dev/null > "$tmpd/ls" || exit 1
      else
        git ls-files --cached --others --exclude-standard -z -- "${globs[@]}" 2>/dev/null \
          > "$tmpd/ls" || exit 1
      fi
      # One entry per path: a conflicted path is listed once per stage.
      LC_ALL=C sort -z -u < "$tmpd/ls" > "$tmpd/all" 2>/dev/null || exit 1
      : > "$tmpd/pairs"
      : > "$tmpd/present"
      : > "$tmpd/present.esc"
      # Gitlinks (mode 160000, stage 0), read only when a listed path turns out to
      # be a directory.
      gl_path=()
      gl_commit=()
      git ls-files -s -z -- "${globs[@]}" 2>/dev/null > "$tmpd/index"
      while IFS= read -r -d '' rec; do
        __rec "$rec" || continue
        # shellcheck disable=SC2086  # `<mode> <object> <stage>`, split on purpose
        set -- $META
        [ "${1:-}" = "160000" ] && [ "${3:-}" = "0" ] || continue
        gl_path+=("$RPATH")
        gl_commit+=("$2")
      done < "$tmpd/index"
      nf=0
      while IFS= read -r -d '' f; do
        [ -n "$f" ] || continue
        __excluded "$f" && continue
        nf=$((nf + 1))
        pwt_rt_esc "$f"
        if [ -L "$f" ]; then
          # A symlink is hashed by its LINK TEXT — the blob git stores for mode
          # 120000 and the one `git ls-files -s` / `git ls-tree` report. Hashing the
          # path (as --stdin-paths does) follows the link: a file link got its
          # target's content and a directory link recorded `-`, so the worktree and
          # staged sides never agreed and every retest with a tracked symlink in the
          # subject was refused at the gate (round-2 review). --stdin applies no
          # filters, as git does not to link text.
          h="-"
          if readlink -n "./$f" > "$tmpd/lt" 2>/dev/null; then
            h=$(git hash-object --stdin < "$tmpd/lt" 2>/dev/null)
            [ -n "$h" ] || h="-"
          fi
          printf '%s%s%s\n' "$PWT_RT_ESC" "$tab" "$h" >> "$tmpd/pairs"
        elif [ -f "$f" ]; then
          case "$f" in
            \"*|*"$nl"*|*"$cr"*)
              # --stdin-paths reads one LINE per path, C-unquotes a line that
              # starts with `"` and drops a CR before the LF: these few are hashed
              # one at a time, by the same filters.
              h=$(git hash-object --path "$f" -- "$f" 2>/dev/null)
              [ -n "$h" ] || h="-"
              printf '%s%s%s\n' "$PWT_RT_ESC" "$tab" "$h" >> "$tmpd/pairs" ;;
            *)
              printf '%s\n' "$f" >> "$tmpd/present"
              printf '%s\n' "$PWT_RT_ESC" >> "$tmpd/present.esc" ;;
          esac
        elif [ -d "$f" ]; then
          # A gitlink (submodule) is recorded by COMMIT, as the index and HEAD record
          # it: a checked-out one by its own HEAD (a new submodule commit is a change
          # git reports too), an unpopulated one by the index commit (git reads an
          # empty gitlink directory as unmodified). `$f/.git` is checked first —
          # `git -C` in a plain directory would answer with the SUPERPROJECT's HEAD —
          # and the repo-local GIT_* variables a hook environment exports are cleared
          # for the same reason (git's own submodule code does both). A directory
          # that is no gitlink (an untracked nested repo) records `-`.
          h="-"
          c=""
          i=0
          while [ "$i" -lt "${#gl_path[@]}" ]; do
            if [ "${gl_path[$i]}" = "$f" ]; then c="${gl_commit[$i]}"; break; fi
            i=$((i + 1))
          done
          if [ -n "$c" ]; then
            if [ -e "$f/.git" ]; then
              # shellcheck disable=SC2046  # variable names, one per line
              h=$(unset $(git rev-parse --local-env-vars 2>/dev/null)
                  git -C "$f" rev-parse --verify -q HEAD 2>/dev/null)
              [ -n "$h" ] || h="-"
            else
              h="$c"
            fi
          fi
          printf '%s%s%s\n' "$PWT_RT_ESC" "$tab" "$h" >> "$tmpd/pairs"
        else
          printf '%s%s-\n' "$PWT_RT_ESC" "$tab" >> "$tmpd/pairs"
        fi
      done < "$tmpd/all"
      [ "$nf" -gt 0 ] || exit 1
      if [ -s "$tmpd/present" ]; then
        # One git process for the whole set (~400 files: 25 ms vs 2 s per-file).
        # --stdin-paths applies each path's own filters, exactly like
        # `git hash-object --path f -- f`. A count mismatch (an unreadable file
        # aborts the batch) falls back to the per-file form rather than
        # mis-pairing paths and blobs. `present` holds the raw paths git reads,
        # `present.esc` the same paths in manifest spelling, line for line.
        git hash-object --stdin-paths < "$tmpd/present" > "$tmpd/blobs" 2>/dev/null
        np=$(LC_ALL=C wc -l < "$tmpd/present" | LC_ALL=C tr -d ' ')
        nb=$(LC_ALL=C wc -l < "$tmpd/blobs" 2>/dev/null | LC_ALL=C tr -d ' ')
        if [ "$np" = "$nb" ]; then
          LC_ALL=C paste -d "$tab" "$tmpd/present.esc" "$tmpd/blobs" >> "$tmpd/pairs"
        else
          while IFS= read -r f; do
            h=$(git hash-object --path "$f" -- "$f" 2>/dev/null)
            [ -n "$h" ] || h="-"
            pwt_rt_esc "$f"
            printf '%s%s%s\n' "$PWT_RT_ESC" "$tab" "$h" >> "$tmpd/pairs"
          done < "$tmpd/present"
        fi
      fi
    fi

    [ -s "$tmpd/pairs" ] || exit 1
    # Sort by the PATH field, not the whole line: `foo` and `foo.bats` order
    # differently once `:blob` is appended, and the digest must match the
    # historical path-sorted form. `tr` in the C locale too: under UTF-8, macOS tr
    # stops at a path byte that is not valid UTF-8 and the manifest is cut short.
    LC_ALL=C sort -t "$tab" -k1,1 "$tmpd/pairs" | LC_ALL=C tr "$tab" ':'
  )
}

# ─── SUBJECT MANIFEST (review -1) ───────────────────────────────────────────
# The watched set above is what the GATE is consulted for; it is not everything the
# suite exercises. The corpus reads hooks, scripts, skills and fixtures far outside
# PWT_WATCHED_GLOBS, so a red base "fixed" by an edit to an unwatched hook used to
# see an empty watched delta, classify as flaky, and certify a retest that never
# re-ran the tests reading that hook. The subject manifest is the wider tracked
# `.claude/**` + `tests/**` tree the suite is about. A verdict records its digest in
# `subject_digest` BESIDE tree_digest, which keeps its historical meaning: every
# recorded tree_digest, and the post-push confirm's tree_digest compare, are
# unchanged.
#
# Runtime paths are excluded — they change on every run or every commit and are not
# code under test. Fixed here, not env-tunable: a knob could narrow the subject back
# down to the watched set.
PWT_RT_SUBJECT_ROOTS='.claude
tests'
PWT_RT_SUBJECT_EXCLUDES='.claude/state/*
.claude/worktrees/*
.claude/.sync-version
.claude/statusline.log
.claude/agents.backup.*
tests/skill/.bats/*
tests/skill/results/*'

# pwt_rt_subject_manifest <root> <worktree|tracked|staged|head> — the subject
# manifest, in the same `path:blob` form and failure contract as pwt_rt_manifest.
# The roots are pathspecs to `git ls-files`, but head mode matches with `case`
# (`*` matches `/`), so there each root `R` is spelled `R/*`: the same files
# `git ls-files -- R` lists, so a clean tree hashes the same in every mode. This
# is the one place that conversion lives (R255 194(6)). The post-push confirm used
# to carry its own copy of it.
pwt_rt_subject_manifest() {
  local roots="$PWT_RT_SUBJECT_ROOTS"
  case "${2:-}" in
    worktree|tracked|staged) ;;
    head) roots=$(printf '%s\n' "$PWT_RT_SUBJECT_ROOTS" | LC_ALL=C sed -e '/^$/d' -e 's|/*$|/*|') ;;
    *) return 1 ;;
  esac
  [ -n "$roots" ] || return 1
  pwt_rt_manifest "$1" "$2" "$roots" "$PWT_RT_SUBJECT_EXCLUDES"
}

# ─── UNTRACKED SUBJECT FILES (R255 194(5)) ──────────────────────────────────
# subject_digest hashes every untracked, non-ignored .claude/ or tests/ file of the
# run's tree, and no commit holds one, so a push of that tree without them never
# matches the verdict's subject: the post-push confirm runs the pushed tree once
# more. That run is kept on purpose. It is the only evidence that the pushed tree,
# which lacks those files, is green: any file under .claude/ or tests/ can be one a
# tracked test sources, walks or needs to exist (a helper, a config file, a doc
# under .claude/docs/ that a corpus lint lists). A digest over the tracked paths
# only would have skipped that run whenever the untracked files looked inert, and
# no rule can tell which files the suite never read: an allowlist of inert notes
# (an R255 draft) let a doc a tracked test required cover a push that lacked it.
# A local note that must never cost a run belongs in git's ignore rules
# (.git/info/exclude): an ignored file is outside the subject in every mode. At the
# end of a full run test-green names the untracked subject files, so they can be
# committed or ignored before the push.

# pwt_rt_untracked <worktree-manifest> <tracked-manifest> — prints, one per line in
# manifest spelling, each path of the worktree manifest that the tracked one lacks:
# the untracked files of that tree. Prints nothing when there is none. Returns 1,
# printing nothing, when either manifest is missing or empty: an unknown untracked
# set is never "none".
pwt_rt_untracked() {
  local wman="$1" tman="$2"
  [ -s "$wman" ] && [ -s "$tman" ] || return 1
  (
    set +e
    tmpd=$(mktemp -d -t pwt-rt-unt.XXXXXX) || exit 1
    trap 'rm -rf "$tmpd" 2>/dev/null' EXIT
    # A manifest line is `<path>:<blob>`; a blob (hex or `-`) holds no `:`, a path may.
    # Under UTF-8, macOS sed stops at a path byte that is not valid UTF-8 and every
    # later path went unlisted, with rc 0 (the pipeline reports sort's status).
    LC_ALL=C sed 's/:[^:]*$//' "$wman" | LC_ALL=C sort -u > "$tmpd/w" || exit 1
    LC_ALL=C sed 's/:[^:]*$//' "$tman" | LC_ALL=C sort -u > "$tmpd/t" || exit 1
    LC_ALL=C comm -23 "$tmpd/w" "$tmpd/t" > "$tmpd/u" || exit 1
    cat "$tmpd/u"
  )
}

# pwt_rt_unstaged <root> <globs> — the commit gate's "stage or stash first" probe
# (review -2). Prints `modified <path>` for a watched path whose working-tree
# content differs from the index (unstaged edit or deletion) and `untracked <path>`
# for an untracked, non-ignored watched file; returns 1 when it printed anything, 2
# when git could not answer, 0 when the index IS the working tree for the watched
# set. A suite verdict describes the working tree it ran on; the commit takes the
# index; only when the two agree over the watched set does the staged digest the
# gate compares stand for the tree the suite saw. Paths are read NUL-delimited and
# printed in manifest spelling (pwt_rt_esc), as the manifest does (R255 195(2)).
pwt_rt_unstaged() {
  local root="$1" globs_text="$2"
  (
    set +e
    set -f
    cd "$root" 2>/dev/null || exit 2
    globs=()
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      globs+=("$g")
    done <<EOF
$globs_text
EOF
    [ "${#globs[@]}" -gt 0 ] || exit 2
    tmpd=$(mktemp -d -t pwt-rt-uns.XXXXXX) || exit 2
    trap 'rm -rf "$tmpd" 2>/dev/null' EXIT
    git diff --name-only -z -- "${globs[@]}" > "$tmpd/modified" 2>/dev/null || exit 2
    git ls-files --others --exclude-standard -z -- "${globs[@]}" > "$tmpd/untracked" 2>/dev/null || exit 2
    found=0
    for kind in modified untracked; do
      [ -s "$tmpd/$kind" ] || continue
      found=1
      LC_ALL=C sort -z -u < "$tmpd/$kind" | while IFS= read -r -d '' p; do
        [ -n "$p" ] || continue
        pwt_rt_esc "$p"
        printf '%s %s\n' "$kind" "$PWT_RT_ESC"
      done
    done
    [ "$found" = "0" ] || exit 1
    exit 0
  )
}

# pwt_rt_path_watched <path> <globs> — 0 when <path> matches a watched glob, read
# the way the hook's gate trigger reads it (`case`, `*` matches `/`).
pwt_rt_path_watched() {
  local p="$1" g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254  # the glob IS the pattern
    case "$p" in $g) return 0 ;; esac
  done <<EOF
$2
EOF
  return 1
}

# pwt_rt_unwatched <delta_file> <globs> — the delta's paths no watched glob covers,
# one per line: the subject-only half of a subject delta.
pwt_rt_unwatched() {
  local p
  [ -r "$1" ] || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    pwt_rt_path_watched "$p" "$2" || printf '%s\n' "$p"
  done < "$1"
  return 0
}

# pwt_rt_digest [file] — sha256 of a manifest (stdin when no file). Empty input →
# empty output: an empty manifest never has a digest.
pwt_rt_digest() {
  (
    set +e
    if [ $# -gt 0 ]; then
      [ -s "$1" ] || exit 1
      shasum -a 256 < "$1" 2>/dev/null | LC_ALL=C awk '{print $1}'
    else
      data=$(cat)
      [ -n "$data" ] || exit 1
      printf '%s\n' "$data" | shasum -a 256 2>/dev/null | LC_ALL=C awk '{print $1}'
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
# pwt_rt_trailer <log> — prints the machine-readable trailer block: the contiguous
# run of SUITE_MODE= / RETEST_RAN / SUITE_FAILED / SUITE_SKIPPED rows directly above
# the final SUITE_EXIT=N line (make's own `make: *** …` lines after it are skipped,
# as pwt_rt_marker does). Returns 1 when there is no final marker, and 2 when any of
# those prefixes — or a second SUITE_EXIT= — appears at column 0 ABOVE the block.
#
# Every reader below parses ONLY this block (review -5). Before it they grepped the
# whole log, so a test that printed `RETEST_RAN bats <rel>` or `SUITE_FAILED …` at
# column 0 anywhere in its output was read as the runner's own witness row: it could
# fake coverage of a file the retest never ran, or plant a failure row. run.sh emits
# its rows only in __suite_exit, immediately ahead of the marker. It DOES relay test
# output (bats TAP via tee) at column 0, so a test that prints one of these prefixes
# makes the log fail closed here (rc 2) — refused, never misread. No case in the
# corpus prints them today; a case that must print one has to indent it.
pwt_rt_trailer() {
  (
    set +e
    [ -r "$1" ] || exit 1
    LC_ALL=C tr -d '\r' < "$1" 2>/dev/null | LC_ALL=C awk '
      { line[NR] = $0 }
      function is_row(s) {
        return (s ~ /^SUITE_MODE=/ || s ~ /^RETEST_RAN / || s ~ /^SUITE_FAILED / || s ~ /^SUITE_SKIPPED /)
      }
      END {
        i = NR
        while (i > 0 && line[i] ~ /^make(\[[0-9]+\])?: \*\*\* /) i--
        if (i < 1 || line[i] !~ /^SUITE_EXIT=[0-9]+$/) exit 1
        j = i - 1
        while (j > 0 && is_row(line[j])) j--
        for (k = 1; k <= j; k++)
          if (is_row(line[k]) || line[k] ~ /^SUITE_EXIT=/) exit 2
        for (k = j + 1; k < i; k++) print line[k]
      }'
  )
}

# pwt_rt_log_mode <log> — the SUITE_MODE value when the trailer block carries
# EXACTLY one SUITE_MODE= line; nothing otherwise (absent = legacy, two = spliced,
# a row above the trailer = forged).
pwt_rt_log_mode() {
  (
    set +e
    block=$(pwt_rt_trailer "$1") || exit 1
    n=$(printf '%s\n' "$block" | LC_ALL=C grep -c '^SUITE_MODE=' 2>/dev/null)
    [ "$n" = "1" ] || exit 1
    printf '%s\n' "$block" | LC_ALL=C grep '^SUITE_MODE=' | head -1 | LC_ALL=C sed 's/^SUITE_MODE=//'
  )
}

# pwt_rt_parse_failures <log> — `kind rel` for every attributed failing file in the
# trailer block. Returns 1 when the block carries an `unattributed` or `leak` row (a
# failure the runner could not tie to a file cannot be retested by file, so it needs
# a full run), and when the log has no valid trailer block at all.
pwt_rt_parse_failures() {
  (
    set +e
    block=$(pwt_rt_trailer "$1") || exit 1
    printf '%s\n' "$block" | LC_ALL=C grep -E '^SUITE_FAILED (unattributed|leak)( |$)' >/dev/null 2>&1 && bad=1 || bad=0
    printf '%s\n' "$block" | LC_ALL=C grep -E '^SUITE_FAILED (bats|shell|ts) .' 2>/dev/null \
      | LC_ALL=C sed 's/^SUITE_FAILED //' | LC_ALL=C sort -u
    [ "$bad" = "0" ]
  )
}

# pwt_rt_ran <log> — `kind rel` for every file the retest log's trailer block says
# it ran. Returns 1 (and prints nothing) when the log has no valid trailer block.
pwt_rt_ran() {
  (
    set +e
    block=$(pwt_rt_trailer "$1") || exit 1
    printf '%s\n' "$block" | LC_ALL=C grep -E '^RETEST_RAN (bats|shell|ts) .' 2>/dev/null \
      | LC_ALL=C sed 's/^RETEST_RAN //' | LC_ALL=C sort -u
    exit 0
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
    tail -n 50 "$1" 2>/dev/null | LC_ALL=C tr -d '\r' | LC_ALL=C awk '
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
# returns 0 and sets PWT_RT_BASE_{SLUG,TS,DIGEST,LOG,MANIFEST,GREEN,EXIT} and
# PWT_RT_BASE_SUBJECT_{DIGEST,MANIFEST}. On failure returns 1 with the reason in
# PWT_RT_ERR. Requires jq + shasum.
#
# A base that predates the subject manifest (no `subject_digest`) is REFUSED, never
# measured against the watched set alone: without the subject a retest cannot see an
# edit to an unwatched file the corpus reads, which is the exact hole review -1
# closed. The cost is one full run after the upgrade.
pwt_rt_check_base() {
  local f="$1" max now mt age mode cmd reason man_sha sub_sha
  # Normalize the cap: a non-numeric value (e.g. a "24h" typo) must not turn the age
  # comparison into a test error that reads as "not stale" (fail open).
  max="$(pwt_rt_int "$2" 86400)"
  PWT_RT_ERR=""
  PWT_RT_BASE_SLUG=""; PWT_RT_BASE_TS=""; PWT_RT_BASE_DIGEST=""; PWT_RT_BASE_LOG=""
  PWT_RT_BASE_MANIFEST=""; PWT_RT_BASE_GREEN=""; PWT_RT_BASE_EXIT=""
  PWT_RT_BASE_SUBJECT_DIGEST=""; PWT_RT_BASE_SUBJECT_MANIFEST=""
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
  if ! pwt_rt_trailer "$PWT_RT_BASE_LOG" >/dev/null; then
    PWT_RT_ERR="the base log's machine-readable rows are not confined to its final trailer block (forged, spliced or truncated)"; return 1
  fi
  if [ "$(pwt_rt_log_mode "$PWT_RT_BASE_LOG")" != "full" ]; then PWT_RT_ERR="the base log does not carry exactly one SUITE_MODE=full"; return 1; fi
  # Defense in depth beside the hash: the failing set R is built from must be exactly
  # the one the (lane-guard-protected) verdict recorded at archive time.
  if ! jq -e '.failed | type == "array"' "$f" >/dev/null 2>&1; then
    PWT_RT_ERR="the base verdict records no failed[] list"; return 1
  fi
  if [ "$(jq -r '.failed[] | tostring' "$f" 2>/dev/null | LC_ALL=C tr -d '\r' | LC_ALL=C sort -u)" \
       != "$(pwt_rt_parse_failures "$PWT_RT_BASE_LOG" 2>/dev/null)" ]; then
    PWT_RT_ERR="the base log's SUITE_FAILED set differs from the base verdict's failed[]"; return 1
  fi
  if [ -z "$PWT_RT_BASE_MANIFEST" ] || [ ! -r "$PWT_RT_BASE_MANIFEST" ]; then PWT_RT_ERR="the base run's manifest is missing or unreadable"; return 1; fi
  man_sha=$(pwt_rt_sha256_file "$PWT_RT_BASE_MANIFEST")
  if [ "$man_sha" != "$PWT_RT_BASE_DIGEST" ]; then PWT_RT_ERR="the base manifest does not hash to the base tree_digest (tampered or replaced)"; return 1; fi
  PWT_RT_BASE_SUBJECT_DIGEST=$(jq -r '.subject_digest // ""' "$f" 2>/dev/null)
  PWT_RT_BASE_SUBJECT_MANIFEST=$(jq -r '.subject_manifest_path // ""' "$f" 2>/dev/null)
  if ! pwt_rt_is_hex64 "$PWT_RT_BASE_SUBJECT_DIGEST"; then
    PWT_RT_ERR="the base verdict predates the subject manifest (no subject_digest, or the tree changed during that run) — run one full run"; return 1
  fi
  if [ -z "$PWT_RT_BASE_SUBJECT_MANIFEST" ] || [ ! -r "$PWT_RT_BASE_SUBJECT_MANIFEST" ]; then PWT_RT_ERR="the base run's subject manifest is missing or unreadable"; return 1; fi
  sub_sha=$(pwt_rt_sha256_file "$PWT_RT_BASE_SUBJECT_MANIFEST")
  if [ "$sub_sha" != "$PWT_RT_BASE_SUBJECT_DIGEST" ]; then PWT_RT_ERR="the base subject manifest does not hash to the base subject_digest (tampered or replaced)"; return 1; fi
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
    b=$(LC_ALL=C awk -v r="$2" 'substr($0, 1, length(r) + 1) == r ":" { print substr($0, length(r) + 2); exit }' "$1" 2>/dev/null)
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
    LC_ALL=C awk '
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
# pwt_rt_required <root> <base_failed_file> <delta_file> <base_green>
#                 [<base_manifest> <current_manifest> [<unwatched_delta_file>]]
#
# Prints R — `kind rel`, sorted, deduplicated — the files a retest against this
# base MUST rerun. Returns 3 (NEED-FULL, reason on stderr) when R cannot be built
# honestly. The CHANGED set is <delta_file> (the watched delta) plus
# <unwatched_delta_file> (subject paths outside the watched globs — review -1). R is
# the union of:
#   1. the base run's failing files (a failing file that left the corpus → NEED-FULL);
#   2. changed corpus files that still exist;
#   3. the sibling test of a changed source (X.sh → X.test.sh, X.ts → X.test.ts);
#   4. every corpus file naming a changed non-corpus file (its stem, or its full
#      basename when the stem is under 6 characters) — one `grep -lF -f` pass;
#   4b. ONE transitive hop (review -4): the watched non-corpus sources (from
#      <current_manifest>; .sh/.bash/.ts/.js/.mjs/.py outside tests/skill/) that
#      name a changed file are CALLERS, and each caller's sibling and name-mention
#      hits join R — a helper exercised only through the script that sources it is
#      retested through that script's tests. Without <current_manifest> there is no
#      caller set and the hop is skipped;
#   5. every entry in tests/skill/retest-always.list (missing/empty/stale → NEED-FULL).
# Special case: a GREEN base whose WATCHED delta is exactly the plan-w-team CHANGELOG
# AND whose CHANGELOG change is nothing but `(PENDING_SHA)` → `(<sha>)` header
# backfills (pwt_rt_changelog_is_backfill, checked against the two manifests' blobs)
# drops the CHANGELOG from the changed set: a backfill cannot change any entry a case
# pins. Unwatched changes are never dropped. Any other CHANGELOG edit — a reworded,
# added or deleted entry — takes the normal path, whose name-mention pass reruns every
# case that asserts CHANGELOG content (opus48-uplift.bats, model-tiering-v3.bats, the
# changelog-sha / doc-ship-gate / version-uplift tests). Without both manifests the
# special case never applies.
pwt_rt_required() {
  local root="$1" basefailed="$2" delta="$3" base_green="$4" bman="${5:-}" cman="${6:-}" udelta="${7:-}"
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
    LC_ALL=C cut -d' ' -f2- "$tmpd/corpus" | LC_ALL=C sort -u > "$tmpd/corpus.rel"
    : > "$tmpd/req"

    # corpus_line <rel> — the `kind rel` corpus line for a path, if any.
    corpus_line() { LC_ALL=C awk -v r="$1" 'substr($0, index($0, " ") + 1) == r { print; exit }' "$tmpd/corpus"; }
    # sibling_of <rel> — the sibling test path of a source, if it has that shape.
    sibling_of() {
      case "$1" in
        *.test.sh|*.test.ts) ;;
        *.sh) printf '%s\n' "${1%.sh}.test.sh" ;;
        *.ts) printf '%s\n' "${1%.ts}.test.ts" ;;
      esac
    }
    # mention_of <rel> — the name-mention pattern: stem, or basename when stem < 6.
    mention_of() {
      local b s
      b="${1##*/}"
      s="${b%.*}"
      [ -n "$s" ] && [ "${#s}" -ge 6 ] || s="$b"
      [ -n "$s" ] && printf '%s\n' "$s"
    }

    # (1) base failures
    if [ -s "$basefailed" ]; then
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        if LC_ALL=C grep -qFx -- "$l" "$tmpd/corpus"; then
          printf '%s\n' "$l" >> "$tmpd/req"
        else
          echo "base failure '$l' is no longer in the corpus — a deleted or moved failing test needs a full run" >&2
          exit 3
        fi
      done < "$basefailed"
    fi

    only_changelog=0
    if [ "$base_green" = "true" ] && [ -s "$delta" ] \
       && [ "$(LC_ALL=C grep -c . "$delta")" = "1" ] && LC_ALL=C grep -qFx -- "$PWT_RT_CHANGELOG_REL" "$delta" \
       && [ -n "$bman" ] && [ -n "$cman" ] \
       && pwt_rt_changelog_is_backfill "$root" "$bman" "$cman"; then
      only_changelog=1
    fi

    : > "$tmpd/changed"
    if [ "$only_changelog" = "0" ] && [ -s "$delta" ]; then cat "$delta" >> "$tmpd/changed"; fi
    if [ -n "$udelta" ] && [ -s "$udelta" ]; then cat "$udelta" >> "$tmpd/changed"; fi
    # Under UTF-8, macOS sed stopped at a path byte that is not valid UTF-8 and every
    # later changed path left the rerun set unseen; BSD grep refused the whole
    # pattern file below for one such pattern (R255 R1). Hence LC_ALL=C throughout.
    LC_ALL=C sort -u "$tmpd/changed" | LC_ALL=C sed '/^$/d' > "$tmpd/changed.u"

    if [ -s "$tmpd/changed.u" ]; then
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
        sib=$(sibling_of "$p")
        if [ -n "$sib" ]; then
          cl=$(corpus_line "$sib")
          [ -n "$cl" ] && printf '%s\n' "$cl" >> "$tmpd/req"
        fi
        # (4) name-mention pattern
        mention_of "$p" >> "$tmpd/patterns"
      done < "$tmpd/changed.u"

      # (4b) one transitive hop through the watched sources that name a changed file.
      if [ -s "$tmpd/patterns" ] && [ -n "$cman" ] && [ -r "$cman" ]; then
        LC_ALL=C sed 's/:[^:]*$//' "$cman" | while IFS= read -r c; do
          [ -n "$c" ] || continue
          case "$c" in
            tests/skill/*) continue ;;
            *.sh|*.bash|*.ts|*.js|*.mjs|*.py) ;;
            *) continue ;;
          esac
          LC_ALL=C grep -qFx -- "$c" "$tmpd/corpus.rel" && continue
          LC_ALL=C grep -qFx -- "$c" "$tmpd/changed.u" && continue
          [ -f "$root/$c" ] && printf '%s\n' "$c"
        done > "$tmpd/callers.cand"
        if [ -s "$tmpd/callers.cand" ]; then
          (
            cd "$root" 2>/dev/null || exit 0
            LC_ALL=C tr '\n' '\0' < "$tmpd/callers.cand" | LC_ALL=C xargs -0 grep -lF -f "$tmpd/patterns" -- 2>/dev/null
          ) > "$tmpd/callers"
          while IFS= read -r c; do
            [ -n "$c" ] || continue
            sib=$(sibling_of "$c")
            if [ -n "$sib" ]; then
              cl=$(corpus_line "$sib")
              [ -n "$cl" ] && printf '%s\n' "$cl" >> "$tmpd/req"
            fi
            mention_of "$c" >> "$tmpd/hop.patterns"
          done < "$tmpd/callers"
          [ -s "$tmpd/hop.patterns" ] && cat "$tmpd/hop.patterns" >> "$tmpd/patterns"
        fi
      fi

      if [ -s "$tmpd/patterns" ]; then
        (
          cd "$root" 2>/dev/null || exit 0
          LC_ALL=C tr '\n' '\0' < "$tmpd/corpus.rel" | LC_ALL=C xargs -0 grep -lF -f "$tmpd/patterns" -- 2>/dev/null
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
      l=$(printf '%s' "$l" | LC_ALL=C sed 's/[[:space:]]*$//; s/^[[:space:]]*//')
      [ -n "$l" ] || continue
      if ! LC_ALL=C grep -qFx -- "$l" "$tmpd/corpus"; then
        echo "$PWT_RT_ALWAYS_LIST_REL names '$l', which is not in the corpus" >&2
        exit 3
      fi
      printf '%s\n' "$l" >> "$tmpd/req"
      n_al=$((n_al + 1))
    done < "$al"
    if [ "$n_al" -eq 0 ]; then echo "$PWT_RT_ALWAYS_LIST_REL is empty" >&2; exit 3; fi

    LC_ALL=C sort -u "$tmpd/req" | LC_ALL=C sed '/^$/d'
    exit 0
  )
}
