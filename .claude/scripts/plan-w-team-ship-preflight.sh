#!/usr/bin/env bash
# plan-w-team-ship-preflight.sh — pre-push environment self-heal (REQ-1).
#
# The 2026-05-29 cleanscale audit found bg workers self-driving to ship then
# WEDGING at the ship gate on two environment issues nothing self-healed:
#   (a) node_modules/turbo: a pwt-goal `claude --bg` LEAD creates its worktree
#       mid-session, so SessionStart (which seeds deps) no-ops for a main-cwd lead
#       and never fires at all for headless `claude -p` (03-execute.md:467). The
#       worktree has no node_modules → pre-push `turbo`/`make test-all` dies with
#       `turbo: command not found`.
#   (b) orphaned iOS sim: a booted-but-app-less simulator left by a stopped worker
#       makes the maestro:ios leg false-fail 57/57 → push blocked.
# This script self-heals BOTH before the test gate, so a wedged worker finishes
# unattended. It is the keystone that flips "operator babysits every wave" →
# "workers finish unattended".
#
# Usage:
#   plan-w-team-ship-preflight.sh [--worktree PATH] [--json]
#   (default worktree = $PWD; dry-run is NOT a mode — this heals, but every step is
#    individually safe + idempotent and the script is fail-open.)
#
# Env knobs:
#   PWT_SHIP_PREFLIGHT_DISABLE=1   skip entirely
#   PWT_SHIP_DEPS_DISABLE=1        skip the node_modules self-heal
#   PWT_SHIP_SIM_SHUTDOWN=0        skip the iOS-sim shutdown (default: shut booted sims)
#   PWT_DEPS_SHARE_CMD=<path>      override the deps-share script (default: sibling) [test]
#   PWT_SHIP_PREFLIGHT_PNPM=<cmd>  override pnpm (fallback installer) [test]
#   PWT_SHIP_PREFLIGHT_XCRUN=<cmd> override xcrun (sim detection) [test]
#
# Fail-open: a self-heal that errors warns to stderr and the script still exits 0 —
# the subsequent test gate is the real arbiter. It NEVER masks a real test failure.
# bash 3.2 safe.

set -u

WORKTREE="$PWD"; JSON=0
while [ $# -gt 0 ]; do
    case "$1" in
        --worktree) WORKTREE="${2:-$PWD}"; shift 2 ;;
        --json)     JSON=1; shift ;;
        *)          shift ;;
    esac
done

DEPS_ACTION="skip"; SIM_ACTION="skip"

emit() {
    if [ "$JSON" = "1" ]; then
        printf '{"deps_action":"%s","sim_action":"%s"}\n' "$DEPS_ACTION" "$SIM_ACTION"
    else
        echo "[ship-preflight] deps=$DEPS_ACTION sim=$SIM_ACTION"
    fi
}

[ "${PWT_SHIP_PREFLIGHT_DISABLE:-0}" = "1" ] && { DEPS_ACTION="disabled"; SIM_ACTION="disabled"; emit; exit 0; }
[ -d "$WORKTREE" ] || { echo "[ship-preflight] worktree not a dir: $WORKTREE — fail-open" >&2; emit; exit 0; }

# ── (a) node_modules / turbo self-heal ────────────────────────────────────────
# Only for a JS workspace (pnpm-lock.yaml or turbo.json present) whose worktree
# node_modules is absent or empty. Prefer the share (symlink, ~0 disk); fall back
# to a frozen-lockfile install so `turbo`/workspace bins resolve.
if [ "${PWT_SHIP_DEPS_DISABLE:-0}" != "1" ]; then
    is_js=0
    { [ -f "$WORKTREE/pnpm-lock.yaml" ] || [ -f "$WORKTREE/turbo.json" ]; } && is_js=1
    nm_empty=1
    if [ -d "$WORKTREE/node_modules" ] && [ -n "$(ls -A "$WORKTREE/node_modules" 2>/dev/null)" ]; then nm_empty=0; fi
    if [ "$is_js" = "1" ] && [ "$nm_empty" = "1" ]; then
        DEPS_SHARE="${PWT_DEPS_SHARE_CMD:-$(cd "$(dirname "$0")" && pwd)/worktree-deps-share.sh}"
        MAIN=$(git -C "$WORKTREE" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')
        seeded=0
        if [ -n "$MAIN" ] && [ "$MAIN" != "$WORKTREE" ] && [ -x "$DEPS_SHARE" ]; then
            if "$DEPS_SHARE" --worktree "$WORKTREE" --main "$MAIN" >/dev/null 2>&1; then
                DEPS_ACTION="shared-from-main"; seeded=1
            fi
        fi
        if [ "$seeded" = "0" ]; then
            PNPM="${PWT_SHIP_PREFLIGHT_PNPM:-pnpm}"
            if command -v "$PNPM" >/dev/null 2>&1; then
                if ( cd "$WORKTREE" && "$PNPM" install --frozen-lockfile ) >/dev/null 2>&1; then
                    DEPS_ACTION="pnpm-install-frozen"
                else
                    DEPS_ACTION="failed(install)"; echo "[ship-preflight] deps install failed — test gate will surface it" >&2
                fi
            else
                DEPS_ACTION="failed(no-pnpm,no-share)"; echo "[ship-preflight] no deps-share + no pnpm — cannot seed node_modules" >&2
            fi
        fi
    elif [ "$is_js" = "1" ]; then
        DEPS_ACTION="present"
    fi
fi

# ── (b) orphaned iOS sim self-heal ────────────────────────────────────────────
# Only for an iOS workspace (ios/ dir, *.xcworkspace/*.xcodeproj, or .maestro/).
# A booted sim left by a stopped worker can be app-less and false-fail maestro;
# shut booted sims so the test harness boots a fresh one with the app installed.
if [ "${PWT_SHIP_SIM_SHUTDOWN:-1}" != "0" ]; then
    is_ios=0
    { [ -d "$WORKTREE/ios" ] || [ -d "$WORKTREE/.maestro" ] \
      || ls "$WORKTREE"/*.xcworkspace >/dev/null 2>&1 || ls "$WORKTREE"/*.xcodeproj >/dev/null 2>&1; } && is_ios=1
    XCRUN="${PWT_SHIP_PREFLIGHT_XCRUN:-xcrun}"
    if [ "$is_ios" = "1" ] && command -v "$XCRUN" >/dev/null 2>&1; then
        # NOTE: `grep -c` prints the count AND exits non-zero on zero matches, so
        # `|| echo 0` would double it to "0\n0". Capture the count directly, then sanitize.
        BOOTED=$("$XCRUN" simctl list devices booted 2>/dev/null | grep -c "Booted")
        printf '%s' "$BOOTED" | grep -qE '^[0-9]+$' || BOOTED=0
        if [ "$BOOTED" -gt 0 ]; then
            if "$XCRUN" simctl shutdown all >/dev/null 2>&1; then
                SIM_ACTION="shutdown($BOOTED booted)"
            else
                SIM_ACTION="failed(shutdown)"; echo "[ship-preflight] simctl shutdown failed — non-fatal" >&2
            fi
        else
            SIM_ACTION="none-booted"
        fi
    elif [ "$is_ios" = "1" ]; then
        SIM_ACTION="no-xcrun"
    fi
fi

emit
exit 0
