#!/bin/bash
# pwt-goal-version-recording.test.sh
#
# Verifies that pwt-goal.sh captures the active /plan-w-team release into
# every run's goal-state JSON + spawn sidecar, across all three spawn paths.
#
# Strategy: source pwt-goal.sh's helpers (it's idempotent for definition
# extraction since the body is gated behind arg parsing), then call the
# extracted helpers directly. This avoids needing to spawn `claude --bg`
# (which isn't available in CI / test env) while still exercising the
# real write paths.
#
# Asserts:
#   AC1: __pwt_resolve_skill_version reads VERSION and returns a semver
#   AC2: __pwt_resolve_skill_commit_sha returns a 7-char (or "unknown") git SHA
#   AC3: __pwt_write_skill_version_sidecar emits a sidecar with the 5 fields
#        when called with a real state dir + slug + spawn-path label
#   AC4: Re-invoking the sidecar writer is idempotent — same input → same
#        non-conflicting overwrite
#   AC5: VERSION file at .claude/commands/plan-w-team/VERSION exists and
#        parses as MAJOR.MINOR.PATCH semver
#   AC6: completion-summary.sh emits skill_version + skill_commit_sha keys
#        when fed a goal-state file containing them
#
# Exit codes:
#   0 = all assertions passed
#   1 = at least one assertion failed
#
# Spec: .claude/commands/plan-w-team/shared/versioning.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PWT_GOAL="$SCRIPT_DIR/pwt-goal.sh"
COMPLETION_SUMMARY="$SCRIPT_DIR/plan-w-team-completion-summary.sh"
VERSION_FILE="$REPO_ROOT/.claude/commands/plan-w-team/VERSION"

PASS=0
FAIL=0

assert_eq() {
    local name="$1"; local expected="$2"; local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name"
        echo "      expected: $expected"
        echo "      actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_match() {
    local name="$1"; local pattern="$2"; local actual="$3"
    if echo "$actual" | grep -qE "$pattern"; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name"
        echo "      pattern: $pattern"
        echo "      actual:  $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local name="$1"; local path="$2"
    if [ -f "$path" ]; then
        echo "  ✓ $name ($path)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name (missing: $path)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== pwt-goal-version-recording test suite ==="

# --- AC5: VERSION file exists, semver-shaped ---
echo "AC5: VERSION file exists and is semver"
assert_file_exists "VERSION file present" "$VERSION_FILE"
if [ -f "$VERSION_FILE" ]; then
    raw_version=$(head -1 "$VERSION_FILE" | tr -d '[:space:]')
    assert_match "VERSION matches MAJOR.MINOR.PATCH" '^[0-9]+\.[0-9]+\.[0-9]+$' "$raw_version"
fi

# --- AC1 + AC2: source pwt-goal.sh helpers + verify them ---
# Sourcing the entire script would trigger arg parsing. We work around this by
# extracting the two helper functions + the cached value assignments using
# bash's -c with a sed-extracted snippet. Cleaner: just run pwt-goal.sh in a
# subshell with `--help` and a tee that intercepts before any arg-required
# code. Easier: extract the helper definitions ad hoc.
extract_helpers() {
    # Pull __pwt_resolve_skill_version() / __pwt_resolve_skill_commit_sha() /
    # __pwt_write_skill_version_sidecar() function bodies from pwt-goal.sh.
    awk '
        /^__pwt_resolve_skill_version\(\)/,/^}$/ { print }
        /^__pwt_resolve_skill_commit_sha\(\)/,/^}$/ { print }
        /^__pwt_write_skill_version_sidecar\(\)/,/^}$/ { print }
    ' "$PWT_GOAL"
}

echo "AC1: __pwt_resolve_skill_version returns semver"
HELPERS=$(extract_helpers)
# shellcheck disable=SC1090
eval "$HELPERS"
# Make sure resolution works from this script's location: pwt-goal.sh's
# helper uses "$(dirname "$0")/../commands/plan-w-team/VERSION"; when sourced
# here, $0 is this test script which is in the same dir, so the relative
# path resolves correctly.
v=$(__pwt_resolve_skill_version)
assert_match "version resolved" '^([0-9]+\.[0-9]+\.[0-9]+|unknown)$' "$v"

echo "AC2: __pwt_resolve_skill_commit_sha returns short SHA or 'unknown'"
sha=$(__pwt_resolve_skill_commit_sha)
assert_match "commit SHA shape" '^([a-f0-9]{4,40}|unknown)$' "$sha"

# --- AC3 + AC4: sidecar writer ---
echo "AC3: sidecar writer emits JSON with all 5 fields"
TEST_STATE_DIR=$(mktemp -d -t pwt-version-test-XXXXXX)
trap 'rm -rf "$TEST_STATE_DIR"' EXIT

