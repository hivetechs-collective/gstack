#!/usr/bin/env bash
# Tests for pwt-live-session-cwds.sh — the canonical live-session liveness probe
# consumed (FAIL-CLOSED) by plan-w-team-worktree-gc.sh and the hygiene composer.
#
# WHY (audit COV-2, 2026-06-08): the two reapers only ever inject a stub for this
# helper, so its OWN parse / fail-closed logic shipped untested. A regression that
# printed neither cwds nor the __QUERY_FAILED__ token would silently flip the GC and
# sweep from fail-CLOSED to fail-OPEN — the exact 2026-06-07 mid-flight-reap incident.
# This pins the contract directly via the helper's documented seams.
#
# bash 3.2 compatible.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/pwt-live-session-cwds.sh"

if [ ! -x "$HELPER" ]; then
    echo "pwt-live-session-cwds.sh not found/executable at $HELPER" >&2
    exit 1
fi

SANDBOX="$(mktemp -d -t pwt-live-cwds.XXXXXX)" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
assert_eq() {
    local n="$1" e="$2" a="$3"
    if [ "$e" = "$a" ]; then echo "  ✓ $n"; PASS=$((PASS + 1))
    else echo "  ✗ $n"; echo "    expected: [$e]"; echo "    actual:   [$a]"; FAIL=$((FAIL + 1)); fi
}

# A stub `claude` whose `agents --json` output we control via $STUB_JSON_FILE.
# Anything other than the `agents` subcommand emits nothing (we never spawn here).
mkdir -p "$SANDBOX/bin"
STUB_JSON_FILE="$SANDBOX/agents.json"
cat > "$SANDBOX/bin/claude" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "agents" ]; then cat "$STUB_JSON_FILE" 2>/dev/null; fi
exit 0
STUB
chmod +x "$SANDBOX/bin/claude"
STUB_BIN="$SANDBOX/bin/claude"

echo "════════════════════════════════════════"
echo "  pwt-live-session-cwds.sh probe tests"
echo "════════════════════════════════════════"

# 1. forced query-fail seam → token
OUT=$(PWT_LIVE_SESSION_QUERY_FAIL=1 "$HELPER" 2>/dev/null)
assert_eq "PWT_LIVE_SESSION_QUERY_FAIL=1 → __QUERY_FAILED__" "__QUERY_FAILED__" "$OUT"

# 2. claude binary absent → fail-closed token (cannot confirm liveness)
OUT=$(PWT_CLAUDE_BIN="$SANDBOX/bin/does-not-exist" "$HELPER" 2>/dev/null)
assert_eq "missing claude binary → __QUERY_FAILED__" "__QUERY_FAILED__" "$OUT"

# 3. [] (valid empty list) → query OK, zero live sessions → EMPTY stdout (safe to reclaim)
printf '[]' > "$STUB_JSON_FILE"
OUT=$(PWT_CLAUDE_BIN="$STUB_BIN" "$HELPER" 2>/dev/null)
assert_eq "empty list [] → empty stdout (NOT the fail token)" "" "$OUT"

# 4. live/dead mix → ONLY (background|interactive) ∧ (busy|idle) entries with a cwd
cat > "$STUB_JSON_FILE" <<'JSON'
[
 {"kind":"background","status":"idle","cwd":"/wt/bg-idle"},
 {"kind":"interactive","status":"busy","cwd":"/wt/int-busy"},
 {"kind":"background","status":"dead","cwd":"/wt/bg-dead"},
 {"kind":"subagent","status":"busy","cwd":"/wt/sub-busy"},
 {"kind":"interactive","status":"idle"},
 {"kind":"background","status":"idle","cwd":"/wt/bg-idle2"}
]
JSON
OUT=$(PWT_CLAUDE_BIN="$STUB_BIN" "$HELPER" 2>/dev/null | sort | tr '\n' ',')
assert_eq "only live bg/interactive busy/idle cwds printed" "/wt/bg-idle,/wt/bg-idle2,/wt/int-busy," "$OUT"

# 5. non-list JSON → __QUERY_FAILED__ (a dict is not the agents array contract)
printf '{"not":"a list"}' > "$STUB_JSON_FILE"
OUT=$(PWT_CLAUDE_BIN="$STUB_BIN" "$HELPER" 2>/dev/null)
assert_eq "non-list JSON → __QUERY_FAILED__" "__QUERY_FAILED__" "$OUT"

# 6. malformed JSON → __QUERY_FAILED__
printf '{not valid json' > "$STUB_JSON_FILE"
OUT=$(PWT_CLAUDE_BIN="$STUB_BIN" "$HELPER" 2>/dev/null)
assert_eq "malformed JSON → __QUERY_FAILED__" "__QUERY_FAILED__" "$OUT"

# 7. claude emits NOTHING (RAW empty: error/killed) → __QUERY_FAILED__
#    (distinct from the 2-byte "[]" which is a legitimate zero-sessions answer)
: > "$STUB_JSON_FILE"
OUT=$(PWT_CLAUDE_BIN="$STUB_BIN" "$HELPER" 2>/dev/null)
assert_eq "empty claude output → __QUERY_FAILED__" "__QUERY_FAILED__" "$OUT"

# 8. override seam bypasses claude entirely (prints the list verbatim)
OUT=$(PWT_LIVE_SESSION_CWDS_OVERRIDE="/a/b
/c/d" PWT_CLAUDE_BIN="$SANDBOX/bin/does-not-exist" "$HELPER" 2>/dev/null | tr '\n' ',')
assert_eq "PWT_LIVE_SESSION_CWDS_OVERRIDE prints verbatim, skips claude" "/a/b,/c/d," "$OUT"

echo "────────────────────────────────────────"
echo "  Pass: $PASS  Fail: $FAIL"
echo "────────────────────────────────────────"
[ "$FAIL" -eq 0 ]
