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
#
# EXIT CODES (registry — keep in sync with tests/skill/cases/test-green-wrapper.bats)
#   0  green     (--check: latest artifact is green)
#   1  red       (--check: latest artifact is red)
#   2  usage     (--check: no artifact to read)
#   3  NO-SUITE  this repo carries no skill suite — no artifact written (consumers)
#   4  busy      another run holds this checkout's lock
#
# bash 3.2 (mac-mini /bin/bash): no `declare -A`, no `${v,,}`, no mapfile.

set -uo pipefail

STATE_FILE_PREFIX="plan-w-team-test-green"
LOCK_NAME="${STATE_FILE_PREFIX}.lock"

usage() {
  cat >&2 <<'EOF'
usage: plan-w-team-test-green.sh --slug <slug> [--log <path>]
       plan-w-team-test-green.sh --check [--slug <slug>]

  --slug <slug>   names the verdict artifact (required unless --check)
  --log <path>    evaluate an existing suite log instead of running the suite
  --check         print the latest verdict and exit 0 green / 1 red / 2 no-artifact

env:
  PWT_TEST_GREEN_SUITE_CMD   suite command (default: make test-skill)
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
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)  SLUG="${2:-}"; shift 2 || usage ;;
    --log)   LOG_IN="${2:-}"; shift 2 || usage ;;
    --check) CHECK=1; shift ;;
    -h|--help) usage ;;
    *) echo "✗ unknown argument: $1" >&2; usage ;;
  esac
done

if [ -n "$SLUG" ]; then
  SLUG="$(__tg_safe_slug "$SLUG")"
  [ -n "$SLUG" ] || { echo "✗ --slug reduced to empty after sanitization" >&2; usage; }
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
  else
    # Malformed/unreadable without jq → treat as red rather than inventing green.
    C_SLUG=$(basename "$LATEST" .json); C_SLUG="${C_SLUG#"${STATE_FILE_PREFIX}-"}"
    C_GREEN=$(sed -n 's/.*"green":[[:space:]]*\([a-z]*\).*/\1/p' "$LATEST" 2>/dev/null | head -1)
    [ -n "$C_GREEN" ] || C_GREEN="false"
    C_EXIT="?"; C_REASON="?"; C_TS="?"
  fi

  if [ "$C_GREEN" = "true" ]; then
    echo "test-green: GREEN  slug=$C_SLUG suite_exit=$C_EXIT ts=$C_TS"
    exit 0
  fi
  echo "test-green: RED    slug=$C_SLUG suite_exit=$C_EXIT reason=$C_REASON ts=$C_TS"
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

cleanup() {
  if [ "$LOCK_HELD" = "1" ] && [ -n "${LOCK_DIR:-}" ]; then
    rm -f "$LOCK_DIR/holder" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ─── RUN (or adopt) THE LOG ─────────────────────────────────────────────────
START_EPOCH=$(date +%s)
if [ -n "$LOG_IN" ]; then
  if [ ! -f "$LOG_IN" ]; then
    echo "✗ --log path is not a regular file: $LOG_IN" >&2
    exit 2
  fi
  LOG_PATH="$LOG_IN"
else
  LOG_PATH="$STATE_DIR/${STATE_FILE_PREFIX}-${SLUG}.log"
  SUITE_CMD="${PWT_TEST_GREEN_SUITE_CMD:-make test-skill}"
  echo "→ test-green: running '$SUITE_CMD' (log: $LOG_PATH)"
  # tee so a human/watcher sees progress; the VERDICT comes from the log, never from
  # this pipeline's exit code — a killed suite exits nonzero with no marker, and a
  # marker-less log is red anyway.
  ( cd "$CUR_ROOT" && sh -c "$SUITE_CMD" ) > "$LOG_PATH" 2>&1
  echo "→ test-green: suite finished (raw exit $?)"
fi
DURATION=$(( $(date +%s) - START_EPOCH ))

# ─── VERDICT ────────────────────────────────────────────────────────────────
# Green requires the LAST line to be literally `SUITE_EXIT=0`. Anything after the
# marker (a late kill message, a truncation artifact) means the run did not end at the
# gate — not green.
LAST_LINE=$(tail -1 "$LOG_PATH" 2>/dev/null | tr -d '\r')
SUITE_EXIT=""
case "$LAST_LINE" in
  SUITE_EXIT=*)
    CANDIDATE="${LAST_LINE#SUITE_EXIT=}"
    case "$CANDIDATE" in
      ''|*[!0-9]*) ;;                     # non-numeric payload → not a valid marker
      *) SUITE_EXIT="$CANDIDATE" ;;
    esac
    ;;
esac

if [ -z "$SUITE_EXIT" ]; then
  GREEN="false"; REASON="marker-absent"; JSON_EXIT="null"
elif [ "$SUITE_EXIT" -eq 0 ]; then
  GREEN="true";  REASON="ok"; JSON_EXIT="$SUITE_EXIT"
