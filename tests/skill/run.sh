#!/usr/bin/env bash
# tests/skill/run.sh
#
# Single entry point for the /plan-w-team test harness.
#
# Responsibilities:
#   1. Ensure bats-core is available (vendored under tests/skill/.bats/, auto-cloned).
#   2. Discover all .bats files under tests/skill/cases/.
#   3. Run them with TAP output + JSON archival.
#   4. Archive each run's results under tests/skill/results/runs/<timestamp>.json
#      and update tests/skill/results/latest.json (symlink-like pointer).
#   5. Exit non-zero if any test failed.
#
# Anti-fragmentation lock-in: this is the ONLY way to run the suite. Do not
# add a `test-skill-fast`, a `test-snippets`, or a parallel runner. The whole
# suite runs together so passing tests cannot mask a regression elsewhere.
# (Filtering specific files for local dev iteration is supported via $1, but
# `make test-skill` always runs everything.)
#
# Usage:
#   tests/skill/run.sh                        # run all cases
#   tests/skill/run.sh cases/secret-scan.bats # run a single file (DEV ONLY)
#   tests/skill/run.sh --no-archive           # skip JSON write (CI smoke runs)
#   tests/skill/run.sh --setup                # bootstrap bats only, exit
#
# Exit codes:
#   0 — all tests passed
#   1 — at least one test failed
#   2 — bootstrap or environment failure (cannot run tests at all)

set -euo pipefail

# ── Sanitize inherited /plan-w-team worker env (test-hygiene) ─────────────────
# When pwt-goal.sh spawns a worker (claude --bg), it exports PLAN_W_TEAM_FORCE_SPAWN=1,
# PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1, and PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 into the
# child. If the suite is run from INSIDE such a worker session (e.g. an autonomous
# /plan-w-team run testing itself, or the pre-commit gate firing under `claude --bg`),
# those leak into every pwt-goal.sh subprocess the tests invoke and silently BYPASS
# the cascade (PWT-DS2) + double-spawn (PWT-DS1) guards — producing FALSE guard-test
# failures that have nothing to do with the code under test (diagnosed 2026-05-29).
# Strip them so the suite always sees a pristine ambient env. Per-test explicit
# settings (`VAR=1 run …`) are unaffected — this only clears the inherited value.
unset PLAN_W_TEAM_FORCE_SPAWN PLAN_W_TEAM_DISABLE_PROMPT_ROUTE PLAN_W_TEAM_AUTO_APPROVE_PUSH

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS_DIR="$REPO_ROOT/tests/skill"
BATS_DIR="$HARNESS_DIR/.bats"
BATS_BIN="$BATS_DIR/bin/bats"
CASES_DIR="$HARNESS_DIR/cases"
SCENARIOS_DIR="$HARNESS_DIR/scenarios"
RESULTS_DIR="$HARNESS_DIR/results"
RUNS_DIR="$RESULTS_DIR/runs"

ARCHIVE=1
SETUP_ONLY=0
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-archive) ARCHIVE=0; shift ;;
    --setup)      SETUP_ONLY=1; shift ;;
    -h|--help)    grep '^#' "$0" | head -30; exit 0 ;;
    *)            TARGET="$1"; shift ;;
  esac
done

# ── Bootstrap bats-core ──────────────────────────────────────────────────────
# Vendored under .bats/ (gitignored). One-time clone on first run.
if [ ! -x "$BATS_BIN" ]; then
  echo "→ bootstrapping bats-core (one-time clone) …"
  rm -rf "$BATS_DIR"
  if ! command -v git >/dev/null 2>&1; then
    echo "✗ git required to bootstrap bats-core" >&2
    exit 2
  fi
  # Pin a known-good release tag — avoids surprise breakage from upstream main.
  if ! git clone --quiet --depth 1 --branch v1.11.0 \
        https://github.com/bats-core/bats-core.git "$BATS_DIR"; then
    echo "✗ failed to clone bats-core" >&2
    echo "  if offline, install via: brew install bats-core" >&2
    echo "  then re-run: tests/skill/run.sh" >&2
    exit 2
  fi
  echo "✓ bats-core v1.11.0 vendored under tests/skill/.bats/"
fi

if [ "$SETUP_ONLY" = "1" ]; then
  echo "✓ harness ready. run: tests/skill/run.sh"
  exit 0
fi

# ── Discover test files ──────────────────────────────────────────────────────
if [ -n "$TARGET" ]; then
  TARGET_PATH="$REPO_ROOT/$TARGET"
  [ -f "$TARGET_PATH" ] || TARGET_PATH="$HARNESS_DIR/$TARGET"
  if [ ! -f "$TARGET_PATH" ]; then
    echo "✗ no such test file: $TARGET" >&2
    exit 2
  fi
  TEST_FILES=("$TARGET_PATH")
