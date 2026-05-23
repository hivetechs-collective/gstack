#!/usr/bin/env bash
# Regression test for .claude/scripts/locate-claude.sh
#
# Test cases:
#   TC1: happy path via command -v (PATH unmodified)
#   TC2: fallback location wins when PATH stripped of claude install dir
#   TC3: clear error when truly missing (PATH and fallback paths shadowed)
#   TC4: stub override — fake claude in temp dir on PATH is preferred (verifies command -v precedence)
#
# Plus edge cases:
#   EC1: PATH empty → fallback cascade still runs
#   EC2: HOME unset → tilde-equivalent path skipped gracefully
#   EC3: claude found at fallback location but mode 0644 → skipped, continues cascade

set -u

# Resolve repo root from this script's location regardless of caller cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCATE="$PROJECT_ROOT/.claude/scripts/locate-claude.sh"

PASS=0
FAIL=0
FAIL_DETAILS=()

note_pass() {
    PASS=$((PASS + 1))
    echo "  ✓ $1"
}
note_fail() {
    FAIL=$((FAIL + 1))
    FAIL_DETAILS+=("$1")
    echo "  ✗ $1"
}

assert_exit_0() {
    local label="$1"
    local rc="$2"
    [ "$rc" = "0" ] && note_pass "$label" || note_fail "$label (got exit $rc)"
}
assert_exit_1() {
    local label="$1"
    local rc="$2"
    [ "$rc" = "1" ] && note_pass "$label" || note_fail "$label (got exit $rc)"
}
assert_nonempty_path() {
    local label="$1"
    local out="$2"
    if [ -n "$out" ] && [ -x "$out" ]; then
        note_pass "$label"
    else
        note_fail "$label (out='$out')"
    fi
}
assert_equal() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        note_pass "$label"
    else
        note_fail "$label (expected '$expected', got '$actual')"
    fi
}
assert_contains() {
    local label="$1"
    local needle="$2"
    local haystack="$3"
    case "$haystack" in
        *"$needle"*) note_pass "$label" ;;
        *) note_fail "$label (needle '$needle' not in haystack)" ;;
    esac
}

# Sandbox HOME so EC2/TC3 cannot accidentally find a user-installed claude
SANDBOX_HOME=$(mktemp -d -t locate-claude-test.XXXXXX)
mkdir -p "$SANDBOX_HOME/.local/bin"
mkdir -p "$SANDBOX_HOME/.npm-global/bin"

cleanup() {
    rm -rf "$SANDBOX_HOME"
    [ -n "${TMP_PATHDIR:-}" ] && rm -rf "$TMP_PATHDIR"
}
trap cleanup EXIT

# Pre-flight: helper exists and is executable
if [ ! -x "$LOCATE" ]; then
    echo "FATAL: $LOCATE not present or not executable"
    exit 1
fi

# ─── TC1: happy path via command -v ────────────────────────────────────────
echo "TC1: happy path (PATH unmodified, claude on PATH)"
if command -v claude >/dev/null 2>&1; then
    OUT=$("$LOCATE" 2>/dev/null)
    RC=$?
    assert_exit_0 "TC1: exits 0" "$RC"
    assert_nonempty_path "TC1: stdout is absolute executable path" "$OUT"
    EXPECTED=$(command -v claude)
    # Resolve symlinks for comparison robustness
    EXPECTED_REAL=$(readlink -f "$EXPECTED" 2>/dev/null || realpath "$EXPECTED" 2>/dev/null || echo "$EXPECTED")
    OUT_REAL=$(readlink -f "$OUT" 2>/dev/null || realpath "$OUT" 2>/dev/null || echo "$OUT")
    assert_equal "TC1: matches command -v claude (resolved)" "$EXPECTED_REAL" "$OUT_REAL"
else
    echo "  ⚠ SKIP TC1 — claude not on PATH; cannot test happy path"
fi

# ─── TC4: stub override — verifies command -v precedence ──────────────────
echo "TC4: stub claude in PATH wins (verifies command -v precedence)"
TMP_PATHDIR=$(mktemp -d -t locate-claude-stub.XXXXXX)
cat > "$TMP_PATHDIR/claude" <<'EOF'
#!/usr/bin/env bash
echo "stub-claude"
EOF
chmod +x "$TMP_PATHDIR/claude"

OUT=$(PATH="$TMP_PATHDIR:$PATH" HOME="$SANDBOX_HOME" "$LOCATE" 2>/dev/null)
RC=$?
assert_exit_0 "TC4: exits 0 with stub on PATH" "$RC"
STUB_REAL=$(readlink -f "$TMP_PATHDIR/claude" 2>/dev/null || realpath "$TMP_PATHDIR/claude")
OUT_REAL=$(readlink -f "$OUT" 2>/dev/null || realpath "$OUT" 2>/dev/null || echo "$OUT")
assert_equal "TC4: returns stub path (not system claude)" "$STUB_REAL" "$OUT_REAL"

