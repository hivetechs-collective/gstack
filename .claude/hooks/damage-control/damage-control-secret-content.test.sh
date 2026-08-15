#!/usr/bin/env bash
# Tests for damage-control.sh B1 fix: write-time (PreToolUse) secret CONTENT scan.
# The Write|Edit case must run secret-scan.sh over the content being written and
# BLOCK (exit 2) on a live secret, ALLOW (exit 0) placeholders/clean content.
#
# NOTE: realistic secret tokens are assembled at RUNTIME via concatenation so this
# source file has no literal pattern match (otherwise the very defense under test
# would block writing it, and the ship-gate --diff scan would flag it).
#
# Coverage:
#   T1  Write with live AWS key            → block (exit 2)
#   T2  Write with embedded placeholder     → allow (exit 0)
#   T3  Edit new_string with GitHub token   → block (exit 2)
#   T4  Write clean content                 → allow (exit 0)
#   T5  kill switch disables content scan   → allow (exit 0)
#   T6  block delivers its reason on STDERR (exit 2)
#   T7  non-Write/Edit (Read) unaffected    → exit 0

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DC="$SCRIPT_DIR/damage-control.sh"

# Runtime-assembled tokens (no literal pattern match in this source).
AWS="AKIA""Z9Q7W2P1N4K8T6RB"
GH="ghp_""ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789xy"

PASS=0; FAIL=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}
run() { printf '%s' "$1" | bash "$DC" >/dev/null 2>&1; echo $?; }
run_out() { printf '%s' "$1" | bash "$DC" 2>/dev/null; }
# A block writes its reason to STDERR and exits 2 (PreToolUse contract:
# stdout is only parsed on exit 0). Capture stderr for block assertions.
run_err() { printf '%s' "$1" | bash "$DC" 2>&1 >/dev/null; }

# Payloads that interpolate a variable are built HERE, not inline inside the
# `$(run "…")` substitution. bash 3.2 — the project's stated compat target and
# macOS's /bin/bash — parses nested escaped double quotes inside a double-quoted
# command substitution differently from bash 4+/5, which silently mangled the JSON
# so damage-control saw no secret and returned 0. That made T1/T3 a permanent
# false-RED under /bin/bash (5 passed / 2 failed) while both were green under a
# homebrew bash 5.x on PATH — i.e. `make test-skill` was red on mac-mini for a
# non-code reason, and green locally only by PATH accident. The DEFENSE was never
# broken: invoking damage-control.sh directly with the same payload blocks (exit 2)
# under both interpreters. Row-12 re-audit, 2026-08-14.
T1_PAYLOAD="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/a.ts\",\"content\":\"const k='$AWS'\"}}"
T3_PAYLOAD="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/tmp/a.ts\",\"new_string\":\"tok=$GH\"}}"

# T1 — live AWS key in Write content.
assert "T1 Write live AWS key blocks" "2" "$(run "$T1_PAYLOAD")"

# T2 — embedded placeholder marker → allowed.
assert "T2 Write placeholder allows" "0" \
  "$(run '{"tool_name":"Write","tool_input":{"file_path":"/tmp/a.ts","content":"const k=\"AKIAEXAMPLE0000000Z\""}}')"

# T3 — Edit new_string carries a GitHub token.
assert "T3 Edit live GH token blocks" "2" "$(run "$T3_PAYLOAD")"

# T4 — clean content.
assert "T4 Write clean content allows" "0" \
  "$(run '{"tool_name":"Write","tool_input":{"file_path":"/tmp/a.ts","content":"hello world"}}')"

# T5 — kill switch.
RC=$(DAMAGE_CONTROL_DISABLE_SECRET_CONTENT=1 bash -c "printf '%s' '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/a.ts\",\"content\":\"$AWS\"}}' | bash '$DC' >/dev/null 2>&1; echo \$?")
assert "T5 kill switch allows" "0" "$RC"

# T6 — a block delivers its reason on STDERR (was: decision:block JSON on stdout).
OUT=$(run_err "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/tmp/a.ts\",\"content\":\"$AWS\"}}")
case "$OUT" in *BLOCKED*) JSON_OK=1 ;; *) JSON_OK=0 ;; esac
assert "T6 block delivers its reason on stderr" "1" "$JSON_OK"

# T7 — Read tool is unaffected by content scan (no content key anyway).
assert "T7 Read unaffected" "0" \
  "$(run '{"tool_name":"Read","tool_input":{"file_path":"/tmp/a.ts"}}')"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
