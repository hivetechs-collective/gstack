#!/bin/bash
# Claude-Pattern: Automatic session start context loading
# Runs when Claude Code session begins or after compaction
# Enhanced: Uncommitted work detection + CI failure check (2025-12-26)

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$PROJECT_ROOT/.claude/state"
STATE_FILE="$STATE_DIR/session-state.md"
SESSION_LOG="$STATE_DIR/session-log.txt"
COMPACT_LOG="$STATE_DIR/compact-log.txt"
HOOKS_DIR="$PROJECT_ROOT/.claude/hooks"
UTILS_DIR="$PROJECT_ROOT/.claude/hooks/utils"

# The SessionStart payload (stdin JSON) carries this session's id — the canonical
# /plan-w-team lane identity (a worker IS the session whose id is its goal-state's
# worker_sid; docs/operations/lane-enforcement.md). Read once, here, before any
# child process can inherit and drain stdin; bounded (`read -t 1`, whole seconds
# for bash 3.2) and skipped on a terminal, so a manual run never waits on it.
# Only the 8-char prefix is kept (__SS_SELF8), lower-cased; empty = unknown.
__SS_SELF8=""
__SS_HOOK_READ=""
__ss_hook_session() {
    [ -n "${__SS_HOOK_READ:-}" ] && return 0
    __SS_HOOK_READ=1
    __SS_SELF8=""
    [ -t 0 ] && return 0
    local input="" sid=""
    IFS= read -r -d '' -t 1 input 2>/dev/null || true
    [ -n "$input" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    sid=$(printf '%s' "$input" | jq -r '.session_id // "" | tostring' 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    __SS_SELF8="${sid:0:8}"
    return 0
}
__ss_hook_session

# Resolve and export CLAUDE_BIN so transitively-spawned subscripts (e.g.
# .claude/scripts/version-uplift/detect-version.sh, which calls
# `claude --version`) don't fail with "env: claude: No such file or directory"
# when the hook's inherited $PATH lacks the install dir. The helper is
# best-effort; if it fails, CLAUDE_BIN stays unset and subscripts fall back
# to bare `claude` (the pre-2026-05-23 behavior).
LOCATE_CLAUDE="$PROJECT_ROOT/.claude/scripts/locate-claude.sh"
if [ -x "$LOCATE_CLAUDE" ]; then
    CLAUDE_BIN="$("$LOCATE_CLAUDE" 2>/dev/null)" || CLAUDE_BIN=""
    [ -n "$CLAUDE_BIN" ] && export CLAUDE_BIN
fi

# =================================================================
# CMUX: Auto-rename workspace tab to repo name (like tmux rename-window)
#
# CMUX is the Claude-pattern workspace manager. When a Claude Code
# session starts inside a CMUX-managed environment, $CMUX_SOCKET is
# set by the cmux daemon — its presence confirms we are inside a
# managed workspace pane.
#
# This block makes each Claude workspace tab display the repository
# name, giving the same "named tab" UX you get with tmux rename-window.
#
# Graceful-failure design:
#   - `command -v cmux` guards against machines that don't have cmux installed
#   - All git/cmux calls redirect stderr to /dev/null so hook never blocks
#     the session if the workspace manager or git is unavailable
# =================================================================
if [ -n "$CMUX_SOCKET" ] && command -v cmux &>/dev/null; then
    # Resolve the top-level git directory name (e.g. "claude-pattern")
    # Works from any subdirectory or worktree inside the repo
    REPO_NAME=$(basename "$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)

    # Only rename if we successfully resolved a repo name
    if [ -n "$REPO_NAME" ]; then
        cmux rename-workspace "$REPO_NAME" 2>/dev/null
    fi
fi

# Source JSON logger if available
if [ -f "$UTILS_DIR/json-logger.sh" ]; then
    source "$UTILS_DIR/json-logger.sh"
    LOGGING_ENABLED=true
else
    LOGGING_ENABLED=false
fi

# Log this session start
mkdir -p "$STATE_DIR"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "[$TIMESTAMP] SESSION_START" >> "$SESSION_LOG"

# JSON log session start
if [ "$LOGGING_ENABLED" = "true" ]; then
    log_session "start" "{\"agent_type\":\"${AGENT_TYPE:-main}\"}"
fi

# =================================================================
# AUTO-SYNC FROM CLAUDE-PATTERN (keeps all projects up to date)
# =================================================================
# Path to the claude-pattern SOURCE repo. This hook is synced INTO consumer
# projects, so it must NOT be derived from this file's location — a consumer's
# copy lives in the consumer repo, not in claude-pattern. Resolution order:
#   1. CLAUDE_PATTERN_ROOT if exported (works for any layout)
#   2. a `claude-pattern` sibling of the current project (the common convention)
# If neither exists, auto_sync_from_pattern no-ops via its SYNC_SCRIPT check.
CLAUDE_PATTERN="${CLAUDE_PATTERN_ROOT:-$(dirname "$PROJECT_ROOT")/claude-pattern}"
LOCAL_VERSION_FILE="$PROJECT_ROOT/.claude/.sync-version"
SOURCE_VERSION_FILE="$CLAUDE_PATTERN/.claude/.sync-version"
SYNC_SCRIPT="$CLAUDE_PATTERN/.claude/scripts/sync-to-project.sh"

# Checkout topology, asked of git instead of `[ -d .git ]`. In a LINKED worktree
# (and a submodule) .git is a FILE, so the old directory test read every lane
# worktree as "not a git checkout": no origin, so mode=regen, so an in-place
# regen of tracked files inside the lane's worktree (/plan-w-team 2.51.5 review).
# `rev-parse --git-common-dir` answers for all three layouts; paths are made
# absolute (git prints them relative to PROJECT_ROOT in a primary checkout) so a
# PROJECT_ROOT below the git toplevel is not misread as a linked worktree.
__ss_git_path() {   # <--git-dir|--git-common-dir> → absolute physical path, or nothing
    local p
    p=$(git -C "$PROJECT_ROOT" rev-parse "$1" 2>/dev/null) || return 1
    [ -n "$p" ] || return 1
    case "$p" in /*) ;; *) p="$PROJECT_ROOT/$p" ;; esac
    (cd "$p" 2>/dev/null && pwd -P)
}
__ss_in_git_checkout() {   # 0 = PROJECT_ROOT is in a git checkout (primary, linked worktree or submodule)
    command -v git >/dev/null 2>&1 && [ -n "$(__ss_git_path --git-common-dir)" ]
}
__ss_linked_worktree() {   # 0 = PROJECT_ROOT is a LINKED worktree (its git dir is not the common dir)
    local gd cd
    gd=$(__ss_git_path --git-dir) && cd=$(__ss_git_path --git-common-dir) || return 1
    [ -n "$gd" ] && [ -n "$cd" ] && [ "$gd" != "$cd" ]
}
__ss_primary_checkout() {   # the PRIMARY checkout this one belongs to (claude-pattern-pull.sh's idiom)
    local cd main
    cd=$(__ss_git_path --git-common-dir) || return 1
    main=$(cd "$cd/.." 2>/dev/null && pwd -P) || return 1
    [ -d "$main/.git" ] && printf '%s' "$main"
}
__ss_checkout_toplevel() {   # 0 = PROJECT_ROOT IS its checkout's toplevel (primary, linked worktree or submodule root)
    # A consumer nested BELOW a git toplevel (a monorepo's apps/<x>) is in a git
    # checkout but is not one: origin, HEAD and `origin/<branch>:.claude/.sync-version`
    # all describe the enclosing repository, and claude-pattern-pull.sh delivers to
    # a checkout root. So it keeps the no-git behaviour (regen) — only a toplevel
    # takes the origin/ff and pull-mode paths. Physical paths on both sides.
    command -v git >/dev/null 2>&1 || return 1
    local top me
    top=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ -n "$top" ] || return 1
    top=$(cd "$top" 2>/dev/null && pwd -P) || return 1
    me=$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P) || return 1
    [ "$top" = "$me" ]
}
# 0 = this session is party to a LIVE /plan-w-team lane, identified the way the
# lane guard and plan-w-team-lane-context.sh identify it (lane-enforcement.md),
# from on-disk state in the MAIN checkout's .claude/state — never from an env
# marker a --bg session may not carry (a --bg session inherits the DAEMON's env,
# not its launcher's) or that doubles as a user kill switch:
#   worker     — this session's id (SessionStart stdin) is a live goal-state's worker_sid;
#   lane zone  — PROJECT_ROOT is (inside) a live lane's manifest worktree_path;
#   supervisor — bound: PLAN_W_TEAM_SUPERVISOR_SESSION=1, the goal-state's
#                supervisor_sid, or a pwt-launches.jsonl row showing this session
#                spawned the lane's worker.
# Live = valid JSON, no terminal_state, a slug, no user lane-release file, an
# 8-hex worker_sid, modified within PWT_GOAL_STALE_HOURS (default 24). Anything
# unreadable or missing (no jq, no state dir) → 1, "not a lane".
__ss_in_pwt_lane() {
    command -v jq >/dev/null 2>&1 || return 1
    local main sd me hours gf row term slug wsid ssid w8 wt
    main=""
    __ss_in_git_checkout && main=$(__ss_primary_checkout)
    [ -n "$main" ] || main=$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P) || return 1
    sd="$main/.claude/state"
    [ -d "$sd" ] || return 1
    __ss_hook_session
    me=$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P) || return 1
    hours="${PWT_GOAL_STALE_HOURS:-24}"
    case "$hours" in ''|*[!0-9]*) hours=24 ;; esac
    while IFS= read -r gf; do
        [ -f "$gf" ] || continue
        row=$(jq -r '[((.terminal_state // "") | tostring), ((.slug // "") | tostring),
                      ((.worker_sid // "") | tostring), ((.supervisor_sid // "") | tostring)]
                     | join("|")' "$gf" 2>/dev/null) || continue
        IFS='|' read -r term slug wsid ssid <<EOF
$row
EOF
        [ -z "$term" ] && [ -n "$slug" ] || continue
        [ -f "$sd/plan-w-team-lane-release-${slug}.json" ] && continue
        wsid=$(printf '%s' "$wsid" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        case "$wsid" in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
            *) continue ;;
        esac
        w8="${wsid:0:8}"
        [ -n "$__SS_SELF8" ] && [ "$__SS_SELF8" = "$w8" ] && return 0
        wt=$(jq -r '.worktree_path // "" | tostring' "$sd/plan-w-team-manifest-${slug}.json" 2>/dev/null)
        if [ -n "$wt" ] && wt=$(cd "$wt" 2>/dev/null && pwd -P) && [ "$wt" != "$main" ]; then
            case "$me" in "$wt"|"$wt"/*) return 0 ;; esac
        fi
        [ "${PLAN_W_TEAM_SUPERVISOR_SESSION:-0}" = "1" ] && return 0
        [ -n "$__SS_SELF8" ] || continue
        ssid=$(printf '%s' "$ssid" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        [ -n "$ssid" ] && [ "${ssid:0:8}" = "$__SS_SELF8" ] && return 0
        if [ -f "$sd/pwt-launches.jsonl" ] \
            && jq -r --arg w "$w8" 'select(((.sid // "") | tostring | ascii_downcase | startswith($w))) | ((.parent_sid // "") | tostring)' \
                   "$sd/pwt-launches.jsonl" 2>/dev/null \
               | tr '[:upper:]' '[:lower:]' | cut -c1-8 | grep -qFx "$__SS_SELF8"; then
            return 0
        fi
    done <<EOF
$(find "$sd" -maxdepth 1 -type f -name 'plan-w-team-goal-*.json' -mmin "-$((hours * 60))" 2>/dev/null)
EOF
    return 1
}
__ss_origin_default_branch() {   # origin's default branch from last-known refs (no fetch)
    local b
    b=$(git -C "$PROJECT_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
    if [ -z "$b" ]; then
        for b in main master; do
            git -C "$PROJECT_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$b" >/dev/null && break
            b=""
        done
    fi
    [ -n "$b" ] && printf '%s' "$b"
}

auto_sync_from_pattern() {
    # Skip if we ARE claude-pattern
    if [ "$PROJECT_ROOT" = "$CLAUDE_PATTERN" ]; then
        return 0
    fi

    # Skip if sync script doesn't exist
    if [ ! -f "$SYNC_SCRIPT" ]; then
        return 0
    fi

    # ...or a linked worktree of it, whose primary IS the source: "syncing" it from
    # that primary would regenerate its committed .claude/ work back to the
    # primary's copy in the working tree. This self-skip asks the BROAD question
    # (any git checkout, at any depth); everything git-driven below — the origin
    # check, the ff-pull, the pull-mode default — asks the narrow one: is
    # PROJECT_ROOT the TOPLEVEL of its checkout (git_top). A consumer nested in a
    # monorepo is not, and keeps the regen behaviour it had before 2.53.0.
    local git_top=false own_primary="" source_root=""
    if __ss_in_git_checkout; then
        own_primary=$(__ss_primary_checkout)
        source_root=$(cd "$CLAUDE_PATTERN" 2>/dev/null && pwd -P)
        if [ -n "$own_primary" ] && [ "$own_primary" = "$source_root" ]; then
            return 0
        fi
        __ss_checkout_toplevel && git_top=true
    fi

    local needs_sync=false
    local reason=""

    # Check if .claude directory is missing entirely
    if [ ! -d "$PROJECT_ROOT/.claude" ]; then
        needs_sync=true
        reason="No .claude directory"
    # Check if version file is missing locally
    elif [ ! -f "$LOCAL_VERSION_FILE" ]; then
        needs_sync=true
        reason="No sync version (first sync)"
    # Check if source version is newer
    elif [ -f "$SOURCE_VERSION_FILE" ]; then
        SOURCE_DATE=$(cat "$SOURCE_VERSION_FILE" 2>/dev/null)
        LOCAL_DATE=$(cat "$LOCAL_VERSION_FILE" 2>/dev/null)
        # Only sync FORWARD. The stamps are ISO-8601 UTC, so a plain string
        # compare orders them. A local claude-pattern checkout that is behind
        # its origin carries an OLDER stamp than the consumer repo; syncing
        # from it rewrites tracked files backwards (cleanscale #1943).
        if [[ "$SOURCE_DATE" < "$LOCAL_DATE" ]]; then
            echo ""
            echo "⚠️  AUTO-SYNC SKIPPED: claude-pattern source ($SOURCE_DATE) is BEHIND this repo ($LOCAL_DATE)"
            echo "   Fast-forward the source first: git -C $CLAUDE_PATTERN pull --ff-only"
            echo ""
            return 0
        elif [ "$SOURCE_DATE" != "$LOCAL_DATE" ]; then
            needs_sync=true
            reason="claude-pattern updated ($SOURCE_DATE)"
        fi
    fi

    if [ "$needs_sync" != true ]; then
        return 0
    fi

    echo ""
    echo "🔄 AUTO-SYNC: $reason"

    # Lane stand-down. A session party to a live /plan-w-team lane (its worker,
    # any session in its worktree, or its bound supervisor — and SessionStart fires
    # again on each resume and compaction) never acts on a claude-pattern sync: no
    # detached pull launched per lane start, no ff-pull moving HEAD under a running
    # pipeline, no in-place regen writing tracked files into the lane's diff. The
    # sync is not lost — the next session outside the lane performs it. Identity is
    # __ss_in_pwt_lane's (on-disk lane state), checked only when a sync is due.
    # Operator override: CLAUDE_PATTERN_SYNC_IN_LANE=1, checked first (deliberately
    # not named in the lane-facing line below).
    if [ "${CLAUDE_PATTERN_SYNC_IN_LANE:-}" != "1" ] && __ss_in_pwt_lane; then
        echo "   ↷ live /plan-w-team lane session — the sync is left to a session outside the lane"
        echo ""
        return 0
    fi

    # OPTION B: Prefer pull-from-origin when origin already has this version.
    # Consumer machines (mac-mini, laptops) pull the committed sync — keeping the
    # working tree clean. Only the author machine (where the bump originated)
    # falls through to local regen, where a commit+push is expected to follow.
    # A LINKED worktree is left to its branch and never pulled into here; what
    # decides it is whether the sync already reached origin's DEFAULT branch —
    # where claude-pattern-pull.sh delivers it — read from last-known refs with no
    # fetch (the detached pull fetches for itself and no-ops if origin has it).
    local origin_has_version=false
    local current_branch="" check_branch="" linked_wt=false
    if [ "$git_top" = true ]; then
        __ss_linked_worktree && linked_wt=true
        if [ "$linked_wt" = true ]; then
            check_branch=$(__ss_origin_default_branch)
        else
            current_branch=$(git -C "$PROJECT_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")
            check_branch="$current_branch"
            if [ -n "$current_branch" ] && git -C "$PROJECT_ROOT" remote get-url origin >/dev/null 2>&1; then
                git -C "$PROJECT_ROOT" fetch origin "$current_branch" --quiet 2>/dev/null || true
            fi
        fi
        if [ -n "$check_branch" ] && git -C "$PROJECT_ROOT" remote get-url origin >/dev/null 2>&1; then
            local origin_version
            origin_version=$(git -C "$PROJECT_ROOT" show "origin/$check_branch:.claude/.sync-version" 2>/dev/null || echo "")
            local source_version
            source_version=$(cat "$SOURCE_VERSION_FILE" 2>/dev/null || echo "")
            if [ -n "$origin_version" ] && [ "$origin_version" = "$source_version" ]; then
                origin_has_version=true
            fi
        fi
    fi

    if [ "$origin_has_version" = true ] && [ "$linked_wt" = true ]; then
        echo "   ✓ origin/$check_branch already carries this version — this linked worktree takes it when its branch merges $check_branch"
        echo ""
        return 0
    fi

    if [ "$origin_has_version" = true ]; then
        # Consumer path: refuse to pull over a dirty .claude/ — surface it instead.
        if ! git -C "$PROJECT_ROOT" diff --quiet -- .claude/ 2>/dev/null \
            || ! git -C "$PROJECT_ROOT" diff --cached --quiet -- .claude/ 2>/dev/null; then
            echo "   ⚠️  .claude/ is dirty — skipping pull to preserve local changes"
            echo "   Review: git -C $PROJECT_ROOT status -- .claude/"
            echo ""
            return 0
        fi
        echo "   ↓ pulling from origin/$current_branch (origin has this version)"
        if git -C "$PROJECT_ROOT" pull --ff-only origin "$current_branch" --quiet 2>/dev/null; then
            echo "   ✅ Pulled from origin"
        else
            echo "   ⚠️  Pull failed (non-fast-forward or conflict) — leave as-is"
        fi
        echo ""
        return 0
    fi

    # Consumer PULL mode (2.39.0). Origin does not carry this version yet. The
    # old behaviour regenerated the sync files IN PLACE here ("author path"),
    # which left uncommitted tracked files on a consumer's primary checkout —
    # cleanscale's ff-only self-update then skipped as "dirty" and lane
    # worktrees piled up behind it (2026-09-03). A consumer with an origin now
    # PULLS instead: claude-pattern-pull.sh runs detached, builds the sync
    # commit in a temporary worktree from claude-pattern's remote, delivers it
    # to origin (direct / pr / branch per .claude/.sync-policy), and only ever
    # fast-forwards a clean primary. The in-place regen survives solely for
    # mode=regen (or a consumer with no origin to deliver to, or one nested below
    # its checkout's toplevel — the pull default needs a checkout root).
    local sync_mode=""
    if [ -f "$PROJECT_ROOT/.claude/.sync-policy" ]; then
        sync_mode=$(sed -n 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*//p' "$PROJECT_ROOT/.claude/.sync-policy" 2>/dev/null | tail -1 | tr -d '[:space:]')
    fi
    if [ -z "$sync_mode" ]; then
        if [ "$git_top" = true ] && git -C "$PROJECT_ROOT" remote get-url origin >/dev/null 2>&1; then
            sync_mode="pull"
        else
            sync_mode="regen"
        fi
    fi
    if [ "$sync_mode" != "regen" ] && [ -z "${CLAUDE_PATTERN_SYNC_FORCE_REGEN:-}" ]; then
        local puller="$PROJECT_ROOT/.claude/scripts/claude-pattern-pull.sh"
        [ -x "$puller" ] || puller="$CLAUDE_PATTERN/.claude/scripts/claude-pattern-pull.sh"
        if [ -x "$puller" ]; then
            mkdir -p "$PROJECT_ROOT/.claude/state" 2>/dev/null || true
            local pull_log="$PROJECT_ROOT/.claude/state/claude-pattern-pull.log"
            echo "   ↓ consumer pull mode: delivering the claude-pattern sync to origin in the background"
            echo "     (temporary worktree; the primary checkout is only ever fast-forwarded when clean)"
            echo "     log: $pull_log"
            nohup "$puller" "$PROJECT_ROOT" --auto >> "$pull_log" 2>&1 < /dev/null &
        else
            echo "   ⚠️  claude-pattern-pull.sh not found — not regenerating in place (set mode=regen in .claude/.sync-policy to opt back in)"
        fi
        echo ""
        return 0
    fi

    # Legacy regen path (mode=regen only): regenerate in place; the caller is
    # expected to commit+push so consumers can pull.
    #
    # The marker is sync-to-project.sh's to write: it stamps .sync-version LAST,
    # only after a sync that completed. This hook used to copy it on ANY exit 0,
    # and sync-to-project.sh also exits 0 on its dirty-.claude/ safety SKIP, so a
    # skipped sync was recorded as done — no retry until the next source bump,
    # "✅ Sync complete" on screen, and the stamp left as tracked dirt in the
    # working tree (/plan-w-team 2.51.5). Judge the outcome by the marker.
    echo "   Syncing from claude-pattern (local regen — commit+push to share)..."
    local sync_out="" sync_rc=0
    sync_out="$("$SYNC_SCRIPT" "$PROJECT_ROOT" 2>&1)" || sync_rc=$?
    if [ "$sync_rc" -ne 0 ]; then
        echo "   ⚠️  Sync failed (exit $sync_rc) - continuing with existing config"
    elif printf '%s\n' "$sync_out" | grep -q '^🛑 SKIP'; then   # anchored, as claude-pattern-pull.sh reads it
        echo "   ⚠️  Sync skipped: .claude/ has uncommitted changes — nothing written, retries next session"
        echo "   Review: git -C $PROJECT_ROOT status -- .claude/"
    elif [ ! -f "$SOURCE_VERSION_FILE" ] \
        || [ "$(cat "$LOCAL_VERSION_FILE" 2>/dev/null)" = "$(cat "$SOURCE_VERSION_FILE" 2>/dev/null)" ]; then
        echo "   ✅ Sync complete"
    else
        echo "   ⚠️  Sync did not complete (marker not updated) - retries next session"
    fi
    echo ""
}

# Status-line bundle refresh (2.37.1). Plan usage is per ACCOUNT and one /login
# changes what every open session on this machine bills to, so the status line must
# be current in every pane — including a repo whose skill sync stands down for
# in-progress work (auto_sync_from_pattern refuses a dirty .claude/) and a repo that
# never takes the skill sync at all. Provenance-guarded per file; the scoped
# `git commit --only` touches nothing else. Linked worktrees are left to their branch.
# A checkout on its DEFAULT branch with an origin (a PR-gated follower — cleanscale's
# primaries on both hosts) is left alone by the helper itself (exit 4, filtered below): the
# bundle reaches it through the sync PR. 2.37.2 — a direct commit on main had turned every
# ff-only follower of that checkout (self-update timer, ship chains) into `diverged`.
refresh_statusline_bundle() {
    local b="$CLAUDE_PATTERN/.claude/scripts/sync-statusline-bundle.sh"
    case "$PROJECT_ROOT" in "$CLAUDE_PATTERN"|"$CLAUDE_PATTERN"/*) return 0 ;; esac
    [ -x "$b" ] && [ -f "$PROJECT_ROOT/.claude/statusline.sh" ] || return 0
    command -v git >/dev/null 2>&1 && __ss_linked_worktree && return 0   # linked worktree
    bash "$b" "$PROJECT_ROOT" --commit 2>/dev/null | grep -E '^(✓|⚠|status-line bundle: [1-9])' | sed 's/^/   📊 /' || true
}
refresh_statusline_bundle

# Run auto-sync check
auto_sync_from_pattern

# =================================================================
# AGENT TYPE DETECTION (Claude Code v2.1.2+)
# =================================================================
# The AGENT_TYPE environment variable is now provided by Claude Code
# when --agent flag is used. This allows agent-specific initialization.
if [ -n "$AGENT_TYPE" ]; then
    echo "[$TIMESTAMP] SESSION_START agent_type=$AGENT_TYPE" >> "$SESSION_LOG"
fi

echo "═══════════════════════════════════════════════════════════════"
if [ -n "$AGENT_TYPE" ]; then
    echo "  CLAUDE-PATTERN SESSION INITIALIZED [Agent: $AGENT_TYPE]"
else
    echo "  CLAUDE-PATTERN SESSION INITIALIZED"
fi
echo "═══════════════════════════════════════════════════════════════"

# =================================================================
# DATE AWARENESS (Critical for accurate searches and context)
# =================================================================
CURRENT_DATE=$(date +"%B %d, %Y")
CURRENT_YEAR=$(date +"%Y")
echo ""
echo "📅 TODAY: $CURRENT_DATE"
echo "   When searching: use $CURRENT_YEAR (not older years)"
echo "   AI knowledge may be outdated - always verify with current sources"

# Agent-specific initialization
if [ -n "$AGENT_TYPE" ]; then
    case "$AGENT_TYPE" in
        security-expert)
            echo ""
            echo "🔒 Security audit mode - read-only analysis enabled"
            ;;
        code-review-expert)
            echo ""
            echo "📝 Code review mode - analysis and recommendations"
            ;;
        system-architect)
            echo ""
            echo "🏗️  Architecture planning mode - design exploration"
            ;;
        orchestrator)
            echo ""
            echo "🎯 Orchestrator mode - multi-agent coordination active"
            ;;
    esac
fi

# =================================================================
# UNCOMMITTED WORK DETECTION (100% reliable via hook)
# =================================================================
UNCOMMITTED=$(git -C "$PROJECT_ROOT" status --short 2>/dev/null)
if [ -n "$UNCOMMITTED" ]; then
    UNCOMMITTED_COUNT=$(echo "$UNCOMMITTED" | wc -l | tr -d ' ')
    echo ""
    echo "⚠️  UNCOMMITTED CHANGES DETECTED ($UNCOMMITTED_COUNT files)"
    echo "─────────────────────────────────────────────────────────────"
    echo "$UNCOMMITTED" | head -10
    if [ "$UNCOMMITTED_COUNT" -gt 10 ]; then
        echo "   ... and $((UNCOMMITTED_COUNT - 10)) more files"
    fi
    echo ""
    echo "📋 ACTIONS REQUIRED:"
    echo "   • Review changes: git diff"
    echo "   • If complete: git add . && git commit -m 'message'"
    echo "   • If incomplete: Continue work or git stash"
    echo "   • If invalid: git checkout . (WARNING: loses changes)"
    echo "─────────────────────────────────────────────────────────────"
fi

# =================================================================
# STALE PRIMARY-CHECKOUT DRIFT GUARD (Fix D)
# =================================================================
# After server-side squash-merges, the primary checkout can be left parked on a
# stale feature branch — behind origin/<default> with 0 unique commits — which
# blocks clean re-sync and accumulates drift. Nudge it back to default when
# provably safe (clean tree + 0 unique commits); otherwise warn. Runs ONLY in
# the MAIN checkout: a linked worktree has a .git FILE (not a dir), so worktree
# sessions — legitimately on a feature branch — are skipped (mirrors line ~124).
# Depends on the per-session state caches being untracked (sync-to-project.sh
# self-heal) so the tree is actually clean enough for the auto-switch to fire.
if [ -d "$PROJECT_ROOT/.git" ] && command -v git >/dev/null 2>&1; then
    pwt_branch=$(git -C "$PROJECT_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")
    pwt_def=$(git -C "$PROJECT_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
    [ -n "$pwt_def" ] || pwt_def=main
    if [ -n "$pwt_branch" ] && [ "$pwt_branch" != "$pwt_def" ] \
        && git -C "$PROJECT_ROOT" remote get-url origin >/dev/null 2>&1 \
        && git -C "$PROJECT_ROOT" fetch origin "$pwt_def" --quiet 2>/dev/null; then
        pwt_ahead=$(git -C "$PROJECT_ROOT" rev-list --count "origin/$pwt_def..HEAD" 2>/dev/null || echo "?")
        pwt_behind=$(git -C "$PROJECT_ROOT" rev-list --count "HEAD..origin/$pwt_def" 2>/dev/null || echo "?")
        pwt_dirty=$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)
        if [ "$pwt_ahead" = "0" ] && [ "$pwt_behind" != "0" ] && [ "$pwt_behind" != "?" ] && [ -z "$pwt_dirty" ]; then
            echo ""
            echo "⟳ Primary checkout on '$pwt_branch' is $pwt_behind behind origin/$pwt_def with 0 unique commits — restoring to $pwt_def."
            if git -C "$PROJECT_ROOT" switch "$pwt_def" 2>/dev/null \
                && git -C "$PROJECT_ROOT" merge --ff-only "origin/$pwt_def" 2>/dev/null; then
                echo "✓ Primary checkout now on $pwt_def (up to date)."
            fi
        elif [ "$pwt_ahead" != "0" ] && [ "$pwt_ahead" != "?" ]; then
            echo ""
            echo "⚠️  Primary checkout on '$pwt_branch' has $pwt_ahead unique commit(s) vs origin/$pwt_def — NOT auto-switching. Review/merge them."
        elif [ -n "$pwt_dirty" ]; then
            echo ""
            echo "⚠️  Primary checkout on '$pwt_branch' is behind origin/$pwt_def but the tree is dirty — commit/stash, then re-run to auto-restore."
        fi
    fi
fi

# =================================================================
# CI FAILURE DETECTION (100% reliable via hook)
# =================================================================
CI_FAILURES_LOG="$STATE_DIR/ci-failures.log"

if command -v gh &> /dev/null; then
    # Check for recent CI failures
    FAILED_RUNS=$(gh run list --limit 5 --json conclusion,name,headBranch --jq '[.[] | select(.conclusion == "failure")] | length' 2>/dev/null || echo "0")
    IN_PROGRESS=$(gh run list --limit 3 --json status --jq '[.[] | select(.status == "in_progress")] | length' 2>/dev/null || echo "0")

    if [ "$FAILED_RUNS" != "0" ] && [ "$FAILED_RUNS" != "" ]; then
        echo ""
        echo "🔴 CI FAILURES DETECTED: $FAILED_RUNS failing run(s)"
        echo "─────────────────────────────────────────────────────────────"
        gh run list --limit 5 --json conclusion,name,headBranch --jq '.[] | select(.conclusion == "failure") | "   ❌ \(.name): \(.headBranch)"' 2>/dev/null || true
        echo ""
        echo "📋 ACTIONS REQUIRED:"
        echo "   • View details: gh run list --limit 5"
        echo "   • See logs: gh run view <run-id> --log-failed"
        echo "   • Fix failures before new development"
        echo "─────────────────────────────────────────────────────────────"
    fi

    if [ "$IN_PROGRESS" != "0" ] && [ "$IN_PROGRESS" != "" ]; then
        echo ""
        echo "🟡 CI IN PROGRESS: $IN_PROGRESS run(s) still running"
        echo "   Monitor with: gh run list --limit 3"
    fi
fi

# =================================================================
# UNRESOLVED ISSUES CHECK (Ownership enforcement)
# =================================================================
if [ -f "$CI_FAILURES_LOG" ]; then
    # Count unresolved failures (FAILURE entries without corresponding RESOLVED)
    UNRESOLVED=$(grep "FAILURE:" "$CI_FAILURES_LOG" 2>/dev/null | while read -r line; do
        WORKFLOW=$(echo "$line" | sed 's/.*FAILURE: \([^-]*\).*/\1/' | xargs)
        if ! grep -q "RESOLVED:.*$WORKFLOW" "$CI_FAILURES_LOG" 2>/dev/null; then
            echo "$line"
        fi
    done | wc -l | tr -d ' ')

    if [ "$UNRESOLVED" -gt 0 ] 2>/dev/null; then
        echo ""
        echo "🚨 UNRESOLVED CI FAILURES: $UNRESOLVED issue(s) logged but not fixed"
        echo "┌─────────────────────────────────────────────────────────────┐"
        echo "│  YOU OWN THESE. FIX THEM BEFORE NEW DEVELOPMENT.           │"
        echo "└─────────────────────────────────────────────────────────────┘"
        echo ""
        echo "📋 Unresolved issues:"
        grep "FAILURE:" "$CI_FAILURES_LOG" 2>/dev/null | while read -r line; do
            WORKFLOW=$(echo "$line" | sed 's/.*FAILURE: \([^-]*\).*/\1/' | xargs)
            if ! grep -q "RESOLVED:.*$WORKFLOW" "$CI_FAILURES_LOG" 2>/dev/null; then
                echo "   $line"
            fi
        done | head -5
        echo ""
        echo "   Log: .claude/state/ci-failures.log"
        echo "   When fixed, mark resolved with:"
        echo "   echo \"[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] RESOLVED: <workflow> - <commit>\" >> .claude/state/ci-failures.log"
        echo "─────────────────────────────────────────────────────────────"
    fi
fi

# Quick hook health verification
HOOK_ISSUES=0
for hook in session-start.sh pre-compact.sh check-blocked-request.sh block-protected-paths.sh session-end.sh; do
    if [ ! -x "$HOOKS_DIR/$hook" ] 2>/dev/null; then
        HOOK_ISSUES=$((HOOK_ISSUES + 1))
    fi
done

if [ "$HOOK_ISSUES" -gt 0 ]; then
    echo ""
    echo "⚠️  HOOK HEALTH WARNING: $HOOK_ISSUES hooks missing or not executable"
    echo "   Run: .claude/hooks/health-check.sh"
    echo ""
fi

# Check if resuming from compaction
if [ -f "$STATE_FILE" ]; then
    echo ""
    echo "📂 RESTORED FROM COMPACTION - Previous state found"
    echo "   See: .claude/state/session-state.md for full details"

    # Show timestamp and trigger type from saved file
    SAVED_TIME=$(grep "Auto-saved:" "$STATE_FILE" | head -1 | sed 's/.*Auto-saved:\*\* //' || echo "unknown")
    TRIGGER=$(grep "Trigger:" "$STATE_FILE" | head -1 | sed 's/.*Trigger:\*\* //' || echo "unknown")
    echo "   Saved at: $SAVED_TIME"
    echo "   Trigger: $TRIGGER"

    # Verify PreCompact hook is working
    if echo "$TRIGGER" | grep -q "auto"; then
        echo "   ✅ PreCompact auto-trigger verified working"
    elif echo "$TRIGGER" | grep -q "manual"; then
        echo "   ✅ PreCompact manual-trigger verified working"
    elif echo "$TRIGGER" | grep -q "unknown"; then
        echo "   ⚠️  PreCompact hook may not be configured correctly"
    fi
    echo ""
    echo "   ⚠️  Review .claude/state/session-state.md for full context"
    echo ""
fi

# =================================================================
# DEATH SPIRAL DETECTION & RECOVERY
# =================================================================
if [ -f "$COMPACT_LOG" ]; then
    AUTO_COUNT=$(grep -c "triggered: auto" "$COMPACT_LOG" 2>/dev/null || true)
    [ -z "$AUTO_COUNT" ] && AUTO_COUNT=0

    # Check for compacts in the last hour (death spiral indicator)
    CURRENT_HOUR=$(date -u +"%Y-%m-%dT%H")
    COMPACTS_THIS_HOUR=$(grep -c "$CURRENT_HOUR" "$COMPACT_LOG" 2>/dev/null || echo "0")
    COMPACTS_THIS_HOUR=$(echo "$COMPACTS_THIS_HOUR" | tr -d '[:space:]')
    [ -z "$COMPACTS_THIS_HOUR" ] && COMPACTS_THIS_HOUR=0

    if [ "$COMPACTS_THIS_HOUR" -gt 2 ] 2>/dev/null; then
        echo ""
        echo "┌─────────────────────────────────────────────────────────────┐"
        echo "│  ⛔ DEATH SPIRAL DETECTED: $COMPACTS_THIS_HOUR COMPACTS THIS HOUR         │"
        echo "└─────────────────────────────────────────────────────────────┘"
        echo ""
        echo "🚨 YOU ARE IN A CONTEXT LOOP. STOP AND READ:"
        echo ""
        echo "   The last operation likely filled your context too fast."
        echo "   DO NOT repeat it. Instead:"
        echo ""
        echo "   ❌ DON'T: Repeat the same large operation"
        echo "   ❌ DON'T: Run multiple heavy tasks back-to-back"
        echo ""
        echo "   ✅ DO: Work on small, focused tasks"
        echo "   ✅ DO: Commit after every 1-2 files"
        echo "   ✅ DO: Check git log - task may already be done"
        echo "   ✅ NOTE: v2.1.2 saves large outputs to disk (not truncated)"
        echo ""
        echo "   📖 See: .claude/state/session-state.md for task state"
        echo "   📖 See: .claude/state/avoid-operations.txt for safe patterns"
        echo ""
        echo "─────────────────────────────────────────────────────────────"
    fi

    if [ "$AUTO_COUNT" -gt 0 ]; then
        echo "📊 Compaction Stats: $AUTO_COUNT auto-triggers verified"
    fi
fi

# =================================================================
# AUTO-CONTEXT INITIALIZATION (Memory Bank)
# =================================================================
# Automatically ensures CLAUDE.md is populated with project context.
# Runs /init --update if context is stale or missing.

CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"
INIT_SCRIPT="$PROJECT_ROOT/scripts/init-project-context.ts"
CONTEXT_STATE="$STATE_DIR/context-state.json"

auto_init_context() {
    local needs_init=false
    local reason=""

    # Check if CLAUDE.md exists
    if [ ! -f "$CLAUDE_MD" ]; then
        needs_init=true
        reason="CLAUDE.md missing"
    # Check if auto-generated section exists
    elif ! grep -q "AUTO-GENERATED by /init" "$CLAUDE_MD" 2>/dev/null; then
        needs_init=true
        reason="No auto-generated context"
    # Check if context is stale (older than 24 hours)
    elif [ -f "$CONTEXT_STATE" ]; then
        LAST_SCAN=$(cat "$CONTEXT_STATE" 2>/dev/null | grep -o '"timestamp":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$LAST_SCAN" ]; then
            # Convert to epoch and compare
            LAST_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_SCAN%.*}" +%s 2>/dev/null || echo "0")
            NOW_EPOCH=$(date +%s)
            AGE_HOURS=$(( (NOW_EPOCH - LAST_EPOCH) / 3600 ))
            if [ "$AGE_HOURS" -gt 24 ]; then
                needs_init=true
                reason="Context stale (${AGE_HOURS}h old)"
            fi
        fi
    fi

    # Run init if needed
    if [ "$needs_init" = true ] && [ -f "$INIT_SCRIPT" ]; then
        echo ""
        echo "🧠 AUTO-CONTEXT: $reason"
        echo "   Running /init --update..."

        # Run init script and capture JSON output
        if command -v tsx &> /dev/null; then
            INIT_OUTPUT=$(tsx "$INIT_SCRIPT" --json 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$INIT_OUTPUT" ]; then
                # Save context state
                echo "$INIT_OUTPUT" > "$CONTEXT_STATE"

                # Extract key info for display using Python (more reliable than grep)
                PROJECT_NAME=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null)
                PROJECT_TYPE=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type',''))" 2>/dev/null)
                AGENT_COUNT=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('claudeIntegration',{}).get('agentCount',0))" 2>/dev/null)

                echo "   ✅ Context loaded: $PROJECT_NAME ($PROJECT_TYPE)"
                echo "   📦 $AGENT_COUNT agents"

                # Update CLAUDE.md with auto-generated sections
                tsx "$INIT_SCRIPT" --update >/dev/null 2>&1
            else
                echo "   ⚠️  Init script failed - using existing context"
            fi
        else
            echo "   ⚠️  tsx not available - skipping auto-init"
        fi
    fi
}

# Run auto-context (silent if already current)
auto_init_context

# =================================================================
# PROJECT CONTEXT SUMMARY
# =================================================================
# Display key project info from context state

if [ -f "$CONTEXT_STATE" ]; then
    PROJECT_NAME=$(cat "$CONTEXT_STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','Unknown'))" 2>/dev/null)
    PROJECT_TYPE=$(cat "$CONTEXT_STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type','unknown'))" 2>/dev/null)
    AGENT_COUNT=$(cat "$CONTEXT_STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('claudeIntegration',{}).get('agentCount',0))" 2>/dev/null)
    COMMAND_COUNT=$(cat "$CONTEXT_STATE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('claudeIntegration',{}).get('commandCount',0))" 2>/dev/null)

    echo ""
    echo "📋 Project: $PROJECT_NAME"
    echo "📂 Type: $PROJECT_TYPE | 📦 $AGENT_COUNT agents | 🔧 $COMMAND_COUNT commands"
else
    # Fallback when no context state exists
    echo ""
    echo "📋 Project: $(basename "$PROJECT_ROOT")"
    echo "   Run /init to generate project context"
fi

echo ""
echo "📖 Commands: /plan-w-team /pwt-goal /init /context /review-pr"
echo "═══════════════════════════════════════════════════════════════"

# =================================================================
# VERSION-UPLIFT: Detect Claude Code CLI version change + auto-adopt
# =================================================================
# Bash-only automated chain (no LLM in the loop):
#   detect-version.sh → pending flag → uplift.sh (bg) → report → auto-launch.sh
#
# Best-effort fire-and-forget on every step (|| true). The chain has two
# eventual-consistency seams: uplift.sh is backgrounded so session-start
# latency stays low (typically <100ms; uplift completes in ~1-3s in the
# background), and auto-launch.sh may run before uplift.sh finishes writing
# the report — that's fine, the next session start picks it up.
VERSION_UPLIFT_DETECT="$PROJECT_ROOT/.claude/scripts/version-uplift/detect-version.sh"
VERSION_UPLIFT_AUTO_LAUNCH="$PROJECT_ROOT/.claude/scripts/version-uplift/auto-launch.sh"
VERSION_UPLIFT_UPLIFT="$PROJECT_ROOT/.claude/commands/plan-w-team/version-uplift/uplift.sh"
VERSION_UPLIFT_PENDING_FLAG="$STATE_DIR/version-uplift-pending.flag"
VERSION_UPLIFT_LOG="$STATE_DIR/version-uplift-detection.log"

if [ -x "$VERSION_UPLIFT_DETECT" ]; then
    DETECTION=$("$VERSION_UPLIFT_DETECT" 2>/dev/null || true)
    if [ -n "$DETECTION" ] && command -v jq >/dev/null 2>&1; then
        UPLIFT_CHANGED=$(printf '%s' "$DETECTION" | jq -r '.changed // false' 2>/dev/null || echo "false")
        if [ "$UPLIFT_CHANGED" = "true" ]; then
            UPLIFT_PREV=$(printf '%s' "$DETECTION" | jq -r '.previous // "null"' 2>/dev/null || echo "null")
            UPLIFT_CUR=$(printf '%s' "$DETECTION" | jq -r '.current' 2>/dev/null || echo "")
            mkdir -p "$STATE_DIR" 2>/dev/null || true
            printf 'previous=%s\ncurrent=%s\ndetected_at=%s\n' \
                "$UPLIFT_PREV" "$UPLIFT_CUR" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                > "$VERSION_UPLIFT_PENDING_FLAG" 2>/dev/null || true

            # Run uplift.sh in the background so the report exists for the
            # next auto-launch invocation. Uplift composes:
            #   detect (persist=0) → fetch --curl → evaluate → write report
            # Logs to detection.log; never blocks session start.
            #
            # --since carries the PREVIOUS version across the persist boundary.
            # detect-version.sh (above) has already persisted CURRENT, so uplift's
            # own detect reads previous == current and, without --since, fetches
            # the empty range current→current: "0 entries parsed", no report, and
            # the version is marked seen anyway. That silently swallowed the
            # 2.1.277–2.1.280 changelogs (incl. the Opus 5.5 launch) until
            # 2026-09-22.
            if [ -x "$VERSION_UPLIFT_UPLIFT" ] && [ "${PLAN_W_TEAM_DISABLE_VERSION_UPLIFT_AUTO:-0}" != "1" ]; then
                UPLIFT_SINCE_ARG=""
                case "$UPLIFT_PREV" in ""|null) ;; *) UPLIFT_SINCE_ARG="--since=$UPLIFT_PREV" ;; esac
                (
                    nohup "$VERSION_UPLIFT_UPLIFT" --force ${UPLIFT_SINCE_ARG:+"$UPLIFT_SINCE_ARG"} >> "$VERSION_UPLIFT_LOG" 2>&1 &
                ) 2>/dev/null || true
            fi
        fi
    fi
