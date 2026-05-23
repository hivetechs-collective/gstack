#!/bin/bash
# Tests for pwt-fair-share.sh — cross-repo allocation math, idle yield, priority.
#
# Run: bash .claude/scripts/pwt-fair-share.test.sh
#
# Test framework: minimal — assert_eq + assert_contains. Same pattern as
# ram-budget.test.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FAIR_SHARE="$SCRIPT_DIR/pwt-fair-share.sh"
CLAIM="$SCRIPT_DIR/pwt-ram-claim.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  ✓ $label"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$label")
        echo "  ✗ $label"
        echo "    expected: $expected"
        echo "    actual:   $actual"
    fi
}

assert_contains() {
    local label="$1"
    local needle="$2"
    local haystack="$3"
    case "$haystack" in
        *"$needle"*)
            PASS=$((PASS + 1))
            echo "  ✓ $label"
            ;;
        *)
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("$label")
            echo "  ✗ $label"
            echo "    expected substring: $needle"
            echo "    in: $haystack"
            ;;
    esac
}

get_field() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" \
        | grep -oE "\"${key}\": *[^,}]*" \
        | head -1 \
        | sed -E "s/.*\"${key}\": *//; s/\"//g; s/^ *//; s/ *$//"
}

# ─── Test 1: empty registry → SPAWN_OK, fair_share == capacity ───────────────
echo "Test 1: empty registry"
TMP_REG=$(mktemp)
OUT=$(PWT_FAIR_SHARE_STUB_REGISTRY="$TMP_REG" \
      PWT_FAIR_SHARE_STUB_CAPACITY=4 \
      PWT_FAIR_SHARE_MY_REPO=test-repo \
      "$FAIR_SHARE")
assert_eq "1a recommendation=SPAWN_OK" "SPAWN_OK" "$(get_field "$OUT" recommendation)"
assert_eq "1b fair_share_per_repo=4"   "4"        "$(get_field "$OUT" fair_share_per_repo)"
assert_eq "1c my_repo_current=0"       "0"        "$(get_field "$OUT" my_repo_current)"
assert_eq "1d n_active_repos=1"        "1"        "$(get_field "$OUT" n_active_repos)"
rm -f "$TMP_REG"

# ─── Test 2: greedy repo, my_repo is the asker (different repo) ─────────────
echo "Test 2: greedy repo-a has 3, my (repo-b) asks → SPAWN_OK with fair_share=2"
TMP_REG=$(mktemp)
cat > "$TMP_REG" <<EOF
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa33333","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF
OUT=$(PWT_FAIR_SHARE_STUB_REGISTRY="$TMP_REG" \
      PWT_FAIR_SHARE_STUB_CAPACITY=1 \
      PWT_FAIR_SHARE_MY_REPO=repo-b \
      PWT_FAIR_SHARE_IDLE_THRESHOLD=0 \
      "$FAIR_SHARE")
assert_eq "2a recommendation=SPAWN_OK" "SPAWN_OK" "$(get_field "$OUT" recommendation)"
# machine_capacity = remaining(1) + active(3) = 4 ; n_active_repos = 2 (a + asker b)
assert_eq "2b fair_share_per_repo=2"   "2"        "$(get_field "$OUT" fair_share_per_repo)"
assert_eq "2c my_repo_current=0"       "0"        "$(get_field "$OUT" my_repo_current)"
assert_eq "2d my_repo_allowed_max=2"   "2"        "$(get_field "$OUT" my_repo_allowed_max)"
rm -f "$TMP_REG"

# ─── Test 3: greedy repo-a asks for 4th when another repo (b) is underserved ─
echo "Test 3: repo-a has 3 + repo-b has 0; repo-a asks for #4 → YIELD"
TMP_REG=$(mktemp)
cat > "$TMP_REG" <<EOF
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa33333","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-b","sid":"bbb11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF
OUT=$(PWT_FAIR_SHARE_STUB_REGISTRY="$TMP_REG" \
      PWT_FAIR_SHARE_STUB_CAPACITY=0 \
      PWT_FAIR_SHARE_MY_REPO=repo-a \
      PWT_FAIR_SHARE_IDLE_THRESHOLD=0 \
      "$FAIR_SHARE")
