#!/usr/bin/env bash
# plan-w-team-worktree-gc.sh
#
# Garbage-collect stale worktrees + merged branches under .claude/worktrees/.
#
# Layer 1 of the disk-hygiene initiative (worktree-lifecycle-cleanup spec).
# Walks `.claude/worktrees/<name>/`, classifies each, and (with --execute)
# runs `git worktree remove --force` + `git branch -D` for SAFE-PRUNE classes.
#
# Classification:
#   SAFE-PRUNE-MERGED  branch merged to default (gh PR list preferred, local --merged fallback)
#                      AND no uncommitted changes AND no live claude session has it as cwd
#   SAFE-PRUNE-IDLE    no commits in PWT_WORKTREE_IDLE_DAYS days (default 7),
#                      AND no open PR, AND no uncommitted, AND no live claude session
#   UNSAFE-KEEP        any blocker: open PR + unmerged, uncommitted, in-use, registered active PWT run
#   ORPHAN-ASK         branch deleted on origin but local has unmerged commits — only removable with --orphans-ok
#
# Usage:
#   plan-w-team-worktree-gc.sh                      # dry-run table (default)
#   plan-w-team-worktree-gc.sh --execute            # actually remove SAFE-PRUNE-* entries
#   plan-w-team-worktree-gc.sh --interactive        # prompt per worktree
#   plan-w-team-worktree-gc.sh --orphans-ok         # also remove ORPHAN-ASK
#   plan-w-team-worktree-gc.sh --json               # machine-readable JSON output
#   plan-w-team-worktree-gc.sh --scope <selector>   # limit work; selectors below
#
# Scope selectors:
#   all                                  default — every worktree under .claude/worktrees/
#   subagent --sid <SID>                 only `.claude/worktrees/agent-<SID>` (used by SubagentStop hook)
#   subagents-of-current-run             every `agent-*` worktree (used by retro stage)
#   branch <BRANCH>                      only worktree whose branch matches BRANCH (used by on-merge.sh)
#
# Environment:
#   PWT_WORKTREE_IDLE_DAYS         days-without-commits to qualify SAFE-PRUNE-IDLE (default 7)
#   PWT_WORKTREE_GC_DISABLE=1      no-op (exit 0)
#   PWT_WORKTREE_GC_DEFAULT_BRANCH override of default branch (auto-detected from origin/HEAD otherwise)
#   PWT_WORKTREE_GC_TEST_MODE=1    skip in-use check (used by tests with stubbed claude-agents-extended)
#
# Safety invariants (uniform across all paths):
#   1. NEVER touch worktrees outside .claude/worktrees/ (resolved real-path check).
#   2. NEVER remove a worktree with uncommitted changes.
#   3. NEVER remove a worktree currently in-use (claude-agents-extended.sh cwd field).
#   4. NEVER force-delete a branch with unmerged commits unless --orphans-ok.
#   5. IDEMPOTENT: re-running on clean repo = exit 0, no changes.
#
# Spec: docs/specs/worktree-lifecycle-cleanup.md
# Tests: .claude/scripts/plan-w-team-worktree-gc.test.sh

set -u
set -o pipefail

# ─── disabled? ────────────────────────────────────────────────────────────
if [ "${PWT_WORKTREE_GC_DISABLE:-0}" = "1" ]; then
    printf '{"skipped":true,"reason":"PWT_WORKTREE_GC_DISABLE=1","worktrees":[]}\n'
    exit 0
fi

# ─── arg parse ────────────────────────────────────────────────────────────
MODE_EXECUTE=0
MODE_INTERACTIVE=0
MODE_ORPHANS_OK=0
MODE_JSON=0
SCOPE_KIND="all"
SCOPE_SID=""
SCOPE_BRANCH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --execute)       MODE_EXECUTE=1; shift ;;
        --interactive)   MODE_INTERACTIVE=1; MODE_EXECUTE=1; shift ;;
        --orphans-ok)    MODE_ORPHANS_OK=1; shift ;;
        --json)          MODE_JSON=1; shift ;;
        --scope)
            SCOPE_KIND="${2:-all}"; shift 2 || { echo "missing --scope value" >&2; exit 2; }
            ;;
        --sid)
            SCOPE_SID="${2:-}"; shift 2 || { echo "missing --sid value" >&2; exit 2; }
            ;;
        --branch)
            SCOPE_BRANCH="${2:-}"; shift 2 || { echo "missing --branch value" >&2; exit 2; }
            ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

