#!/usr/bin/env bash
# Tests for plan-w-team-cleanup-stale-goal-states.sh
#
# Verifies the cleanup script:
#   - Removes goal-state files where terminal_state == "SUCCESS"
#   - Preserves files where terminal_state is null, USER_ESCALATION_HALT,
#     LOW_CONFIDENCE_STREAK, or DEAD
#   - Tolerates missing state dir
#   - --dry-run does not remove anything
#   - --verbose logs preservations

set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/plan-w-team-cleanup-stale-goal-states.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: script not executable: $SCRIPT"; exit 1; }

PASS=0
FAIL=0
FAIL_NAMES=()

setup_sandbox() {
    SANDBOX=$(mktemp -d -t pwt-cleanup-test.XXXXXX)
    mkdir -p "$SANDBOX/.claude/state"
    export STATE_DIR="$SANDBOX/.claude/state"
}

teardown_sandbox() {
    [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
    unset STATE_DIR
}

write_state_file() {
    local slug="$1" state="$2"
    local f="$STATE_DIR/plan-w-team-goal-${slug}.json"
    if [ "$state" = "null" ]; then
        cat > "$f" <<EOF
{
  "slug": "${slug}",
  "started_at": "2026-05-21T00:00:00Z",
  "terminal_state": null,
  "terminal_reason": null
}
EOF
    else
        cat > "$f" <<EOF
{
  "slug": "${slug}",
  "started_at": "2026-05-21T00:00:00Z",
  "terminal_state": "${state}",
  "terminal_reason": "test fixture",
  "terminated_at": "2026-05-21T01:00:00Z"
}
EOF
    fi
}

assert_exists()    { local n="$1" f="$2"; [ -f "$f" ] && { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$n"; } || { FAIL=$((FAIL+1)); FAIL_NAMES+=("$n"); printf "  \033[31m✗\033[0m %s (missing %s)\n" "$n" "$f"; }; }
assert_absent()    { local n="$1" f="$2"; [ ! -f "$f" ] && { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$n"; } || { FAIL=$((FAIL+1)); FAIL_NAMES+=("$n"); printf "  \033[31m✗\033[0m %s (still present: %s)\n" "$n" "$f"; }; }
assert_eq()        { local n="$1" e="$2" a="$3"; [ "$e" = "$a" ] && { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$n"; } || { FAIL=$((FAIL+1)); FAIL_NAMES+=("$n"); printf "  \033[31m✗\033[0m %s (expected '%s', got '%s')\n" "$n" "$e" "$a"; }; }

echo "Testing plan-w-team-cleanup-stale-goal-states.sh"
echo

# ─── SUCCESS files are removed ───────────────────────────────────────────────
setup_sandbox
write_state_file "alpha"   "SUCCESS"
write_state_file "beta"    "SUCCESS"
out=$(bash "$SCRIPT" 2>&1)
rc=$?
assert_eq    "exit 0 on cleanup run"               0 "$rc"
assert_absent "SUCCESS file 'alpha' removed"       "$STATE_DIR/plan-w-team-goal-alpha.json"
assert_absent "SUCCESS file 'beta' removed"        "$STATE_DIR/plan-w-team-goal-beta.json"
case "$out" in
    *"cleaned 2 stale SUCCESS"*)
        PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "stdout reports 2 removals" ;;
    *)
        FAIL=$((FAIL+1)); FAIL_NAMES+=("stdout reports 2 removals")
        printf "  \033[31m✗\033[0m stdout reports 2 removals (got: %s)\n" "$out" ;;
esac
teardown_sandbox

# ─── Non-SUCCESS files are preserved ─────────────────────────────────────────
setup_sandbox
write_state_file "in-flight"    "null"
write_state_file "escalated"    "USER_ESCALATION_HALT"
write_state_file "low-conf"     "LOW_CONFIDENCE_STREAK"
write_state_file "dead"         "DEAD"
write_state_file "success"      "SUCCESS"
bash "$SCRIPT" >/dev/null 2>&1
assert_exists "in-flight (null) preserved"          "$STATE_DIR/plan-w-team-goal-in-flight.json"
assert_exists "USER_ESCALATION_HALT preserved"      "$STATE_DIR/plan-w-team-goal-escalated.json"
assert_exists "LOW_CONFIDENCE_STREAK preserved"     "$STATE_DIR/plan-w-team-goal-low-conf.json"
assert_exists "DEAD preserved"                      "$STATE_DIR/plan-w-team-goal-dead.json"
assert_absent "SUCCESS removed when mixed with non-SUCCESS" "$STATE_DIR/plan-w-team-goal-success.json"
teardown_sandbox

# ─── Missing state dir is tolerated ──────────────────────────────────────────
setup_sandbox
rm -rf "$STATE_DIR"
out=$(bash "$SCRIPT" 2>&1)
rc=$?
assert_eq "exit 0 when state dir missing" 0 "$rc"
assert_eq "no output when state dir missing" "" "$out"
teardown_sandbox

# ─── No matching files = silent success ──────────────────────────────────────
setup_sandbox
out=$(bash "$SCRIPT" 2>&1)
rc=$?
assert_eq "exit 0 when no goal-state files exist" 0 "$rc"
assert_eq "no output when nothing to clean" "" "$out"
teardown_sandbox

# ─── --dry-run does not remove anything ──────────────────────────────────────
setup_sandbox
write_state_file "alpha" "SUCCESS"
out=$(bash "$SCRIPT" --dry-run 2>&1)
assert_exists "dry-run preserves SUCCESS file"     "$STATE_DIR/plan-w-team-goal-alpha.json"
case "$out" in
    *"[dry-run]"*"alpha"*) PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "dry-run logs prospective removal" ;;
    *) FAIL=$((FAIL+1)); FAIL_NAMES+=("dry-run logs prospective removal")
       printf "  \033[31m✗\033[0m dry-run logs prospective removal (got: %s)\n" "$out" ;;
esac
teardown_sandbox

# ─── --verbose logs both kept and removed ────────────────────────────────────
setup_sandbox
write_state_file "kept"     "USER_ESCALATION_HALT"
write_state_file "removed"  "SUCCESS"
out=$(bash "$SCRIPT" --verbose 2>&1)
case "$out" in
    *"kept"*"removed"*|*"removed"*"kept"*) PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "verbose mentions both kept and removed" ;;
    *) FAIL=$((FAIL+1)); FAIL_NAMES+=("verbose mentions both kept and removed")
       printf "  \033[31m✗\033[0m verbose mentions both kept and removed (got: %s)\n" "$out" ;;
esac
teardown_sandbox

# ─── Malformed JSON: skip (don't crash) ──────────────────────────────────────
setup_sandbox
echo "{not valid json" > "$STATE_DIR/plan-w-team-goal-malformed.json"
write_state_file "good" "SUCCESS"
out=$(bash "$SCRIPT" 2>&1)
rc=$?
assert_eq    "exit 0 with malformed file present" 0 "$rc"
assert_absent "valid SUCCESS removed despite malformed sibling" "$STATE_DIR/plan-w-team-goal-good.json"
assert_exists "malformed file preserved (no terminal_state)" "$STATE_DIR/plan-w-team-goal-malformed.json"
teardown_sandbox

echo
echo "─────────────────────────────────────────"
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed cases:"
    for n in "${FAIL_NAMES[@]}"; do echo "  - $n"; done
    exit 1
fi
exit 0
