#!/bin/bash
# Tests for plan-w-team-child-cleanup.sh
#
# The cleanup script is invoked by 07-retro.md §8j-sexies before retro-complete.
# These tests run the helper against a mocked manifest with a shimmed `claude`
# binary and assert the right session_ids get stopped.
#
# Usage: bash .claude/scripts/plan-w-team-child-cleanup.test.sh
# Exits 0 on all pass, 1 on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/plan-w-team-child-cleanup.sh"

TEST_SLUG="child-cleanup-test-$$"
WORK_DIR=$(mktemp -d -t pwt-cleanup-test.XXXXXX)
MANIFEST="$WORK_DIR/manifest.jsonl"
SHIM_DIR="$WORK_DIR/shim"
SHIM_LOG="$WORK_DIR/claude-calls.log"
mkdir -p "$SHIM_DIR"

PASS=0
FAIL=0

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name"
        echo "    expected: [$expected]"
        echo "    actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name"
        echo "    expected substring: $needle"
        echo "    in haystack: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

# Build a shim that records every `claude stop` call to SHIM_LOG. The shim
# accepts a SHIM_FAIL_SID env var listing comma-separated sids that should
# exit 1 (simulating "already finished"); all others exit 0.
build_shim() {
    cat > "$SHIM_DIR/claude" <<'EOF'
#!/bin/bash
echo "$@" >> "$SHIM_LOG"
if [ "$1" = "stop" ]; then
    IFS=',' read -ra FAILS <<< "${SHIM_FAIL_SID:-}"
    for f in "${FAILS[@]}"; do
        if [ "$2" = "$f" ]; then
            exit 1
        fi
    done
    exit 0
fi
exit 0
EOF
    chmod +x "$SHIM_DIR/claude"
}

build_shim

# Seed a manifest with three rows
seed_manifest() {
    rm -f "$MANIFEST"
    printf '{"ts":"2026-05-20T00:00:00Z","session_id":"alpha111","parent_session_id":"","purpose":"pwt-goal-launch","slug":"%s","spawned_by":"pwt-goal.sh"}\n' "$TEST_SLUG" >> "$MANIFEST"
    printf '{"ts":"2026-05-20T00:00:01Z","session_id":"beta2222","parent_session_id":"","purpose":"supervisor-spawn","slug":"%s","spawned_by":"pwt-goal.sh"}\n' "$TEST_SLUG" >> "$MANIFEST"
    printf '{"ts":"2026-05-20T00:00:02Z","session_id":"gamma333","parent_session_id":"","purpose":"stage-spawn","slug":"%s","spawned_by":"pwt-goal.sh"}\n' "$TEST_SLUG" >> "$MANIFEST"
}

# ───────────────────────────────────────────────────────────────────────────
# AC-CC1: kill switch short-circuits before reading the manifest
# ───────────────────────────────────────────────────────────────────────────
echo "U1: PLAN_W_TEAM_DISABLE_CHILD_CLEANUP=1 short-circuits"
seed_manifest
: > "$SHIM_LOG"
OUT=$(SHIM_LOG="$SHIM_LOG" PATH="$SHIM_DIR:$PATH" \
    PLAN_W_TEAM_DISABLE_CHILD_CLEANUP=1 \
    "$HELPER" "$TEST_SLUG" "$MANIFEST")