fi

# Auto-launch the adoption /plan-w-team worker when there is a pending flag
# AND no kill switch. The script itself is best-effort (always exits 0 on
# error) — we double-guard with || true for paranoia.
if [ -f "$VERSION_UPLIFT_PENDING_FLAG" ] && [ -x "$VERSION_UPLIFT_AUTO_LAUNCH" ]; then
    "$VERSION_UPLIFT_AUTO_LAUNCH" 2>/dev/null || true
fi

# =================================================================
# /plan-w-team: GC stale terminal=SUCCESS goal-state files
# =================================================================
# Best-effort cleanup. Goal-state files from runs that completed BEFORE the
# retro auto-cleanup landed (commit 409e265) linger on disk with
# terminal_state="SUCCESS" until removed. Never block session start on this.
#
# DETACHED, and that is the rule for every hygiene step in this file: SessionStart
# also fires with source=compact, so anything synchronous here is paid on EVERY
# compaction, not once per session. 2026-09-21 (cleanscale): this call ran inline,
# the janitor had gone quadratic over a ~1,350-entry state dir, and a busy lead
# session spent 6–10 min in "Running SessionStart hooks" after each compaction —
# about half its wall-clock, for three days. A janitor is hygiene, never a
# prerequisite for the session. Pinned by session-start-nonblocking.test.sh.
CLEANUP_GOAL_STATES="$PROJECT_ROOT/.claude/scripts/plan-w-team-cleanup-stale-goal-states.sh"
if [ -x "$CLEANUP_GOAL_STATES" ]; then
    nohup "$CLEANUP_GOAL_STATES" >/dev/null 2>&1 < /dev/null &
