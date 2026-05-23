#!/bin/bash
# Unit tests for pwt-conflict-detector.sh
#
# Test isolation: every test that exercises any path touching the cross-repo
# claims registry sets PWT_RAM_CLAIMS_REGISTRY to a temp file. The detector
# itself does NOT touch the registry, but we set the override defensively so
# that any integration call (ram-budget, fair-share) cannot pollute production.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR="$SCRIPT_DIR/pwt-conflict-detector.sh"

[ -x "$DETECTOR" ] || { echo "FATAL: $DETECTOR not executable"; exit 1; }

# ─── Test isolation ──────────────────────────────────────────────────────────
TMP_REG=$(mktemp -t pwt-cd-test-reg.XXXXXX)
export PWT_RAM_CLAIMS_REGISTRY="$TMP_REG"
TEST_TMP=$(mktemp -d -t pwt-cd-test.XXXXXX)
trap 'rm -rf "$TEST_TMP" "$TMP_REG"' EXIT

PASS=0
FAIL=0
FAILURES=""

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$(( PASS + 1 ))
        echo "  ✓ $label"
    else
        FAIL=$(( FAIL + 1 ))
        FAILURES+="  ✗ $label\n    needle: $needle\n    got: $haystack\n"
        echo "  ✗ $label"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$(( FAIL + 1 ))
        FAILURES+="  ✗ $label\n    unwanted needle: $needle\n    got: $haystack\n"
        echo "  ✗ $label"
    else
        PASS=$(( PASS + 1 ))
        echo "  ✓ $label"
    fi
}

# ─── Test 1: disjoint directives → each task its own group ───────────────────
echo "Test 1: disjoint directives"
T1A="$TEST_TMP/t1a.md"; T1B="$TEST_TMP/t1b.md"
cat > "$T1A" <<'EOF'
Edit .claude/scripts/foo.sh only.
EOF
cat > "$T1B" <<'EOF'
Edit .claude/scripts/bar.sh only.
EOF
OUT=$("$DETECTOR" "$T1A" "$T1B")
# Two groups, each with one task. No reasons should mention sharing.
assert_contains "$OUT" '"parallel_safe_groups": [["t1a"], ["t1b"]]' "two singleton groups"
assert_contains "$OUT" '"t1a": []' "t1a has no reasons"
assert_contains "$OUT" '"t1b": []' "t1b has no reasons"

# ─── Test 2: overlapping directives → merged into one group ──────────────────
echo "Test 2: overlapping directives"
T2A="$TEST_TMP/t2a.md"; T2B="$TEST_TMP/t2b.md"
cat > "$T2A" <<'EOF'
Modify shared/supervisor-protocol.md to add CAPACITY CHECK.
EOF
cat > "$T2B" <<'EOF'
Edit shared/supervisor-protocol.md POLLING LOOP for new event.
EOF
OUT=$("$DETECTOR" "$T2A" "$T2B")
assert_contains "$OUT" '"parallel_safe_groups": [["t2a", "t2b"]]' "single group with both tasks"
assert_contains "$OUT" 'shared file shared/supervisor-protocol.md with task t2b' "t2a reasons cite t2b"
assert_contains "$OUT" 'shared file shared/supervisor-protocol.md with task t2a' "t2b reasons cite t2a"

# ─── Test 3: transitive closure A↔B, B↔C ⇒ {A,B,C} one group ─────────────────
echo "Test 3: transitive closure"
T3A="$TEST_TMP/t3a.md"; T3B="$TEST_TMP/t3b.md"; T3C="$TEST_TMP/t3c.md"
cat > "$T3A" <<'EOF'
Edit .claude/scripts/alpha.sh
EOF
cat > "$T3B" <<'EOF'
Edit .claude/scripts/alpha.sh and .claude/scripts/beta.sh
EOF
cat > "$T3C" <<'EOF'
Edit .claude/scripts/beta.sh
EOF
OUT=$("$DETECTOR" "$T3A" "$T3B" "$T3C")
# A and C don't share, but they're both linked to B → one transitive group.
assert_contains "$OUT" '"parallel_safe_groups": [["t3a", "t3b", "t3c"]]' "transitive group of three"

