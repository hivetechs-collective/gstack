#!/bin/bash
# pwt-claims-cleanup — remove orphan and test-pattern entries from the
# cross-repo PWT RAM claims registry.
#
# The fair-share gate (pwt-fair-share.sh) counts "active workers" by reading
# the registry at ~/.claude/state/pwt-ram-claims.jsonl. Bats tests, crashed
# workers, and supervisors that died without running the cleanup hook all
# leave orphan rows that wrongly inflate the count and refuse legitimate
# spawns with AT_FAIR_SHARE. This script removes:
#
#   1. Test-pattern entries: repo names matching
#        plan-w-team-test.*  (bats sandbox basenames)
#        pwt-shim-*          (harness shim repos)
#        sandbox-*           (manual test sandboxes)
#   2. Orphan SIDs: claim's sid is not present in `claude agents --json`
#      (only attempted if `claude` is on PATH; otherwise skipped).
#
# Usage:
#   pwt-claims-cleanup.sh              # default: clean and print summary
#   pwt-claims-cleanup.sh --dry-run    # print what would be removed, no write
#   pwt-claims-cleanup.sh --quiet      # suppress non-error output
#
# Exit codes:
#   0  success (or no-op when registry missing/empty)
#   1  malformed registry path or unwritable target
#
# Env:
#   PWT_RAM_CLAIMS_PATH       canonical override (preferred)
#   PWT_RAM_CLAIMS_REGISTRY   legacy alias (back-compat)
#
# See docs/specs/pwt-test-isolation-fair-share.md.

set -u

REGISTRY="${PWT_RAM_CLAIMS_PATH:-${PWT_RAM_CLAIMS_REGISTRY:-$HOME/.claude/state/pwt-ram-claims.jsonl}}"
LOCK_DIR="${REGISTRY}.lock"

# keep in sync with pwt-ram-claim.sh acquire_lock — same lock dir, same semantics
acquire_lock() {
    local attempts=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        attempts=$(( attempts + 1 ))
        if [ "$attempts" -gt 50 ]; then
            # Stale-lock recovery: if no PID file or owner is dead, reclaim.
            local stale_pid=""
            stale_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
            if [ -z "$stale_pid" ] || ! kill -0 "$stale_pid" 2>/dev/null; then
                rm -rf "$LOCK_DIR" 2>/dev/null
                continue
            fi
            echo "ERR: pwt-claims-cleanup could not acquire lock $LOCK_DIR (held by PID $stale_pid)" >&2
            return 1
        fi
        sleep 0.05 2>/dev/null || sleep 1
    done
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null
}

DRY_RUN=0
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --quiet)   QUIET=1 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "pwt-claims-cleanup: unknown arg: $arg" >&2
            exit 1
            ;;
    esac
done

log() {
    [ "$QUIET" = "1" ] && return 0
    printf '%s\n' "$*"
}

# Fast path: nothing to do.
if [ ! -f "$REGISTRY" ]; then
    log "pwt-claims-cleanup: no registry at $REGISTRY (no-op)"
    exit 0
fi

if [ ! -s "$REGISTRY" ]; then
    log "pwt-claims-cleanup: empty registry at $REGISTRY (no-op)"
    exit 0
fi

# Collect live SIDs from `claude agents --json` if available. If unavailable
# or if `claude` itself fails, we still do test-pattern cleanup but skip
# orphan-SID removal — we cannot safely classify a SID as orphan when we
# can't read the live-agents list.
LIVE_SIDS_FILE=""
HAS_LIVE_SIDS=0
if command -v claude >/dev/null 2>&1; then
    LIVE_SIDS_FILE=$(mktemp)
    CLAUDE_RAW=$(mktemp)
    # Prefer the extended wrapper so Agent-tool subagent sessionIds are also
    # considered "live" — without this, the cleanup would treat a worker that
    # spawned subagents as orphaned mid-flight and GC its claims.
    CLAUDE_AGENTS_WRAPPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-agents-extended.sh"
    if [ -x "$CLAUDE_AGENTS_WRAPPER" ]; then
        CLAUDE_AGENTS_CMD=("$CLAUDE_AGENTS_WRAPPER")
    else
        CLAUDE_AGENTS_CMD=(claude agents --json)
    fi
    if "${CLAUDE_AGENTS_CMD[@]}" >"$CLAUDE_RAW" 2>/dev/null; then
        grep -oE '"sessionId"[[:space:]]*:[[:space:]]*"[a-f0-9-]+"' "$CLAUDE_RAW" \
            | sed -E 's/.*"([a-f0-9-]+)"/\1/' \
            | tr -d ' ' \
            > "$LIVE_SIDS_FILE" 2>/dev/null || true
        # Add short-SID variants (first 8 hex chars) since the registry stores
        # short SIDs and `claude agents` returns full uuid-style SIDs.
        if [ -s "$LIVE_SIDS_FILE" ]; then
            awk '{ print $0; print substr($0, 1, 8) }' "$LIVE_SIDS_FILE" \
                > "${LIVE_SIDS_FILE}.full" \
                && mv "${LIVE_SIDS_FILE}.full" "$LIVE_SIDS_FILE"
        fi
        # Only enable orphan-SID removal if `claude agents` actually succeeded.
        # An empty live-SID list with a successful exit means "no agents running"
        # — orphan-SID removal IS appropriate (everything in the registry is
        # genuinely stale). Failure means we shouldn't infer anything.
        HAS_LIVE_SIDS=1
    fi
    rm -f "$CLAUDE_RAW"
