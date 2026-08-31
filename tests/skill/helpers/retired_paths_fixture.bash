#!/usr/bin/env bash
# tests/skill/helpers/retired_paths_fixture.bash
#
# Scratch-consumer fixture harness for the sync-to-project.sh retired-paths
# cleanup pass (agent-roster restructure, spec R6 + Key decision 4).
#
# WHY A FIXTURE AND NOT THE REAL REPOS. The pass under test deletes files in
# OTHER people's repositories, unattended, on every sync. There is exactly one
# safe place to exercise it: a throwaway pair of git repos in $TMPDIR, built
# fresh per test. Nothing here ever touches the real source tree or a real
# consumer — every path is rooted at $SANDBOX_DIR (created by the shared
# `sandbox` helper, removed at teardown, refusing to rm outside tmp).
#
# WHAT IT BUILDS
#   $SANDBOX_DIR/source/          a stand-in claude-pattern (git, clean)
#     .claude/agents/...          a couple of keep-tier files
#     .claude/skills/<name>/      "shipped" skill dirs (rule-6 ancestor set)
#     .claude/scripts/sync-retired-paths.txt   the manifest under test
#   $SANDBOX_DIR/consumer/        a stand-in synced repo (git)
#     .claude/...                 whatever the test wants deleted (or not)
#
# HOW THE PASS IS LOADED. sync-to-project.sh is a top-level script (it runs the
# sync the moment it is sourced), so the cleanup functions are delimited by
# sentinel comments and extracted with sed — the same mechanism
# sync-profile-pipeline-agents.bats uses to evaluate get_profile_agents() in
# isolation. ONE implementation, in ONE file, exercised directly. If the
# sentinels ever go missing, `load_retired_paths_pass` fails loudly rather than
# silently testing nothing.

RETIRED_PATHS_BEGIN_MARK='PWT_RETIRED_PATHS_CLEANUP_BEGIN'
RETIRED_PATHS_END_MARK='PWT_RETIRED_PATHS_CLEANUP_END'

# Extract get_profile_agents() + the sentinel-delimited cleanup block out of
# sync-to-project.sh and source them into the current shell. The profile
# function comes along because rule 6 builds its ancestor set from the live
# profiles — the pass must never be able to delete something a profile ships.
load_retired_paths_pass() {
  local sync="${1:-$REPO_ROOT/.claude/scripts/sync-to-project.sh}"
  local lib="${SANDBOX_DIR:-$BATS_TEST_TMPDIR}/retired-paths-pass.bash"

  [ -f "$sync" ] || { echo "fixture: no sync-to-project.sh at $sync" >&2; return 1; }

  {
    sed -n '/^get_profile_agents()/,/^}/p' "$sync"
    sed -n "/$RETIRED_PATHS_BEGIN_MARK/,/$RETIRED_PATHS_END_MARK/p" "$sync"
  } > "$lib"

  # Anti-vacuity: an empty or marker-less extraction would make every test below
  # pass against nothing at all. Both halves must be real.
  grep -q '^get_profile_agents()' "$lib" || {
    echo "fixture: get_profile_agents() not extracted — sed range rot" >&2; return 1; }
  grep -q '^retired_paths_cleanup()' "$lib" || {
    echo "fixture: retired_paths_cleanup() not extracted — sentinel markers missing from sync-to-project.sh" >&2; return 1; }

  # shellcheck disable=SC1090
  . "$lib"
}

