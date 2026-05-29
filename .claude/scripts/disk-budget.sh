#!/usr/bin/env bash
# disk-budget.sh — pre-spawn DISK capacity gate for /plan-w-team worktrees.
#
# Mirror of ram-budget.sh (PWT-RAM1) for the disk dimension (PWT-DISK1). The
# 2026-05-29 cleanscale incident (67 worktrees / 64 GB → 0 bytes free → ENOSPC,
# git + Bash tool failing) proved there was NO disk gate: pwt-goal.sh consulted
# ram-budget.sh but nothing checked free disk, so spawns proceeded into a ~98%-full
# filesystem. This script is that gate.
#
# Emits a single JSON object on stdout. Example:
#   {
#     "free_gb": 26.7,
#     "used_pct": 31,
#     "inode_free_pct": 99,
#     "heavy_build": false,
#     "min_free_gb": 15,
#     "est_worktree_cost_gb": 2.5,
#     "capacity_for_new_worktrees": 4,
#     "recommended_action": "SPAWN_OK"
#   }
#
# recommended_action enum:
#   SPAWN_OK    — comfortable headroom above the floor; spawn freely.
#   REDUCE      — room for ~1 more worktree above the floor; spawn but warn.
#   AT_CAPACITY — at the floor; a new worktree would breach min-free. Hold.
#   BLOCK       — free_gb < min_free_gb (or inodes exhausted). Refuse the spawn.
#   null        — fail-open (df unreadable / non-numeric). pwt-goal.sh proceeds
#                 with a LOUD stderr warning; never silently block on a read error.
#
# IMPORTANT — gate on FREE GB, not %: on macOS/APFS, `df` % counts the whole
# shared container, so it reads ~90%+ even with tens of GB free. used_pct is
# therefore ADVISORY only here; the hard gate is absolute free GB.
#
# Env knobs (documented in shared/disk-budget.md):
#   PWT_DISK_PATH                 path whose filesystem to measure (default $PWD)
#   PWT_DISK_MIN_FREE_GB          hard floor, normal spawn (default 15)
#   PWT_DISK_MIN_FREE_GB_BUILD    hard floor, heavy-build spawn (default 25)
#   PWT_DISK_WORKTREE_COST_GB     est. cost of one worktree, normal (default 2.5)
#   PWT_DISK_WORKTREE_COST_GB_BUILD est. cost, heavy-build (default 6)
#   PWT_DISK_MIN_INODE_PCT        BLOCK if inode-free% below this (default 5)
#   PWT_DISK_MAX_PCT              advisory used-% warning threshold (default 95)
#   PWT_DISK_DIRECTIVE            the run's directive text (heavy-build sniff)
#   DISK_BUDGET_STUB_DF           file used in place of `df -k` output (tests)
#   DISK_BUDGET_STUB_DF_INODES    file used in place of `df -i` output (tests)
#
# bash 3.2 safe: no associative arrays / mapfile; float math via awk.

set -u

PATH_TARGET="${PWT_DISK_PATH:-$PWD}"
MIN_FREE_GB="${PWT_DISK_MIN_FREE_GB:-15}"
MIN_FREE_GB_BUILD="${PWT_DISK_MIN_FREE_GB_BUILD:-25}"
COST_GB="${PWT_DISK_WORKTREE_COST_GB:-2.5}"
COST_GB_BUILD="${PWT_DISK_WORKTREE_COST_GB_BUILD:-6}"
MIN_INODE_PCT="${PWT_DISK_MIN_INODE_PCT:-5}"
MAX_PCT="${PWT_DISK_MAX_PCT:-95}"
DIRECTIVE="${PWT_DISK_DIRECTIVE:-}"

# Allow a positional directive too: disk-budget.sh "ship the iOS build with pod install"
[ -n "${1:-}" ] && DIRECTIVE="$1"

emit_fail_open() {
    # Loud: warn on stderr so a read failure is visible, but exit 0 so the gate
    # fails OPEN (never block a run because df was unreadable).
    echo "[disk-budget] WARN: $1 — failing OPEN (recommended_action=null)" >&2
    cat <<EOF
{
  "free_gb": null,
  "used_pct": null,
  "inode_free_pct": null,
  "heavy_build": null,
  "min_free_gb": null,
  "est_worktree_cost_gb": null,
  "capacity_for_new_worktrees": null,
  "recommended_action": null,
  "note": "$1"
}
EOF
}

