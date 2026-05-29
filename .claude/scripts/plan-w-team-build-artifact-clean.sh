#!/usr/bin/env bash
# plan-w-team-build-artifact-clean.sh — reclaim regenerable build output (E7).
#
# After a build worker ships, its worktree lingers awaiting merge still holding
# 100%-regenerable build output: iOS Pods + DerivedData (5–9 GB each), Android
# .gradle + build dirs, Rust target/, etc. The 2026-05-29 cleanscale incident's
# 64 GB was dominated by exactly this. This script removes ONLY known-regenerable
# build dirs from a worktree (or sweeps all worktrees), never touching source or
# uncommitted work.
#
# Usage:
#   plan-w-team-build-artifact-clean.sh <worktree-path> [--execute]
#   plan-w-team-build-artifact-clean.sh --all [--execute]      # sweep .claude/worktrees/*
#   (default is DRY-RUN; pass --execute to actually delete. --json for machine output.)
#
# SAFETY INVARIANTS (mirror plan-w-team-worktree-gc.sh):
#   • Operates ONLY inside <repo>/.claude/worktrees/ — never the main checkout,
#     never a path outside the worktrees dir. Refuses anything else.
#   • Removes ONLY the fixed allowlist of regenerable build dirs below.
#   • node_modules is intentionally NOT touched — it is symlinked to main by
#     worktree-deps-share.sh (E5); removing it would break the shared tree.
#   • Idempotent; missing dirs are skipped silently.
#
# Env: PWT_BUILD_ARTIFACT_DIRS overrides the allowlist (newline/space separated,
#      paths relative to the worktree root).

set -u

# Regenerable build-output dirs (relative to a worktree root). 100% rebuildable.
DEFAULT_ARTIFACT_DIRS='ios/Pods ios/build ios/DerivedData
android/.gradle android/build android/app/build
DerivedData .gradle target/release target/debug
.next/cache .expo .turbo'
ARTIFACT_DIRS="${PWT_BUILD_ARTIFACT_DIRS:-$DEFAULT_ARTIFACT_DIRS}"

EXECUTE=0; JSON=0; ALL=0; TARGET=""
for a in "$@"; do
    case "$a" in
        --execute) EXECUTE=1 ;;
        --json)    JSON=1 ;;
        --all)     ALL=1 ;;
        --*)       ;;  # ignore unknown flags
        *)         TARGET="$a" ;;
    esac
done

REPO_ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WORKTREES_DIR="$REPO_ROOT/.claude/worktrees"

dir_bytes() { du -sk "$1" 2>/dev/null | awk '{print $1*1024}'; }   # bytes (from 1K blocks)

reclaimed_total=0
cleaned_list=""

# Clean one worktree. $1 = absolute worktree path. SAFETY: must be under WORKTREES_DIR.
clean_worktree() {
    local wt="$1" rel d full b
    case "$wt" in
        "$WORKTREES_DIR"/*) : ;;                       # OK — inside worktrees dir
        *) echo "[build-clean] REFUSE (outside .claude/worktrees): $wt" >&2; return 1 ;;
    esac
    [ -d "$wt" ] || { echo "[build-clean] not a dir: $wt" >&2; return 1; }
    for rel in $ARTIFACT_DIRS; do
        full="$wt/$rel"
        # Guard against traversal / absolute escapes in the allowlist.
        case "$rel" in /*|*..*) continue ;; esac
        [ -d "$full" ] || continue
        b=$(dir_bytes "$full"); [ -z "$b" ] && b=0
        reclaimed_total=$(( reclaimed_total + b ))
        cleaned_list="${cleaned_list}${cleaned_list:+,}\"$(basename "$wt")/$rel\""
        if [ "$EXECUTE" = "1" ]; then
            rm -rf "$full" 2>/dev/null || echo "[build-clean] rm failed: $full" >&2
        fi
    done
}

if [ "$ALL" = "1" ]; then
    if [ -d "$WORKTREES_DIR" ]; then
        for wt in "$WORKTREES_DIR"/*/; do [ -d "$wt" ] && clean_worktree "${wt%/}"; done
    fi
elif [ -n "$TARGET" ]; then
    # Resolve to absolute for the under-worktrees check.
    case "$TARGET" in /*) : ;; *) TARGET="$(cd "$TARGET" 2>/dev/null && pwd || echo "$TARGET")" ;; esac
    clean_worktree "$TARGET"
else
    echo "usage: $0 <worktree-path> [--execute] | --all [--execute]" >&2
    exit 2
fi

reclaimed_mb=$(( reclaimed_total / 1048576 ))
MODE=$([ "$EXECUTE" = "1" ] && echo executed || echo dry-run)
if [ "$JSON" = "1" ]; then
    printf '{\n  "mode": "%s",\n  "reclaimable_mb": %d,\n  "dirs": [%s]\n}\n' "$MODE" "$reclaimed_mb" "$cleaned_list"
else
    echo "[build-clean] $MODE: ${reclaimed_mb} MB in regenerable build dirs${cleaned_list:+ (}${cleaned_list//\"/}${cleaned_list:+)}"
fi
exit 0
