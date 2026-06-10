#!/bin/bash
# pwt-claims-cleanup.test — verify pwt-claims-cleanup.sh removes test-pattern
# and orphan-SID rows while preserving real entries.
#
# Run directly: bash .claude/scripts/pwt-claims-cleanup.test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEANUP="$SCRIPT_DIR/pwt-claims-cleanup.sh"

if [ ! -x "$CLEANUP" ]; then
    echo "FAIL: cleanup script not executable at $CLEANUP" >&2
    exit 1
fi

PASS=0
FAIL=0
TOTAL=0

# Hermetic isolation (fixes intermittent in-suite failure): pin the projects dir
# to an empty sandbox so the claude-agents-extended.sh wrapper — reached via
# pwt-claims-cleanup.sh's live-SID lookup — finds NO live subagents on the host.
# Without this, concurrent sessions' subagents (a running /plan-w-team or a
# Workflow fan-out) leak their SIDs into the "live" set, so orphan-removal
# assertions pass standalone but fail intermittently inside a full `make
# test-skill` run during live pwt activity. The PATH-injected fake `claude`
# remains the only live-SID source. (SUBAGENT_FRESHNESS_SEC=0 is belt-and-braces.)
EMPTY_PROJECTS=$(mktemp -d)
export CLAUDE_PROJECTS_DIR="$EMPTY_PROJECTS"
export SUBAGENT_FRESHNESS_SEC=0
trap 'rm -rf "$EMPTY_PROJECTS"' EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  ✓ %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf '  ✗ %s\n     expected: %s\n     actual:   %s\n' "$label" "$expected" "$actual"
    fi
}

assert_grep() {
    local label="$1" needle="$2" file="$3"
    TOTAL=$((TOTAL + 1))
    if grep -qF "$needle" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        printf '  ✓ %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf '  ✗ %s\n     missing %q from %s\n' "$label" "$needle" "$file"
    fi
}

assert_not_grep() {
    local label="$1" needle="$2" file="$3"
    TOTAL=$((TOTAL + 1))
    if grep -qF "$needle" "$file" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        printf '  ✗ %s\n     found %q in %s\n' "$label" "$needle" "$file"
    else
        PASS=$((PASS + 1))
        printf '  ✓ %s\n' "$label"
    fi
}

# Build a "claude" stub that returns the given SIDs (one per arg) as live, then
# prepend its dir to PATH so the cleanup script sees a working but predictable
# `claude agents --json`. Returns the bin dir path on stdout.
make_fake_claude_with_sids() {
    local fakedir
    fakedir=$(mktemp -d)
    {
        echo '#!/bin/bash'
        echo 'if [ "$1" = "agents" ] && [ "$2" = "--json" ]; then'
        echo '  printf "[\n"'
        local first=1
        for sid in "$@"; do
            if [ "$first" = 1 ]; then first=0; else echo '  printf ",\n"'; fi
            echo "  printf '  {\"sessionId\": \"$sid\", \"status\": \"running\"}'"
        done
        echo '  printf "\n]\n"'
        echo '  exit 0'
        echo 'fi'
        echo 'exit 1'
    } > "$fakedir/claude"
    chmod +x "$fakedir/claude"
    printf '%s' "$fakedir"
}

# Build a "claude" stub that always fails — simulates claude not being usable.
# Returns the bin dir path on stdout.
make_failing_claude() {
    local fakedir
    fakedir=$(mktemp -d)
    cat > "$fakedir/claude" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$fakedir/claude"
    printf '%s' "$fakedir"
}