else
  if [ ! -d "$CASES_DIR" ]; then
    echo "✗ cases directory missing: $CASES_DIR" >&2
    exit 2
  fi
  TEST_FILES=()
  # Walk both cases/ (unit tests) and scenarios/ (E2E integration tests).
  # Anti-fragmentation lock-in: this single discovery is the only place that
  # decides what runs. `run-scenarios.sh` is a dev-iteration shortcut for the
  # scenarios/ subset; pre-commit and `make test-skill` always invoke this
  # runner so passing tests cannot mask a regression elsewhere.
  while IFS= read -r f; do
    TEST_FILES+=("$f")
  done < <(
    {
      find "$CASES_DIR" -name '*.bats' -type f 2>/dev/null
      [ -d "$SCENARIOS_DIR" ] && find "$SCENARIOS_DIR" -name '*.bats' -type f 2>/dev/null
    } | sort
  )
fi

if [ "${#TEST_FILES[@]}" -eq 0 ]; then
  echo "⚠ no .bats files found under $CASES_DIR or $SCENARIOS_DIR — nothing to run"
  exit 0
fi

# ── Run tests ────────────────────────────────────────────────────────────────
mkdir -p "$RUNS_DIR"
TIMESTAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
TAP_LOG=$(mktemp)
trap 'rm -f "$TAP_LOG"' EXIT

echo "→ running ${#TEST_FILES[@]} bats file(s) under tests/skill/{cases,scenarios}/"

# Use --tap to get machine-parseable output AND tee it to terminal for dev UX.
# `bats` exits non-zero on any failure; capture exit independently of the tee
# pipeline so PIPESTAT does not mask it.
set +e
"$BATS_BIN" --tap "${TEST_FILES[@]}" | tee "$TAP_LOG"
BATS_EXIT=${PIPESTATUS[0]}
set -e

# ── Phase 2: shell integration tests (.test.sh) ──────────────────────────────
# Anti-fragmentation lock-in (extended 2026-05-25 complexity audit): the
# .claude/{scripts,hooks}/*.test.sh integration tests (pwt-goal, goal-evaluator,
# route-prompt, worktree-gc, supervisor-route, …) were historically orphaned —
# run by NEITHER this canonical runner NOR the .githooks/pre-commit guard — so
# stale assertions bit-rotted undetected (4 stale test files found in that
# audit). They are now part of THE single suite: one runner discovers and runs
# ALL tests so a passing bats run cannot mask a regression in a shell test.
#
# Skipped in single-file TARGET mode (dev iteration on one bats file). Each test
# gets an optional wall-clock timeout (portable: timeout/gtimeout if present,
# else bare) so a hung test cannot stall the whole suite. Disable via
# SKILL_SKIP_SHELL_TESTS=1 (escape hatch, mirrors the bats --no-archive intent).
SHELL_TOTAL=0
SHELL_PASSED=0
SHELL_FAILED=0
SHELL_FAILED_NAMES=""
if [ -z "$TARGET" ] && [ "${SKILL_SKIP_SHELL_TESTS:-0}" != "1" ]; then
  TIMEOUT_BIN=""
  if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"; fi
  SHELL_TEST_TIMEOUT="${SHELL_TEST_TIMEOUT:-180}"

  # The canonical suite may be invoked from INSIDE a /plan-w-team worker session
  # (e.g. Step 6 ship, or an autonomous run auditing the skill). That ambient
  # environment carries the pwt control vars — PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1
  # (PWT-DS2 cascade guard → pwt-goal.sh exits 4), AUTO_APPROVE_PUSH=1, etc. The
  # shell tests assert DEFAULT behavior and set their own per-case env when they
  # need the kill-switch, so we scrub these inherited vars before each test. This
  # is the systemic counterpart to the per-test `unset` guards (see the
  # route-prompt-recursion test) and prevents worker-session ambient state from
  # producing spurious failures (2026-05-25 audit: spawn-registry, heredoc-size).
  run_one_shell_test() {
    if [ -n "$TIMEOUT_BIN" ]; then
      env -u PLAN_W_TEAM_DISABLE_PROMPT_ROUTE -u PLAN_W_TEAM_AUTO_APPROVE_PUSH \
          -u PLAN_W_TEAM_FORCE_SPAWN -u PLAN_W_TEAM_DISABLE_GOAL \
          "$TIMEOUT_BIN" "$SHELL_TEST_TIMEOUT" bash "$1" >/dev/null 2>&1
    else
      env -u PLAN_W_TEAM_DISABLE_PROMPT_ROUTE -u PLAN_W_TEAM_AUTO_APPROVE_PUSH \
          -u PLAN_W_TEAM_FORCE_SPAWN -u PLAN_W_TEAM_DISABLE_GOAL \
          bash "$1" >/dev/null 2>&1
    fi
  }

  echo ""
  echo "→ running shell integration tests under .claude/{scripts,hooks}/ + tests/version-uplift/"
  while IFS= read -r tf; do
    [ -z "$tf" ] && continue
    SHELL_TOTAL=$((SHELL_TOTAL + 1))
    rel="${tf#"$REPO_ROOT"/}"
    if run_one_shell_test "$tf"; then
      SHELL_PASSED=$((SHELL_PASSED + 1))
      echo "  ok   $rel"
    else
      SHELL_FAILED=$((SHELL_FAILED + 1))
      SHELL_FAILED_NAMES="${SHELL_FAILED_NAMES}${rel}"$'\n'
      echo "  FAIL $rel"
    fi
  done < <(
    {
      [ -d "$REPO_ROOT/.claude/scripts" ] && find "$REPO_ROOT/.claude/scripts" -name '*.test.sh' -type f 2>/dev/null
      [ -d "$REPO_ROOT/.claude/hooks" ]   && find "$REPO_ROOT/.claude/hooks"   -name '*.test.sh' -type f 2>/dev/null
      [ -d "$REPO_ROOT/tests/version-uplift" ] && find "$REPO_ROOT/tests/version-uplift" -name '*.test.sh' -type f 2>/dev/null
    } | sort
  )
  echo "→ shell integration tests: $SHELL_PASSED/$SHELL_TOTAL passed"
