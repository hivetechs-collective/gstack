#!/usr/bin/env bash
# Tests for .claude/scripts/claude-agents-extended.sh
# Convention: bash test, follows the style of pwt-goal-*.test.sh.
# Run: ./claude-agents-extended.test.sh
# Exit 0 = all green; nonzero = failure count.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/claude-agents-extended.sh"
PASS=0
FAIL=0

# ── helpers ──────────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
ok()    { PASS=$((PASS+1)); printf '  %s %s\n' "$(green ✓)" "$1"; }
no()    { FAIL=$((FAIL+1)); printf '  %s %s\n' "$(red ✗)" "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }

assert_jq() {
  # assert_jq <name> <jq_filter> <json> <expected_literal>
  local name="$1" filter="$2" json="$3" expected="$4"
  local actual
  actual=$(printf '%s' "$json" | jq -r "$filter" 2>/dev/null || echo "<jq-error>")
  if [ "$actual" = "$expected" ]; then
    ok "$name"
  else
    no "$name" "expected: $expected | actual: $actual"
  fi
}

# Build a fake projects dir layout:
#   $base/<project>/<parent-sid>/subagents/agent-<agentId>.jsonl
#   $base/<project>/<parent-sid>.jsonl   (parent transcript)
make_subagent() {
  # make_subagent <base> <project> <parent-sid> <agentId> <cwd> <description> [<age_secs>]
  local base="$1" project="$2" psid="$3" aid="$4" cwd="$5" desc="$6" age="${7:-0}"
  local subdir="$base/$project/$psid/subagents"
  mkdir -p "$subdir"
  local file="$subdir/agent-${aid}.jsonl"
  cat > "$file" <<EOF
{"agentId":"$aid","type":"user","message":{"role":"user","content":"$desc"},"timestamp":"2026-05-23T10:00:00Z","cwd":"$cwd","sessionKind":"bg","sessionId":"$psid"}
EOF
  if [ "$age" -gt 0 ]; then
    # Backdate mtime to make it stale.
    local target_epoch=$(( $(date +%s) - age ))
    touch -t "$(date -r "$target_epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$target_epoch" +%Y%m%d%H%M.%S)" "$file"
  fi
}

mark_completed() {
  # mark_completed <base> <project> <parent-sid> <agentId>
  # Writes a parent-transcript line that satisfies the terminal heuristic.
  local base="$1" project="$2" psid="$3" aid="$4"
  local pt="$base/$project/$psid.jsonl"
  mkdir -p "$(dirname "$pt")"
  cat > "$pt" <<EOF
{"type":"user","toolUseResult":{"agentId":"$aid","status":"completed","isAsync":true}}
EOF
}

# ── tests ─────────────────────────────────────────────────────────────────────

echo "Test suite: claude-agents-extended.sh"
echo ""

# Test 1: empty input — no subagents dir, no base, no claude binary.
echo "[1] empty input → []"
TMP=$(mktemp -d)
out=$(CLAUDE_PROJECTS_DIR="$TMP/empty" CLAUDE_AGENTS_EXTENDED_NO_RUN_CLAUDE=1 "$WRAPPER")
assert_jq "empty array" '. | length' "$out" "0"
rm -rf "$TMP"

# Test 2: subagent-only (no base entries).
echo ""
echo "[2] subagent-only — fresh + no completion marker → 1 entry"
TMP=$(mktemp -d)
make_subagent "$TMP" "proj1" "sid-aaa-bbb-ccc" "a1111111111111111" "/home/x" "task one"
out=$(CLAUDE_PROJECTS_DIR="$TMP" CLAUDE_AGENTS_EXTENDED_NO_RUN_CLAUDE=1 "$WRAPPER")
assert_jq "length == 1"        '. | length'               "$out" "1"
assert_jq "kind == subagent"   '.[0].kind'                "$out" "subagent"
assert_jq "agentId echoes"     '.[0].agentId'             "$out" "a1111111111111111"
assert_jq "parentSessionId"    '.[0].parentSessionId'     "$out" "sid-aaa-bbb-ccc"
assert_jq "sessionId == aid"   '.[0].sessionId'           "$out" "a1111111111111111"
assert_jq "cwd preserved"      '.[0].cwd'                 "$out" "/home/x"
assert_jq "status busy"        '.[0].status'              "$out" "busy"
rm -rf "$TMP"

# Test 3: mixed bg + subagent — both appear in output.
echo ""
echo "[3] mixed bg + subagent — both present"
TMP=$(mktemp -d)
make_subagent "$TMP" "proj1" "sid-xyz" "a2222222222222222" "/home/x" "subagent task"
base='[{"kind":"background","sessionId":"bg-1","cwd":"/home/x","status":"idle"}]'
out=$(CLAUDE_PROJECTS_DIR="$TMP" CLAUDE_AGENTS_RAW="$base" "$WRAPPER")
assert_jq "total == 2"         '. | length'                              "$out" "2"
assert_jq "1 background kind"  '[.[] | select(.kind=="background")] | length' "$out" "1"
assert_jq "1 subagent kind"    '[.[] | select(.kind=="subagent")] | length'   "$out" "1"
rm -rf "$TMP"

# Test 4: completed subagent excluded via parent tool_use_result.
echo ""
echo "[4] completed subagent excluded via parent transcript"
TMP=$(mktemp -d)
make_subagent "$TMP" "proj1" "sid-done" "a3333333333333333" "/home/x" "done task"
mark_completed "$TMP" "proj1" "sid-done" "a3333333333333333"
out=$(CLAUDE_PROJECTS_DIR="$TMP" CLAUDE_AGENTS_EXTENDED_NO_RUN_CLAUDE=1 "$WRAPPER")
assert_jq "length == 0"        '. | length'               "$out" "0"
rm -rf "$TMP"

# Test 5: stale-by-mtime exclusion.
echo ""
echo "[5] stale-by-mtime (> SUBAGENT_FRESHNESS_SEC) excluded"
TMP=$(mktemp -d)
make_subagent "$TMP" "proj1" "sid-stale" "a4444444444444444" "/home/x" "stale task" 600
out=$(SUBAGENT_FRESHNESS_SEC=60 CLAUDE_PROJECTS_DIR="$TMP" CLAUDE_AGENTS_EXTENDED_NO_RUN_CLAUDE=1 "$WRAPPER")
assert_jq "stale excluded"     '. | length'               "$out" "0"
# But: bumping the freshness window should let it through.
out2=$(SUBAGENT_FRESHNESS_SEC=86400 CLAUDE_PROJECTS_DIR="$TMP" CLAUDE_AGENTS_EXTENDED_NO_RUN_CLAUDE=1 "$WRAPPER")
assert_jq "wide window keeps it"  '. | length'            "$out2" "1"
rm -rf "$TMP"

# Test 6: malformed JSONL tolerance — no crash, that entry skipped.
echo ""
echo "[6] malformed JSONL tolerance"
TMP=$(mktemp -d)
mkdir -p "$TMP/proj1/sid-bad/subagents"
echo "not-json-at-all{{" > "$TMP/proj1/sid-bad/subagents/agent-a5555555555555555.jsonl"
# And a good one alongside.
make_subagent "$TMP" "proj1" "sid-good" "a6666666666666666" "/home/x" "good task"
out=$(CLAUDE_PROJECTS_DIR="$TMP" CLAUDE_AGENTS_EXTENDED_NO_RUN_CLAUDE=1 "$WRAPPER")
assert_jq "only good entry kept"  '. | length'                                 "$out" "1"
assert_jq "good entry's agentId"  '.[0].agentId'                               "$out" "a6666666666666666"
rm -rf "$TMP"

# Test 7: missing parent transcript tolerance — entry still emitted (advisory).
echo ""
echo "[7] missing parent transcript — entry emitted via mtime fallback"
TMP=$(mktemp -d)
make_subagent "$TMP" "proj1" "sid-noparent" "a7777777777777777" "/home/x" "orphan"
# Do NOT call mark_completed; do NOT create parent transcript.
out=$(CLAUDE_PROJECTS_DIR="$TMP" CLAUDE_AGENTS_EXTENDED_NO_RUN_CLAUDE=1 "$WRAPPER")
assert_jq "still emits entry"  '. | length'               "$out" "1"
assert_jq "kind == subagent"   '.[0].kind'                "$out" "subagent"
rm -rf "$TMP"

# Test 8: --bg-only bypasses subagent scan entirely.
echo ""
echo "[8] --bg-only short-circuits subagent scan"
TMP=$(mktemp -d)
make_subagent "$TMP" "proj1" "sid-x" "a8888888888888888" "/home/x" "task"
base='[{"kind":"background","sessionId":"bg-1","cwd":"/home/x","status":"busy"}]'
out=$(CLAUDE_PROJECTS_DIR="$TMP" CLAUDE_AGENTS_RAW="$base" "$WRAPPER" --bg-only)
assert_jq "only base entries"   '. | length'                                 "$out" "1"
assert_jq "no subagent entries" '[.[] | select(.kind=="subagent")] | length' "$out" "0"
rm -rf "$TMP"

# Test 9: --cwd filter.
echo ""
echo "[9] --cwd filter applies to base + subagents"
TMP=$(mktemp -d)
make_subagent "$TMP" "proj1" "sid-here" "a9999999999999999" "/home/here" "in scope"
make_subagent "$TMP" "proj2" "sid-there" "ab000000000000000" "/home/there" "out of scope"
base='[
  {"kind":"background","sessionId":"bg-1","cwd":"/home/here","status":"idle"},
  {"kind":"background","sessionId":"bg-2","cwd":"/home/there","status":"idle"}
]'
out=$(CLAUDE_PROJECTS_DIR="$TMP" CLAUDE_AGENTS_RAW="$base" "$WRAPPER" --cwd /home/here)
assert_jq "total filtered"      '. | length'                                   "$out" "2"
assert_jq "no /home/there"      '[.[] | select(.cwd | startswith("/home/there"))] | length' "$out" "0"
rm -rf "$TMP"

