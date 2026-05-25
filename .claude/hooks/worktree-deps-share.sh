#!/usr/bin/env bash
# worktree-deps-share.sh (HOOK) — SubagentStart + SessionStart event wrapper.
#
# Fires AFTER a worktree directory already exists and shares its dependency
# trees from the main repo via .claude/scripts/worktree-deps-share.sh, instead
# of re-materializing node_modules / target / .venv from scratch (Layer 2
# disk-hygiene). Two trigger events, one event-agnostic shim — both carry `cwd`:
#   • SubagentStart — an Agent-tool subagent with isolation:"worktree" begins.
#       `cwd` IS the subagent's worktree.
#   • SessionStart  — a top-level `claude --worktree` / `claude --bg` session
#       (which are NOT subagents and never fire SubagentStart) starts inside its
#       worktree. `cwd` IS that worktree.
# In both cases a normal session whose `cwd` is the main repo no-ops (cwd==main).
#
# WHY NOT WorktreeCreate? That event REPLACES default git worktree creation:
#   the hook must itself create the worktree and echo its path to stdout, and
#   ANY non-zero exit (or no path) FAILS creation. It also fires BEFORE the
#   directory exists (payload cwd = the *main* repo, plus a `name`), so there
#   is nothing to share into yet. Registering a deps-share shim there silently
#   broke every worktree-isolated agent. SubagentStart/SessionStart are the
#   correct post-create, non-blocking triggers.
#
# This hook is a thin, fail-open shim:
#   • Neither event can block; on any error it logs and exits 0.
#   • Skips when WORKTREE_DEPS_SHARE_DISABLE=1 (incident kill switch).
#   • On SessionStart, skips redundant `compact`/`clear` re-fires (the worktree
#     was already set up on the originating `startup`/`resume`). SubagentStart
#     has no `source` field, so it always proceeds.
#
# Payloads (verified 2026-05-25, CLI 2.1.150):
#   SubagentStart: { session_id, transcript_path, cwd, agent_id, agent_type, hook_event_name }
#   SessionStart:  { session_id, transcript_path, cwd, source, model, hook_event_name }
#   The main repo is resolved via `git worktree list` (first / bare entry).
#
# Exit: always 0 (fail-open).

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$PROJECT_ROOT/.claude/scripts/worktree-deps-share.sh"
STATE_DIR="$PROJECT_ROOT/.claude/state"
LOG="$STATE_DIR/worktree-deps-share-hook.log"
mkdir -p "$STATE_DIR" 2>/dev/null || true

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true; }

# Kill switch
if [ "${WORKTREE_DEPS_SHARE_DISABLE:-0}" = "1" ]; then
    log "skip: WORKTREE_DEPS_SHARE_DISABLE=1"
    exit 0
fi

# Engine must exist (it ships in .claude/scripts/ via the sync allowlist).
if [ ! -x "$ENGINE" ]; then
    log "skip: engine not found/executable at $ENGINE"
    exit 0
fi

INPUT="$(cat 2>/dev/null || echo '{}')"

# SessionStart re-fires on compact/clear within an already-set-up session — the
# worktree was shared on the originating startup/resume, so skip the redundant
# re-run. SubagentStart has no `source` field (jq → empty), so it proceeds.
SOURCE=""
if command -v jq >/dev/null 2>&1; then
    SOURCE="$(echo "$INPUT" | jq -r '.source // empty' 2>/dev/null)"
fi
case "$SOURCE" in
    compact|clear)
        log "skip: SessionStart source=$SOURCE (already set up on startup/resume)"
        exit 0
        ;;
esac

# Resolve the worktree from the payload. `cwd` is the session's / subagent's
# working directory — for a worktree session that IS the worktree.
# (Older WorktreeCreate-shaped keys kept as defensive fallbacks.)
WT=""
if command -v jq >/dev/null 2>&1; then
    WT="$(echo "$INPUT" | jq -r '
        .cwd // .worktree_path // .worktreePath // .path // .worktree // empty
    ' 2>/dev/null)"
fi
# Fallback to env or current dir if payload had nothing usable.
[ -z "$WT" ] && WT="${CLAUDE_WORKTREE_PATH:-}"
[ -z "$WT" ] && WT="$(pwd)"

if [ ! -d "$WT" ]; then
    log "skip: resolved worktree path is not a directory: $WT"
    exit 0
fi

# Resolve the MAIN working tree for THIS repo via git (invariant #4: share only
# within the same repo's worktrees). The main tree is the first `git worktree
# list` entry (the primary checkout), NOT the newly created worktree.
MAIN=""
if command -v git >/dev/null 2>&1; then
    MAIN="$(git -C "$WT" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{print substr($0,10); exit}')"
fi
# Fallback: if git didn't resolve (e.g. detached), use PROJECT_ROOT.
[ -z "$MAIN" ] && MAIN="$PROJECT_ROOT"

# Don't share a tree with itself (the main tree itself can fire this event in
# some flows). Engine also guards this, but short-circuit cleanly.
WT_ABS="$(cd "$WT" 2>/dev/null && pwd)"
MAIN_ABS="$(cd "$MAIN" 2>/dev/null && pwd)"
if [ "$WT_ABS" = "$MAIN_ABS" ]; then
    log "skip: worktree == main ($WT_ABS)"
    exit 0
fi

# Strategy / disable lists flow through from env (set by the /plan-w-team
# directive or the user). Engine defaults to auto + lockfile-divergence guard.
SLUG="$(basename "$WT_ABS")"

log "applying deps-share: worktree=$WT_ABS main=$MAIN_ABS strategy=${WORKTREE_DEPS_STRATEGY:-auto}"

# --json output captured to the log for retro; engine never fails the run.
RESULT="$("$ENGINE" --worktree "$WT_ABS" --main "$MAIN_ABS" --slug "$SLUG" \
    --state-dir "$MAIN_ABS/.claude/state" --json 2>>"$LOG")" || {
    log "engine returned non-zero (non-fatal)"
    exit 0
}
log "result: $(echo "$RESULT" | tr -d '\n' | head -c 800)"

exit 0
