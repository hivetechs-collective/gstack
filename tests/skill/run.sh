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
      '{
        timestamp: $ts,
        git_sha: $sha,
        git_branch: $branch,
        total: $total,
        passed: $passed,
        failed: $failed,
        skipped: $skipped,
        exit_code: $exit_code,
        failed_tests: $failed_names
      }' > "$RUN_FILE"

    cp "$RUN_FILE" "$RESULTS_DIR/latest.json"
    echo ""
    echo "→ archived: tests/skill/results/runs/$TIMESTAMP.json"
  else
    echo "⚠ jq not found — skipping JSON archival" >&2
  fi
fi

# Final summary line for human eyes.
if [ "$BATS_EXIT" -eq 0 ]; then
  echo "✓ all tests passed"
else
  echo "✗ test run failed (bats exit $BATS_EXIT)"
fi
exit "$BATS_EXIT"