# ─── Test 1: pure test-pattern pollution removed (orphan check disabled) ─────
echo "TEST 1: removes plan-w-team-test.*, pwt-shim-*, sandbox-* repos"
TMP1=$(mktemp -d)
REG1="$TMP1/registry.jsonl"
cat > "$REG1" <<EOF
{"repo":"plan-w-team-test.aaaaaa","sid":"deadbeef","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"plan-w-team-test.bbbbbb","sid":"cafef00d","started_at":"2026-05-22T00:00:01Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"pwt-shim-XXXXXX.zzzzzz","sid":"11111111","started_at":"2026-05-22T00:00:02Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"sandbox-foo","sid":"22222222","started_at":"2026-05-22T00:00:03Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"claude-pattern","sid":"33333333","started_at":"2026-05-22T00:00:04Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"cleanscale","sid":"44444444","started_at":"2026-05-22T00:00:05Z","estimated_gb":1.8,"priority":"normal"}
EOF

# Use a failing claude stub so HAS_LIVE_SIDS=0 (test-pattern path only).
FAKEDIR1=$(make_failing_claude)
PATH_SAVED="$PATH"
PATH="$FAKEDIR1:$PATH"
PWT_RAM_CLAIMS_PATH="$REG1" "$CLEANUP" --quiet
EXIT1=$?
PATH="$PATH_SAVED"
rm -rf "$FAKEDIR1"

assert_eq "exit code 0 on successful cleanup" "0" "$EXIT1"
assert_eq "registry shrank to 2 real entries" "2" "$(wc -l < "$REG1" | tr -d ' ')"
assert_grep "real entry claude-pattern preserved" '"repo":"claude-pattern"' "$REG1"
assert_grep "real entry cleanscale preserved" '"repo":"cleanscale"' "$REG1"
assert_not_grep "test-pattern plan-w-team-test removed" 'plan-w-team-test' "$REG1"
assert_not_grep "shim-pattern pwt-shim removed" 'pwt-shim' "$REG1"
assert_not_grep "sandbox-pattern sandbox- removed" 'sandbox-' "$REG1"
rm -rf "$TMP1"

# ─── Test 2: no-op when registry is empty / missing ──────────────────────────
echo "TEST 2: empty/missing registry no-op"
TMP2=$(mktemp -d)
REG2="$TMP2/nonexistent.jsonl"
PWT_RAM_CLAIMS_PATH="$REG2" "$CLEANUP" --quiet
EXIT2=$?
assert_eq "exit 0 when registry missing" "0" "$EXIT2"
assert_eq "no file created" "0" "$([ -e "$REG2" ] && echo 1 || echo 0)"

REG2B="$TMP2/empty.jsonl"
: > "$REG2B"
PWT_RAM_CLAIMS_PATH="$REG2B" "$CLEANUP" --quiet
EXIT2B=$?
assert_eq "exit 0 when registry empty" "0" "$EXIT2B"
assert_eq "registry still empty" "0" "$(wc -l < "$REG2B" | tr -d ' ')"
rm -rf "$TMP2"

# ─── Test 3: --dry-run does not modify ───────────────────────────────────────
echo "TEST 3: --dry-run preserves registry"
TMP3=$(mktemp -d)
REG3="$TMP3/registry.jsonl"
cat > "$REG3" <<EOF
{"repo":"plan-w-team-test.cccccc","sid":"55555555","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"claude-pattern","sid":"66666666","started_at":"2026-05-22T00:00:01Z","estimated_gb":1.8,"priority":"normal"}
EOF
ORIG_LINES=$(wc -l < "$REG3" | tr -d ' ')

FAKEDIR3=$(make_failing_claude)
PATH_SAVED="$PATH"
PATH="$FAKEDIR3:$PATH"
PWT_RAM_CLAIMS_PATH="$REG3" "$CLEANUP" --dry-run --quiet
EXIT3=$?
PATH="$PATH_SAVED"
rm -rf "$FAKEDIR3"

assert_eq "exit 0 from --dry-run" "0" "$EXIT3"
assert_eq "dry-run preserved all $ORIG_LINES lines" "$ORIG_LINES" "$(wc -l < "$REG3" | tr -d ' ')"
assert_grep "dry-run still has test-pattern entry" 'plan-w-team-test.cccccc' "$REG3"
rm -rf "$TMP3"

# ─── Test 4: orphan-SID removal with mocked `claude agents --json` ───────────
echo "TEST 4: orphan-SID removal when claude lists only some SIDs as alive"
TMP4=$(mktemp -d)
REG4="$TMP4/registry.jsonl"
cat > "$REG4" <<EOF
{"repo":"claude-pattern","sid":"a11ce001","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"claude-pattern","sid":"dead0001","started_at":"2026-05-22T00:00:01Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"cleanscale","sid":"a11ce002","started_at":"2026-05-22T00:00:02Z","estimated_gb":1.8,"priority":"normal"}
EOF

FAKEDIR4=$(make_fake_claude_with_sids a11ce001 a11ce002)
PATH_SAVED="$PATH"
PATH="$FAKEDIR4:$PATH"
PWT_RAM_CLAIMS_PATH="$REG4" "$CLEANUP" --quiet
EXIT4=$?
PATH="$PATH_SAVED"
rm -rf "$FAKEDIR4"

assert_eq "exit 0 with mocked claude" "0" "$EXIT4"
assert_eq "registry shrank to 2 alive entries" "2" "$(wc -l < "$REG4" | tr -d ' ')"
assert_grep "a11ce001 preserved" '"sid":"a11ce001"' "$REG4"
assert_grep "a11ce002 preserved" '"sid":"a11ce002"' "$REG4"
assert_not_grep "dead0001 removed (orphan SID)" '"sid":"dead0001"' "$REG4"
rm -rf "$TMP4"

# ─── Test 5: PWT_RAM_CLAIMS_REGISTRY legacy alias still honored ──────────────
echo "TEST 5: legacy PWT_RAM_CLAIMS_REGISTRY env still works"
TMP5=$(mktemp -d)
REG5="$TMP5/legacy.jsonl"
cat > "$REG5" <<EOF
{"repo":"plan-w-team-test.dddddd","sid":"77777777","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"real-repo","sid":"88888888","started_at":"2026-05-22T00:00:01Z","estimated_gb":1.8,"priority":"normal"}
EOF

FAKEDIR5=$(make_failing_claude)
PATH_SAVED="$PATH"
PATH="$FAKEDIR5:$PATH"
unset PWT_RAM_CLAIMS_PATH
PWT_RAM_CLAIMS_REGISTRY="$REG5" "$CLEANUP" --quiet
EXIT5=$?
PATH="$PATH_SAVED"
rm -rf "$FAKEDIR5"

assert_eq "exit 0 with legacy env" "0" "$EXIT5"
assert_eq "legacy registry shrank to 1" "1" "$(wc -l < "$REG5" | tr -d ' ')"
assert_grep "legacy env real-repo preserved" '"repo":"real-repo"' "$REG5"
rm -rf "$TMP5"

# ─── Test 6: PWT_RAM_CLAIMS_PATH takes precedence over legacy alias ──────────
echo "TEST 6: PWT_RAM_CLAIMS_PATH wins over PWT_RAM_CLAIMS_REGISTRY"
TMP6=$(mktemp -d)
REG_PATH="$TMP6/path-target.jsonl"
REG_LEGACY="$TMP6/legacy-target.jsonl"
cat > "$REG_PATH" <<EOF
{"repo":"plan-w-team-test.eeeeee","sid":"99999999","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF
cat > "$REG_LEGACY" <<EOF
{"repo":"untouched","sid":"abcd1234","started_at":"2026-05-22T00:00:01Z","estimated_gb":1.8,"priority":"normal"}
EOF

FAKEDIR6=$(make_failing_claude)
PATH_SAVED="$PATH"
PATH="$FAKEDIR6:$PATH"
PWT_RAM_CLAIMS_PATH="$REG_PATH" PWT_RAM_CLAIMS_REGISTRY="$REG_LEGACY" "$CLEANUP" --quiet
EXIT6=$?
PATH="$PATH_SAVED"
rm -rf "$FAKEDIR6"

assert_eq "exit 0 with both env vars set" "0" "$EXIT6"
assert_eq "PATH target cleaned to 0 entries" "0" "$(wc -l < "$REG_PATH" | tr -d ' ')"
assert_eq "legacy target NOT touched (still 1 line)" "1" "$(wc -l < "$REG_LEGACY" | tr -d ' ')"
assert_grep "legacy target unchanged" '"repo":"untouched"' "$REG_LEGACY"
rm -rf "$TMP6"

# ─── Test 7: lock held by live process → fail-open skip, registry untouched ──
# Cleanup shares ${REGISTRY}.lock with pwt-ram-claim.sh remove/sweep. When the
# lock is held by a LIVE process, cleanup must NOT block the fair-share gate or
# rewrite the registry — it skips (fail-open, exit 0) and leaves every row,
# including removable test-pattern rows, in place.
echo "TEST 7: held lock (live owner) → cleanup skips fail-open, registry untouched"
TMP7=$(mktemp -d)
REG7="$TMP7/registry.jsonl"
cat > "$REG7" <<EOF
{"repo":"plan-w-team-test.ffffff","sid":"aaaa0001","started_at":"2026-06-09T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"claude-pattern","sid":"aaaa0002","started_at":"2026-06-09T00:00:01Z","estimated_gb":1.8,"priority":"normal"}
EOF
# Pre-acquire the lock as this (live) test process so stale-takeover can't fire.
mkdir "$REG7.lock"
echo "$$" > "$REG7.lock/pid"

FAKEDIR7=$(make_failing_claude)
PATH_SAVED="$PATH"
PATH="$FAKEDIR7:$PATH"
PWT_RAM_CLAIMS_PATH="$REG7" "$CLEANUP" --quiet 2>/dev/null
EXIT7=$?
PATH="$PATH_SAVED"
rm -rf "$FAKEDIR7"
rm -rf "$REG7.lock"

assert_eq "exit 0 despite held lock (fail-open)" "0" "$EXIT7"
assert_eq "registry untouched (still 2 lines)" "2" "$(wc -l < "$REG7" | tr -d ' ')"
assert_grep "removable test-pattern row NOT removed while locked" 'plan-w-team-test.ffffff' "$REG7"
rm -rf "$TMP7"

# ─── Test 8: concurrent pwt-ram-claim add during cleanup window survives ─────
# The X-coord-1 lost-update interleave: cleanup snapshot → concurrent add →
# cleanup mv clobbers the add. With the shared lock, a cleanup started while
# the lock is held blocks until release, so its snapshot INCLUDES the claim
# appended during the window — the add must survive the rewrite.
echo "TEST 8: claim added during cleanup's lock-wait window survives rewrite"
RAMCLAIM="$SCRIPT_DIR/pwt-ram-claim.sh"
if [ ! -x "$RAMCLAIM" ]; then
    echo "FAIL: pwt-ram-claim.sh not executable at $RAMCLAIM" >&2
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
else
    TMP8=$(mktemp -d)
    REG8="$TMP8/registry.jsonl"
    cat > "$REG8" <<EOF
{"repo":"plan-w-team-test.gggggg","sid":"bbbb0001","started_at":"2026-06-09T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"claude-pattern","sid":"bbbb0002","started_at":"2026-06-09T00:00:01Z","estimated_gb":1.8,"priority":"normal"}
EOF
    # Hold the lock (live owner) so the background cleanup blocks in acquire_lock.
    mkdir "$REG8.lock"
    echo "$$" > "$REG8.lock/pid"

    FAKEDIR8=$(make_failing_claude)
    PATH_SAVED="$PATH"
    PATH="$FAKEDIR8:$PATH"
    PWT_RAM_CLAIMS_PATH="$REG8" "$CLEANUP" --quiet 2>/dev/null &
    CLEANUP_PID=$!
    PATH="$PATH_SAVED"

    # While cleanup is blocked on the lock, append a new claim (add is
    # lock-free / append-only — exactly the racing writer from the finding).
    sleep 0.5
    PWT_RAM_CLAIMS_PATH="$REG8" "$RAMCLAIM" add concurrent-repo cccc0003 2>/dev/null

    # Release the lock well inside cleanup's retry budget, then let it finish.
    rm -rf "$REG8.lock"
    wait "$CLEANUP_PID"
    EXIT8=$?
    rm -rf "$FAKEDIR8"

    assert_eq "exit 0 after lock released" "0" "$EXIT8"
    assert_eq "registry has 2 surviving rows" "2" "$(wc -l < "$REG8" | tr -d ' ')"
    assert_grep "pre-existing real entry preserved" '"repo":"claude-pattern"' "$REG8"
    assert_grep "concurrently-added claim survived rewrite" '"repo":"concurrent-repo"' "$REG8"
    assert_not_grep "test-pattern row removed once unlocked" 'plan-w-team-test.gggggg' "$REG8"
    rm -rf "$TMP8"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "─────────────────────────────────────────"
printf "RESULTS: %d/%d passed, %d failed\n" "$PASS" "$TOTAL" "$FAIL"
echo "─────────────────────────────────────────"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