fi

# =================================================================
# Shared task list: archive old completed / long-stale open tasks, enforce a cap
# =================================================================
# The shell wrapper keys CLAUDE_CODE_TASK_LIST_ID on the repo name, so every session
# in a repo shares ONE list that nothing prunes, and Claude Code's task_reminder
# carries the WHOLE list (cleanscale 2026-09-21: 969 tasks ≈ 39K tokens per reminder,
# compaction every ~20 min instead of hourly). Archives with mv, never deletes;
# detached for the same reason as the janitor above.
# Kill switch: PWT_DISABLE_TASK_LIST_RETENTION=1.
TASK_LIST_RETENTION="$PROJECT_ROOT/.claude/scripts/task-list-retention.sh"
if [ -x "$TASK_LIST_RETENTION" ]; then
    nohup "$TASK_LIST_RETENTION" --quiet >/dev/null 2>&1 < /dev/null &
fi

# =================================================================
# Compaction health: regression alarm (compactions/hour, post-compaction hook time,
# task_reminder size, post-compaction context floor, state-dir entry count)
# =================================================================
# The 2026-09-21 regression ran three days with every signal sitting in the transcript
# and nothing reading it. The SCAN is detached (a lead transcript reaches 1 GB); what is
# shown here is the banner the PREVIOUS scan left, which exists only while it alarms —
# so surfacing costs one small file read. → docs/operations/compaction-health.md
# Kill switch: PWT_DISABLE_COMPACTION_HEALTH=1.
COMPACTION_HEALTH="$PROJECT_ROOT/.claude/scripts/compaction-health.sh"
COMPACTION_HEALTH_BANNER="$PROJECT_ROOT/.claude/state/compaction-health.txt"
if [ -x "$COMPACTION_HEALTH" ] && [ "${PWT_DISABLE_COMPACTION_HEALTH:-}" != "1" ]; then
    if [ -s "$COMPACTION_HEALTH_BANNER" ] && [ -n "$(find "$COMPACTION_HEALTH_BANNER" -mmin -1440 2>/dev/null)" ]; then
        echo ""
        cat "$COMPACTION_HEALTH_BANNER" 2>/dev/null || true
    fi
    nohup "$COMPACTION_HEALTH" --quiet >/dev/null 2>&1 < /dev/null &