# ─── resolve repo root + worktrees dir ────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
    # Allow tests to operate by setting PWT_WORKTREE_GC_FAKE_ROOT
    REPO_ROOT="${PWT_WORKTREE_GC_FAKE_ROOT:-$PWD}"
fi
# If we're inside a worktree, climb to common dir's parent (main checkout)
WORKTREES_DIR_REL=".claude/worktrees"
# common dir = main repo's .git dir for the worktree network
COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
if [ -n "$COMMON_DIR" ]; then
    # COMMON_DIR is typically "<main-repo>/.git" — main checkout is its parent
    MAIN_CHECKOUT="$(dirname "$(realpath "$COMMON_DIR" 2>/dev/null || echo "$COMMON_DIR")" 2>/dev/null || echo "$REPO_ROOT")"
else
    MAIN_CHECKOUT="$REPO_ROOT"
fi
WORKTREES_DIR="$MAIN_CHECKOUT/$WORKTREES_DIR_REL"

# ─── default branch detection ─────────────────────────────────────────────
detect_default_branch() {
    if [ -n "${PWT_WORKTREE_GC_DEFAULT_BRANCH:-}" ]; then
        echo "$PWT_WORKTREE_GC_DEFAULT_BRANCH"
        return
    fi
    local r
    r="$(git -C "$MAIN_CHECKOUT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    if [ -n "$r" ]; then echo "$r"; return; fi
    # fallback: main, then master
    if git -C "$MAIN_CHECKOUT" show-ref --quiet --verify refs/heads/main; then echo "main"; return; fi
    if git -C "$MAIN_CHECKOUT" show-ref --quiet --verify refs/heads/master; then echo "master"; return; fi
    echo "main"
}
DEFAULT_BRANCH="$(detect_default_branch)"

# ─── gh CLI availability ──────────────────────────────────────────────────
GH_AVAILABLE=0
GH_REPO=""
MERGE_SOURCE="local"
if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
        # confirm we can list PRs (some repos may not have remote configured)
        if GH_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"; then
            GH_AVAILABLE=1
            MERGE_SOURCE="gh"
        fi
    fi
fi

# Cache gh PR data once
GH_MERGED_BRANCHES=""
GH_OPEN_PR_BRANCHES=""
if [ "$GH_AVAILABLE" = "1" ]; then
    GH_MERGED_BRANCHES="$(gh pr list --state merged --limit 1000 --json headRefName -q '.[].headRefName' 2>/dev/null || true)"
    GH_OPEN_PR_BRANCHES="$(gh pr list --state open --limit 1000 --json headRefName -q '.[].headRefName' 2>/dev/null || true)"
fi

# ─── in-use check via claude-agents-extended.sh ───────────────────────────
# claude-agents-extended.sh ONLY emits entries that are currently live:
#   - base entries (kind interactive/background) come straight from
#     `claude agents --json`, which lists running sessions only.
#   - subagent entries (kind subagent) are emitted only when their transcript
#     mtime is within SUBAGENT_FRESHNESS_SEC (i.e. still active).
# There is therefore NO "state"/"status" field to filter on — every returned
# entry is a live agent. We collect BOTH .cwd (where the parent session runs)
# and .worktreePath (the subagent's per-agent worktree) because either may be
# the worktree we're about to delete. A test stub can inject this list via
# PWT_WORKTREE_GC_TEST_LIVE_CWDS (newline-separated) to exercise is_in_use
# without a live claude binary.
LIVE_CWDS=""
if [ -n "${PWT_WORKTREE_GC_TEST_LIVE_CWDS:-}" ]; then
    LIVE_CWDS="$PWT_WORKTREE_GC_TEST_LIVE_CWDS"