else
  GREEN="false"; REASON="suite-exit-nonzero"; JSON_EXIT="$SUITE_EXIT"
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

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

# Digest of WORKING-TREE content over the watched set: `«path»:«git blob hash»` per
# file, sorted (LC_ALL=C so the ordering is locale-independent), piped to shasum.
# `--others --exclude-standard` includes untracked-but-not-ignored files, so a brand
# new test file the suite just ran is covered too — without it, `git add`ing that
# file after the run would change the file LIST and mismatch every time.
# Prints an empty string on any failure; the caller validates the shape.
__tg_tree_digest() {
  local root="$1" g
  local globs=()
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    globs+=("$g")
  done <<EOF
$PWT_WATCHED_GLOBS
EOF
  (
    set +e
    cd "$root" 2>/dev/null || exit 0
    files=$(git ls-files --cached --others --exclude-standard -- ${globs[@]:+"${globs[@]}"} 2>/dev/null | LC_ALL=C sort)
    # An EMPTY watched set must NOT produce a digest. `shasum` of nothing is a
    # perfectly well-formed hash, and the gate would recompute that same hash from
    # its own empty enumeration and call it a match — a broken glob list would
    # corroborate itself. Fail closed instead: no files, no digest.
    [ -n "$files" ] || exit 0
    printf '%s\n' "$files" \
      | while IFS= read -r f; do
          [ -n "$f" ] || continue
          h=""
          if [ -f "$f" ]; then
            h=$(git hash-object --path "$f" -- "$f" 2>/dev/null)
          else
            h=$(git rev-parse "HEAD:$f" 2>/dev/null)
          fi
          [ -n "$h" ] || h="-"
          printf '%s:%s\n' "$f" "$h"
        done \
      | shasum -a 256 2>/dev/null | awk '{print $1}'
  )
}

# RUN mode only. In --log mode this script never saw the tree the log came from, so
# it must not assert one — the empty digest makes the gate fail closed instead.
TREE_DIGEST=""
if [ -z "$LOG_IN" ]; then
  TREE_DIGEST="$(__tg_tree_digest "$CUR_ROOT")"
  # Shape check with builtins only. A `printf ... | grep -q` form can return
  # non-zero because grep closed the pipe rather than because the value failed to
  # match, which would intermittently void a perfectly good digest.
  case "$TREE_DIGEST" in
    ""|*[!0-9a-f]*) TREE_DIGEST="" ;;
    *) [ "${#TREE_DIGEST}" -eq 64 ] || TREE_DIGEST="" ;;
  esac
  if [ -z "$TREE_DIGEST" ]; then
    echo "  test-green: tree_digest unavailable (no git/shasum, empty watched set, or not a work tree) — the commit gate will block until a digest-bearing verdict exists" >&2
  fi
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
      --arg tree_digest "$TREE_DIGEST" \
      --argjson suite_exit "$JSON_EXIT" \
      --argjson green "$GREEN" \
      --argjson duration_s "$DURATION" \
      '{ts:$ts, slug:$slug, suite_exit:$suite_exit, green:$green, reason:$reason, log_path:$log_path, duration_s:$duration_s, tree_digest:$tree_digest}' \
      > "$tmp" 2>/dev/null || return 0
  else
    # jq-absent fallback: every interpolated value is PROGRAM-CONTROLLED — $TS/$REASON/
    # $GREEN/$JSON_EXIT/$DURATION are literals this script chose, $SLUG passed
    # __tg_safe_slug, and $LOG_PATH is emitted only when it is likewise a safe derived
    # path. No user text is ever printf'd into JSON (the injection rule from the
    # done-when parser: jq --arg or nothing).
    local safe_log=""
    case "$LOG_PATH" in
      *'"'*|*'\'*|*$'\n'*) safe_log="" ;;
      *) safe_log="$LOG_PATH" ;;
    esac
    # $TREE_DIGEST is 64 lowercase hex or empty — validated above, never user text.
    printf '{"ts":"%s","slug":"%s","suite_exit":%s,"green":%s,"reason":"%s","log_path":"%s","duration_s":%s,"tree_digest":"%s"}\n' \
      "$TS" "$SLUG" "$JSON_EXIT" "$GREEN" "$REASON" "$safe_log" "$DURATION" "$TREE_DIGEST" \
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
  echo "✓ test-green: GREEN (SUITE_EXIT=0, ${DURATION}s)"
  exit 0
fi
if [ "$REASON" = "marker-absent" ]; then
  echo "✗ test-green: RED — no trailing SUITE_EXIT marker in $LOG_PATH" >&2
  echo "  the suite was killed, truncated, or aborted before its final gate." >&2
  echo "  a marker-less log is RED by construction — it is never treated as green." >&2
else
  echo "✗ test-green: RED — suite exited $SUITE_EXIT (log: $LOG_PATH)" >&2
fi
exit 1