fi

# =================================================================
# Post-push confirm: surface a detached full-suite run of the last push that is
# red or could not run
# =================================================================
# post-git-push.sh launches the confirm detached; this only READS its one small
# record (no scan, no run) and prints one line when it is red or could not run
# (error / died / skipped-disk / stale — a run still marked running past its
# bound). Silent when green, running within its bound, or absent.
# → docs/operations/post-push-confirm.md
# Kill switch: PWT_DISABLE_POST_PUSH_CONFIRM=1.
PWT_POST_PUSH_SURFACE="$PROJECT_ROOT/.claude/scripts/plan-w-team-post-push-confirm.sh"
if [ -x "$PWT_POST_PUSH_SURFACE" ] && [ "${PWT_DISABLE_POST_PUSH_CONFIRM:-}" != "1" ]; then
    "$PWT_POST_PUSH_SURFACE" --surface --root "$PROJECT_ROOT" 2>/dev/null || true
fi

# =================================================================
# DISK GOVERNANCE: auto-install the worktree-GC timer (E3) + pressure sweep
# Root cause #2 of the 2026-05-29 cleanscale ENOSPC incident was that the GC
# launchd/systemd timer was never installed (manual template), so no periodic
# sweep ever ran. This installs it idempotently on session start — never relying
# on a human — and, when disk-budget.sh reports pressure, runs the GC now.
# Backgrounded so it never slows session start; the script is fail-open (exit 0).
# Kill switch: PWT_GC_TIMER_DISABLE=1.
# =================================================================
GC_TIMER_INSTALL="$PROJECT_ROOT/.claude/scripts/plan-w-team-gc-timer-install.sh"
if [ -x "$GC_TIMER_INSTALL" ] && [ "${PWT_GC_TIMER_DISABLE:-0}" != "1" ]; then
    nohup "$GC_TIMER_INSTALL" >/dev/null 2>&1 &
