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
# FINAL-ARTIFACT PRESERVATION (build-artifact-preservation, 1.28.0): a build dir
# may also contain a FINAL installable (*.app / *.ipa / *.apk / *.aab) — small,
# reusable for installs/demos/recordings, NOT regenerable on the demo critical
# path without a multi-minute rebuild. The 2026-06-02 cleanscale incident deleted
# an iOS .app together with its ~931 MB ios/build intermediates. Before removing a
# build dir, this script RELOCATES any installable within it to a protected
# kept-artifacts home (default .playwright-mcp/, rooted at the repo root so it
# survives worktree removal); only the intermediates are then reclaimed. Policy:
# docs/operations/build-cleanup-preserve-installables.md.
#
# Usage:
#   plan-w-team-build-artifact-clean.sh <worktree-path> [--execute]
#   plan-w-team-build-artifact-clean.sh --all [--execute]      # sweep .claude/worktrees/*
#   (default is DRY-RUN; pass --execute to actually delete. --json for machine output.)
#
# SAFETY INVARIANTS (mirror plan-w-team-worktree-gc.sh):
#   • LOCATION: operates ONLY inside <repo>/.claude/worktrees/ — never the main
#     checkout, never a path outside the worktrees dir. Refuses anything else.
#   • SOURCE: removes ONLY the fixed allowlist of regenerable build dirs below;
#     node_modules is intentionally NOT touched — it is symlinked to main by
#     worktree-deps-share.sh (E5); removing it would break the shared tree.
#   • FINAL ARTIFACT (new): never deletes a *.app/*.ipa/*.apk/*.aab — relocates it
#     to the kept-artifacts home first. If relocation FAILS, the enclosing dir is
#     NOT removed (fail-safe: never lose an artifact we could not save).
#   • The kept-artifacts home itself is NEVER cleaned (preserve-only).
#   • Idempotent; missing dirs are skipped silently.
#
# Env: PWT_BUILD_ARTIFACT_DIRS overrides the allowlist (newline/space separated,
#      paths relative to the worktree root).
#      PWT_KEPT_ARTIFACTS_HOME overrides the kept-artifacts home (absolute path
#      used as-is, or relative resolved under the repo root; default .playwright-mcp).

set -u

# Regenerable build-output dirs (relative to a worktree root). 100% rebuildable.
DEFAULT_ARTIFACT_DIRS='ios/Pods ios/build ios/DerivedData
android/.gradle android/build android/app/build
DerivedData .gradle target/release target/debug
.next/cache .expo .turbo'
ARTIFACT_DIRS="${PWT_BUILD_ARTIFACT_DIRS:-$DEFAULT_ARTIFACT_DIRS}"

# Final installables — PRESERVE, never delete. Kept consistent with the same set
# in .claude/hooks/damage-control/damage-control.sh (the reactive guard) and the
# policy doc. If you add an extension here, add it there too.
INSTALLABLE_GLOBS='*.app *.ipa *.apk *.aab'

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

