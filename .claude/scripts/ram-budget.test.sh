#!/bin/bash
# ram-budget.test.sh — test harness for .claude/scripts/ram-budget.sh
#
# Uses RAM_BUDGET_STUB_* env vars (documented at the top of ram-budget.sh)
# to inject deterministic vm_stat / sysctl / /proc/meminfo / claude-agents
# outputs without touching the real system.
#
# Usage:  ./ram-budget.test.sh
# Exit:   0 on full pass, 1 on any failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RAM_SCRIPT="$SCRIPT_DIR/ram-budget.sh"

if [ ! -x "$RAM_SCRIPT" ]; then
    echo "FAIL: ram-budget.sh not found or not executable at $RAM_SCRIPT" >&2
    exit 1
fi

PASS=0
FAIL=0
TESTS_RUN=()

# ── helpers ─────────────────────────────────────────────────────────────────

# Build a fake vm_stat output (page-size 16384) given pages_free/inactive/spec.
make_vm_stat() {
    local free="$1" inactive="$2" spec="$3"
    cat <<EOF
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                    ${free}.
Pages active:                                 200000.
Pages inactive:                               ${inactive}.
Pages speculative:                               ${spec}.
Pages wired down:                             241345.
EOF
}

assert_field() {
    local label="$1" json="$2" jq_expr="$3" expected="$4"
    local actual
    actual=$(echo "$json" | jq -r "$jq_expr" 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $label: $jq_expr == $expected"
        return 0
    else
        echo "  ✗ $label: $jq_expr expected=$expected actual=$actual"
        echo "    full json: $json"
        return 1
    fi
}

run_test() {
    local name="$1"
    shift
    echo ""
    echo "── TEST: $name ──"
    TESTS_RUN+=("$name")
    if "$@"; then
        echo "  → PASS"
        PASS=$((PASS + 1))
    else
        echo "  → FAIL"
        FAIL=$((FAIL + 1))
    fi
}

# Common stub bundle: 24GB Mac, 16KB pages.
STUB_TOTAL_24GB=$((24 * 1073741824))
STUB_PAGESIZE=16384

# ── tests ───────────────────────────────────────────────────────────────────

# T1: high free RAM on macOS → SPAWN_OK with capacity >= 1.
test_t1_macos_high_ram() {
    # 8GB free: 524288 free pages (16KB pages).  bg_count = 0.
    local vm; vm=$(make_vm_stat 524288 0 0)
    local tmp; tmp=$(mktemp); echo "$vm" > "$tmp"
    local json
    json=$(
        RAM_BUDGET_PLATFORM_OVERRIDE=Darwin \
        RAM_BUDGET_STUB_TOTAL_BYTES="$STUB_TOTAL_24GB" \
        RAM_BUDGET_STUB_PAGESIZE="$STUB_PAGESIZE" \
        RAM_BUDGET_STUB_VM_STAT="$tmp" \
        RAM_BUDGET_STUB_BG_COUNT=0 \
        "$RAM_SCRIPT"
    )
    rm -f "$tmp"
    assert_field "T1" "$json" '.recommended_action' 'SPAWN_OK' || return 1
    assert_field "T1" "$json" '.total_gb' '24.0' || return 1
    assert_field "T1" "$json" '.bg_session_count' '0' || return 1
    # capacity ≥ 1 (with default 1.8 × 1.5 = 2.7 GB per session, 8/2.7 ≈ 2)
    local cap; cap=$(echo "$json" | jq -r '.capacity_for_new_sessions')
    [ "$cap" -ge 1 ] || { echo "  ✗ T1: capacity expected ≥1, got $cap"; return 1; }
    return 0
}

# T2: near-zero free RAM with bg_count=2 → AT_CAPACITY.
test_t2_macos_at_capacity() {
    # 0 free + 0 inactive + 0 speculative → 0 bytes free.
    local vm; vm=$(make_vm_stat 0 0 0)
    local tmp; tmp=$(mktemp); echo "$vm" > "$tmp"
    local json
    json=$(
        RAM_BUDGET_PLATFORM_OVERRIDE=Darwin \
        RAM_BUDGET_STUB_TOTAL_BYTES="$STUB_TOTAL_24GB" \
        RAM_BUDGET_STUB_PAGESIZE="$STUB_PAGESIZE" \
        RAM_BUDGET_STUB_VM_STAT="$tmp" \
        RAM_BUDGET_STUB_BG_COUNT=2 \
        "$RAM_SCRIPT"
    )
    rm -f "$tmp"
    assert_field "T2" "$json" '.recommended_action' 'AT_CAPACITY' || return 1
    assert_field "T2" "$json" '.bg_session_count' '2' || return 1
    assert_field "T2" "$json" '.capacity_for_new_sessions' '0' || return 1
    return 0
}

# T3: near-zero free RAM with bg_count=0 → REDUCE_PARALLEL.
test_t3_macos_reduce_parallel() {
    local vm; vm=$(make_vm_stat 0 0 0)
    local tmp; tmp=$(mktemp); echo "$vm" > "$tmp"
    local json
    json=$(
        RAM_BUDGET_PLATFORM_OVERRIDE=Darwin \
        RAM_BUDGET_STUB_TOTAL_BYTES="$STUB_TOTAL_24GB" \
        RAM_BUDGET_STUB_PAGESIZE="$STUB_PAGESIZE" \
        RAM_BUDGET_STUB_VM_STAT="$tmp" \
        RAM_BUDGET_STUB_BG_COUNT=0 \
        "$RAM_SCRIPT"
    )
    rm -f "$tmp"
    assert_field "T3" "$json" '.recommended_action' 'REDUCE_PARALLEL' || return 1
    assert_field "T3" "$json" '.bg_session_count' '0' || return 1
    return 0
}

# T4: env override RAM_BUDGET_SESSION_COST_GB=3.0 reduces capacity.
test_t4_session_cost_override() {
    # 8GB free.  Default cost: 1.8×1.5=2.7 GB/sess → capacity ~3.
    # Override 3.0×1.5=4.5 GB/sess → capacity ~1.
    local vm; vm=$(make_vm_stat 524288 0 0)
    local tmp; tmp=$(mktemp); echo "$vm" > "$tmp"
    local cap_default
    cap_default=$(
        RAM_BUDGET_PLATFORM_OVERRIDE=Darwin \
        RAM_BUDGET_STUB_TOTAL_BYTES="$STUB_TOTAL_24GB" \
        RAM_BUDGET_STUB_PAGESIZE="$STUB_PAGESIZE" \
        RAM_BUDGET_STUB_VM_STAT="$tmp" \
        RAM_BUDGET_STUB_BG_COUNT=0 \
        "$RAM_SCRIPT" | jq -r '.capacity_for_new_sessions'
    )
    local cap_override
    cap_override=$(
        RAM_BUDGET_PLATFORM_OVERRIDE=Darwin \
        RAM_BUDGET_STUB_TOTAL_BYTES="$STUB_TOTAL_24GB" \
        RAM_BUDGET_STUB_PAGESIZE="$STUB_PAGESIZE" \
        RAM_BUDGET_STUB_VM_STAT="$tmp" \
        RAM_BUDGET_STUB_BG_COUNT=0 \
        RAM_BUDGET_SESSION_COST_GB=3.0 \
        "$RAM_SCRIPT" | jq -r '.capacity_for_new_sessions'
    )
    rm -f "$tmp"
    if [ "$cap_override" -lt "$cap_default" ]; then
        echo "  ✓ T4: override capacity ($cap_override) < default ($cap_default)"
        return 0
    fi
    echo "  ✗ T4: override capacity ($cap_override) NOT less than default ($cap_default)"
    return 1
}

# T5: bg_session_count from stub propagates.
test_t5_bg_count_stub() {
    local vm; vm=$(make_vm_stat 524288 0 0)
    local tmp; tmp=$(mktemp); echo "$vm" > "$tmp"
    local json
    json=$(
        RAM_BUDGET_PLATFORM_OVERRIDE=Darwin \
        RAM_BUDGET_STUB_TOTAL_BYTES="$STUB_TOTAL_24GB" \
        RAM_BUDGET_STUB_PAGESIZE="$STUB_PAGESIZE" \
        RAM_BUDGET_STUB_VM_STAT="$tmp" \
        RAM_BUDGET_STUB_BG_COUNT=4 \
        "$RAM_SCRIPT"
    )
    rm -f "$tmp"
    assert_field "T5" "$json" '.bg_session_count' '4' || return 1
    return 0
}

# T6: Linux branch via /proc/meminfo stubs.
test_t6_linux_branch() {
    local json
    json=$(
        RAM_BUDGET_PLATFORM_OVERRIDE=Linux \
        RAM_BUDGET_STUB_MEMTOTAL_KB=$((16 * 1024 * 1024)) \
        RAM_BUDGET_STUB_MEMAVAIL_KB=$((8 * 1024 * 1024)) \
        RAM_BUDGET_STUB_BG_COUNT=0 \
        "$RAM_SCRIPT"
    )
    assert_field "T6" "$json" '.total_gb' '16.0' || return 1
    assert_field "T6" "$json" '.free_gb' '8.0' || return 1
    assert_field "T6" "$json" '.recommended_action' 'SPAWN_OK' || return 1
    return 0
}

# T7: Unsupported platform falls open (recommended_action: null).
test_t7_unsupported_platform_fails_open() {
    local json
    json=$(
        RAM_BUDGET_PLATFORM_OVERRIDE=Plan9 \
        RAM_BUDGET_STUB_BG_COUNT=0 \
        "$RAM_SCRIPT"
    )
    assert_field "T7" "$json" '.recommended_action' 'null' || return 1
    return 0
}

# ── run all ─────────────────────────────────────────────────────────────────

run_test "T1 macos_high_ram → SPAWN_OK" test_t1_macos_high_ram
run_test "T2 macos_low_ram + bg=2 → AT_CAPACITY" test_t2_macos_at_capacity
run_test "T3 macos_low_ram + bg=0 → REDUCE_PARALLEL" test_t3_macos_reduce_parallel
run_test "T4 RAM_BUDGET_SESSION_COST_GB override reduces capacity" test_t4_session_cost_override
run_test "T5 bg_session_count stub propagates" test_t5_bg_count_stub
run_test "T6 linux branch via /proc/meminfo stubs" test_t6_linux_branch
run_test "T7 unsupported platform → null (fail-open)" test_t7_unsupported_platform_fails_open

echo ""
echo "─────────────────────────────────────────────"
echo "Tests run: ${#TESTS_RUN[@]}   passed: $PASS   failed: $FAIL"
echo "─────────────────────────────────────────────"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