fi

# =================================================================
# /plan-w-team: opportunistic follow-up drain (laptop-aware trigger)
# A 03:00 launchd StartCalendarInterval is close to useless on a LAPTOP: the
# machine is usually asleep or shut at that hour, so the timer alone would
# rarely fire. The drainer is therefore ALSO invoked here — the moment the
# machine is demonstrably awake and in use — with its own cooldown
# (PWT_FOLLOWUP_DRAIN_COOLDOWN_H, default 20h) so opening Claude repeatedly
# does not spawn repeatedly. The launchd entry is kept as a second chance for
# always-on machines and post-wake catch-up; neither path is required.
# Still DEFAULT OFF: it no-ops unless PWT_FOLLOWUP_DRAIN_ENABLE=1 or
# .claude/state/pwt-followup-drain-enabled exists. Backgrounded and fail-open,
# so it can never slow or break session start. Kill switch:
# PWT_FOLLOWUP_DRAIN_DISABLE=1.
# =================================================================
FOLLOWUP_DRAIN="$PROJECT_ROOT/.claude/scripts/plan-w-team-followup-drain.sh"
if [ -x "$FOLLOWUP_DRAIN" ] && [ "${PWT_FOLLOWUP_DRAIN_DISABLE:-0}" != "1" ]; then
    nohup "$FOLLOWUP_DRAIN" >/dev/null 2>&1 &