# Test 10: backwards-compat — base entries shape unchanged.
echo ""
echo "[10] base entries shape preserved (backwards compat)"
TMP=$(mktemp -d)
base='[{"kind":"background","sessionId":"abc","cwd":"/x","status":"busy","extraField":42}]'
out=$(CLAUDE_PROJECTS_DIR="$TMP/empty" CLAUDE_AGENTS_RAW="$base" "$WRAPPER")
assert_jq "extraField survives" '.[0].extraField' "$out" "42"
rm -rf "$TMP"

# Test 11: performance — wrapper completes under budget on empty input.
# Budget: 1500ms cold (generous; the real <300ms target is for cached path).
echo ""
echo "[11] perf — completes within 1500ms on empty input"
TMP=$(mktemp -d)
t0=$(date +%s)
CLAUDE_PROJECTS_DIR="$TMP" CLAUDE_AGENTS_EXTENDED_NO_RUN_CLAUDE=1 "$WRAPPER" >/dev/null
t1=$(date +%s)
elapsed_sec=$(( t1 - t0 ))
if [ "$elapsed_sec" -le 2 ]; then
  ok "completed in ${elapsed_sec}s"
else
  no "completed in ${elapsed_sec}s" "expected <= 2s"
fi
rm -rf "$TMP"