# machine_capacity = remaining(0) + active(4) = 4 ; n_active_repos = 2 ; fair = 2
# repo-a has 3 (> 2), repo-b has 1 (< 2). repo-a is the asker and is over share
# while repo-b is under → YIELD.
assert_eq "3a recommendation=YIELD_TO_OTHER_REPO" "YIELD_TO_OTHER_REPO" "$(get_field "$OUT" recommendation)"
assert_eq "3b fair_share_per_repo=2"              "2"                   "$(get_field "$OUT" fair_share_per_repo)"
assert_eq "3c my_repo_current=3"                  "3"                   "$(get_field "$OUT" my_repo_current)"
rm -f "$TMP_REG"

# ─── Test 4: priority=critical bypasses fair-share ──────────────────────────
echo "Test 4: same scenario as #3 but PRIORITY=critical → SPAWN_OK"
TMP_REG=$(mktemp)
cat > "$TMP_REG" <<EOF
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa33333","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-b","sid":"bbb11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF
OUT=$(PWT_FAIR_SHARE_STUB_REGISTRY="$TMP_REG" \
      PWT_FAIR_SHARE_STUB_CAPACITY=0 \
      PWT_FAIR_SHARE_MY_REPO=repo-a \
      PWT_FAIR_SHARE_IDLE_THRESHOLD=0 \
      PWT_RUN_PRIORITY=critical \
      "$FAIR_SHARE")
assert_eq "4a recommendation=SPAWN_OK" "SPAWN_OK" "$(get_field "$OUT" recommendation)"
assert_eq "4b priority=critical"       "critical" "$(get_field "$OUT" priority)"
rm -f "$TMP_REG"

# ─── Test 5: priority=background yields under contention ────────────────────
echo "Test 5: background priority + at-capacity → YIELD"
TMP_REG=$(mktemp)
cat > "$TMP_REG" <<EOF
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF
OUT=$(PWT_FAIR_SHARE_STUB_REGISTRY="$TMP_REG" \
      PWT_FAIR_SHARE_STUB_CAPACITY=0 \
      PWT_FAIR_SHARE_MY_REPO=repo-c \
      PWT_FAIR_SHARE_IDLE_THRESHOLD=0 \
      PWT_RUN_PRIORITY=background \
      "$FAIR_SHARE")
# machine_capacity = 2 ; n_total_active = 2 ; >= machine_capacity → background yields
assert_eq "5a background yields" "YIELD_TO_OTHER_REPO" "$(get_field "$OUT" recommendation)"
rm -f "$TMP_REG"

# ─── Test 6: AT_FAIR_SHARE when every repo is at exact share ────────────────
echo "Test 6: balanced state → AT_FAIR_SHARE for asker at share"
TMP_REG=$(mktemp)
cat > "$TMP_REG" <<EOF
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-b","sid":"bbb11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-b","sid":"bbb22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF
OUT=$(PWT_FAIR_SHARE_STUB_REGISTRY="$TMP_REG" \
      PWT_FAIR_SHARE_STUB_CAPACITY=0 \
      PWT_FAIR_SHARE_MY_REPO=repo-a \
      PWT_FAIR_SHARE_IDLE_THRESHOLD=0 \
      "$FAIR_SHARE")
# machine_capacity=4 ; n_active=2 ; fair=2 ; a has 2 (= fair), b has 2 (= fair)
# repo-a is at share, repo-b is not underserved → AT_FAIR_SHARE
assert_eq "6a AT_FAIR_SHARE" "AT_FAIR_SHARE" "$(get_field "$OUT" recommendation)"
rm -f "$TMP_REG"