fi

# ── Archive ──────────────────────────────────────────────────────────────────
if [ "$ARCHIVE" = "1" ]; then
  RUN_FILE="$RUNS_DIR/$TIMESTAMP.json"

  # Parse TAP for counts. Format:
  #   1..N
  #   ok 1 - description
  #   not ok 2 - description
  TOTAL=$(grep -E '^1\.\.[0-9]+' "$TAP_LOG" | head -1 | sed -E 's/1\.\.//')
  PASSED=$(grep -cE '^ok [0-9]' "$TAP_LOG" || true)
  FAILED=$(grep -cE '^not ok [0-9]' "$TAP_LOG" || true)
  SKIPPED=$(grep -cE '^ok [0-9]+.*# skip' "$TAP_LOG" || true)

  # Collect failing test names for trend analysis. Empty on green runs — guard
  # against jq choking on empty input by short-circuiting to "[]".
  FAILED_RAW=$(grep -E '^not ok [0-9]' "$TAP_LOG" | sed -E 's/^not ok [0-9]+ - //' || true)
  if [ -z "$FAILED_RAW" ]; then
    FAILED_NAMES='[]'
  else
    FAILED_NAMES=$(printf '%s\n' "$FAILED_RAW" | jq -R . | jq -s . 2>/dev/null || echo '[]')
  fi

  GIT_SHA=$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  GIT_BRANCH=$(cd "$REPO_ROOT" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  # Shell-test failed names as a JSON array (empty → []).
  if [ -z "$SHELL_FAILED_NAMES" ]; then
    SHELL_FAILED_JSON='[]'
  else
    SHELL_FAILED_JSON=$(printf '%s' "$SHELL_FAILED_NAMES" | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo '[]')
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg sha "$GIT_SHA" \
      --arg branch "$GIT_BRANCH" \
      --argjson total "${TOTAL:-0}" \
      --argjson passed "${PASSED:-0}" \
      --argjson failed "${FAILED:-0}" \
      --argjson skipped "${SKIPPED:-0}" \
      --argjson exit_code "$BATS_EXIT" \
      --argjson failed_names "$FAILED_NAMES" \
      --argjson shell_total "${SHELL_TOTAL:-0}" \
      --argjson shell_passed "${SHELL_PASSED:-0}" \
      --argjson shell_failed "${SHELL_FAILED:-0}" \
      --argjson shell_failed_names "$SHELL_FAILED_JSON" \
      '{
        timestamp: $ts,
        git_sha: $sha,
        git_branch: $branch,
        total: $total,
        passed: $passed,
        failed: $failed,
        skipped: $skipped,
        exit_code: $exit_code,
        failed_tests: $failed_names,
        shell_total: $shell_total,
        shell_passed: $shell_passed,
        shell_failed: $shell_failed,
        shell_failed_tests: $shell_failed_names
      }' > "$RUN_FILE"

    cp "$RUN_FILE" "$RESULTS_DIR/latest.json"
    echo ""
    echo "→ archived: tests/skill/results/runs/$TIMESTAMP.json"
  else
    echo "⚠ jq not found — skipping JSON archival" >&2
  fi
fi

# Final summary line for human eyes. The suite is green only when BOTH the bats
# phase AND the shell-integration phase pass.
if [ "$BATS_EXIT" -eq 0 ] && [ "${SHELL_FAILED:-0}" -eq 0 ]; then
  echo "✓ all tests passed (bats + ${SHELL_PASSED:-0} shell integration tests)"
  exit 0
fi
[ "$BATS_EXIT" -ne 0 ] && echo "✗ bats phase failed (exit $BATS_EXIT)"
if [ "${SHELL_FAILED:-0}" -ne 0 ]; then
  echo "✗ shell integration phase failed ($SHELL_FAILED of $SHELL_TOTAL):"
  printf '%s' "$SHELL_FAILED_NAMES" | grep -v '^$' | sed 's/^/    - /'
fi
exit 1
