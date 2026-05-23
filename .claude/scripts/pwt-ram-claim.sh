#!/bin/bash
# pwt-ram-claim — manage the cross-repo spawn-claims registry.
#
# The registry is a JSONL file at ~/.claude/state/pwt-ram-claims.jsonl.
# Override the path with PWT_RAM_CLAIMS_PATH (canonical) or
# PWT_RAM_CLAIMS_REGISTRY (legacy alias, back-compat). Each line is a worker
# claim:
#
#   {"repo":"<name>","sid":"<8hex>","started_at":"<iso8601>","estimated_gb":1.8,"priority":"normal"}
#
# Commands:
#   pwt-ram-claim.sh add <repo> <sid> [<priority>]
#   pwt-ram-claim.sh remove <sid>
#   pwt-ram-claim.sh list
#   pwt-ram-claim.sh sweep    # remove claims whose transcript is older than IDLE threshold
#
# Idle threshold: PWT_FAIR_SHARE_IDLE_THRESHOLD (default 300s). 0 disables sweep.
#
# Concurrency: append-only (atomic short writes); remove uses mkdir lock and
# rewrites the file. The sweep operation also takes the lock.
#
# Used by pwt-goal.sh (add on spawn), retro/cleanup hooks (remove on terminal),
# and the supervisor POLLING LOOP (sweep idle).
#
# See docs/specs/pwt-cross-repo-fair-share.md and shared/supervisor-protocol.md
# §FAIR SHARE CHECK.

set -u

# Env precedence: PWT_RAM_CLAIMS_PATH (canonical) > PWT_RAM_CLAIMS_REGISTRY
# (legacy alias) > default ~/.claude/state/pwt-ram-claims.jsonl. The two env
# names are equivalent; PWT_RAM_CLAIMS_PATH is the name new code and tests
# should use.
REGISTRY="${PWT_RAM_CLAIMS_PATH:-${PWT_RAM_CLAIMS_REGISTRY:-$HOME/.claude/state/pwt-ram-claims.jsonl}}"
LOCK_DIR="${REGISTRY}.lock"
IDLE_THRESHOLD="${PWT_FAIR_SHARE_IDLE_THRESHOLD:-300}"
[[ "$IDLE_THRESHOLD" =~ ^[0-9]+$ ]] || IDLE_THRESHOLD=300

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
            echo "ERR: pwt-ram-claim could not acquire lock $LOCK_DIR (held by PID $stale_pid)" >&2
            return 1
        fi
        sleep 0.05 2>/dev/null || sleep 1
    done
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null
}

ensure_registry() {
    local dir
    dir=$(dirname "$REGISTRY")
    mkdir -p "$dir" 2>/dev/null
    [ -f "$REGISTRY" ] || : > "$REGISTRY"
}

# Resolve this repo's name. Worktrees → parent repo basename.
resolve_repo_name() {
    local override="${1:-}"
    if [ -n "$override" ]; then
        printf '%s' "$override"
        return
    fi
    local top
    top=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$top" ]; then
        case "$top" in
            */.claude/worktrees/*)
                printf '%s' "$(basename "$(printf '%s' "$top" | sed -E 's|/.claude/worktrees/.*$||')")"
                ;;
            *)
                basename "$top"
                ;;
        esac
        return
    fi
    basename "$PWD"
}

# Transcript mtime for sid. Returns epoch or empty.
transcript_mtime_for_sid() {
    local sid="$1"
    if [ -n "${PWT_FAIR_SHARE_STUB_TRANSCRIPT_MTIME:-}" ] \
            && [ -r "${PWT_FAIR_SHARE_STUB_TRANSCRIPT_MTIME}" ]; then
        awk -v s="$sid" '$1==s {print $2; found=1; exit} END{if(!found) exit 1}' \
            "${PWT_FAIR_SHARE_STUB_TRANSCRIPT_MTIME}"
        return $?
    fi
    local f
    for f in "$HOME"/.claude/projects/*/"${sid}".jsonl; do
        [ -e "$f" ] || continue
        stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null
        return 0
    done
    return 1
}

cmd_add() {
    local repo="$1"
    local sid="$2"
    local priority="${3:-normal}"
    [ -z "$repo" ] && { echo "ERR: repo required" >&2; return 2; }
    [ -z "$sid" ] && { echo "ERR: sid required" >&2; return 2; }
    case "$priority" in
        critical|normal|background) ;;
        *) priority="normal" ;;
    esac
    ensure_registry
    local now est_gb
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    est_gb="${RAM_BUDGET_SESSION_COST_GB:-1.8}"
    # Append is atomic for small writes; no lock needed.
    printf '{"repo":"%s","sid":"%s","started_at":"%s","estimated_gb":%s,"priority":"%s"}\n' \
        "$repo" "$sid" "$now" "$est_gb" "$priority" >> "$REGISTRY"
}

cmd_remove() {
    local sid="$1"
    [ -z "$sid" ] && { echo "ERR: sid required" >&2; return 2; }
    ensure_registry
    acquire_lock || return 1
    local tmp
    tmp=$(mktemp -t pwt-claims.XXXXXX 2>/dev/null) || { release_lock; return 1; }
    grep -v "\"sid\":\"${sid}\"" "$REGISTRY" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$REGISTRY"
    release_lock
}

cmd_list() {
    ensure_registry
    cat "$REGISTRY"
}

cmd_sweep() {
    [ "$IDLE_THRESHOLD" -le 0 ] && return 0
    ensure_registry
    local now
    now="${PWT_FAIR_SHARE_STUB_NOW:-$(date +%s)}"
    acquire_lock || return 1
    local tmp
    tmp=$(mktemp -t pwt-claims-sweep.XXXXXX 2>/dev/null) || { release_lock; return 1; }
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local sid
        sid=$(printf '%s' "$line" | grep -oE '"sid":"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
        if [ -z "$sid" ]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        local mtime age
        mtime=$(transcript_mtime_for_sid "$sid" 2>/dev/null || echo "")
        if [ -z "$mtime" ] || ! [[ "$mtime" =~ ^[0-9]+$ ]]; then
            # No transcript info; keep the row (don't sweep what we can't measure).
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        age=$(( now - mtime ))
        if [ "$age" -le "$IDLE_THRESHOLD" ]; then
            printf '%s\n' "$line" >> "$tmp"
        else
            # Swept — log to stderr for observability.
            echo "swept idle claim sid=$sid age=${age}s threshold=${IDLE_THRESHOLD}s" >&2
        fi
    done < "$REGISTRY"
    mv "$tmp" "$REGISTRY"
    release_lock
}

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        add)    cmd_add "$@" ;;
        remove) cmd_remove "$@" ;;
        list)   cmd_list "$@" ;;
        sweep)  cmd_sweep "$@" ;;
        ""|-h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#$//'
            ;;
        *)
            echo "ERR: unknown command '$cmd'" >&2
            return 2
            ;;
    esac
}

main "$@"