# ─── Test 7: idle yield — claim with stale transcript excluded ──────────────
echo "Test 7: idle worker (>5min) excluded from active count"
TMP_REG=$(mktemp)
TMP_MT=$(mktemp)
cat > "$TMP_REG" <<EOF
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF
# now = 1000000; aaa11111 active (recent mtime), aaa22222 idle (>5min old)
NOW_FAKE=1000000
cat > "$TMP_MT" <<EOF
aaa11111 999900
aaa22222 999000
EOF
OUT=$(PWT_FAIR_SHARE_STUB_REGISTRY="$TMP_REG" \
      PWT_FAIR_SHARE_STUB_CAPACITY=4 \
      PWT_FAIR_SHARE_MY_REPO=repo-b \
      PWT_FAIR_SHARE_IDLE_THRESHOLD=300 \
      PWT_FAIR_SHARE_STUB_NOW=$NOW_FAKE \
      PWT_FAIR_SHARE_STUB_TRANSCRIPT_MTIME="$TMP_MT" \
      "$FAIR_SHARE")
# Only aaa11111 counted → repos_with_active_workers = {"repo-a": 1}
assert_contains "7a only one repo-a worker counted" '"repo-a": 1' "$OUT"
rm -f "$TMP_REG" "$TMP_MT"

# ─── Test 8: pwt-ram-claim.sh add/remove round-trip ─────────────────────────
echo "Test 8: claim add/remove round-trip"
TMP_REG=$(mktemp)
PWT_RAM_CLAIMS_REGISTRY="$TMP_REG" "$CLAIM" add repo-x sidxxxxx normal
PWT_RAM_CLAIMS_REGISTRY="$TMP_REG" "$CLAIM" add repo-x sidyyyyy critical
COUNT_BEFORE=$(wc -l < "$TMP_REG" | tr -d ' ')
assert_eq "8a 2 rows after 2 adds" "2" "$COUNT_BEFORE"
PWT_RAM_CLAIMS_REGISTRY="$TMP_REG" "$CLAIM" remove sidxxxxx
COUNT_AFTER=$(wc -l < "$TMP_REG" | tr -d ' ')
assert_eq "8b 1 row after 1 remove" "1" "$COUNT_AFTER"
LIST_OUT=$(PWT_RAM_CLAIMS_REGISTRY="$TMP_REG" "$CLAIM" list)
assert_contains "8c remaining row has sidyyyyy" "sidyyyyy" "$LIST_OUT"
rm -f "$TMP_REG"

# ─── Test 9: sweep removes idle claims ───────────────────────────────────────
echo "Test 9: sweep removes idle claims"
TMP_REG=$(mktemp)
TMP_MT=$(mktemp)
cat > "$TMP_REG" <<EOF
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
{"repo":"repo-a","sid":"aaa22222","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}
EOF
cat > "$TMP_MT" <<EOF
aaa11111 999900
aaa22222 999000
EOF
PWT_RAM_CLAIMS_REGISTRY="$TMP_REG" \
  PWT_FAIR_SHARE_IDLE_THRESHOLD=300 \
  PWT_FAIR_SHARE_STUB_NOW=1000000 \
  PWT_FAIR_SHARE_STUB_TRANSCRIPT_MTIME="$TMP_MT" \
  "$CLAIM" sweep 2>/dev/null
COUNT_POST=$(wc -l < "$TMP_REG" | tr -d ' ')
assert_eq "9a sweep leaves 1 fresh row" "1" "$COUNT_POST"
SWEEPED=$(cat "$TMP_REG")
assert_contains "9b survivor is aaa11111" "aaa11111" "$SWEEPED"
rm -f "$TMP_REG" "$TMP_MT"

# ─── Test 10: malformed line tolerated (skipped, not crash) ─────────────────
echo "Test 10: malformed registry line is skipped, not fatal"
TMP_REG=$(mktemp)
cat > "$TMP_REG" <<EOF
this is not json
{"repo":"repo-a","sid":"aaa11111","started_at":"2026-05-22T00:00:00Z","estimated_gb":1.8,"priority":"normal"}

EOF
OUT=$(PWT_FAIR_SHARE_STUB_REGISTRY="$TMP_REG" \
      PWT_FAIR_SHARE_STUB_CAPACITY=4 \
      PWT_FAIR_SHARE_MY_REPO=repo-b \
      PWT_FAIR_SHARE_IDLE_THRESHOLD=0 \
      "$FAIR_SHARE")
# repo-a should still be detected; malformed line silently skipped
assert_contains "10a repo-a still counted" '"repo-a": 1' "$OUT"
rm -f "$TMP_REG"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────"
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failed:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
exit 0