# ── Scratch source repo ─────────────────────────────────────────────────────
# $1.. = extra `.claude`-relative paths to materialise (files get a byte of
# content, paths ending in `/` become directories).
# FIXTURE_SRC_SUBDIR relocates the scratch source inside the sandbox — the
# not-a-worktree gate needs a source that literally lives under
# `.claude/worktrees/`, which is a property of the PATH, not of the content.
fixture_make_source() {
  SRC_ROOT="$SANDBOX_DIR/${FIXTURE_SRC_SUBDIR:-source}"
  SRC_CLAUDE="$SRC_ROOT/.claude"
  export SRC_ROOT SRC_CLAUDE

  mkdir -p "$SRC_ROOT"
  mkdir -p "$SRC_CLAUDE/agents/team" "$SRC_CLAUDE/agents/research-planning" \
           "$SRC_CLAUDE/scripts" "$SRC_CLAUDE/skills"
  # Keep-tier stand-ins so the profile-derived ancestor set resolves to something.
  printf 'keep\n' > "$SRC_CLAUDE/agents/team/builder.md"
  printf 'keep\n' > "$SRC_CLAUDE/agents/research-planning/security-expert.md"
  # A "shipped" skill dir — rule 6 must treat it as untouchable.
  mkdir -p "$SRC_CLAUDE/skills/frontend-web"
  printf -- '---\nname: frontend-web\n---\n' > "$SRC_CLAUDE/skills/frontend-web/SKILL.md"

  fixture_materialise "$SRC_ROOT" "$@"

  (
    cd "$SRC_ROOT" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    git add -A -f
    git commit -q --allow-empty -m "source"
  )
}

# ── Scratch consumer repo ───────────────────────────────────────────────────
# $1.. = repo-relative paths to materialise. By default they are committed
# (tracked), which is the common consumer state; pass FIXTURE_TRACK=0 for an
# untracked working tree.
fixture_make_consumer() {
  DST_ROOT="$SANDBOX_DIR/consumer"
  DST_CLAUDE="$DST_ROOT/.claude"
  export DST_ROOT DST_CLAUDE

  mkdir -p "$DST_CLAUDE"
  fixture_materialise "$DST_ROOT" "$@"

  (
    cd "$DST_ROOT" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "Test"
    # `-f` bypasses the OPERATOR's global core.excludesFile — a fixture path
    # like .claude/settings.local.json is ignored on some machines and not
    # others, and a test whose tracked/untracked setup depends on the developer's
    # personal gitignore is not a test. `--allow-empty` covers the fixtures whose
    # only content is an empty directory (git cannot track those at all), which
    # would otherwise abort the whole setup with "nothing to commit".
    if [ "${FIXTURE_TRACK:-1}" = "1" ]; then
      git add -A -f
      git commit -q --allow-empty -m "consumer"
    else
      git commit -q --allow-empty -m "consumer"
    fi
  )
}

# Create each path under $1. A trailing `/` means directory; otherwise a file
# (parents auto-created). Deliberately dumb — tests should read as a list of
# paths, not as mkdir plumbing.
fixture_materialise() {
  local root="$1"; shift
  local p
  for p in "$@"; do
    case "$p" in
      */)
        mkdir -p "$root/$p"
        ;;
      *)
        mkdir -p "$root/$(dirname "$p")"
        printf 'x\n' > "$root/$p"
        ;;
    esac
  done
}

# Write the manifest into the scratch SOURCE (the only copy the pass reads).
# Every argument is one raw line, written verbatim — hazard tests depend on
# bytes surviving unmangled (CRLF, spaces, globs).
fixture_write_manifest() {
  local mf="$SRC_CLAUDE/scripts/sync-retired-paths.txt"
  mkdir -p "$SRC_CLAUDE/scripts"
  : > "$mf"
  local l
  for l in "$@"; do
    printf '%s\n' "$l" >> "$mf"
  done
}

# Same, but writes bytes with no trailing newline handling — used for the CRLF
# hazard where the line ending itself is the payload.
fixture_write_manifest_raw() {
  local mf="$SRC_CLAUDE/scripts/sync-retired-paths.txt"
  mkdir -p "$SRC_CLAUDE/scripts"
  printf '%b' "$1" > "$mf"
}

# Run the pass against the scratch pair. $1 = "--dry-run" or "".
fixture_run_pass() {
  retired_paths_cleanup "$SRC_CLAUDE" "$DST_CLAUDE" "${1:-}"
}

# True when the consumer still has the path (file, dir, or dangling symlink).
fixture_consumer_has() {
  [ -e "$DST_ROOT/$1" ] || [ -L "$DST_ROOT/$1" ]
}
