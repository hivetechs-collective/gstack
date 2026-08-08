#!/bin/bash
# Tests for plan-w-team-surface-status.sh
# Usage: bash .claude/scripts/plan-w-team-surface-status.test.sh
# Exits 0 on all pass, 1 on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$SCRIPT_DIR/plan-w-team-surface-status.sh"

# ── Corpus state isolation (1.48.0) — NEVER write to the live .claude/state ───
# This test used to set STATE_DIR=$PROJECT_ROOT/.claude/state and CLAUDE_PROJECT_DIR
# at the LIVE repo, so the helper's manifest mirror (pwt-manifest.sh) and the test's
# own LOCK_DIR/SUP_LOG/FLEET_LOG writes landed in the live tree under a test slug.
# ROOT FIX: redirect every write into a per-test mktemp sandbox and tear it down with
# the test. We `cd` into the sandbox so the helper's $PWD-preferred state-dir resolves
# inside it, and export CLAUDE_PROJECT_DIR + PWT_PROJECT_ROOT_OVERRIDE so the helper and
# pwt-manifest.sh resolve the sandbox too. SCRIPT_DIR/HELPER are absolute, so the cd does
# not break the real-script lookups. Assertions are UNCHANGED — only the write path moves.
PWT_TEST_SANDBOX=$(mktemp -d -t pwt-surfstat.XXXXXX)
STATE_DIR="$PWT_TEST_SANDBOX/.claude/state"
mkdir -p "$PWT_TEST_SANDBOX/.claude" "$STATE_DIR"
# surface-status.sh resolves its sibling scripts (fleet-query, pwt-manifest) via
# $PROJECT_ROOT/.claude/scripts — i.e. CLAUDE_PROJECT_DIR. Symlink the REAL scripts
# dir into the sandbox so those lookups still resolve while state writes stay isolated
# (U5 fleet summary needs the real fleet-query; the manifest mirror then lands in the
# sandbox's own state, not live). Sibling-script resolution + sandboxed state, together.
ln -s "$PROJECT_ROOT/.claude/scripts" "$PWT_TEST_SANDBOX/.claude/scripts"
cd "$PWT_TEST_SANDBOX" || exit 1
export CLAUDE_PROJECT_DIR="$PWT_TEST_SANDBOX"
export PWT_PROJECT_ROOT_OVERRIDE="$PWT_TEST_SANDBOX"

TEST_SLUG="surface-status-test-$$"
LOCK_DIR="$STATE_DIR/plan-w-team-workflow-${TEST_SLUG}.lock"
SUP_LOG="$STATE_DIR/plan-w-team-supervisor-actions-${TEST_SLUG}.jsonl"
FLEET_LOG="$STATE_DIR/plan-w-team-fleet-${TEST_SLUG}.jsonl"

PASS=0
FAIL=0

# cleanup() removes only the per-test state FILES — it is called MID-TEST (U2) to
# reset state between assertions, so it must NOT remove the sandbox (which holds the
# .claude/scripts symlink the helper needs). The sandbox is torn down once, at EXIT.
cleanup() {
    rm -rf "$LOCK_DIR"
    rm -f "$SUP_LOG" "$FLEET_LOG"
}
final_cleanup() {
    cleanup
    rm -rf "$PWT_TEST_SANDBOX"
}
trap final_cleanup EXIT

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $name"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

# Extract JSON between ```status fences from helper output
extract_json() {
    awk '/^```status$/{flag=1; next} /^```$/{flag=0} flag'
}

echo "U1: missing slug → exit 1 + usage stderr"
"$HELPER" 2>/tmp/serr-$$ >/dev/null
EXIT=$?
assert_eq "exit code" "1" "$EXIT"
assert_eq "usage in stderr" "1" "$(grep -c 'Usage:' /tmp/serr-$$ || echo 0)"
rm -f /tmp/serr-$$

echo "U2: no state → block with workflow_lock=missing, empty arrays, exit 0"
cleanup
OUT=$("$HELPER" "$TEST_SLUG" "test-stage" 2>/dev/null)
EXIT=$?
assert_eq "exit code" "0" "$EXIT"
JSON=$(echo "$OUT" | extract_json)
assert_eq "valid JSON" "1" "$(echo "$JSON" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)"
assert_eq "workflow_lock=missing" "missing" "$(echo "$JSON" | jq -r '.workflow_lock')"
assert_eq "pending_escalations empty" "0" "$(echo "$JSON" | jq -r '.pending_escalations | length')"
assert_eq "low_confidence_routes=0" "0" "$(echo "$JSON" | jq -r '.low_confidence_routes')"
assert_eq "stage matches" "test-stage" "$(echo "$JSON" | jq -r '.stage')"
assert_eq "slug matches" "$TEST_SLUG" "$(echo "$JSON" | jq -r '.slug')"

