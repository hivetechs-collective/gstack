#!/bin/bash
# ram-budget — emit JSON describing host RAM availability and recommended
# action for spawning another `claude --bg` session.
#
# Used by .claude/scripts/pwt-goal.sh as a pre-spawn capacity gate so that
# /plan-w-team workers don't OOM-kill each other under high parallelism.
#
# Output (always JSON to stdout; soft errors go to stderr and produce a
# fail-open record with recommended_action=null):
#
#   {
#     "free_gb": 8.4,
#     "total_gb": 24.0,
#     "used_gb": 15.6,
#     "bg_session_count": 2,
#     "estimated_session_cost_gb": 1.8,
#     "safety_factor": 1.5,
#     "capacity_for_new_sessions": 2,
#     "recommended_action": "SPAWN_OK"
#   }
#
# recommended_action enum:
#   SPAWN_OK         — capacity_for_new_sessions >= 1; spawn freely.
#   AT_CAPACITY      — capacity == 0 AND bg_session_count >= 1; running
#                      sessions consumed the budget; stop or wait.
#   REDUCE_PARALLEL  — capacity == 0 AND bg_session_count == 0; the host
#                      itself can't fit one session; close other apps or
#                      tune RAM_BUDGET_SESSION_COST_GB.
#   null             — unsupported platform or unrecoverable read failure;
#                      pwt-goal.sh treats this as fail-open.
#
# Environment overrides:
#   RAM_BUDGET_SESSION_COST_GB  default 1.8 — per-bg-session RAM estimate.
#   RAM_BUDGET_SAFETY_FACTOR    default 1.5 — multiplier applied to per-
#                                             session cost when computing
#                                             capacity for new sessions.
#
# Stubbing for tests:
#   RAM_BUDGET_STUB_VM_STAT     path to a file used in place of `vm_stat`.
#   RAM_BUDGET_STUB_MEMTOTAL_KB integer (KB) used in place of /proc/meminfo MemTotal.
#   RAM_BUDGET_STUB_MEMAVAIL_KB integer (KB) used in place of /proc/meminfo MemAvailable.
#   RAM_BUDGET_STUB_TOTAL_BYTES integer (bytes) used in place of `sysctl hw.memsize`.
#   RAM_BUDGET_STUB_PAGESIZE    integer used in place of `sysctl hw.pagesize`.
#   RAM_BUDGET_STUB_BG_COUNT    integer used in place of `claude agents --json`.
#
# See: .claude/commands/plan-w-team/shared/ram-budget.md

set -u

SESSION_COST_GB="${RAM_BUDGET_SESSION_COST_GB:-1.8}"
SAFETY_FACTOR="${RAM_BUDGET_SAFETY_FACTOR:-1.5}"

# ─── Helpers ────────────────────────────────────────────────────────────────

# Print integer division of bytes → GB (1 decimal place, truncated).
# Pure shell arithmetic; avoids bc/python/awk dependencies.
bytes_to_gb_tenths() {
    local bytes="$1"
    # multiply by 10 first to get one decimal place
    local gb_x10=$(( bytes * 10 / 1073741824 ))
    local whole=$(( gb_x10 / 10 ))
    local tenth=$(( gb_x10 % 10 ))
    printf '%d.%d' "$whole" "$tenth"
}

# Multiply two decimals (one fractional digit each) and return integer floor
# of the product, in tenths.  Used for safety_factor × session_cost.
# Inputs: 1.8 1.5 → 2.7 (returned as 27).
mul_tenths() {
    local a="$1"
    local b="$2"
    local a_int="${a%.*}"; local a_frac="${a#*.}"
    local b_int="${b%.*}"; local b_frac="${b#*.}"
    [ "$a_int" = "$a" ] && a_frac=0
    [ "$b_int" = "$b" ] && b_frac=0
    local a10=$(( a_int * 10 + a_frac ))
    local b10=$(( b_int * 10 + b_frac ))
    # product is in hundredths; divide by 10 to return tenths (truncated)
    echo $(( a10 * b10 / 10 ))
}