fi

# Helper: is the given line a removal candidate? Echo "REMOVE:<reason>" or "KEEP".
classify_line() {
    local line="$1"
    # Empty / comment / non-JSON: keep (don't touch).
    case "$line" in
        ''|'#'*) printf 'KEEP\n'; return ;;
    esac
    # Extract repo and sid via grep+sed (no jq dependency).
    local repo sid
    repo=$(printf '%s' "$line" \
        | grep -oE '"repo"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed -E 's/.*"([^"]*)"$/\1/')
    sid=$(printf '%s' "$line" \
        | grep -oE '"sid"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed -E 's/.*"([^"]*)"$/\1/')

    # Test-pattern repos.
    case "$repo" in
        plan-w-team-test.*|pwt-shim-*|sandbox-*)
            printf 'REMOVE:test-pattern repo=%s\n' "$repo"
            return
            ;;
    esac

    # Orphan-SID removal (only when we have a live-SID list).
    if [ "$HAS_LIVE_SIDS" = "1" ] && [ -n "$sid" ]; then
        if ! grep -qxF "$sid" "$LIVE_SIDS_FILE"; then
            printf 'REMOVE:orphan-sid sid=%s repo=%s\n' "$sid" "$repo"
            return
        fi
    fi

    printf 'KEEP\n'
}

# Serialize the read→rewrite window against pwt-ram-claim.sh remove/sweep
# (same ${REGISTRY}.lock mkdir lock). Without it, a concurrent add/remove
# between our snapshot read and the Pass-2 mv is silently clobbered (lost
# update). Contention degrades to skip-cleanup: this script runs --quiet on
# every fair-share gate evaluation, so fail-open (registry untouched, exit 0)
# rather than blocking the spawn gate. Live-SID collection above stays
# OUTSIDE the lock — `claude agents` can be slow and is not a registry write.
if ! acquire_lock; then
    log "pwt-claims-cleanup: registry lock busy — skipping cleanup (fail-open)"
    [ -n "$LIVE_SIDS_FILE" ] && rm -f "$LIVE_SIDS_FILE"
    exit 0
fi

# Pass 1: classify and report.
KEPT_FILE=$(mktemp)
REMOVED_COUNT=0
KEPT_COUNT=0
REMOVAL_REASONS=$(mktemp)

while IFS= read -r line || [ -n "$line" ]; do
    verdict=$(classify_line "$line")
    case "$verdict" in
        KEEP)
            printf '%s\n' "$line" >> "$KEPT_FILE"
            KEPT_COUNT=$((KEPT_COUNT + 1))
            ;;
        REMOVE:*)
            reason="${verdict#REMOVE:}"
            printf '  - %s\n' "$reason" >> "$REMOVAL_REASONS"
            REMOVED_COUNT=$((REMOVED_COUNT + 1))
            ;;
    esac
done < "$REGISTRY"

# Summary.
if [ "$REMOVED_COUNT" = "0" ]; then
    release_lock
    log "pwt-claims-cleanup: registry clean ($KEPT_COUNT entries, 0 removed)"
    rm -f "$KEPT_FILE" "$REMOVAL_REASONS"
    [ -n "$LIVE_SIDS_FILE" ] && rm -f "$LIVE_SIDS_FILE"
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    release_lock
    log "pwt-claims-cleanup: DRY-RUN would remove $REMOVED_COUNT / $((KEPT_COUNT + REMOVED_COUNT)) entries from $REGISTRY"
    [ "$QUIET" = "0" ] && cat "$REMOVAL_REASONS"
    rm -f "$KEPT_FILE" "$REMOVAL_REASONS"
    [ -n "$LIVE_SIDS_FILE" ] && rm -f "$LIVE_SIDS_FILE"
    exit 0
fi

# Pass 2: atomic rewrite (temp + rename).
TMP_REG="${REGISTRY}.cleanup.$$"
if ! mv "$KEPT_FILE" "$TMP_REG"; then
    release_lock
    echo "pwt-claims-cleanup: failed to stage kept file" >&2
    rm -f "$REMOVAL_REASONS"
    [ -n "$LIVE_SIDS_FILE" ] && rm -f "$LIVE_SIDS_FILE"
    exit 1
fi
if ! mv "$TMP_REG" "$REGISTRY"; then
    release_lock
    echo "pwt-claims-cleanup: failed to rename $TMP_REG → $REGISTRY" >&2
    rm -f "$TMP_REG" "$REMOVAL_REASONS"
    [ -n "$LIVE_SIDS_FILE" ] && rm -f "$LIVE_SIDS_FILE"
    exit 1
fi
release_lock

log "pwt-claims-cleanup: removed $REMOVED_COUNT entries from $REGISTRY (kept $KEPT_COUNT)"
[ "$QUIET" = "0" ] && cat "$REMOVAL_REASONS"

rm -f "$REMOVAL_REASONS"
[ -n "$LIVE_SIDS_FILE" ] && rm -f "$LIVE_SIDS_FILE"
exit 0