fi

# =================================================================
# /plan-w-team: friction-log triage-due advisory (T4 right-sizing)
# The friction log (.claude/state/plan-w-team-friction-log.jsonl) had a
# writer, 3 schema generations across its live rows, and ZERO programmatic
# readers before this. A launchd triage timer was right-sized AWAY (actor
# problem — see docs/operations/friction-log-audit-2026-07-06.md); this
# advisory rides session start instead, where a human is already reading
# output. Deterministic (literal marker FRICTION_TRIAGE_DUE), fail-open,
# and silent when the log is absent, malformed-tolerant, or under threshold.
# =================================================================
FRICTION_TRIAGE_DUE="$PROJECT_ROOT/.claude/scripts/plan-w-team-friction-triage-due.sh"
if [ -x "$FRICTION_TRIAGE_DUE" ]; then
    "$FRICTION_TRIAGE_DUE" 2>/dev/null || true
fi

# =================================================================
# COMPOUND: Surface learnings and auto-act on patterns
# =================================================================
COMPOUND_DIR="$PROJECT_ROOT/.claude/hooks/compound"

if [ -x "$COMPOUND_DIR/surface-learnings.sh" ]; then
    "$COMPOUND_DIR/surface-learnings.sh"
fi

if [ -x "$COMPOUND_DIR/auto-act.sh" ]; then
    "$COMPOUND_DIR/auto-act.sh"
fi

echo ""

exit 0
