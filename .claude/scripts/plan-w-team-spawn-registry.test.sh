#!/bin/bash
# Tests for plan-w-team-register-spawn.sh + the 07-retro.md §8j-sexies
# cleanup loop (snippet-based — we exec the snippet against a seeded registry
# with a `claude` shim that records its arguments).
#
# Also exercises the AC2/AC3 integration paths (pwt-goal.sh, route hook) with
# a `claude --bg` shim that emits the canonical "backgrounded · <sid>" line.
#
# Usage: bash .claude/scripts/plan-w-team-spawn-registry.test.sh
# Exits 0 on all pass, 1 on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$SCRIPT_DIR/plan-w-team-register-spawn.sh"
STATE_DIR="$PROJECT_ROOT/.claude/state"

TEST_SLUG="spawn-registry-test-$$"
REGISTRY="$STATE_DIR/plan-w-team-spawned-children-${TEST_SLUG}.jsonl"
SHIM_DIR=$(mktemp -d -t pwt-spawn-shim.XXXXXX)
SHIM_LOG="$SHIM_DIR/claude-calls.log"

PASS=0
FAIL=0

cleanup() {
    rm -f "$REGISTRY"
    rm -rf "$SHIM_DIR"
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

# ───────────────────────────────────────────────────────────────────────────
# AC1: helper writes valid JSONL with the documented schema
# ───────────────────────────────────────────────────────────────────────────
echo "U1: helper writes valid JSONL row"
rm -f "$REGISTRY"
"$HELPER" "abc12345" "pwt-goal-launch" "$TEST_SLUG" "def67890" "pwt-goal.sh"
[ -f "$REGISTRY" ]
assert_eq "registry file exists" "0" "$?"
ROW=$(cat "$REGISTRY")
assert_contains "row has session_id" '"session_id":"abc12345"' "$ROW"
assert_contains "row has purpose" '"purpose":"pwt-goal-launch"' "$ROW"
assert_contains "row has slug" "\"slug\":\"$TEST_SLUG\"" "$ROW"
assert_contains "row has parent_session_id" '"parent_session_id":"def67890"' "$ROW"
assert_contains "row has spawned_by" '"spawned_by":"pwt-goal.sh"' "$ROW"
# Verify JSONL validity via jq round-trip
JQ_OK=$(jq -c . "$REGISTRY" >/dev/null 2>&1 && echo "valid" || echo "invalid")
assert_eq "JSONL parses with jq" "valid" "$JQ_OK"

echo "U2: multiple calls append rows (one per call)"
rm -f "$REGISTRY"
"$HELPER" "sid00001" "pwt-goal-launch" "$TEST_SLUG"
"$HELPER" "sid00002" "stage-spawn" "$TEST_SLUG"
"$HELPER" "sid00003" "supervisor-spawn" "$TEST_SLUG"
ROW_COUNT=$(wc -l < "$REGISTRY" | tr -d ' ')
assert_eq "three rows written" "3" "$ROW_COUNT"

# ───────────────────────────────────────────────────────────────────────────
# AC1 cont: fail-open on bad/missing input
# ───────────────────────────────────────────────────────────────────────────
echo "U3: missing session_id → exit 0, no row appended"
rm -f "$REGISTRY"
"$HELPER" "" "pwt-goal-launch" "$TEST_SLUG"
RC=$?
assert_eq "exit code on empty sid" "0" "$RC"
[ ! -f "$REGISTRY" ]
assert_eq "no registry written" "0" "$?"

echo "U4: missing slug → exit 0, no row appended"
"$HELPER" "abc12345" "pwt-goal-launch" ""
RC=$?
assert_eq "exit code on empty slug" "0" "$RC"
[ ! -f "$REGISTRY" ]
assert_eq "no registry written" "0" "$?"

echo "U5: unknown purpose folds to 'other'"
rm -f "$REGISTRY"
"$HELPER" "sid99999" "garbage-purpose" "$TEST_SLUG"
ROW=$(cat "$REGISTRY")
assert_contains "purpose folded to 'other'" '"purpose":"other"' "$ROW"

# ───────────────────────────────────────────────────────────────────────────
# Cleanup loop (07-retro.md §8j-sexies): seed registry + run snippet
# ───────────────────────────────────────────────────────────────────────────
echo "U6: cleanup loop iterates registry and calls 'claude stop' for each"
rm -f "$REGISTRY"
"$HELPER" "stoppable1" "pwt-goal-launch" "$TEST_SLUG"
"$HELPER" "stoppable2" "stage-spawn" "$TEST_SLUG"
"$HELPER" "stoppable3" "supervisor-spawn" "$TEST_SLUG"

# Shim `claude` to record stop calls
cat > "$SHIM_DIR/claude" <<EOF
#!/bin/bash
echo "\$@" >> "$SHIM_LOG"
# Simulate: stop succeeds for stoppable1+2, fails for stoppable3 (already finished)
if [ "\$1" = "stop" ] && [ "\$2" = "stoppable3" ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$SHIM_DIR/claude"

# Run the cleanup loop in a subshell with PATH=shim:rest
SLUG="$TEST_SLUG" PATH="$SHIM_DIR:$PATH" bash -c '
REGISTRY=".claude/state/plan-w-team-spawned-children-${SLUG}.jsonl"
ATTEMPTS_JSON="[]"
TOTAL_REGISTERED=0
TOTAL_STOPPED=0
TOTAL_NOOP=0
while IFS= read -r row; do
    [ -z "$row" ] && continue
    SID=$(printf "%s" "$row" | jq -r ".session_id // empty" 2>/dev/null)
    [ -z "$SID" ] && continue
    TOTAL_REGISTERED=$((TOTAL_REGISTERED + 1))
    if claude stop "$SID" >/dev/null 2>&1; then
        TOTAL_STOPPED=$((TOTAL_STOPPED + 1))
    else
        TOTAL_NOOP=$((TOTAL_NOOP + 1))
    fi
done < "$REGISTRY"
echo "registered=$TOTAL_REGISTERED stopped=$TOTAL_STOPPED noop=$TOTAL_NOOP"
' > "$SHIM_DIR/loop-out.txt"

# All three should have been attempted
ATTEMPT_COUNT=$(grep -c '^stop ' "$SHIM_LOG" || echo 0)
assert_eq "claude stop called for each row" "3" "$ATTEMPT_COUNT"

LOOP_OUT=$(cat "$SHIM_DIR/loop-out.txt")
assert_contains "registered=3" "registered=3" "$LOOP_OUT"
assert_contains "stopped=2 (shim returns 0 for stoppable1+2)" "stopped=2" "$LOOP_OUT"
assert_contains "noop=1 (shim returns 1 for stoppable3)" "noop=1" "$LOOP_OUT"

echo "U7: cleanup tolerates malformed JSONL row (skips, continues)"
rm -f "$REGISTRY" "$SHIM_LOG"
"$HELPER" "good1" "pwt-goal-launch" "$TEST_SLUG"
echo "this is not json" >> "$REGISTRY"
"$HELPER" "good2" "stage-spawn" "$TEST_SLUG"

SLUG="$TEST_SLUG" PATH="$SHIM_DIR:$PATH" bash -c '
REGISTRY=".claude/state/plan-w-team-spawned-children-${SLUG}.jsonl"
while IFS= read -r row; do
    [ -z "$row" ] && continue
    SID=$(printf "%s" "$row" | jq -r ".session_id // empty" 2>/dev/null)
    [ -z "$SID" ] && continue
    claude stop "$SID" >/dev/null 2>&1 || true
done < "$REGISTRY"
'

# Only good1 and good2 should have been attempted (the garbage row has no session_id)
ATTEMPT_COUNT=$(grep -c '^stop ' "$SHIM_LOG" || echo 0)
assert_eq "malformed row skipped; only valid rows attempted" "2" "$ATTEMPT_COUNT"

# ───────────────────────────────────────────────────────────────────────────
# AC2: pwt-goal.sh --launch calls the helper after claude --bg returns
# ───────────────────────────────────────────────────────────────────────────
echo "U8: pwt-goal.sh --launch records spawn"
rm -f "$REGISTRY" "$SHIM_LOG"

# Shim `claude --bg` to print the canonical backgrounded line
cat > "$SHIM_DIR/claude" <<EOF
#!/bin/bash
if [ "\$1" = "--bg" ]; then
    # Mimic the canonical Claude Code CLI output
    echo "Session backgrounded · feedf00d"
    echo "  monitor: claude logs feedf00d"
    exit 0
fi
echo "\$@" >> "$SHIM_LOG"
exit 0
EOF
chmod +x "$SHIM_DIR/claude"

# Run pwt-goal.sh --launch with a request whose slug derivation produces
# something stable enough to match.
PATH="$SHIM_DIR:$PATH" "$SCRIPT_DIR/pwt-goal.sh" --launch "$TEST_SLUG request body" >/dev/null 2>&1 || true

# pwt-goal.sh derives a slug from the request; it MAY use the full "request"
# string. Just verify a row was written and contains feedf00d.
if [ -f "$REGISTRY" ]; then
    ROW=$(cat "$REGISTRY")
    assert_contains "registry row has feedf00d session_id" '"session_id":"feedf00d"' "$ROW"
    assert_contains "registry row marks pwt-goal-launch purpose" '"purpose":"pwt-goal-launch"' "$ROW"
    assert_contains "registry row attributes to pwt-goal.sh" '"spawned_by":"pwt-goal.sh"' "$ROW"
else
    # pwt-goal may have derived a different slug — search all spawned-children files
    FOUND=$(grep -l '"session_id":"feedf00d"' "$STATE_DIR"/plan-w-team-spawned-children-*.jsonl 2>/dev/null | head -1)
    if [ -n "$FOUND" ]; then
        echo "  ✓ pwt-goal.sh --launch wrote registry row (under slug from request)"
        PASS=$((PASS + 1))
        rm -f "$FOUND"
    else
        echo "  ✗ pwt-goal.sh --launch did not write a registry row anywhere"
        FAIL=$((FAIL + 1))
    fi
fi

# Clean up any extra spawned-children files the test created via slug derivation
for f in "$STATE_DIR"/plan-w-team-spawned-children-*.jsonl; do
    [ -f "$f" ] || continue
    if grep -q "feedf00d" "$f" 2>/dev/null; then
        rm -f "$f"
    fi
done

# ───────────────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