# Resolve the protected kept-artifacts home. Absolute → used as-is; relative →
# under the repo root (main checkout) so relocated installables survive a
# per-merge worktree removal.
KEPT_HOME_RAW="${PWT_KEPT_ARTIFACTS_HOME:-.playwright-mcp}"
case "$KEPT_HOME_RAW" in
    /*) KEPT_HOME_ABS="$KEPT_HOME_RAW" ;;
    *)  KEPT_HOME_ABS="$REPO_ROOT/$KEPT_HOME_RAW" ;;
esac
KEPT_ARTIFACTS_DIR="$KEPT_HOME_ABS/kept-build-artifacts"

dir_bytes() { du -sk "$1" 2>/dev/null | awk '{print $1*1024}'; }   # bytes (from 1K blocks)

# is_under PATH BASE → true (0) if PATH == BASE or PATH is nested under BASE/.
is_under() {
    local p="${1%/}" base="${2%/}"
    [ -z "$base" ] && return 1
    [ "$p" = "$base" ] && return 0
    case "$p/" in "$base"/*) return 0 ;; *) return 1 ;; esac
}

reclaimed_total=0
cleaned_list=""
preserved_list=""

# Relocate any FINAL installable out of a build dir BEFORE it is removed.
# $1 = build dir (absolute), $2 = worktree root (absolute).
# Returns 0 if all relocations succeeded (or none were needed / dry-run), 1 if a
# relocation FAILED — the caller must then NOT remove the dir (fail-safe).
preserve_installables() {
    local dir="$1" wt="$2" find_expr=() g first=1 inst rel dest fail=0
    # Build the find OR-expression from INSTALLABLE_GLOBS.
    for g in $INSTALLABLE_GLOBS; do
        if [ "$first" = "1" ]; then find_expr+=( -name "$g" ); first=0
        else find_expr+=( -o -name "$g" ); fi
    done
    # -prune so we never descend INTO a matched *.app bundle (it moves whole).
    # FAIL CLOSED: capture find's exit status. If find could NOT fully enumerate
    # the dir (unreadable subdir, transient FS error), we must NOT assume "no
    # installable present" — an unenumerated installable would otherwise be
    # deleted with the dir. On a find error, keep the dir intact (return 1) so the
    # caller refuses the rm. (set -u is active, not set -e, so $? capture is safe.)
    local _found _frc
    _found=$(find "$dir" \( "${find_expr[@]}" \) -prune -print 2>/dev/null)
    _frc=$?
    if [ "$_frc" -ne 0 ]; then
        echo "[build-clean] find FAILED to enumerate $dir (rc=$_frc) — keeping dir intact (fail-closed)" >&2
        return 1
    fi
    while IFS= read -r inst; do
        [ -z "$inst" ] && continue
        rel="${inst#"$wt"/}"                          # path relative to worktree root
        dest="$KEPT_ARTIFACTS_DIR/$(basename "$wt")/$rel"
        if [ "$EXECUTE" = "1" ]; then
            mkdir -p "$(dirname "$dest")" 2>/dev/null
            [ -e "$dest" ] && rm -rf "$dest" 2>/dev/null   # newest build supersedes
            if mv "$inst" "$dest" 2>/dev/null; then
                preserved_list="${preserved_list}${preserved_list:+,}\"$(basename "$wt")/$rel\""
            else
                echo "[build-clean] preserve FAILED (keeping dir intact): $inst" >&2
                fail=1
            fi
        else
            preserved_list="${preserved_list}${preserved_list:+,}\"$(basename "$wt")/$rel\""
        fi
    done <<EOF
$_found
EOF
    return $fail
}

# Clean one worktree. $1 = absolute worktree path. SAFETY: must be under WORKTREES_DIR.
clean_worktree() {
    local wt="$1" rel d full b
    case "$wt" in
        "$WORKTREES_DIR"/*) : ;;                       # OK — inside worktrees dir
        *) echo "[build-clean] REFUSE (outside .claude/worktrees): $wt" >&2; return 1 ;;
    esac
    # FINAL-ARTIFACT invariant: never clean the kept-artifacts home (preserve-only).
    if is_under "$wt" "$KEPT_HOME_ABS"; then
        echo "[build-clean] REFUSE (kept-artifacts home — preserve-only): $wt" >&2
        return 0
    fi
    [ -d "$wt" ] || { echo "[build-clean] not a dir: $wt" >&2; return 1; }
    for rel in $ARTIFACT_DIRS; do
        full="$wt/$rel"
        # Guard against traversal / absolute escapes in the allowlist.
        case "$rel" in /*|*..*) continue ;; esac
        [ -d "$full" ] || continue
        # Relocate any final installable out before reclaiming intermediates.
        # If a relocation failed, refuse to remove this dir (never lose an artifact).
        if ! preserve_installables "$full" "$wt"; then
            echo "[build-clean] SKIP rm (a preserve failed): $full" >&2
            continue
        fi
        # Measure AFTER relocation so the reported reclaim reflects intermediates
        # only (the small installable was moved out, not reclaimed).
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
    printf '{\n  "mode": "%s",\n  "reclaimable_mb": %d,\n  "dirs": [%s],\n  "preserved": [%s]\n}\n' \
        "$MODE" "$reclaimed_mb" "$cleaned_list" "$preserved_list"
else
    echo "[build-clean] $MODE: ${reclaimed_mb} MB in regenerable build dirs${cleaned_list:+ (}${cleaned_list//\"/}${cleaned_list:+)}"
    [ -n "$preserved_list" ] && echo "[build-clean] preserved installables → ${KEPT_ARTIFACTS_DIR}: ${preserved_list//\"/}"
fi
exit 0
