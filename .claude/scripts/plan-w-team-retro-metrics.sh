#!/usr/bin/env bash
# plan-w-team-retro-metrics.sh
#
# Computes objective retro metrics for a /plan-w-team run and emits JSON.
# Replaces the ad-hoc shell snippets in 07-retro.md §8a that the retro lead
# previously had to invoke (and often recalled from memory instead). This
# script is the single source of truth for retro numbers.
#
# Usage:
#   .claude/scripts/plan-w-team-retro-metrics.sh <SLUG> [--base <git-ref>]
#
# Defaults:
#   --base origin/main  (override with --base origin/develop, etc.)
#
# Output: JSON to stdout with fields:
#   slug                 (string)
#   base_ref             (string)
#   commit_count         (integer)
#   lines_added          (integer)
#   lines_removed        (integer)
#   files_changed        (integer)
#   commit_type_breakdown (object: feat/fix/refactor/test/docs/chore/other → count)
#   fix_ratio            (float, 0.0-1.0 — fixes / total commits)
#   ai_assisted_count    (integer — commits with Co-Authored-By trailer)
#   test_pass_count      (integer | null — most recent npm test output, best-effort)
#   fleet_stats          (object | null — from fleet-query summary)
#   generated_at         (ISO-8601 timestamp)

set -euo pipefail

SLUG="${1:-}"
BASE_REF="origin/main"

shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE_REF="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^# Output:/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "[retro-metrics] unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$SLUG" ]; then
    echo "Usage: $0 <SLUG> [--base <git-ref>]" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[retro-metrics] jq required" >&2
    exit 2
fi

# Resolve repo root (so we can be invoked from a worktree)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "[retro-metrics] not inside a git repo" >&2
    exit 2
}

# Resolve base ref — fall back to local main if origin/main unavailable
if ! git rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1; then
    if git rev-parse --verify --quiet "main" >/dev/null 2>&1; then
        BASE_REF="main"
    elif git rev-parse --verify --quiet "master" >/dev/null 2>&1; then
        BASE_REF="master"
    else
        echo "[retro-metrics] cannot resolve base ref (tried $BASE_REF, main, master)" >&2
        exit 2
    fi
fi

# Range: BASE_REF..HEAD
RANGE="${BASE_REF}..HEAD"

# Commit count
COMMIT_COUNT=$(git rev-list --count "$RANGE" 2>/dev/null || echo 0)

# Lines added/removed/files changed (shortstat)
SHORTSTAT=$(git diff --shortstat "$RANGE" 2>/dev/null || echo "")
LINES_ADDED=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
LINES_REMOVED=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)
FILES_CHANGED=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo 0)
LINES_ADDED=${LINES_ADDED:-0}
LINES_REMOVED=${LINES_REMOVED:-0}
FILES_CHANGED=${FILES_CHANGED:-0}

# Commit type breakdown (subject-line prefix).
# `grep -c` exits 1 when no matches but still prints "0" to stdout. We rely on
# the printed count and suppress set -e via `|| true` rather than adding `|| echo 0`
# (which would concatenate two "0\n" outputs and break --argjson downstream).
COMMIT_SUBJECTS=$(git log --format="%s" "$RANGE" 2>/dev/null || true)
count_prefix() {
    local prefix="$1" count
    if [ -z "$COMMIT_SUBJECTS" ]; then
        echo 0; return
    fi
    count=$(printf '%s\n' "$COMMIT_SUBJECTS" | grep -cE "^${prefix}(\(.+\))?: " || true)
    echo "${count:-0}"
}
FEAT_COUNT=$(count_prefix "feat")
FIX_COUNT=$(count_prefix "fix")
REFACTOR_COUNT=$(count_prefix "refactor")
TEST_COUNT=$(count_prefix "test")
DOCS_COUNT=$(count_prefix "docs")
CHORE_COUNT=$(count_prefix "chore")
# Other = anything not in the above set
if [ -z "$COMMIT_SUBJECTS" ]; then
    OTHER_COUNT=0
else
    OTHER_COUNT=$(printf '%s\n' "$COMMIT_SUBJECTS" \
        | grep -cvE '^(feat|fix|refactor|test|docs|chore)(\(.+\))?: ' || true)
    OTHER_COUNT=${OTHER_COUNT:-0}