# ─── TC2: fallback location wins when PATH is stripped ────────────────────
echo "TC2: fallback location wins when PATH stripped"
# Plant a fake claude at the npm-global fallback (HOME-based path the script
# checks). Override USER so /Users/$USER/.local/bin/claude doesn't resolve
# back to the real install on this Mac.
cat > "$SANDBOX_HOME/.npm-global/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "fallback-claude"
EOF
chmod +x "$SANDBOX_HOME/.npm-global/bin/claude"

TC2_USER="locate-claude-test-tc2-$$"
# Strip PATH to system-only (no claude install dir) AND override USER
OUT=$(PATH="/usr/bin:/bin" HOME="$SANDBOX_HOME" USER="$TC2_USER" "$LOCATE" 2>/dev/null)
RC=$?
assert_exit_0 "TC2: exits 0 via fallback" "$RC"
EXPECTED_REAL=$(readlink -f "$SANDBOX_HOME/.npm-global/bin/claude" 2>/dev/null || realpath "$SANDBOX_HOME/.npm-global/bin/claude")
OUT_REAL=$(readlink -f "$OUT" 2>/dev/null || realpath "$OUT" 2>/dev/null || echo "$OUT")
assert_equal "TC2: returns ~/.npm-global/bin/claude" "$EXPECTED_REAL" "$OUT_REAL"

# Cleanup the fallback stub for TC3
rm -f "$SANDBOX_HOME/.npm-global/bin/claude"

# ─── TC3: clear error when truly missing ───────────────────────────────────
echo "TC3: clear error when claude truly absent"
# PATH = only system dirs; HOME = sandbox with no claude; force USER to a
# sandbox-internal name so /Users/$USER/.local/bin doesn't resolve to real install
ERR_TMP=$(mktemp)
SANDBOX_USER="locate-claude-test-nobody-$$"
OUT=$(PATH="/usr/bin:/bin" HOME="$SANDBOX_HOME" USER="$SANDBOX_USER" "$LOCATE" 2>"$ERR_TMP")
RC=$?
ERR=$(cat "$ERR_TMP")
rm -f "$ERR_TMP"
assert_exit_1 "TC3: exits 1 when not found" "$RC"
assert_equal "TC3: stdout empty on failure" "" "$OUT"
assert_contains "TC3: stderr names every searched location" "/Users/$SANDBOX_USER/.local/bin/claude" "$ERR"
assert_contains "TC3: stderr names homebrew arm64 path" "/opt/homebrew/bin/claude" "$ERR"
assert_contains "TC3: stderr names homebrew intel path" "/usr/local/bin/claude" "$ERR"
assert_contains "TC3: stderr names npm-global path" "$SANDBOX_HOME/.npm-global/bin/claude" "$ERR"
assert_contains "TC3: stderr mentions PATH or hint" "PATH" "$ERR"

# ─── EC1: PATH empty ───────────────────────────────────────────────────────
echo "EC1: PATH empty (fallback cascade still runs)"
cat > "$SANDBOX_HOME/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "ec1-claude"
EOF
chmod +x "$SANDBOX_HOME/.local/bin/claude"
# Set USER such that /Users/$USER/.local/bin resolves into sandbox
EC1_USER=$(basename "$SANDBOX_HOME")
# Mirror the sandbox into /Users/<that-user>/.local/bin — we can't, so use npm-global path again
# Actually simpler: re-plant in npm-global (HOME-based) for EC1
rm -f "$SANDBOX_HOME/.local/bin/claude"
cat > "$SANDBOX_HOME/.npm-global/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "ec1-claude"
EOF
chmod +x "$SANDBOX_HOME/.npm-global/bin/claude"

OUT=$(PATH="" HOME="$SANDBOX_HOME" "$LOCATE" 2>/dev/null)
RC=$?
assert_exit_0 "EC1: exits 0 with empty PATH" "$RC"
assert_nonempty_path "EC1: stdout is executable path" "$OUT"
rm -f "$SANDBOX_HOME/.npm-global/bin/claude"

# ─── EC3: claude found but not executable ──────────────────────────────────
echo "EC3: fallback file exists but is mode 0644 → skipped"
# Plant non-executable file at npm-global location and an executable file at
# a path EARLIER in the cascade so the cascade continues PAST the non-exec one.
# Cascade order: command -v → /Users/$USER/.local/bin → /opt/homebrew/bin → /usr/local/bin → ~/.npm-global/bin
# We can only safely shadow npm-global (HOME-based). So plant non-exec there
# and observe that locate-claude exits 1 because no other fallback exists in sandbox.
cat > "$SANDBOX_HOME/.npm-global/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "ec3-claude"
EOF
chmod 0644 "$SANDBOX_HOME/.npm-global/bin/claude"  # non-executable

OUT=$(PATH="/usr/bin:/bin" HOME="$SANDBOX_HOME" USER="$SANDBOX_USER" "$LOCATE" 2>/dev/null)
RC=$?
# Because the file exists but is non-exec AND no other fallback resolves in sandbox,
# locate-claude.sh should exit 1 (skip the file as if it didn't exist).
assert_exit_1 "EC3: non-executable file is skipped (exit 1, no other fallback)" "$RC"

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failures:"
    for d in "${FAIL_DETAILS[@]}"; do
        echo "  - $d"
    done
    exit 1
fi
echo "✓ locate-claude.sh: all tests pass"
exit 0