echo "U3: workflow lock dir present → workflow_lock=active"
mkdir -p "$LOCK_DIR"
echo "$$" > "$LOCK_DIR/pid"
JSON=$("$HELPER" "$TEST_SLUG" "execute" 2>/dev/null | extract_json)
assert_eq "workflow_lock=active" "active" "$(echo "$JSON" | jq -r '.workflow_lock')"

echo "U4: 3 low-confidence rows in supervisor-actions → low_confidence_routes=3"
cat > "$SUP_LOG" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"supervisor_start","slug":"$TEST_SLUG","supervisor_agent_id":"AGT-1"}
{"ts":"2026-05-19T22:01:00Z","event":"route_delegation","slug":"$TEST_SLUG","call_site":"qa-tier-selection","router_choice":"standard","router_confidence":"low"}
{"ts":"2026-05-19T22:02:00Z","event":"route_delegation","slug":"$TEST_SLUG","call_site":"version-bump-major-vs-minor","router_choice":"minor","router_confidence":"low"}
{"ts":"2026-05-19T22:03:00Z","event":"route_delegation","slug":"$TEST_SLUG","call_site":"agent-roster-selection","router_choice":"react-typescript-specialist","router_confidence":"high"}
{"ts":"2026-05-19T22:04:00Z","event":"route_delegation","slug":"$TEST_SLUG","call_site":"ship-readiness-gate","router_choice":"PASS","router_confidence":"low"}
EOF
JSON=$("$HELPER" "$TEST_SLUG" "ship" 2>/dev/null | extract_json)
assert_eq "low_confidence_routes=3" "3" "$(echo "$JSON" | jq -r '.low_confidence_routes')"
assert_eq "ship_readiness_gate=PASS" "PASS" "$(echo "$JSON" | jq -r '.ship_readiness_gate')"

echo "U5: fleet log present → fleet object populated"
cat > "$FLEET_LOG" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"spawn","slug":"$TEST_SLUG","agent_id":"AGT-A","agent_type":"builder","cwd":"/r"}
{"ts":"2026-05-19T22:00:05Z","event":"spawn","slug":"$TEST_SLUG","agent_id":"AGT-B","agent_type":"builder","cwd":"/r"}
{"ts":"2026-05-19T22:05:00Z","event":"complete","slug":"$TEST_SLUG","agent_id":"AGT-A","last_msg":"done"}
EOF
JSON=$("$HELPER" "$TEST_SLUG" "execute" 2>/dev/null | extract_json)
assert_eq "fleet.spawned=2" "2" "$(echo "$JSON" | jq -r '.fleet.spawned')"
assert_eq "fleet.completed=1" "1" "$(echo "$JSON" | jq -r '.fleet.completed')"
assert_eq "fleet.running=1" "1" "$(echo "$JSON" | jq -r '.fleet.running')"

echo 'U6: status block emits to stdout inside fenced wrapper, JSON parseable'
OUT=$("$HELPER" "$TEST_SLUG" "verify" 2>/dev/null)
FENCE_OPEN=$(echo "$OUT" | grep -c '^```status$' || echo 0)
FENCE_CLOSE=$(echo "$OUT" | grep -c '^```$' || echo 0)
assert_eq "opening fence" "1" "$FENCE_OPEN"
assert_eq "closing fence" "1" "$FENCE_CLOSE"
PARSED=$(echo "$OUT" | extract_json | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)
assert_eq "inner JSON parses" "1" "$PARSED"

echo 'U7: retro-complete stage -> workflow_lock=done (success anchor)'
JSON=$("$HELPER" "$TEST_SLUG" "retro-complete" 2>/dev/null | extract_json)
assert_eq "workflow_lock=done" "done" "$(echo "$JSON" | jq -r '.workflow_lock')"

echo "U8: escalation rows surface in pending_escalations"
cat >> "$SUP_LOG" <<EOF
{"ts":"2026-05-19T22:06:00Z","event":"escalation","slug":"$TEST_SLUG","call_site":"push-ack","reason":"hard-gate"}
EOF
JSON=$("$HELPER" "$TEST_SLUG" "ship" 2>/dev/null | extract_json)
ESC_COUNT=$(echo "$JSON" | jq -r '.pending_escalations | length')
ESC_FIRST=$(echo "$JSON" | jq -r '.pending_escalations[0]')
assert_eq "pending_escalations has 1" "1" "$ESC_COUNT"
assert_eq "escalation is push-ack" "push-ack" "$ESC_FIRST"