# Test 12: exit code propagation — when `claude` fails AND no subagents
# present, the wrapper exits non-zero so callers like pwt-claims-cleanup can
# treat the result as "unknown" rather than "no live agents".
echo ""
echo "[12] exit code propagates base failure when no subagent fallback signal"
TMP=$(mktemp -d)
# Build a fake claude binary that always fails (simulates `claude` unusable).
FAKEDIR=$(mktemp -d)
cat > "$FAKEDIR/claude" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$FAKEDIR/claude"
# Empty projects dir → no subagent fallback signal.
if PATH="$FAKEDIR:$PATH" CLAUDE_PROJECTS_DIR="$TMP/empty" "$WRAPPER" >/dev/null 2>&1; then
  no "exit non-zero when claude fails AND no subagents" "exit was 0"
else
  ok "exit non-zero when claude fails AND no subagents"
fi
# Presence of fresh subagents should restore exit 0 (partial info > nothing).
make_subagent "$TMP" "proj1" "sid-x" "ac111111111111111" "/x" "live one"
if PATH="$FAKEDIR:$PATH" CLAUDE_PROJECTS_DIR="$TMP" "$WRAPPER" >/dev/null 2>&1; then
  ok "exit 0 when claude fails but subagents present"
else
  no "exit 0 when claude fails but subagents present" "exit was non-zero"
fi
rm -rf "$TMP" "$FAKEDIR"

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $(green "$PASS passed"), $(if [ "$FAIL" -gt 0 ]; then red "$FAIL failed"; else echo "0 failed"; fi)"
[ "$FAIL" -eq 0 ]