fi

# Fix ratio (float)
if [ "$COMMIT_COUNT" -gt 0 ]; then
    FIX_RATIO=$(awk "BEGIN { printf \"%.4f\", $FIX_COUNT / $COMMIT_COUNT }")
else
    FIX_RATIO="0.0000"
fi

# AI-assisted count (Co-Authored-By trailer)
AI_ASSISTED_RAW=$(git log --format="%B" "$RANGE" 2>/dev/null || true)
if [ -z "$AI_ASSISTED_RAW" ]; then
    AI_ASSISTED_COUNT=0
else
    AI_ASSISTED_COUNT=$(printf '%s\n' "$AI_ASSISTED_RAW" | grep -cE '^Co-Authored-By:' || true)
    AI_ASSISTED_COUNT=${AI_ASSISTED_COUNT:-0}
fi

# Test pass count — best-effort lookup in common locations
TEST_PASS_COUNT="null"
TEST_LOG_CANDIDATES=(
    ".claude/state/plan-w-team-test-output-${SLUG}.log"
    "test-output.log"
    "tests.log"
)
for log in "${TEST_LOG_CANDIDATES[@]}"; do
    if [ -f "$REPO_ROOT/$log" ]; then
        # Try common patterns: "X passing", "X passed", "Tests: X passed"
        EXTRACTED=$(grep -oE '([0-9]+) (passing|passed)' "$REPO_ROOT/$log" 2>/dev/null \
            | tail -1 | grep -oE '^[0-9]+' || echo "")
        if [ -n "$EXTRACTED" ]; then
            TEST_PASS_COUNT="$EXTRACTED"
            break
        fi
    fi
done

# Fleet stats — invoke fleet-query if available
FLEET_STATS="null"
FLEET_QUERY="$REPO_ROOT/.claude/scripts/plan-w-team-fleet-query.sh"
if [ -x "$FLEET_QUERY" ]; then
    FLEET_OUT=$("$FLEET_QUERY" summary "$SLUG" 2>/dev/null || echo "")
    if [ -n "$FLEET_OUT" ] && echo "$FLEET_OUT" | jq -e . >/dev/null 2>&1; then
        FLEET_STATS="$FLEET_OUT"
    fi
fi

# Generated timestamp
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Emit JSON via jq -n for valid output (handles edge cases, escapes)
jq -n \
    --arg slug "$SLUG" \
    --arg base_ref "$BASE_REF" \
    --argjson commit_count "$COMMIT_COUNT" \
    --argjson lines_added "$LINES_ADDED" \
    --argjson lines_removed "$LINES_REMOVED" \
    --argjson files_changed "$FILES_CHANGED" \
    --argjson feat "$FEAT_COUNT" \
    --argjson fix "$FIX_COUNT" \
    --argjson refactor "$REFACTOR_COUNT" \
    --argjson test "$TEST_COUNT" \
    --argjson docs "$DOCS_COUNT" \
    --argjson chore "$CHORE_COUNT" \
    --argjson other "$OTHER_COUNT" \
    --arg fix_ratio "$FIX_RATIO" \
    --argjson ai_assisted_count "$AI_ASSISTED_COUNT" \
    --arg test_pass_count "$TEST_PASS_COUNT" \
    --arg fleet_stats_raw "$FLEET_STATS" \
    --arg ts "$TS" \
    '{
        slug: $slug,
        base_ref: $base_ref,
        commit_count: $commit_count,
        lines_added: $lines_added,
        lines_removed: $lines_removed,
        files_changed: $files_changed,
        commit_type_breakdown: {
            feat: $feat, fix: $fix, refactor: $refactor,
            test: $test, docs: $docs, chore: $chore, other: $other
        },
        fix_ratio: ($fix_ratio | tonumber),
        ai_assisted_count: $ai_assisted_count,
        test_pass_count: (if $test_pass_count == "null" then null else ($test_pass_count | tonumber) end),
        fleet_stats: (if $fleet_stats_raw == "null" then null else ($fleet_stats_raw | fromjson) end),
        generated_at: $ts
    }'