echo "U9: resolved site filtered out (escalation + valid escalation_resolved for same call_site)"
cleanup
cat > "$SUP_LOG" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"escalation","slug":"$TEST_SLUG","call_site":"push-ack","reason":"hard-gate"}
{"ts":"2026-05-19T22:01:00Z","event":"escalation_resolved","slug":"$TEST_SLUG","call_site":"push-ack","reason":"user_ack"}
EOF
JSON=$("$HELPER" "$TEST_SLUG" "ship" 2>/dev/null | extract_json)
assert_eq "pending_escalations empty after resolve" "0" "$(echo "$JSON" | jq -r '.pending_escalations | length')"

echo "U10: legacy log (escalation rows only, no resolution rows) renders byte-identically vs pre-change golden"
cleanup
# Golden captured from the PRE-Fix-4 (task #36) plan-w-team-surface-status.sh
# against this EXACT fixture, BEFORE the escalation_resolved pairing edit
# landed (mandatory sequencing per the spec — golden must predate the fix).
# ts is stripped before comparison since it always reflects wall-clock
# `date -u` at invocation time; every other field must match byte-for-byte.
LEGACY_SLUG="legacy-golden-test-fixed"
LEGACY_LOG="$STATE_DIR/plan-w-team-supervisor-actions-${LEGACY_SLUG}.jsonl"
cat > "$LEGACY_LOG" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"supervisor_start","slug":"$LEGACY_SLUG","supervisor_agent_id":"AGT-1"}
{"ts":"2026-05-19T22:01:00Z","event":"escalation","slug":"$LEGACY_SLUG","call_site":"push-ack","reason":"hard-gate"}
{"ts":"2026-05-19T22:02:00Z","event":"escalation","slug":"$LEGACY_SLUG","call_site":"secret-scan-allow","reason":"hard-gate"}
{"ts":"2026-05-19T22:03:00Z","event":"escalation","slug":"$LEGACY_SLUG","call_site":"scope-unlock-for-drift","reason":"hard-gate"}
{"ts":"2026-05-19T22:04:00Z","event":"escalation","slug":"$LEGACY_SLUG","call_site":"credential-wall","reason":"hard-gate"}
{"ts":"2026-05-19T22:05:00Z","event":"escalation","slug":"$LEGACY_SLUG","call_site":"push-ack","reason":"hard-gate"}
{"ts":"2026-05-19T22:06:00Z","event":"route_delegation","slug":"$LEGACY_SLUG","call_site":"qa-tier-selection","router_choice":"standard","router_confidence":"low"}
EOF
GOLDEN_JSON='{"slug":"legacy-golden-test-fixed","stage":"ship","workflow_lock":"missing","ship_readiness_gate":"pending","fleet":{},"pending_escalations":["credential-wall","push-ack","scope-unlock-for-drift","secret-scan-allow"],"low_confidence_routes":1}'
JSON=$("$HELPER" "$LEGACY_SLUG" "ship" 2>/dev/null | extract_json)
ACTUAL_NO_TS=$(echo "$JSON" | jq -S -c 'del(.ts)')
EXPECTED_NO_TS=$(echo "$GOLDEN_JSON" | jq -S -c .)
assert_eq "legacy log byte-identical to pre-change golden (ts excluded)" "$EXPECTED_NO_TS" "$ACTUAL_NO_TS"
rm -f "$LEGACY_LOG"

echo "U11: same-second resolve-then-re-escalate re-pends (file order beats ts tie)"
cleanup
cat > "$SUP_LOG" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"escalation","slug":"$TEST_SLUG","call_site":"push-ack","reason":"hard-gate"}
{"ts":"2026-05-19T22:00:00Z","event":"escalation_resolved","slug":"$TEST_SLUG","call_site":"push-ack","reason":"user_ack"}
{"ts":"2026-05-19T22:00:00Z","event":"escalation","slug":"$TEST_SLUG","call_site":"push-ack","reason":"hard-gate"}
EOF
JSON=$("$HELPER" "$TEST_SLUG" "ship" 2>/dev/null | extract_json)
assert_eq "push-ack re-pends after same-second re-escalation" "1" "$(echo "$JSON" | jq -r '.pending_escalations | length')"
assert_eq "push-ack is the pending site" "push-ack" "$(echo "$JSON" | jq -r '.pending_escalations[0]')"

echo "U12: resolution row for a never-escalated site is ignored (no phantom entries)"
cleanup
cat > "$SUP_LOG" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"escalation","slug":"$TEST_SLUG","call_site":"push-ack","reason":"hard-gate"}
{"ts":"2026-05-19T22:01:00Z","event":"escalation_resolved","slug":"$TEST_SLUG","call_site":"secret-scan-allow","reason":"user_ack"}
EOF
JSON=$("$HELPER" "$TEST_SLUG" "ship" 2>/dev/null | extract_json)
assert_eq "pending_escalations has 1 (only push-ack)" "1" "$(echo "$JSON" | jq -r '.pending_escalations | length')"
assert_eq "escalation is push-ack" "push-ack" "$(echo "$JSON" | jq -r '.pending_escalations[0]')"