# Heavy-build sniff: directives that trigger large regenerable trees.
HEAVY=false
if printf '%s' "$DIRECTIVE" | grep -iqE 'pnpm install|npm install|yarn install|pod install|expo|eas build|gradlew|xcodebuild|cargo build'; then
    HEAVY=true
fi
if [ "$HEAVY" = "true" ]; then
    MIN_FREE="$MIN_FREE_GB_BUILD"; COST="$COST_GB_BUILD"
else
    MIN_FREE="$MIN_FREE_GB"; COST="$COST_GB"
fi

# ── read df (1K blocks) ───────────────────────────────────────────────────────
if [ -n "${DISK_BUDGET_STUB_DF:-}" ]; then
    DF_OUT="$(cat "$DISK_BUDGET_STUB_DF" 2>/dev/null)" || { emit_fail_open "stub_df_unreadable"; exit 0; }
else
    DF_OUT="$(df -k "$PATH_TARGET" 2>/dev/null)" || { emit_fail_open "df_failed"; exit 0; }
fi
# Last line, fields: Filesystem 1K-blocks Used Avail Capacity ... ; Avail=$4, Capacity=$5
FREE_KB=$(printf '%s\n' "$DF_OUT" | awk 'END{print $4}')
USED_PCT=$(printf '%s\n' "$DF_OUT" | awk 'END{gsub(/%/,"",$5); print $5}')
if ! printf '%s' "$FREE_KB" | grep -qE '^[0-9]+$'; then emit_fail_open "non_numeric_free_kb"; exit 0; fi
printf '%s' "$USED_PCT" | grep -qE '^[0-9]+$' || USED_PCT="null"

# free GB to one decimal (awk; bash can't float)
FREE_GB=$(awk -v k="$FREE_KB" 'BEGIN{printf "%.1f", k/1048576}')

# ── read inodes (best-effort; absent on some FS → report null, don't block) ───
INODE_FREE_PCT="null"
if [ -n "${DISK_BUDGET_STUB_DF_INODES:-}" ]; then
    DFI_OUT="$(cat "$DISK_BUDGET_STUB_DF_INODES" 2>/dev/null)"
else
    DFI_OUT="$(df -i "$PATH_TARGET" 2>/dev/null || true)"
fi
if [ -n "$DFI_OUT" ]; then
    # macOS df -i: ... iused ifree %iused ; compute ifree/(iused+ifree).
    INODE_FREE_PCT=$(printf '%s\n' "$DFI_OUT" | awk 'END{
        for(i=1;i<=NF;i++){} # noop; rely on iused/ifree being numeric near end
        iu=$6; ifr=$7;
        if (iu ~ /^[0-9]+$/ && ifr ~ /^[0-9]+$/ && (iu+ifr)>0) printf "%d", (ifr*100)/(iu+ifr); else print "null"
    }')
    printf '%s' "$INODE_FREE_PCT" | grep -qE '^[0-9]+$' || INODE_FREE_PCT="null"
fi

# ── capacity above the floor ──────────────────────────────────────────────────
# capacity = floor( max(0, free_gb - min_free) / cost )
CAPACITY=$(awk -v f="$FREE_GB" -v m="$MIN_FREE" -v c="$COST" 'BEGIN{
    head=f-m; if(head<0)head=0; if(c<=0)c=2.5; printf "%d", int(head/c)
}')

# ── decide action (gate on free GB + inodes; used_pct advisory only) ──────────
BELOW_FLOOR=$(awk -v f="$FREE_GB" -v m="$MIN_FREE" 'BEGIN{print (f<m)?1:0}')
if [ "$INODE_FREE_PCT" != "null" ] && [ "$INODE_FREE_PCT" -lt "$MIN_INODE_PCT" ]; then
    ACTION="BLOCK"   # inode exhaustion — ENOSPC even with free bytes
elif [ "$BELOW_FLOOR" = "1" ]; then
    ACTION="BLOCK"
elif [ "$CAPACITY" -ge 2 ]; then
    ACTION="SPAWN_OK"
elif [ "$CAPACITY" -eq 1 ]; then
    ACTION="REDUCE"
else
    ACTION="AT_CAPACITY"
fi

cat <<EOF
{
  "free_gb": ${FREE_GB},
  "used_pct": ${USED_PCT},
  "inode_free_pct": ${INODE_FREE_PCT},
  "heavy_build": ${HEAVY},
  "min_free_gb": ${MIN_FREE},
  "est_worktree_cost_gb": ${COST},
  "capacity_for_new_worktrees": ${CAPACITY},
  "max_pct_advisory": ${MAX_PCT},
  "recommended_action": "${ACTION}"
}
EOF