# ─── Test 4: three-task mix — two share, one disjoint (E2E acceptance shape) ─
echo "Test 4: three-task mix (AC5 shape)"
TA="$TEST_TMP/A.md"; TB="$TEST_TMP/B.md"; TC="$TEST_TMP/C.md"
cat > "$TA" <<'EOF'
Edit shared/supervisor-protocol.md POLLING LOOP.
EOF
cat > "$TB" <<'EOF'
Update shared/supervisor-protocol.md hard rules.
EOF
cat > "$TC" <<'EOF'
Touch docs/specs/standalone.md only.
EOF
OUT=$("$DETECTOR" "$TA" "$TB" "$TC")
# Group containing A+B exists; C is its own group.
assert_contains "$OUT" '["A", "B"]' "A and B grouped"
assert_contains "$OUT" '["C"]' "C alone"
assert_contains "$OUT" '"C": []' "C has no reasons"

# ─── Test 5: empty directive → unknown scope, parallel-safe ──────────────────
echo "Test 5: empty directive (unknown scope)"
T5A="$TEST_TMP/empty.md"; T5B="$TEST_TMP/scoped.md"
cat > "$T5A" <<'EOF'
A vague directive with no recognized path patterns. Just prose.
EOF
cat > "$T5B" <<'EOF'
Edit .claude/scripts/zeta.sh
EOF
OUT=$("$DETECTOR" "$T5A" "$T5B")
assert_contains "$OUT" '"tasks_with_unknown_scope": ["empty"]' "empty.md flagged unknown-scope"
# Empty file-set never intersects, so it remains parallel-safe — own group.
assert_contains "$OUT" '["empty"]' "empty as own group"
assert_contains "$OUT" '["scoped"]' "scoped as own group"

# ─── Test 6: unreadable directive → skipped, fail-open ──────────────────────
echo "Test 6: unreadable directive"
T6A="$TEST_TMP/exists.md"
NONEXISTENT="$TEST_TMP/does-not-exist.md"
cat > "$T6A" <<'EOF'
Edit shared/x.md
EOF
OUT=$("$DETECTOR" "$T6A" "$NONEXISTENT" 2>/dev/null)
assert_contains "$OUT" '"skipped": ["does-not-exist"]' "missing file in skipped list"
assert_contains "$OUT" '["exists"]' "readable directive still grouped"

# ─── Test 7: no args → empty advisory JSON, exit 0 ───────────────────────────
echo "Test 7: no args"
OUT=$("$DETECTOR")
RC=$?
assert_contains "$OUT" '"parallel_safe_groups": []' "empty groups on no args"
if [ "$RC" -eq 0 ]; then PASS=$((PASS+1)); echo "  ✓ exit 0 on no args"
else FAIL=$((FAIL+1)); FAILURES+="  ✗ exit 0 on no args (got $RC)\n"; echo "  ✗ exit 0 on no args (got $RC)"; fi

# ─── Test 8: registry isolation — production registry untouched ──────────────
echo "Test 8: production registry isolation"
PROD_BEFORE=""
PROD_REG="$HOME/.claude/state/pwt-ram-claims.jsonl"
if [ -f "$PROD_REG" ]; then
    PROD_BEFORE=$(wc -c < "$PROD_REG" 2>/dev/null || echo "")
fi
# Run a normal invocation; PWT_RAM_CLAIMS_REGISTRY is overridden via env above.
T8="$TEST_TMP/t8.md"
echo "Edit shared/foo.md" > "$T8"
"$DETECTOR" "$T8" > /dev/null
PROD_AFTER=""
if [ -f "$PROD_REG" ]; then
    PROD_AFTER=$(wc -c < "$PROD_REG" 2>/dev/null || echo "")
fi
if [ "$PROD_BEFORE" = "$PROD_AFTER" ]; then
    PASS=$((PASS+1)); echo "  ✓ production registry size unchanged"
else
    FAIL=$((FAIL+1))
    FAILURES+="  ✗ production registry size changed: '$PROD_BEFORE' → '$PROD_AFTER'\n"
    echo "  ✗ production registry size changed"
fi

# ─── Test 9: PWT_RAM_CLAIMS_REGISTRY override is honoured in env ─────────────
echo "Test 9: env override respected"
# Sanity: the test process must have the override set; assertions in tests 1–8
# inherit it. Verify directly.
if [ "${PWT_RAM_CLAIMS_REGISTRY:-}" = "$TMP_REG" ]; then
    PASS=$((PASS+1)); echo "  ✓ PWT_RAM_CLAIMS_REGISTRY points to test temp"
else
    FAIL=$((FAIL+1))
    FAILURES+="  ✗ env override not set: '$PWT_RAM_CLAIMS_REGISTRY' != '$TMP_REG'\n"
    echo "  ✗ env override not set"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "─────────────────────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo
    echo "Failures:"
    printf '%b' "$FAILURES"
    exit 1
fi
exit 0