echo "U13: one corrupt JSONL line does not blank valid pending sites"
cleanup
printf '%s\n' \
  '{"ts":"2026-05-19T22:00:00Z","event":"escalation","slug":"'"$TEST_SLUG"'","call_site":"push-ack","reason":"hard-gate"}' \
  '{this is not valid json at all!!' \
  '{"ts":"2026-05-19T22:02:00Z","event":"escalation","slug":"'"$TEST_SLUG"'","call_site":"secret-scan-allow","reason":"hard-gate"}' \
  '{"ts":"2026-05-19T22:03:00Z","event":"route_delegation","slug":"'"$TEST_SLUG"'","call_site":"x","router_choice":"a","router_confidence":"low"}' \
  '{"ts":"2026-05-19T22:04:00Z","event":"route_delegation","slug":"'"$TEST_SLUG"'","call_site":"y","router_choice":"b","router_confidence":"low"}' \
  > "$SUP_LOG"
JSON=$("$HELPER" "$TEST_SLUG" "ship" 2>/dev/null | extract_json)
assert_eq "pending_escalations has 2 despite corrupt line" "2" "$(echo "$JSON" | jq -r '.pending_escalations | length')"
# G1 (Step-5 fix): low_confidence_routes previously used the whole-file jq -s
# form, so the SAME corrupt line blanked it to 0 — suppressing the
# "3 consecutive low-confidence decisions" goal HALT signal (fail-open).
assert_eq "low_confidence_routes survives the corrupt line" "2" "$(echo "$JSON" | jq -r '.low_confidence_routes')"

echo "U14: hard-gate site with a non-enum resolution reason stays pending"
cleanup
cat > "$SUP_LOG" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"escalation","slug":"$TEST_SLUG","call_site":"scope-unlock-for-drift","reason":"hard-gate"}
{"ts":"2026-05-19T22:01:00Z","event":"escalation_resolved","slug":"$TEST_SLUG","call_site":"scope-unlock-for-drift","reason":"operator_said_so"}
EOF
JSON=$("$HELPER" "$TEST_SLUG" "ship" 2>/dev/null | extract_json)
assert_eq "pending_escalations has 1 (non-enum reason ignored)" "1" "$(echo "$JSON" | jq -r '.pending_escalations | length')"
assert_eq "scope-unlock-for-drift still pending" "scope-unlock-for-drift" "$(echo "$JSON" | jq -r '.pending_escalations[0]')"

echo "U15: JSON-valid escalation row missing call_site does not blank real pending sites"
# Step-5 fix (evaluator finding, this run): a schema-invalid-but-parseable row
# (event=escalation, NO call_site) reached the reduce, indexed the object with
# null, killed the whole jq pipeline, and the || fallback blanked the array —
# fail-OPEN on a hard-gate signal, strictly worse than the pre-change output.
# The select now requires (.call_site | type == "string"); the bad row is
# dropped individually and every real site stays visible.
cleanup
cat > "$SUP_LOG" <<EOF
{"ts":"2026-05-19T22:00:00Z","event":"escalation","slug":"$TEST_SLUG","call_site":"credential-wall","reason":"hard-gate"}
{"ts":"2026-05-19T22:01:00Z","event":"escalation","slug":"$TEST_SLUG","reason":"schema-invalid: no call_site"}
{"ts":"2026-05-19T22:02:00Z","event":"escalation","slug":"$TEST_SLUG","call_site":"push-ack","reason":"hard-gate"}
EOF
JSON=$("$HELPER" "$TEST_SLUG" "ship" 2>/dev/null | extract_json)
assert_eq "pending_escalations has 2 despite schema-invalid row" "2" "$(echo "$JSON" | jq -r '.pending_escalations | length')"
assert_eq "credential-wall survives the bad row" "credential-wall" "$(echo "$JSON" | jq -r '.pending_escalations[0]')"
assert_eq "push-ack survives the bad row" "push-ack" "$(echo "$JSON" | jq -r '.pending_escalations[1]')"

echo ""
echo "Results: $PASS passed, $FAIL failed"

# Expected-PASS-count assertion (test lane E8) — a silently-vanished assertion
# (e.g. a future edit that drops a case without updating callers) still shows
# green on FAIL==0 alone; pin the exact count so a shrinkage is caught.
EXPECTED_PASS=34
if [ "$PASS" -ne "$EXPECTED_PASS" ]; then
    echo "✗ expected exactly $EXPECTED_PASS passing assertions, got $PASS"
    FAIL=$((FAIL + 1))
fi

[ "$FAIL" -eq 0 ] || exit 1