# Floor of (free_bytes / per_session_bytes) — capacity_for_new_sessions.
capacity_for() {
    local free_bytes="$1"
    local per_session_bytes="$2"
    if [ "$per_session_bytes" -le 0 ]; then
        echo 0
        return
    fi
    echo $(( free_bytes / per_session_bytes ))
}

# ─── Background session count ────────────────────────────────────────────────

count_bg_sessions() {
    if [ -n "${RAM_BUDGET_STUB_BG_COUNT:-}" ]; then
        echo "${RAM_BUDGET_STUB_BG_COUNT}"
        return
    fi

    # PWT-RAM2: the shared cross-repo claims registry is authoritative for
    # machine-wide RAM accounting. If present and readable, count its rows;
    # otherwise fall back to `claude agents --json` (which only sees the
    # current shell's bg sessions and misses workers spawned from other repos).
    local registry="${PWT_RAM_CLAIMS_REGISTRY:-$HOME/.claude/state/pwt-ram-claims.jsonl}"
    if [ -r "$registry" ]; then
        local n
        n=$(grep -c '"sid":"' "$registry" 2>/dev/null || echo 0)
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        echo "$n"
        return
    fi

    if ! command -v claude >/dev/null 2>&1; then
        echo 0
        return
    fi
    # Try claude agents --json; tolerate any failure.
    local json
    json=$(claude agents --json 2>/dev/null) || { echo 0; return; }
    [ -z "$json" ] && { echo 0; return; }
    # Prefer jq if available, else grep-count.
    if command -v jq >/dev/null 2>&1; then
        local n
        n=$(printf '%s' "$json" | jq '[.[] | select(.kind == "background")] | length' 2>/dev/null) || n=0
        # jq returns "null" on bad input; coerce.
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        echo "$n"
    else
        # Fallback: count occurrences of "kind": "background"
        printf '%s' "$json" | grep -c '"kind": *"background"'
    fi
}

# ─── Platform read: macOS ───────────────────────────────────────────────────

read_mac() {
    local total_bytes free_bytes pagesize
    if [ -n "${RAM_BUDGET_STUB_TOTAL_BYTES:-}" ]; then
        total_bytes="${RAM_BUDGET_STUB_TOTAL_BYTES}"
    else
        total_bytes=$(sysctl -n hw.memsize 2>/dev/null) || return 1
    fi
    if [ -n "${RAM_BUDGET_STUB_PAGESIZE:-}" ]; then
        pagesize="${RAM_BUDGET_STUB_PAGESIZE}"
    else
        pagesize=$(sysctl -n hw.pagesize 2>/dev/null) || return 1
    fi

    local vm
    if [ -n "${RAM_BUDGET_STUB_VM_STAT:-}" ]; then
        vm=$(cat "${RAM_BUDGET_STUB_VM_STAT}" 2>/dev/null) || return 1
    else
        vm=$(vm_stat 2>/dev/null) || return 1
    fi

    # Pages we treat as "available": free + inactive + speculative.
    # Active and wired are in-use; not counted as free.
    local pages_free pages_inactive pages_speculative
    pages_free=$(    printf '%s' "$vm" | awk '/Pages free/                 {gsub(/\./,"",$3); print $3}')
    pages_inactive=$(printf '%s' "$vm" | awk '/Pages inactive/             {gsub(/\./,"",$3); print $3}')
    pages_speculative=$(printf '%s' "$vm" | awk '/Pages speculative/       {gsub(/\./,"",$3); print $3}')

    [ -z "$pages_free" ]        && pages_free=0
    [ -z "$pages_inactive" ]    && pages_inactive=0
    [ -z "$pages_speculative" ] && pages_speculative=0

    local pages_avail=$(( pages_free + pages_inactive + pages_speculative ))
    free_bytes=$(( pages_avail * pagesize ))

    printf '%d %d\n' "$total_bytes" "$free_bytes"
}