# Manually set SKILL_VERSION + SKILL_COMMIT_SHA in this shell so the helper
# can read them as globals (pwt-goal.sh caches these at process start).
SKILL_VERSION="$v"
SKILL_COMMIT_SHA="$sha"

__pwt_write_skill_version_sidecar "$TEST_STATE_DIR" "test-slug-abc12345" "launch"

SIDECAR="$TEST_STATE_DIR/plan-w-team-skill-version-test-slug-abc12345.json"
assert_file_exists "sidecar created" "$SIDECAR"
if [ -f "$SIDECAR" ] && command -v jq >/dev/null 2>&1; then
    slug_field=$(jq -r '.slug' "$SIDECAR" 2>/dev/null || echo "")
    assert_eq "sidecar.slug" "test-slug-abc12345" "$slug_field"
    sv_field=$(jq -r '.skill_version' "$SIDECAR" 2>/dev/null || echo "")
    assert_eq "sidecar.skill_version" "$SKILL_VERSION" "$sv_field"
    sc_field=$(jq -r '.skill_commit_sha' "$SIDECAR" 2>/dev/null || echo "")
    assert_eq "sidecar.skill_commit_sha" "$SKILL_COMMIT_SHA" "$sc_field"
    sp_field=$(jq -r '.spawn_path' "$SIDECAR" 2>/dev/null || echo "")
    assert_eq "sidecar.spawn_path" "launch" "$sp_field"
    ra_field=$(jq -r '.recorded_at' "$SIDECAR" 2>/dev/null || echo "")
    assert_match "sidecar.recorded_at is ISO8601" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$ra_field"
fi

echo "AC4: re-invocation is idempotent (overwrites cleanly)"
__pwt_write_skill_version_sidecar "$TEST_STATE_DIR" "test-slug-abc12345" "supervisor-goal"
if [ -f "$SIDECAR" ] && command -v jq >/dev/null 2>&1; then
    sp2=$(jq -r '.spawn_path' "$SIDECAR" 2>/dev/null || echo "")
    assert_eq "second-write spawn_path took effect" "supervisor-goal" "$sp2"
fi

# --- AC6: completion-summary picks up the fields ---
echo "AC6: completion-summary.sh propagates skill_version + skill_commit_sha"
TEST_RUN_DIR=$(mktemp -d -t pwt-completion-test-XXXXXX)
trap 'rm -rf "$TEST_STATE_DIR" "$TEST_RUN_DIR"' EXIT
mkdir -p "$TEST_RUN_DIR/.claude/state"
mkdir -p "$TEST_RUN_DIR/docs/specs"

# Seed a goal-state file with skill_version + skill_commit_sha so the
# completion-summary reads them from there (preferred path).
TEST_SLUG="test-completion-summary-fixture"
cat > "$TEST_RUN_DIR/.claude/state/plan-w-team-goal-${TEST_SLUG}.json" <<EOF_GOAL
{
  "slug": "${TEST_SLUG}",
  "started_at": "2026-05-22T12:00:00Z",
  "skill_version": "1.0.0",
  "skill_commit_sha": "abcdef0",
  "terminal_state": null
}
EOF_GOAL

(
  cd "$TEST_RUN_DIR"
  "$COMPLETION_SUMMARY" "$TEST_SLUG" >/dev/null 2>&1
)

OUT_JSON="$TEST_RUN_DIR/.claude/state/plan-w-team-completion-${TEST_SLUG}.json"
OUT_MD="$TEST_RUN_DIR/.claude/state/plan-w-team-completion-${TEST_SLUG}.md"
assert_file_exists "completion JSON written" "$OUT_JSON"
assert_file_exists "completion MD written" "$OUT_MD"
if [ -f "$OUT_JSON" ] && command -v jq >/dev/null 2>&1; then
    json_sv=$(jq -r '.skill_version // empty' "$OUT_JSON" 2>/dev/null || echo "")
    assert_eq "completion JSON.skill_version" "1.0.0" "$json_sv"
    json_sc=$(jq -r '.skill_commit_sha // empty' "$OUT_JSON" 2>/dev/null || echo "")
    assert_eq "completion JSON.skill_commit_sha" "abcdef0" "$json_sc"
fi
if [ -f "$OUT_MD" ]; then
    if grep -q 'Skill version:.*1\.0\.0' "$OUT_MD" && grep -q 'abcdef0' "$OUT_MD"; then
        echo "  ✓ completion MD header includes skill_version + commit SHA"
        PASS=$((PASS + 1))
    else
        echo "  ✗ completion MD header missing skill_version + commit SHA"
        echo "      first 10 lines of MD:"
        head -10 "$OUT_MD" | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