assert_contains "kill switch JSON" '"skipped":true' "$OUT"
assert_contains "kill switch reason" 'PLAN_W_TEAM_DISABLE_CHILD_CLEANUP=1' "$OUT"
ATTEMPT_COUNT=$(grep '^stop ' "$SHIM_LOG" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no claude stop calls when kill switch active" "0" "$ATTEMPT_COUNT"

# ───────────────────────────────────────────────────────────────────────────
# AC-CC2: missing manifest emits skipped JSON, no stop calls
# ───────────────────────────────────────────────────────────────────────────
echo "U2: missing manifest path"
rm -f "$MANIFEST"
: > "$SHIM_LOG"
OUT=$(SHIM_LOG="$SHIM_LOG" PATH="$SHIM_DIR:$PATH" \
    "$HELPER" "$TEST_SLUG" "$MANIFEST")
assert_contains "missing manifest JSON" '"skipped":true' "$OUT"
assert_contains "missing manifest reason" 'no registry' "$OUT"
ATTEMPT_COUNT=$(grep '^stop ' "$SHIM_LOG" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no claude stop calls when manifest missing" "0" "$ATTEMPT_COUNT"

# ───────────────────────────────────────────────────────────────────────────
# AC-CC3: cleanup iterates manifest and calls claude stop for every session
# ───────────────────────────────────────────────────────────────────────────
echo "U3: every session_id receives a claude stop call"
seed_manifest
: > "$SHIM_LOG"
OUT=$(SHIM_LOG="$SHIM_LOG" PATH="$SHIM_DIR:$PATH" \
    "$HELPER" "$TEST_SLUG" "$MANIFEST")

ATTEMPT_COUNT=$(grep '^stop ' "$SHIM_LOG" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "claude stop called once per registered session" "3" "$ATTEMPT_COUNT"
assert_contains "alpha111 was stopped" "stop alpha111" "$(cat "$SHIM_LOG")"
assert_contains "beta2222 was stopped" "stop beta2222" "$(cat "$SHIM_LOG")"
assert_contains "gamma333 was stopped" "stop gamma333" "$(cat "$SHIM_LOG")"
assert_contains "registered=3" '"registered":3' "$OUT"
assert_contains "stopped=3" '"stopped":3' "$OUT"
assert_contains "noop=0" '"noop":0' "$OUT"

# ───────────────────────────────────────────────────────────────────────────
# AC-CC4: stop failures recorded as noop, do not abort the loop
# ───────────────────────────────────────────────────────────────────────────
echo "U4: tolerates claude stop failures (records as noop)"
seed_manifest
: > "$SHIM_LOG"
OUT=$(SHIM_LOG="$SHIM_LOG" PATH="$SHIM_DIR:$PATH" \
    SHIM_FAIL_SID="beta2222" \
    "$HELPER" "$TEST_SLUG" "$MANIFEST")

assert_contains "registered counted across success+fail" '"registered":3' "$OUT"
assert_contains "stopped counts successes only" '"stopped":2' "$OUT"
assert_contains "noop counts failures" '"noop":1' "$OUT"
# Verify the loop continued past the failure and called stop on gamma333 too
assert_contains "gamma333 still attempted after beta2222 failure" "stop gamma333" "$(cat "$SHIM_LOG")"

# ───────────────────────────────────────────────────────────────────────────
# AC-CC5: malformed manifest rows are skipped, loop continues
# ───────────────────────────────────────────────────────────────────────────
echo "U5: malformed rows are skipped"
rm -f "$MANIFEST"
printf '{"session_id":"good1","purpose":"pwt-goal-launch"}\n' >> "$MANIFEST"
printf 'this is not json\n' >> "$MANIFEST"
printf '{"missing":"session_id_field"}\n' >> "$MANIFEST"
printf '\n' >> "$MANIFEST"
printf '{"session_id":"good2","purpose":"stage-spawn"}\n' >> "$MANIFEST"
: > "$SHIM_LOG"
OUT=$(SHIM_LOG="$SHIM_LOG" PATH="$SHIM_DIR:$PATH" \
    "$HELPER" "$TEST_SLUG" "$MANIFEST")

ATTEMPT_COUNT=$(grep '^stop ' "$SHIM_LOG" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "only valid rows trigger claude stop" "2" "$ATTEMPT_COUNT"
assert_contains "good1 was stopped" "stop good1" "$(cat "$SHIM_LOG")"
assert_contains "good2 was stopped" "stop good2" "$(cat "$SHIM_LOG")"
assert_contains "registered=2 (malformed skipped)" '"registered":2' "$OUT"

# ───────────────────────────────────────────────────────────────────────────
# AC-CC6: missing slug fails open with skipped JSON
# ───────────────────────────────────────────────────────────────────────────
echo "U6: missing slug fails open"
OUT=$("$HELPER" "" "")
assert_contains "missing slug JSON" '"skipped":true' "$OUT"
assert_contains "missing slug reason" 'missing slug' "$OUT"

# ───────────────────────────────────────────────────────────────────────────
# AC-CC7: attempts JSON contains every session_id we tried
# ───────────────────────────────────────────────────────────────────────────
echo "U7: attempts JSON carries every session attempted"
seed_manifest
: > "$SHIM_LOG"
OUT=$(SHIM_LOG="$SHIM_LOG" PATH="$SHIM_DIR:$PATH" \
    "$HELPER" "$TEST_SLUG" "$MANIFEST")

ATTEMPT_SIDS=$(printf '%s' "$OUT" | jq -r '.attempts[].session_id' 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')
assert_eq "attempts array session_ids" "alpha111,beta2222,gamma333" "$ATTEMPT_SIDS"

# Summary
echo ""
echo "════════════════════════════════════════"
echo "  Pass: $PASS  Fail: $FAIL"
echo "════════════════════════════════════════"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