elif [ "${PWT_WORKTREE_GC_TEST_MODE:-0}" != "1" ]; then
    AGENTS_EXTENDED="${PWT_WORKTREE_GC_AGENTS_EXTENDED:-$MAIN_CHECKOUT/.claude/scripts/claude-agents-extended.sh}"
    if [ -x "$AGENTS_EXTENDED" ]; then
        LIVE_CWDS="$("$AGENTS_EXTENDED" 2>/dev/null \
            | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for entry in (data if isinstance(data, list) else []):
    for key in ("cwd", "worktreePath"):
        v = entry.get(key) or ""
        if v:
            print(v)
' 2>/dev/null || true)"
    fi
fi

is_in_use() {
    local wt_path="$1"
    [ -z "$LIVE_CWDS" ] && return 1
    local real_wt
    real_wt="$(realpath "$wt_path" 2>/dev/null || echo "$wt_path")"
    while IFS= read -r cwd; do
        [ -z "$cwd" ] && continue
        local real_cwd
        real_cwd="$(realpath "$cwd" 2>/dev/null || echo "$cwd")"
        case "$real_cwd" in
            "$real_wt"|"$real_wt"/*) return 0 ;;
        esac
    done <<< "$LIVE_CWDS"
    return 1
}

# ─── active PWT-run detection via state JSONL ─────────────────────────────
# A worktree is "active" if its branch appears in any non-terminal goal-state
# JSONL row OR the worktree path appears in any spawned-children JSONL row.
ACTIVE_BRANCHES=""
ACTIVE_PATHS=""
if [ -d "$MAIN_CHECKOUT/.claude/state" ]; then
    # spawned-children JSONLs may have a worktree_path or cwd field
    ACTIVE_PATHS="$(grep -h -E '"(worktree_path|cwd)"' "$MAIN_CHECKOUT/.claude/state/"plan-w-team-spawned-children-*.jsonl 2>/dev/null \
        | python3 -c '
import json, sys
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        d=json.loads(line)
    except Exception:
        continue
    for k in ("worktree_path","cwd"):
        v=d.get(k)
        if v: print(v)
' 2>/dev/null || true)"
fi

is_registered_active() {
    local wt_path="$1"
    local branch="$2"
    [ -z "$ACTIVE_PATHS" ] && return 1
    local real_wt
    real_wt="$(realpath "$wt_path" 2>/dev/null || echo "$wt_path")"
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        local real_p
        real_p="$(realpath "$p" 2>/dev/null || echo "$p")"
        case "$real_p" in
            "$real_wt"|"$real_wt"/*) return 0 ;;
        esac
    done <<< "$ACTIVE_PATHS"
    return 1
}

# ─── git-lock detection ────────────────────────────────────────────────────
# Cache `git worktree list --porcelain` once. Locked worktrees emit a "locked"
# line in their porcelain stanza. Claude Code locks Agent-tool subagent
# worktrees for the duration of the subagent; a lock is a deliberate "do not
# touch" marker. We treat locked == in-use.
WORKTREE_LIST_PORCELAIN="$(git -C "$MAIN_CHECKOUT" worktree list --porcelain 2>/dev/null || echo "")"

is_worktree_locked() {
    local wt_path="$1"
    [ -z "$WORKTREE_LIST_PORCELAIN" ] && return 1
    local real_wt
    real_wt="$(realpath "$wt_path" 2>/dev/null || echo "$wt_path")"
    # Parse porcelain stanzas: each begins with "worktree <path>" and may carry
    # a bare "locked" line before the blank-line separator.
    printf '%s\n' "$WORKTREE_LIST_PORCELAIN" | LOCK_TARGET="$real_wt" python3 -c '
import sys, os
target = os.environ.get("LOCK_TARGET","")
try:
    target = os.path.realpath(target)
except Exception:
    pass
cur = None
locked = False
hit = False
def flush():
    global hit
    if cur is not None and locked:
        try:
            rp = os.path.realpath(cur)
        except Exception:
            rp = cur
        if rp == target:
            hit = True
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("worktree "):
        flush()
        cur = line[len("worktree "):]
        locked = False
    elif line == "locked" or line.startswith("locked "):
        locked = True
    elif line == "":
        flush()
        cur = None
        locked = False
flush()
sys.exit(0 if hit else 1)
' 2>/dev/null
    return $?
}

# ─── safety invariant 1: real-path containment ────────────────────────────
real_worktrees_dir="$(realpath "$WORKTREES_DIR" 2>/dev/null || echo "$WORKTREES_DIR")"

is_under_worktrees_dir() {
    local p="$1"
    local rp
    rp="$(realpath "$p" 2>/dev/null || echo "$p")"
    case "$rp" in
        "$real_worktrees_dir"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── enumerate worktrees ──────────────────────────────────────────────────
declare -a WT_PATHS=()
if [ -d "$WORKTREES_DIR" ]; then
    while IFS= read -r -d '' p; do
        WT_PATHS+=("$p")
    done < <(find "$WORKTREES_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

# ─── scope filter ─────────────────────────────────────────────────────────
filter_in_scope() {
    local wt_path="$1"
    local wt_branch="$2"
    local name
    name="$(basename "$wt_path")"
    case "$SCOPE_KIND" in
        all) return 0 ;;
        subagent)
            [ -z "$SCOPE_SID" ] && return 1
            [ "$name" = "agent-$SCOPE_SID" ] && return 0
            return 1
            ;;
        subagents-of-current-run)
            case "$name" in agent-*) return 0 ;; *) return 1 ;; esac
            ;;
        branch)
            [ -z "$SCOPE_BRANCH" ] && return 1
            [ "$wt_branch" = "$SCOPE_BRANCH" ] && return 0
            return 1
            ;;
        *) return 0 ;;
    esac
}

# ─── classification ───────────────────────────────────────────────────────
classify_one() {
    # Sets globals: CLASS, BRANCH, REASON, LAST_COMMIT_AGE_DAYS, UNCOMMITTED, MERGED, OPEN_PR, IN_USE, ACTIVE_RUN, OUTSIDE, ORIGIN_GONE, MERGED_BY
    local wt_path="$1"
    CLASS=""; BRANCH=""; REASON=""; LAST_COMMIT_AGE_DAYS=""; UNCOMMITTED=0
    MERGED=0; OPEN_PR=0; IN_USE=0; ACTIVE_RUN=0; OUTSIDE=0; MERGED_BY=""; ORIGIN_GONE=0

    if ! is_under_worktrees_dir "$wt_path"; then
        CLASS="REFUSED-OUTSIDE-CLAUDE-WORKTREES"
        REASON="path is outside .claude/worktrees/ — invariant 1 refusal"
        OUTSIDE=1
        return 0
    fi

    BRANCH="$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
        # Detached or no git — treat as ORPHAN-ASK
        CLASS="ORPHAN-ASK"
        REASON="detached HEAD or non-git worktree"
        return 0
    fi

    # Uncommitted check
    local porcelain
    porcelain="$(git -C "$wt_path" status --porcelain 2>/dev/null || echo "")"
    if [ -n "$porcelain" ]; then UNCOMMITTED=1; fi

    # Last commit age in days
    local last_commit_epoch
    last_commit_epoch="$(git -C "$wt_path" log -1 --format=%ct 2>/dev/null || echo "0")"
    if [ "$last_commit_epoch" -gt 0 ] 2>/dev/null; then
        local now
        now="$(date +%s)"
        LAST_COMMIT_AGE_DAYS=$(( (now - last_commit_epoch) / 86400 ))
    fi

    # Merged check — a branch counts as merged if EITHER gh PR-state OR local
    # `git branch --merged` says so (directive: "...per git branch --merged OR
    # per gh pr list..."). gh catches squash-merges invisible to local history;
    # local catches direct-to-main merges that never became a PR. We OR them and
    # record which source(s) confirmed it.
    local merged_gh=0 merged_local=0
    if [ "$GH_AVAILABLE" = "1" ] && echo "$GH_MERGED_BRANCHES" | grep -qxF "$BRANCH"; then
        merged_gh=1
    fi
    if git -C "$MAIN_CHECKOUT" branch --merged "$DEFAULT_BRANCH" 2>/dev/null \
        | sed 's/^[* +] //' | grep -qxF "$BRANCH"; then
        merged_local=1
    fi
    if [ "$merged_gh" = "1" ] || [ "$merged_local" = "1" ]; then MERGED=1; fi
    MERGED_BY=""
    [ "$merged_gh" = "1" ] && MERGED_BY="gh"
    [ "$merged_local" = "1" ] && MERGED_BY="${MERGED_BY:+$MERGED_BY+}local"

    # Open PR check
    if [ "$GH_AVAILABLE" = "1" ]; then
        if echo "$GH_OPEN_PR_BRANCHES" | grep -qxF "$BRANCH"; then OPEN_PR=1; fi
    fi

    # Origin-existence check — does the branch still exist on origin? Used to
    # distinguish a true ORPHAN-ASK (branch deleted on origin, local commits
    # stranded) from a never-pushed local branch. A remote-tracking ref present
    # OR a live `git ls-remote` hit means origin still has it.
    ORIGIN_GONE=1
    if git -C "$MAIN_CHECKOUT" show-ref --quiet --verify "refs/remotes/origin/$BRANCH" 2>/dev/null; then
        ORIGIN_GONE=0
    fi

    # In-use check (live claude session whose cwd / worktreePath is this dir)
    if is_in_use "$wt_path"; then IN_USE=1; fi

    # Git-lock check — Claude Code locks Agent-tool subagent worktrees while the
    # subagent is running (`git worktree list` shows "locked"). A locked worktree
    # is a deliberate in-use signal; honor it as a hard keep even if the live
    # session scan missed it (e.g. claude binary unavailable). Tests can suppress
    # via PWT_WORKTREE_GC_IGNORE_LOCKS=1.
    if [ "${PWT_WORKTREE_GC_IGNORE_LOCKS:-0}" != "1" ]; then
        if is_worktree_locked "$wt_path"; then IN_USE=1; fi
    fi

    # Active PWT run check
    if is_registered_active "$wt_path" "$BRANCH"; then ACTIVE_RUN=1; fi

    # ─── classify ───
    #
    # Precedence rationale:
    #   1. IN_USE and UNCOMMITTED are ABSOLUTE keeps. They protect a live
    #      session's cwd and unsaved work — never overridden, even if merged.
    #   2. MERGED then wins over a stale ACTIVE_RUN fleet row: a branch that is
    #      already merged to the default branch cannot be "in-flight". Fleet
    #      registry rows (plan-w-team-spawned-children-*.jsonl) are known to
    #      outlive their runs when a retro didn't clean them, so a merged branch
    #      carrying a stale row is exactly the post-merge garbage this GC sweeps.
    #   3. ACTIVE_RUN keeps an UNMERGED worktree (a genuinely in-flight run).
    #   4. An unmerged branch with an open PR is a keep (work in review).
    if [ "$IN_USE" = "1" ]; then
        CLASS="UNSAFE-KEEP"; REASON="in-use by live claude session"; return 0
    fi
    if [ "$UNCOMMITTED" = "1" ]; then
        CLASS="UNSAFE-KEEP"; REASON="uncommitted changes"; return 0
    fi

    if [ "$MERGED" = "1" ]; then
        CLASS="SAFE-PRUNE-MERGED"
        REASON="branch merged (source: ${MERGED_BY:-unknown})"
        return 0
    fi

    if [ "$ACTIVE_RUN" = "1" ]; then
        CLASS="UNSAFE-KEEP"; REASON="registered in active /plan-w-team run"; return 0
    fi
    if [ "$OPEN_PR" = "1" ]; then
        CLASS="UNSAFE-KEEP"; REASON="unmerged branch with open PR"; return 0
    fi

    # Idle check
    local idle_days="${PWT_WORKTREE_IDLE_DAYS:-7}"
    if [ -n "$LAST_COMMIT_AGE_DAYS" ] && [ "$LAST_COMMIT_AGE_DAYS" -ge "$idle_days" ] && [ "$OPEN_PR" = "0" ]; then
        CLASS="SAFE-PRUNE-IDLE"
        REASON="no commits in ${LAST_COMMIT_AGE_DAYS}d (threshold ${idle_days}d), no open PR"
        return 0
    fi

    # Default → ORPHAN-ASK. Two flavors, both require --orphans-ok to remove:
    #   1. Branch deleted on origin but local has unmerged commits (the canonical
    #      orphan per the directive) — local work stranded with no upstream.
    #   2. Unmerged local-only branch, not idle enough to auto-prune, no open PR.
    CLASS="ORPHAN-ASK"
    if [ "$ORIGIN_GONE" = "1" ]; then
        REASON="branch gone from origin, local unmerged commits (${LAST_COMMIT_AGE_DAYS:-?}d idle) — needs --orphans-ok"
    else
        REASON="unmerged branch, no open PR, only ${LAST_COMMIT_AGE_DAYS:-?}d idle — needs --orphans-ok"
    fi
    return 0
}

# ─── remove worktree + branch ─────────────────────────────────────────────
remove_one() {
    local wt_path="$1"
    local branch="$2"
    local removed_wt=0
    local removed_branch=0
    # Pre-conditions
    if ! is_under_worktrees_dir "$wt_path"; then
        echo "refuse: path outside .claude/worktrees/ ($wt_path)" >&2
        return 1
    fi
    # Run git worktree remove
    if git -C "$MAIN_CHECKOUT" worktree remove --force "$wt_path" 2>/dev/null; then
        removed_wt=1
    else
        # Fallback: prune the registry + rm -rf if dir still exists
        git -C "$MAIN_CHECKOUT" worktree prune 2>/dev/null || true
        if [ -d "$wt_path" ] && is_under_worktrees_dir "$wt_path"; then
            rm -rf "$wt_path"
            removed_wt=1
        fi
    fi
    if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
        if git -C "$MAIN_CHECKOUT" branch -D "$branch" >/dev/null 2>&1; then
            removed_branch=1
        fi
    fi
    echo "$removed_wt $removed_branch"
}

# ─── unregister from fleet JSONL ──────────────────────────────────────────
unregister_from_fleet() {
    local wt_path="$1"
    local branch="$2"
    [ -d "$MAIN_CHECKOUT/.claude/state" ] || return 0
    local manifest
    for manifest in "$MAIN_CHECKOUT/.claude/state/"plan-w-team-spawned-children-*.jsonl; do
        [ -f "$manifest" ] || continue
        local tmp
        tmp="$(mktemp)"
        python3 -c '
import json, sys, os
keep = []
removed = 0
target_path = os.environ.get("WT_PATH","")
target_branch = os.environ.get("WT_BRANCH","")
with open(sys.argv[1]) as f:
    for line in f:
        line=line.strip()
        if not line:
            continue
        try:
            d=json.loads(line)
        except Exception:
            keep.append(line)
            continue
        wp = d.get("worktree_path") or d.get("cwd") or ""
        br = d.get("branch") or ""
        if target_path and wp and os.path.realpath(wp) == os.path.realpath(target_path):
            removed += 1
            continue
        if target_branch and br == target_branch:
            removed += 1
            continue
        keep.append(line)
for line in keep:
    print(line)
sys.stderr.write(f"removed={removed}\n")
' "$manifest" > "$tmp" 2>/dev/null
        # only write back if file changed
        if ! cmp -s "$tmp" "$manifest"; then
            mv "$tmp" "$manifest"
        else
            rm -f "$tmp"
        fi
    done
    return 0
}

# ─── main loop: classify + (optionally) execute ───────────────────────────
RESULTS_JSON_TMP="$(mktemp)"
echo "[" > "$RESULTS_JSON_TMP"
FIRST=1
TOTAL=0
REMOVED=0
KEPT=0
SKIPPED_OUT_OF_SCOPE=0

for wt_path in "${WT_PATHS[@]:-}"; do
    [ -z "${wt_path:-}" ] && continue
    [ -d "$wt_path" ] || continue
    classify_one "$wt_path"
    name="$(basename "$wt_path")"
    if ! filter_in_scope "$wt_path" "$BRANCH"; then
        SKIPPED_OUT_OF_SCOPE=$((SKIPPED_OUT_OF_SCOPE+1))
        continue
    fi
    TOTAL=$((TOTAL+1))

    # Decide action
    ACTION="keep"
    case "$CLASS" in
        SAFE-PRUNE-MERGED|SAFE-PRUNE-IDLE)
            if [ "$MODE_EXECUTE" = "1" ]; then ACTION="remove"; else ACTION="dry-remove"; fi
            ;;
        ORPHAN-ASK)
            if [ "$MODE_ORPHANS_OK" = "1" ] && [ "$MODE_EXECUTE" = "1" ]; then ACTION="remove"
            elif [ "$MODE_ORPHANS_OK" = "1" ];                                 then ACTION="dry-remove"
            else                                                                    ACTION="keep-orphan"
            fi
            ;;
        UNSAFE-KEEP|REFUSED-OUTSIDE-CLAUDE-WORKTREES)
            ACTION="keep"
            ;;
    esac

    # Interactive prompt
    if [ "$MODE_INTERACTIVE" = "1" ] && [ "$ACTION" = "remove" ]; then
        printf "Remove worktree %s [%s] branch=%s reason=\"%s\"? [y/N] " "$name" "$CLASS" "$BRANCH" "$REASON" >&2
        read -r ans
        case "$ans" in
            y|Y|yes|YES) : ;;
            *) ACTION="keep-user-declined" ;;
        esac
    fi

    REMOVED_WT=0; REMOVED_BRANCH=0
    if [ "$ACTION" = "remove" ]; then
        read -r REMOVED_WT REMOVED_BRANCH <<< "$(remove_one "$wt_path" "$BRANCH")"
        if [ "$REMOVED_WT" = "1" ]; then
            REMOVED=$((REMOVED+1))
            WT_PATH="$wt_path" WT_BRANCH="$BRANCH" unregister_from_fleet "$wt_path" "$BRANCH"
        else
            ACTION="remove-failed"
            KEPT=$((KEPT+1))
        fi
    else
        if [ "$CLASS" = "SAFE-PRUNE-MERGED" ] || [ "$CLASS" = "SAFE-PRUNE-IDLE" ]; then
            : # would-have-removed
        else
            KEPT=$((KEPT+1))
        fi
    fi

    # JSON row
    [ "$FIRST" = "1" ] && FIRST=0 || echo "," >> "$RESULTS_JSON_TMP"
    python3 -c '
import json, sys
row = {
    "path": sys.argv[1],
    "name": sys.argv[2],
    "branch": sys.argv[3],
    "class": sys.argv[4],
    "reason": sys.argv[5],
    "action": sys.argv[6],
    "removed_worktree": sys.argv[7] == "1",
    "removed_branch": sys.argv[8] == "1",
    "uncommitted": sys.argv[9] == "1",
    "merged": sys.argv[10] == "1",
    "open_pr": sys.argv[11] == "1",
    "in_use": sys.argv[12] == "1",
    "active_run": sys.argv[13] == "1",
    "last_commit_age_days": int(sys.argv[14]) if sys.argv[14].isdigit() else None,
    "merge_source": sys.argv[15],
    "merged_by": sys.argv[16],
    "origin_gone": sys.argv[17] == "1",
}
sys.stdout.write(json.dumps(row))
' "$wt_path" "$name" "$BRANCH" "$CLASS" "$REASON" "$ACTION" \
  "$REMOVED_WT" "$REMOVED_BRANCH" "$UNCOMMITTED" "$MERGED" "$OPEN_PR" \
  "$IN_USE" "$ACTIVE_RUN" "${LAST_COMMIT_AGE_DAYS:-?}" "$MERGE_SOURCE" "${MERGED_BY:-}" "${ORIGIN_GONE:-0}" >> "$RESULTS_JSON_TMP"

    # Human table row
    if [ "$MODE_JSON" = "0" ]; then
        printf "  %-32s  %-22s  %-22s  %s\n" \
            "$name" "$CLASS" "$ACTION" "$REASON" >&2
    fi
done

echo "]" >> "$RESULTS_JSON_TMP"

# After removals — prune any orphan registry entries
if [ "$MODE_EXECUTE" = "1" ]; then
    git -C "$MAIN_CHECKOUT" worktree prune 2>/dev/null || true
fi

# ─── export totals/context for the JSON serializer (MUST precede output) ──
export MAIN_CHECKOUT WORKTREES_DIR DEFAULT_BRANCH MERGE_SOURCE GH_AVAILABLE \
    MODE_EXECUTE MODE_INTERACTIVE MODE_ORPHANS_OK SCOPE_KIND SCOPE_SID SCOPE_BRANCH \
    TOTAL REMOVED KEPT SKIPPED_OUT_OF_SCOPE

# ─── output ───────────────────────────────────────────────────────────────
if [ "$MODE_JSON" = "1" ]; then
    python3 -c '
import json, sys, os
with open(sys.argv[1]) as f:
    items = json.load(f)
out = {
    "schema": "plan-w-team-worktree-gc/v1",
    "main_checkout": os.environ.get("MAIN_CHECKOUT",""),
    "worktrees_dir": os.environ.get("WORKTREES_DIR",""),
    "default_branch": os.environ.get("DEFAULT_BRANCH",""),
    "merge_source": os.environ.get("MERGE_SOURCE",""),
    "gh_available": os.environ.get("GH_AVAILABLE","0") == "1",
    "mode": {
        "execute":     os.environ.get("MODE_EXECUTE","0") == "1",
        "interactive": os.environ.get("MODE_INTERACTIVE","0") == "1",
        "orphans_ok":  os.environ.get("MODE_ORPHANS_OK","0") == "1",
    },
    "scope": {"kind": os.environ.get("SCOPE_KIND","all"), "sid": os.environ.get("SCOPE_SID",""), "branch": os.environ.get("SCOPE_BRANCH","")},
    "totals": {
        "scanned": int(os.environ.get("TOTAL","0")),
        "removed": int(os.environ.get("REMOVED","0")),
        "kept":    int(os.environ.get("KEPT","0")),
        "skipped_out_of_scope": int(os.environ.get("SKIPPED_OUT_OF_SCOPE","0")),
    },
    "worktrees": items,
}
print(json.dumps(out, indent=2))
' "$RESULTS_JSON_TMP"
else
    echo "" >&2
    echo "  --- worktree GC summary ---" >&2
    echo "  main checkout:    $MAIN_CHECKOUT" >&2
    echo "  worktrees dir:    $WORKTREES_DIR" >&2
    echo "  default branch:   $DEFAULT_BRANCH" >&2
    echo "  merge source:     $MERGE_SOURCE (gh=${GH_AVAILABLE})" >&2
    echo "  scanned: $TOTAL  removed: $REMOVED  kept: $KEPT  out-of-scope: $SKIPPED_OUT_OF_SCOPE" >&2
    if [ "$MODE_EXECUTE" = "0" ]; then
        echo "  (dry-run — re-run with --execute to actually remove)" >&2
    fi
fi

rm -f "$RESULTS_JSON_TMP"
exit 0
