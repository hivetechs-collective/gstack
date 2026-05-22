#!/usr/bin/env bash
# tests/skill/run-scenarios.sh
#
# Focused runner for the E2E scenario subset under tests/skill/scenarios/.
# DEV-ITERATION ONLY — pre-commit and `make test-skill` invoke
# `tests/skill/run.sh` which discovers BOTH cases/ and scenarios/ as one
# canonical suite. This sub-runner exists for fast iteration on the
# scenario suite alone.
#
# Anti-fragmentation note: this script does NOT define an alternate test
# discovery rule, an alternate archival format, or a "fast subset" filter.
# It is a thin wrapper that delegates to bats with the scenarios/ glob,
# and emits a summary line matching run.sh's format.
#
# Usage:
#   tests/skill/run-scenarios.sh                    # run all scenarios
#   tests/skill/run-scenarios.sh imperative-nl-one-worker.bats   # single file
#   tests/skill/run-scenarios.sh --no-summary       # suppress summary line
#
# Exit codes:
#   0 — all scenarios passed
#   1 — at least one scenario failed
#   2 — environment failure (no scenarios/ dir, bats missing, etc.)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS_DIR="$REPO_ROOT/tests/skill"
BATS_BIN="$HARNESS_DIR/.bats/bin/bats"
SCENARIOS_DIR="$HARNESS_DIR/scenarios"

PRINT_SUMMARY=1
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-summary) PRINT_SUMMARY=0; shift ;;
    -h|--help)    grep '^#' "$0" | head -25; exit 0 ;;
    *)            TARGET="$1"; shift ;;
  esac
done

# ─── Environment checks ──────────────────────────────────────────────────────
if [ ! -d "$SCENARIOS_DIR" ]; then
  echo "✗ scenarios directory missing: $SCENARIOS_DIR" >&2
  exit 2
fi

if [ ! -x "$BATS_BIN" ]; then
  echo "✗ bats not bootstrapped — run: tests/skill/run.sh --setup" >&2
  exit 2
fi

# ─── Discover test files ─────────────────────────────────────────────────────
TEST_FILES=()
if [ -n "$TARGET" ]; then
  T_PATH="$SCENARIOS_DIR/$TARGET"
  [ -f "$T_PATH" ] || T_PATH="$TARGET"
  if [ ! -f "$T_PATH" ]; then
    echo "✗ no such scenario file: $TARGET" >&2
    exit 2
  fi
  TEST_FILES=("$T_PATH")
else
  while IFS= read -r f; do
    TEST_FILES+=("$f")
  done < <(find "$SCENARIOS_DIR" -name '*.bats' -type f | sort)
fi

if [ "${#TEST_FILES[@]}" -eq 0 ]; then
  echo "✗ no .bats files found under $SCENARIOS_DIR" >&2
  exit 2
fi

# ─── Run scenarios via bats with TAP output ──────────────────────────────────
TAP_LOG=$(mktemp -t pwt-run-scenarios-XXXXXX)
trap 'rm -f "$TAP_LOG"' EXIT

echo "→ running ${#TEST_FILES[@]} scenario file(s) under tests/skill/scenarios/"
set +e
"$BATS_BIN" --tap "${TEST_FILES[@]}" | tee "$TAP_LOG"
BATS_EXIT=${PIPESTATUS[0]}
set -e

# ─── Summary line in run.sh's shape ──────────────────────────────────────────
if [ "$PRINT_SUMMARY" = "1" ]; then
  TOTAL=$(grep -E '^1\.\.[0-9]+' "$TAP_LOG" | head -1 | sed -E 's/1\.\.//')
  PASSED=$(grep -cE '^ok [0-9]' "$TAP_LOG" || true)
  FAILED=$(grep -cE '^not ok [0-9]' "$TAP_LOG" || true)
  TOTAL="${TOTAL:-0}"
  PASSED="${PASSED:-0}"
  FAILED="${FAILED:-0}"
  echo ""
  echo "→ scenarios summary: PASS: $PASSED / FAIL: $FAILED / TOTAL: $TOTAL"
fi

if [ "$BATS_EXIT" -eq 0 ]; then
  echo "✓ all scenarios passed"
else
  echo "✗ scenario run failed (bats exit $BATS_EXIT)"
fi
exit "$BATS_EXIT"
