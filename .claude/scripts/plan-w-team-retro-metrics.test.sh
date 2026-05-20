#!/usr/bin/env bash
# plan-w-team-retro-metrics.test.sh
#
# Tests for plan-w-team-retro-metrics.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
METRICS_SCRIPT="$SCRIPT_DIR/plan-w-team-retro-metrics.sh"

PASS=0
FAIL=0

assert() {
    local desc="$1" cond_msg="$2"
    if [ "$cond_msg" = "true" ]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"
        FAIL=$((FAIL + 1))
    fi
}

# Test 1: Exits 2 with no SLUG
echo "Test 1: no SLUG → exit 2"
if "$METRICS_SCRIPT" >/dev/null 2>&1; then
    assert "exits 2 with no args" "false"
else
    rc=$?
    if [ "$rc" -eq 2 ]; then assert "exits 2 with no args" "true"
    else assert "exits 2 with no args (got $rc)" "false"; fi
fi

# Test 2: Valid SLUG returns valid JSON
echo "Test 2: valid SLUG → valid JSON"
OUT=$("$METRICS_SCRIPT" test-slug-for-retro-metrics 2>/dev/null || echo "{}")
if echo "$OUT" | jq -e . >/dev/null 2>&1; then
    assert "stdout is valid JSON" "true"
else
    assert "stdout is valid JSON" "false"
    echo "    raw output: $OUT" >&2
fi

# Test 3: JSON has all required fields
echo "Test 3: JSON has required fields"
for field in slug base_ref commit_count lines_added lines_removed files_changed \
             commit_type_breakdown fix_ratio ai_assisted_count test_pass_count \
             fleet_stats generated_at; do
    if echo "$OUT" | jq -e "has(\"$field\")" >/dev/null 2>&1; then
        assert "field '$field' present" "true"
    else
        assert "field '$field' present" "false"
    fi
done

# Test 4: commit_count is a non-negative integer
echo "Test 4: commit_count is integer"
CC=$(echo "$OUT" | jq -r '.commit_count')
if [[ "$CC" =~ ^[0-9]+$ ]]; then
    assert "commit_count is integer ($CC)" "true"
else
    assert "commit_count is integer (got '$CC')" "false"
fi

# Test 5: fix_ratio is a float between 0 and 1
echo "Test 5: fix_ratio in [0,1]"
FR=$(echo "$OUT" | jq -r '.fix_ratio')
if awk -v v="$FR" 'BEGIN { exit !(v >= 0 && v <= 1) }'; then
    assert "fix_ratio in [0,1] (got $FR)" "true"
else
    assert "fix_ratio in [0,1] (got $FR)" "false"
fi

# Test 6: commit_type_breakdown has all keys
echo "Test 6: commit_type_breakdown has all keys"
for key in feat fix refactor test docs chore other; do
    if echo "$OUT" | jq -e ".commit_type_breakdown | has(\"$key\")" >/dev/null 2>&1; then
        assert "commit_type_breakdown.$key present" "true"
    else
        assert "commit_type_breakdown.$key present" "false"
    fi
done

# Test 7: slug echoes back the input
echo "Test 7: slug echoes input"
S=$(echo "$OUT" | jq -r '.slug')
if [ "$S" = "test-slug-for-retro-metrics" ]; then
    assert "slug echoes input ($S)" "true"
else
    assert "slug echoes input (got '$S')" "false"
fi

# Test 8: fleet_stats is null when no fleet log for this SLUG
echo "Test 8: fleet_stats null when no log"
FS=$(echo "$OUT" | jq -r '.fleet_stats')
# Could be null (no fleet log) or an object (empty fleet log returned by fleet-query summary)
# Both are acceptable as long as the field exists.
if [ "$FS" = "null" ] || echo "$OUT" | jq -e '.fleet_stats | type == "object"' >/dev/null 2>&1; then
    assert "fleet_stats is null or object" "true"
else
    assert "fleet_stats is null or object (got '$FS')" "false"
fi

# Test 9: generated_at is ISO-8601-ish
echo "Test 9: generated_at is timestamp"
GA=$(echo "$OUT" | jq -r '.generated_at')
if [[ "$GA" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    assert "generated_at is ISO-8601 ($GA)" "true"
else
    assert "generated_at is ISO-8601 (got '$GA')" "false"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