# ─── Platform read: Linux ───────────────────────────────────────────────────

read_linux() {
    local total_kb avail_kb
    if [ -n "${RAM_BUDGET_STUB_MEMTOTAL_KB:-}" ]; then
        total_kb="${RAM_BUDGET_STUB_MEMTOTAL_KB}"
    else
        [ -r /proc/meminfo ] || return 1
        total_kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo)
    fi
    if [ -n "${RAM_BUDGET_STUB_MEMAVAIL_KB:-}" ]; then
        avail_kb="${RAM_BUDGET_STUB_MEMAVAIL_KB}"
    else
        [ -r /proc/meminfo ] || return 1
        avail_kb=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo)
    fi
    [ -z "$total_kb" ] && return 1
    [ -z "$avail_kb" ] && return 1
    printf '%d %d\n' "$(( total_kb * 1024 ))" "$(( avail_kb * 1024 ))"
}

# ─── Main ───────────────────────────────────────────────────────────────────

emit_fail_open() {
    local reason="$1"
    cat <<EOF
{
  "free_gb": null,
  "total_gb": null,
  "used_gb": null,
  "bg_session_count": $(count_bg_sessions),
  "estimated_session_cost_gb": ${SESSION_COST_GB},
  "safety_factor": ${SAFETY_FACTOR},
  "capacity_for_new_sessions": null,
  "recommended_action": null,
  "note": "${reason}"
}
EOF
}

PLATFORM="${RAM_BUDGET_PLATFORM_OVERRIDE:-}"
[ -z "$PLATFORM" ] && PLATFORM="$(uname -s 2>/dev/null || echo unknown)"

case "$PLATFORM" in
    Darwin|darwin)
        read_result=$(read_mac) || { emit_fail_open "macos_read_failed"; exit 0; }
        ;;
    Linux|linux)
        read_result=$(read_linux) || { emit_fail_open "linux_read_failed"; exit 0; }
        ;;
    *)
        emit_fail_open "unsupported_platform:${PLATFORM}"
        exit 0
        ;;
esac

total_bytes="${read_result% *}"
free_bytes="${read_result#* }"

if ! [[ "$total_bytes" =~ ^[0-9]+$ ]] || ! [[ "$free_bytes" =~ ^[0-9]+$ ]]; then
    emit_fail_open "non_numeric_read"
    exit 0
fi

used_bytes=$(( total_bytes - free_bytes ))
[ "$used_bytes" -lt 0 ] && used_bytes=0

total_gb=$(bytes_to_gb_tenths "$total_bytes")
free_gb=$(bytes_to_gb_tenths "$free_bytes")
used_gb=$(bytes_to_gb_tenths "$used_bytes")

bg_count=$(count_bg_sessions)

# per_session_bytes = ceil(session_cost_gb × safety_factor × 1GB)
# Implemented via mul_tenths to avoid bc.
per_session_tenths=$(mul_tenths "$SESSION_COST_GB" "$SAFETY_FACTOR")
# tenths to bytes: tenths × 1GB / 10
per_session_bytes=$(( per_session_tenths * 1073741824 / 10 ))

capacity=$(capacity_for "$free_bytes" "$per_session_bytes")

if [ "$capacity" -ge 1 ]; then
    action="SPAWN_OK"
elif [ "$bg_count" -ge 1 ]; then
    action="AT_CAPACITY"
else
    action="REDUCE_PARALLEL"
fi

cat <<EOF
{
  "free_gb": ${free_gb},
  "total_gb": ${total_gb},
  "used_gb": ${used_gb},
  "bg_session_count": ${bg_count},
  "estimated_session_cost_gb": ${SESSION_COST_GB},
  "safety_factor": ${SAFETY_FACTOR},
  "capacity_for_new_sessions": ${capacity},
  "recommended_action": "${action}"
}
EOF
