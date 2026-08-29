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
#                      AND no REAL uncommitted changes AND no live claude session has it as cwd
#   SAFE-PRUNE-IDLE    no commits in PWT_WORKTREE_IDLE_DAYS days (default 7),
#                      AND no open PR, AND no uncommitted, AND no live claude session
#   UNSAFE-KEEP        any blocker: open PR + unmerged, uncommitted, in-use, registered active PWT run
#   ORPHAN-ASK         branch deleted on origin but local has unmerged commits — only removable with --orphans-ok
#
# Two refinements (2026-05) prevent the stale-state accumulation that let
# .claude/worktrees/ grow to tens of GB despite this GC existing:
#   • Stale-lock awareness: Claude Code locks a subagent's worktree for its
#     lifetime and SHOULD unlock on SubagentStop, but the unlock is unreliable
#     (crash/timeout). A lock is therefore honored as in-use ONLY when a live
#     session corroborates it OR the worktree shows recent activity (last commit
#     within PWT_WORKTREE_LOCK_STALE_HOURS). A lock with neither is STALE and
#     does NOT block reclamation.
#   • Ignore-path dirty check: runtime hooks rewrite .claude/state/* into every
#     worktree, which would mark every worktree dirty forever. Dirtiness confined
#     to PWT_WORKTREE_GC_DIRTY_IGNORE prefixes (default ".claude/state/") is
#     treated as clean; only REAL source/doc edits count as uncommitted.
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
#   PWT_WORKTREE_LOCK_STALE_HOURS  a lock + no live session + last commit older than
#                                  this (default 24) is STALE → does not block prune
#   PWT_WORKTREE_GC_IGNORE_LOCKS=1 force EVERY lock stale (manual sweep / tests)
#   PWT_WORKTREE_GC_TRUST_LOCKS=1  legacy behavior: ANY lock == in-use hard-keep
#   PWT_WORKTREE_GC_DIRTY_IGNORE   colon-separated path prefixes whose dirtiness is
#                                  ignored (default ".claude/state/"; empty disables)
#   PWT_LIVE_SESSION_CWDS_SCRIPT   override path to pwt-live-session-cwds.sh (the
#                                  canonical `claude agents --json` liveness probe)
#   PWT_WORKTREE_GC_TEST_QUERY_FAILED=1  test seam: simulate a failed liveness
#                                  probe (sets the fail-closed flag) without a fake
#                                  claude binary
#
# Safety invariants (uniform across all paths):
#   1. NEVER touch worktrees outside .claude/worktrees/ (resolved real-path check).
#   2. NEVER remove a worktree with REAL uncommitted changes (dirtiness outside
#      the PWT_WORKTREE_GC_DIRTY_IGNORE prefixes).
#   3. NEVER remove a worktree currently in-use: a LIVE claude session (background
#      OR interactive) whose cwd is the worktree — the canonical signal is
#      pwt-live-session-cwds.sh (`claude agents --json`), with claude-agents-
#      extended.sh as an additive subagent-worktreePath source — or holding a lock
#      backed by a live session / recent activity.
#   3b. FAIL-CLOSED: if the liveness probe cannot run (claude unavailable / timeout
#      / unparseable), NEVER reap a reclaimable (merged/pushed/idle) worktree. A
#      worker that pushed in Step 6 still has Steps 6b-8 to run; reaping it the
#      instant HEAD reaches origin orphaned it (2026-06-07 incident). A missed reap
#      is cheap; an erroneous one orphans a live run.
#   4. NEVER force-delete a branch with unmerged commits unless --orphans-ok.
#   5. IDEMPOTENT: re-running on clean repo = exit 0, no changes.
#
# Spec: docs/specs/worktree-lifecycle-cleanup.md
# Tests: .claude/scripts/plan-w-team-worktree-gc.test.sh

set -u
set -o pipefail

# Resolve this script's own directory so co-located helpers (pwt-live-session-cwds.sh)
# are found regardless of whether the sibling-but-synced-separately .claude/ layer in
# the MAIN_CHECKOUT is current. The GC and its helper ship + sync together, so the
# script's own dir is the most reliable place to find the helper.
GC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

# ─── shared dirty-ignore policy ───────────────────────────────────────────
# The ignore sets, the porcelain filter, the tracked-dirt veto and
# preserve-then-reap live in ONE module shared with plan-w-team-worktree-on-merge.sh
# (see that file's header for why a private copy is a bug, not a convenience).
# Co-located, so it ships and syncs with this script.
PWT_DIRTY_IGNORE_LIB="${PWT_DIRTY_IGNORE_LIB:-$GC_SCRIPT_DIR/plan-w-team-dirty-ignore-lib.sh}"
if [ -r "$PWT_DIRTY_IGNORE_LIB" ]; then
    # shellcheck source=plan-w-team-dirty-ignore-lib.sh disable=SC1090
    . "$PWT_DIRTY_IGNORE_LIB"
    PWT_LIB_OK=1
else
    # FAIL-CLOSED: without the module there is no dirty filter, no tracked-dirt
    # veto and no backup routine — i.e. none of the guards that make a removal
    # safe can be evaluated. Refuse to classify anything as reapable, same
    # posture as VETO 0 below.
    PWT_LIB_OK=0
    echo "[plan-w-team-worktree-gc] dirty-ignore lib not readable at $PWT_DIRTY_IGNORE_LIB — nothing is reapable" >&2
fi

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
# LIVE_QUERY_FAILED is the FAIL-CLOSED signal (2026-06-07 mid-flight-reap fix):
# when the live-session probe cannot be performed we must NOT reap any reclaimable
# worktree, because absence of a matching path no longer proves absence of a live
# owner. classify_one's guard converts every SAFE-PRUNE-* candidate to UNSAFE-KEEP
# while this is set. The two test seams (TEST_LIVE_CWDS / TEST_MODE) keep it 0 so
# the existing SAFE-PRUNE tests still fire — only a REAL failed probe sets it.
# ─── python3 availability (FAIL-CLOSED — 2026-07-30 review finding) ─────────
# EVERY structural guard in this script is implemented in python3: lock
# detection (is_worktree_locked / worktree_lock_reason), the dirty-ignore filter
# (__pwt_dirty_ignore_filter), the live-cwd extraction, and the JSON serializer.
# Each of those helpers returns non-zero / empty when python3 cannot run, and
# non-zero from `is_worktree_locked` means "NOT locked" — so a missing or broken
# python3 silently disarmed the lock veto and the dirty veto at once.
#
# Measured 2026-07-30 with a `python3` stub exiting 127: a MERGED worktree that
# was git-locked classified SAFE-PRUNE-MERGED and `--execute` DELETED it
# (`removed: 1`). That is the same silently-inert-guard failure this script's
# four vetoes exist to prevent, reachable by an environment gap rather than a
# race. So python3 is now a hard precondition: without it the classifier cannot
# be trusted at all, and nothing is reaped.
# The probe itself is shared (__pwt_python_ok) so on-merge applies the identical
# precondition. A missing lib is folded in here: no lib ⇒ no guards ⇒ not trusted.
# PY_OK_REASON keeps the two causes distinguishable in the classifier output —
# reporting "python3 unavailable" when the real cause was a missing module sends
# whoever debugs a fleet-wide keep-everything to the wrong place entirely.
PY_OK=1
PY_OK_REASON="python3 unavailable"
if [ "${PWT_LIB_OK:-0}" != "1" ]; then
    PY_OK=0
    PY_OK_REASON="dirty-ignore lib unavailable"
elif ! __pwt_python_ok; then
    PY_OK=0
fi

LIVE_CWDS=""
LIVE_QUERY_FAILED=0
if [ "${PWT_WORKTREE_GC_TEST_QUERY_FAILED:-0}" = "1" ]; then
    # Test seam: simulate a failed liveness probe without a fake claude binary.
    LIVE_QUERY_FAILED=1
elif [ -n "${PWT_WORKTREE_GC_TEST_LIVE_CWDS:-}" ]; then
    LIVE_CWDS="$PWT_WORKTREE_GC_TEST_LIVE_CWDS"
elif [ "${PWT_WORKTREE_GC_TEST_MODE:-0}" != "1" ]; then
    # ── Canonical live-session source: `claude agents --json` via the shared
    #    helper (directive 2026-06-07). Returns the cwd of every live bg/interactive
    #    session, or the __QUERY_FAILED__ token if the probe could not run. A
    #    supervised worker that pushed in Step 6 is a live background session whose
    #    cwd IS this worktree; it MUST keep its worktree through Steps 6b-8.
    LIVE_HELPER="${PWT_LIVE_SESSION_CWDS_SCRIPT:-}"
    if [ -z "$LIVE_HELPER" ]; then
        # Prefer the sibling next to THIS script; fall back to MAIN_CHECKOUT's copy.
        if [ -n "$GC_SCRIPT_DIR" ] && [ -x "$GC_SCRIPT_DIR/pwt-live-session-cwds.sh" ]; then
            LIVE_HELPER="$GC_SCRIPT_DIR/pwt-live-session-cwds.sh"
        else
            LIVE_HELPER="$MAIN_CHECKOUT/.claude/scripts/pwt-live-session-cwds.sh"
        fi
    fi
    if [ -x "$LIVE_HELPER" ]; then
        _live_out="$("$LIVE_HELPER" 2>/dev/null || printf '__QUERY_FAILED__\n')"
        if printf '%s\n' "$_live_out" | grep -qx '__QUERY_FAILED__'; then
            LIVE_QUERY_FAILED=1
        else
            LIVE_CWDS="$_live_out"
        fi
    else
        # Canonical helper missing → cannot confirm liveness → fail closed.
        LIVE_QUERY_FAILED=1
    fi
    # Secondary (ADDITIVE) source: claude-agents-extended.sh also surfaces the
    # per-subagent worktreePath that the plain agents list doesn't carry. It only
    # ADDS protected paths — it never clears the fail-closed flag. If the canonical
    # probe failed but this one succeeds with data, we keep the fail-closed posture
    # (conservative) while still protecting any extra paths it found.
    AGENTS_EXTENDED="${PWT_WORKTREE_GC_AGENTS_EXTENDED:-$MAIN_CHECKOUT/.claude/scripts/claude-agents-extended.sh}"
    if [ -x "$AGENTS_EXTENDED" ]; then
        _ext_cwds="$("$AGENTS_EXTENDED" 2>/dev/null \
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
        if [ -n "$_ext_cwds" ]; then
            LIVE_CWDS="${LIVE_CWDS:+$LIVE_CWDS
}$_ext_cwds"
        fi
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

# ─── lock reason + PID liveness (VETO 3) ───────────────────────────────────
# `git worktree list --porcelain` emits the lock reason on the `locked` line as
# `locked <reason>` (a bare `locked` means "locked with no reason"). pwt-goal.sh
# and Claude Code both write a reason carrying the owning PID, e.g.
#   locked claude session <slug> (pid 74860 start Thu Jul 30 11:27:02 2026)
# That PID is an INDEPENDENT liveness signal, and a strictly earlier one than
# `claude agents --json`: the lock is written by `git worktree add` at spawn,
# whereas the bg session becomes observable only once it registers (measured
# 2026-07-30: lock at 11:27:02 vs goal-state started_at 12:10:22 — a ~43 min
# window in which the path-matching probe returns nothing).
worktree_lock_reason() {
    local wt_path="$1"
    [ -z "$WORKTREE_LIST_PORCELAIN" ] && return 0
    local real_wt
    real_wt="$(realpath "$wt_path" 2>/dev/null || echo "$wt_path")"
    printf '%s\n' "$WORKTREE_LIST_PORCELAIN" | LOCK_TARGET="$real_wt" python3 -c '
import sys, os
target = os.environ.get("LOCK_TARGET","")
try: target = os.path.realpath(target)
except Exception: pass
cur=None; reason=None; found=None
def flush():
    global found
    if cur is not None and reason is not None:
        try: rp=os.path.realpath(cur)
        except Exception: rp=cur
        if rp==target: found=reason
for line in sys.stdin:
    line=line.rstrip("\n")
    if line.startswith("worktree "):
        flush(); cur=line[len("worktree "):]; reason=None
    elif line=="locked":
        reason=""
    elif line.startswith("locked "):
        reason=line[len("locked "):]
    elif line=="":
        flush(); cur=None; reason=None
flush()
if found is not None: sys.stdout.write(found)
' 2>/dev/null
}

# Extract the owning PID from a lock reason, if it carries one.
lock_reason_pid() {
    printf '%s' "${1:-}" | sed -n 's/.*[(, ]pid[= ]\{1,\}\([0-9]\{1,\}\).*/\1/p' | head -1
}

# ─── worktree age (VETO 4 — newborn grace window) ──────────────────────────
# A freshly-created worktree is the most dangerous thing to reap: its seed branch
# is already pushed (⇒ origin-reachable ⇒ prunable), it has no commits of its own
# yet, and its owning session has not registered with the liveness probe. The
# `.git` FILE inside a linked worktree is written exactly once, by
# `git worktree add`, so its mtime is a faithful birth timestamp.
# PWT_WORKTREE_MIN_AGE_MINUTES=0 disables the grace window (used by the test
# suite, whose fixtures are seconds old by construction).
worktree_age_minutes() {
    local wt_path="$1" born now
    born="$(stat -f %m "$wt_path/.git" 2>/dev/null || stat -c %Y "$wt_path/.git" 2>/dev/null || echo "")"
    [ -z "$born" ] && born="$(stat -f %m "$wt_path" 2>/dev/null || stat -c %Y "$wt_path" 2>/dev/null || echo "")"
    [ -z "$born" ] && { echo ""; return 0; }   # unknowable → caller fails closed
    now="$(date +%s)"
    echo $(( (now - born) / 60 ))
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

# ─── registered-worktree check (AC5b) ─────────────────────────────────────
# A directory under .claude/worktrees/ is a REGISTERED worktree iff it appears as a
# "worktree <path>" entry in `git worktree list --porcelain`. A leftover dir that is
# NOT registered (e.g. an esbuild/Metro service's cwd whose parent session died and
# whose `git worktree remove` never ran) would otherwise have its `git -C <dir>`
# commands resolve UP to the main checkout's .git and be misclassified against the
# main branch. We detect these as git-unregistered ORPHAN dirs instead.
is_registered_worktree() {
    local wt_path="$1"
    [ -z "$WORKTREE_LIST_PORCELAIN" ] && return 1
    local real_wt
    real_wt="$(realpath "$wt_path" 2>/dev/null || echo "$wt_path")"
    printf '%s\n' "$WORKTREE_LIST_PORCELAIN" | REG_TARGET="$real_wt" python3 -c '
import sys, os
target = os.environ.get("REG_TARGET","")
try:
    target = os.path.realpath(target)
except Exception:
    pass
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("worktree "):
        p = line[len("worktree "):]
        try:
            rp = os.path.realpath(p)
        except Exception:
            rp = p
        if rp == target:
            sys.exit(0)
sys.exit(1)
' 2>/dev/null
    return $?
}

# ─── origin-reachability check (AC1 — SAFE-PRUNE-PUSHED) ───────────────────
# HEAD is "pushed" (work preserved on the remote / in an open PR) iff the worktree's
# current HEAD commit is contained in ANY origin/* ref. This is STRONGER than the
# branch-name-exists ORIGIN_GONE check: it confirms the exact local commit is on the
# remote, so reclaiming the worktree loses nothing. Used for the push-not-merge
# lifecycle where SAFE-PRUNE-MERGED never fires (founder-gated merge).
origin_reachable() {
    local wt_path="$1"
    local sha
    sha="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo "")"
    [ -z "$sha" ] && return 1
    # `git branch -r --contains <sha>` lists remote-tracking refs containing the
    # commit; any `origin/` line means it is on origin. Run from the main checkout
    # so the full remote-tracking ref set is visible.
    git -C "$MAIN_CHECKOUT" branch -r --contains "$sha" 2>/dev/null \
        | sed 's/^[* ]*//' | grep -q '^origin/'
}

# ─── dirty-ignore policy ──────────────────────────────────────────────────
# MOVED to .claude/scripts/plan-w-team-dirty-ignore-lib.sh (sourced at the top of
# this script) so the periodic GC and the per-merge ship path cannot drift apart.
# It defines PWT_DIRTY_IGNORE_DEFAULT, PWT_PRESERVE_IGNORE_DEFAULT,
# PWT_DIRTY_FILTER_PY, __pwt_dirty_ignore_filter, __pwt_tracked_dirty,
# __pwt_python_ok and preserve_then_reap. Do NOT re-add a local copy here — that
# fork is the 2026-06-08 WT-2 defect class.

# ─── classification ───────────────────────────────────────────────────────
# ─── SAFE-PRUNE-SHIPPED marker validation (Part B, disk-hygiene as-it-goes) ──
# A worktree carrying a `.pwt-shipped` marker (written at ship, Part A) whose
# `.tag` resolves to a commit REACHABLE FROM THE DEFAULT BRANCH is post-ship: its
# output is provably on the default branch, so its uncommitted content is stale
# generated artifacts, not work — reclaimable even though `git branch --merged` (a
# squash-merge defeats it) and `gh` (a local-ship repo has no PR) both miss it.
# Returns 0 ONLY on that positive proof; a forged/stale marker (tag absent, or tag
# not on the default branch) → 1, falling through to today's uncommitted veto.
# Reads globals MAIN_CHECKOUT + DEFAULT_BRANCH (both set before classify_one /
# remove_one run). Kill switch: PWT_WORKTREE_GC_DISABLE_SHIPPED=1.
shipped_marker_valid() {
    local wt="$1" marker tag tagcommit
    [ "${PWT_WORKTREE_GC_DISABLE_SHIPPED:-0}" = "1" ] && return 1
    marker="$wt/.pwt-shipped"
    [ -f "$marker" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local sha shacommit
    # Trust the marker if EITHER its version tag OR its ship sha resolves to a
    # commit reachable from the default branch (local OR origin) — the proof the
    # shipped output actually landed. A tag/sha that exists but sits off the
    # default branch, or does not resolve at all, is NOT trusted (guards a
    # forged/stale marker). The sha is the universal proof (every ship advances
    # the default branch); the tag covers repos that cut one.
    sha="$(jq -r '.sha // ""' "$marker" 2>/dev/null)"
    if [ -n "$sha" ]; then
        shacommit="$(git -C "$MAIN_CHECKOUT" rev-parse -q --verify "${sha}^{commit}" 2>/dev/null)"
        if [ -n "$shacommit" ]; then
            git -C "$MAIN_CHECKOUT" merge-base --is-ancestor "$shacommit" "$DEFAULT_BRANCH" 2>/dev/null && return 0
            git -C "$MAIN_CHECKOUT" merge-base --is-ancestor "$shacommit" "origin/$DEFAULT_BRANCH" 2>/dev/null && return 0
        fi
    fi
    tag="$(jq -r '.tag // ""' "$marker" 2>/dev/null)"
    if [ -n "$tag" ]; then
        tagcommit="$(git -C "$MAIN_CHECKOUT" rev-parse -q --verify "refs/tags/${tag}^{commit}" 2>/dev/null)"
        if [ -n "$tagcommit" ]; then
            git -C "$MAIN_CHECKOUT" merge-base --is-ancestor "$tagcommit" "$DEFAULT_BRANCH" 2>/dev/null && return 0
            git -C "$MAIN_CHECKOUT" merge-base --is-ancestor "$tagcommit" "origin/$DEFAULT_BRANCH" 2>/dev/null && return 0
        fi
    fi
    return 1
}

classify_one() {
    # Sets globals: CLASS, BRANCH, REASON, LAST_COMMIT_AGE_DAYS, UNCOMMITTED, MERGED, OPEN_PR, IN_USE, ACTIVE_RUN, OUTSIDE, ORIGIN_GONE, MERGED_BY, ORIGIN_REACHABLE, ORPHAN_DIR
    local wt_path="$1"
    CLASS=""; BRANCH=""; REASON=""; LAST_COMMIT_AGE_DAYS=""; UNCOMMITTED=0
    MERGED=0; OPEN_PR=0; IN_USE=0; ACTIVE_RUN=0; OUTSIDE=0; MERGED_BY=""; ORIGIN_GONE=0
    LOCKED=0; STALE_LOCK=0; IN_USE_SOURCE=""; ORIGIN_REACHABLE=0; ORPHAN_DIR=0
    UNCOMMITTED_TRACKED=0; LOCK_REASON=""; LOCK_PID=""; LOCK_PID_ALIVE=0
    LOCK_UNVERIFIABLE=0; AGE_MINUTES=""; NEWBORN=0; SHIPPED_OK=0

    if ! is_under_worktrees_dir "$wt_path"; then
        CLASS="REFUSED-OUTSIDE-CLAUDE-WORKTREES"
        REASON="path is outside .claude/worktrees/ — invariant 1 refusal"
        OUTSIDE=1
        return 0
    fi

    # ══ VETO 0 — python3 unavailable ⇒ NOTHING is reapable ═══════════════════
    # Placed ahead of EVERY other branch (including the orphan-dir check below)
    # because it invalidates the EVIDENCE they all rest on. With python3 broken,
    # `is_worktree_locked` reports "not locked" and the dirty filter reports
    # "clean", so vetoes 2 and 3 read as satisfied when they were never
    # evaluated — and `is_registered_worktree` reports "not registered", so
    # every live worktree looks like a git-unregistered orphan.
    #
    # That orphan arm is why this gate sits here rather than just above VETO 1,
    # where it was first written. ORPHAN-ASK is normally a safe keep, but it is
    # reapable under `--orphans-ok` — so `--execute --orphans-ok` with a broken
    # interpreter classified all 8 live lanes in this repo `dry-remove`,
    # including the worktree authoring this fix. VETO 0 covered `classify_one`'s
    # veto chain but not the branch that returned before reaching it: the same
    # data-loss class, one arm over. Only `is_under_worktrees_dir` (pure shell,
    # realpath) may be trusted ahead of this gate.
    if [ "${PY_OK:-1}" != "1" ]; then
        CLASS="UNSAFE-KEEP"
        REASON="${PY_OK_REASON:-python3 unavailable} — lock/dirty/liveness/registration guards cannot be evaluated; fail-closed"
        return 0
    fi

    # AC5b: a dir present on disk but NOT registered as a git worktree is an orphan
    # (its session died without `git worktree remove`). Classify ORPHAN-ASK so it is
    # only reapable under --orphans-ok; never run the main-repo-resolving git checks
    # on it. (TEST_MODE skips porcelain — fixtures always use real worktrees.)
    if [ "${PWT_WORKTREE_GC_TEST_MODE:-0}" != "1" ] && ! is_registered_worktree "$wt_path"; then
        CLASS="ORPHAN-ASK"
        REASON="git-unregistered orphan dir under .claude/worktrees/ (no worktree registration) — needs --orphans-ok"
        ORPHAN_DIR=1
        return 0
    fi

    BRANCH="$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
        # Detached or no git — treat as ORPHAN-ASK
        CLASS="ORPHAN-ASK"
        REASON="detached HEAD or non-git worktree"
        return 0
    fi

    # Uncommitted check — ignore churn confined to transient runtime paths.
    # Hooks rewrite .claude/state/* (e.g. bg-agents-cache.json) into every
    # worktree; counting that as "uncommitted work" would mark every worktree
    # dirty forever and block GC. We strip porcelain lines whose path is under an
    # ignore prefix, so only REAL source/doc edits set UNCOMMITTED. Policy, token
    # semantics, and the matcher live in the SHARED dirty-ignore block above
    # (PWT_DIRTY_IGNORE_DEFAULT + __pwt_dirty_ignore_filter) — this dirtiness
    # decision and preserve_then_reap's backup decision MUST stay in lockstep.
    local porcelain real_dirty ignore_prefixes
    porcelain="$(git -C "$wt_path" -c core.quotePath=false status --porcelain 2>/dev/null || echo "")"
    ignore_prefixes="${PWT_WORKTREE_GC_DIRTY_IGNORE-$PWT_DIRTY_IGNORE_DEFAULT}"
    if [ -z "$porcelain" ]; then
        UNCOMMITTED=0
    elif [ -z "$ignore_prefixes" ]; then
        UNCOMMITTED=1
    else
        real_dirty="$(printf '%s\n' "$porcelain" | __pwt_dirty_ignore_filter "$ignore_prefixes")"
        if [ -n "$real_dirty" ]; then UNCOMMITTED=1; else UNCOMMITTED=0; fi
    fi

    # VETO 2 — TRACKED-file modification is an ABSOLUTE veto, in ANY path,
    # ignore-set prefixes included. This is the gap that made the 2026-07-29
    # incident lossy: /plan-w-team tooling lanes do their work under `.claude/`,
    # `tests/skill/` and `docs/operations/`, which the ignore set (correctly, for
    # its own purpose) filters out — so UNCOMMITTED was 0 while five hand-edited
    # hook files sat in the tree, and `preserve_then_reap` skipped the backup for
    # exactly the same reason. Measured on the live
    # `pwt-please-use-plan-w-team-…` lane 2026-07-30.
    #
    # The discriminator lives in __pwt_tracked_dirty (shared module) so the
    # per-merge ship path applies the identical veto; see that function's comment
    # for why it is scoped to TRACKED changes and why it is pure shell.
    UNCOMMITTED_TRACKED=0
    if [ -n "$porcelain" ]; then
        if printf '%s\n' "$porcelain" | __pwt_tracked_dirty; then
            UNCOMMITTED_TRACKED=1
        fi
    fi

    # Shipped-marker check (Part B, disk-hygiene as-it-goes) — computed here so
    # VETO 2 (uncommitted) can honor it below and the post-veto classifier can
    # assign SAFE-PRUNE-SHIPPED. Positive proof only (tag resolves on the default
    # branch); in-use (VETO 1) / unverifiable-lock (VETO 3) / newborn (VETO 4)
    # remain absolute and are checked independently.
    if shipped_marker_valid "$wt_path"; then SHIPPED_OK=1; fi

    # Last commit age — used for SAFE-PRUNE-IDLE and stale-lock detection.
    local last_commit_epoch now_epoch
    now_epoch="$(date +%s)"
    last_commit_epoch="$(git -C "$wt_path" log -1 --format=%ct 2>/dev/null || echo "0")"
    if [ "$last_commit_epoch" -gt 0 ] 2>/dev/null; then
        LAST_COMMIT_AGE_DAYS=$(( (now_epoch - last_commit_epoch) / 86400 ))
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

    # AC1: origin-reachability — is the worktree's exact HEAD commit on origin/*?
    # This is the push-not-merge signal: committed work is preserved on the remote /
    # in the open PR, so the worktree is reclaimable even though it never merged.
    if origin_reachable "$wt_path"; then ORIGIN_REACHABLE=1; fi

    # In-use check (live claude session whose cwd / worktreePath is this dir)
    if is_in_use "$wt_path"; then IN_USE=1; IN_USE_SOURCE="session"; fi

    # Git-lock check (stale-lock aware) — Claude Code locks an Agent-tool
    # subagent's worktree for its lifetime and SHOULD unlock on SubagentStop, but
    # the unlock is unreliable (crash/timeout). The legacy rule "lock == in-use"
    # therefore pinned merged/idle worktrees forever once their owner died — the
    # root cause of .claude/worktrees/ disk bloat. We now honor a lock as in-use
    # ONLY when corroborated by liveness:
    #   • a live session/subagent already claims it (IN_USE set above), OR
    #   • the worktree shows recent activity (last commit within
    #     PWT_WORKTREE_LOCK_STALE_HOURS) — covers the case where the claude binary
    #     was unavailable so the live scan returned nothing.
    # A lock with neither is STALE and must not block reclamation.
    #   PWT_WORKTREE_GC_IGNORE_LOCKS=1 → treat every lock as absent (don't check).
    #   PWT_WORKTREE_GC_TRUST_LOCKS=1  → restore legacy any-lock=in-use.
    if [ "${PWT_WORKTREE_GC_IGNORE_LOCKS:-0}" != "1" ] && is_worktree_locked "$wt_path"; then
        LOCKED=1
        LOCK_REASON="$(worktree_lock_reason "$wt_path")"
        LOCK_PID="$(lock_reason_pid "$LOCK_REASON")"
        if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
            # VETO 3 (proof arm) — the lock names a PID and that PID is ALIVE.
            # This is positive proof of an owning process, independent of the
            # `claude agents --json` path match, and available from the instant
            # `git worktree add` runs. It closes the newborn race directly.
            LOCK_PID_ALIVE=1
            IN_USE=1; IN_USE_SOURCE="lock-pid-alive"
        fi
        if [ "${PWT_WORKTREE_GC_TRUST_LOCKS:-0}" = "1" ]; then
            IN_USE=1; [ -z "$IN_USE_SOURCE" ] && IN_USE_SOURCE="lock-trusted"
        elif [ "$IN_USE" = "1" ]; then
            : # a live session (or a live lock PID) already corroborates the lock
        else
            local lock_stale_hours recent_commit age_hours
            # E1 (2026-05-29 ENOSPC incident): a lock older than this AND
            # merged/idle is force-reaped. Canonical knob is PWT_STALE_LOCK_HOURS
            # (default 6 — was 24); the legacy PWT_WORKTREE_LOCK_STALE_HOURS name
            # is still honored. 24h let merged-but-locked worktrees linger ~a day
            # each, which fed the 67-worktree / 64 GB pileup.
            lock_stale_hours="${PWT_STALE_LOCK_HOURS:-${PWT_WORKTREE_LOCK_STALE_HOURS:-6}}"
            recent_commit=0
            if [ "$last_commit_epoch" -gt 0 ] 2>/dev/null; then
                age_hours=$(( (now_epoch - last_commit_epoch) / 3600 ))
                [ "$age_hours" -lt "$lock_stale_hours" ] && recent_commit=1
            fi
            if [ "$recent_commit" = "1" ]; then
                IN_USE=1; IN_USE_SOURCE="lock-recent"  # fresh lock, agent may be live but unseen
            elif [ -n "$LOCK_PID" ]; then
                # Lock names a PID and that PID is DEAD (the alive branch above
                # already returned) — the owner is PROVABLY gone, so the lock has
                # outlived it and must not pin the worktree. This is the arm that
                # preserves the E1 / 2026-05-29 ENOSPC fix: every lock written by
                # pwt-goal.sh or Claude Code carries a PID, so the automated
                # majority stays reclaimable once its process exits.
                STALE_LOCK=1
            else
                # VETO 3 (fail-closed arm) — a lock with NO parseable PID cannot
                # be proven abandoned. Commit recency is only a proxy, and it is
                # the wrong proxy: a hand-written `git worktree lock` reason, or a
                # bare lock with no reason at all, was previously reported as
                # "stale lock ignored" and removed anyway — so a human explicitly
                # marking a tree do-not-touch got no protection whatsoever
                # (2026-07-29 finding). Absence of proof of death is not proof of
                # absence of an owner: keep it, and let the operator opt out via
                # PWT_WORKTREE_GC_IGNORE_LOCKS=1.
                LOCK_UNVERIFIABLE=1
                IN_USE_SOURCE="lock-unverifiable"
            fi
        fi
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
    # ══ VETO 1 — LIVENESS WINS UNCONDITIONALLY ═══════════════════════════════
    # First and absolute, ahead of MERGED / PUSHED / IDLE alike. The 2026-07-29
    # incident showed the failure is not this ordering but the *derivation* of
    # IN_USE from one fallible path-matching probe; VETO 3's lock-PID arm now
    # feeds this same gate from an independent source, so a single blind probe
    # can no longer authorize a reap.
    if [ "$IN_USE" = "1" ]; then
        CLASS="UNSAFE-KEEP"
        case "$IN_USE_SOURCE" in
            lock-pid-alive) REASON="locked by LIVE pid $LOCK_PID — owning process alive (independent of session probe)" ;;
            lock-recent)  REASON="locked, recent activity (<${PWT_STALE_LOCK_HOURS:-${PWT_WORKTREE_LOCK_STALE_HOURS:-6}}h) — possible live agent" ;;
            lock-trusted) REASON="locked worktree (PWT_WORKTREE_GC_TRUST_LOCKS=1)" ;;
            *)            REASON="in-use by live claude session" ;;
        esac
        return 0
    fi

    # ══ VETO 2 — UNCOMMITTED IS AN ABSOLUTE VETO ═════════════════════════════
    # Tracked-file modifications first, because they are NOT subject to the
    # dirty-ignore set. This is the arm that saves a /plan-w-team tooling lane
    # whose entire diff lives under `.claude/` — the shape of the measured
    # incident, where UNCOMMITTED read 0 with five hand-edited hook files present.
    # A valid `.pwt-shipped` marker (Part B) makes the uncommitted content stale
    # post-ship generated artifacts, not work — its output is provably on the
    # default branch — so it does NOT veto. (VETO 1 in-use above already returned;
    # this only relaxes the uncommitted veto, never the liveness one.)
    if [ "$UNCOMMITTED_TRACKED" = "1" ] && [ "$SHIPPED_OK" != "1" ]; then
        CLASS="UNSAFE-KEEP"
        REASON="uncommitted tracked-file changes (absolute veto — ignore-set does not apply)"
        return 0
    fi
    if [ "$UNCOMMITTED" = "1" ] && [ "$SHIPPED_OK" != "1" ]; then
        CLASS="UNSAFE-KEEP"; REASON="uncommitted changes"; return 0
    fi

    # ══ VETO 3 — ANY LOCK WE CANNOT PROVE ABANDONED IS A VETO ════════════════
    # A lock with a live PID already returned via VETO 1. A lock with a dead PID
    # is provably abandoned (STALE_LOCK) and stays reclaimable so the 2026-05-29
    # ENOSPC fix is not reverted. What is left is a lock we cannot adjudicate —
    # no parseable PID, e.g. a hand-written `git worktree lock` reason or a bare
    # lock. Previously reported "stale lock ignored" and removed anyway, which is
    # why a human marking a tree do-not-touch got no protection at all. Keep it.
    if [ "$LOCK_UNVERIFIABLE" = "1" ]; then
        CLASS="UNSAFE-KEEP"
        REASON="locked, owner not verifiable (no pid in lock reason) — fail-closed; override with PWT_WORKTREE_GC_IGNORE_LOCKS=1"
        return 0
    fi

    # ══ VETO 4 — NEWBORN-WORKTREE GRACE WINDOW ═══════════════════════════════
    # The window between `git worktree add` (+ seed-branch push, which makes HEAD
    # origin-reachable and therefore prunable) and the owning bg session becoming
    # visible to the liveness probe. Nothing authored exists to protect yet, and
    # every other signal reads "safe" — so age is the only guard left. Fails
    # CLOSED when the birth time is unreadable.
    local min_age="${PWT_WORKTREE_MIN_AGE_MINUTES:-30}"
    if [ "$min_age" -gt 0 ] 2>/dev/null; then
        AGE_MINUTES="$(worktree_age_minutes "$wt_path")"
        if [ -z "$AGE_MINUTES" ]; then
            NEWBORN=1
            CLASS="UNSAFE-KEEP"
            REASON="worktree age unreadable — fail-closed inside newborn grace window (${min_age}m)"
            return 0
        fi
        if [ "$AGE_MINUTES" -lt "$min_age" ] 2>/dev/null; then
            NEWBORN=1
            CLASS="UNSAFE-KEEP"
            REASON="newborn worktree ${AGE_MINUTES}m old (< ${min_age}m grace) — owning session may not have registered yet"
            return 0
        fi
    fi

    # ── FAIL-CLOSED liveness guard (directive 2026-06-07) ──────────────────────
    # If the live-session probe could not run, we cannot prove this worktree has NO
    # live owning session, so we must NOT auto-reap it. A supervised worker that
    # pushed in Step 6 (HEAD now on origin/* → would classify SAFE-PRUNE-PUSHED)
    # still has Steps 6b-8 to run; reaping it here orphans the run. A missed reap is
    # cheap (next run, with a working probe, reclaims it); an erroneous reap is not.
    # IN_USE / UNCOMMITTED already returned above; this only blocks the auto-reap
    # classes (MERGED / PUSHED / IDLE) and never weakens an existing keep.
    if [ "${LIVE_QUERY_FAILED:-0}" = "1" ]; then
        CLASS="UNSAFE-KEEP"
        REASON="live-session probe unavailable — fail-closed (cannot confirm no live owner)"
        return 0
    fi

    # ── SAFE-PRUNE-SHIPPED (Part B) — a `.pwt-shipped` marker whose tag resolves
    # on the default branch is the merge-path-independent proof of ship. It wins
    # over MERGED-detection precisely because it closes MERGED's blind spots
    # (squash-merge defeats `git branch --merged`; a local-ship repo has no gh PR).
    # It is reached only AFTER the in-use / uncommitted-vetoed / lock / newborn /
    # fail-closed-liveness guards above, so those keeps are never weakened.
    if [ "$SHIPPED_OK" = "1" ]; then
        CLASS="SAFE-PRUNE-SHIPPED"
        REASON="shipped marker + tag on default branch (post-ship; reclaimable despite uncommitted)"
        [ "$STALE_LOCK" = "1" ] && REASON="$REASON; stale lock ignored"
        return 0
    fi

    if [ "$MERGED" = "1" ]; then
        CLASS="SAFE-PRUNE-MERGED"
        REASON="branch merged (source: ${MERGED_BY:-unknown})"
        [ "$STALE_LOCK" = "1" ] && REASON="$REASON; stale lock ignored"
        return 0
    fi

    if [ "$ACTIVE_RUN" = "1" ]; then
        CLASS="UNSAFE-KEEP"; REASON="registered in active /plan-w-team run"; return 0
    fi

    # AC1 — SAFE-PRUNE-PUSHED: HEAD reachable from origin/* (work preserved on the
    # remote / open PR) AND not in-use / not real-uncommitted (those returned above)
    # / not an in-flight active run. This is the push-not-merge reclaim path: in
    # consumer repos the standing directive is "push branch + open PR, never merge",
    # so SAFE-PRUNE-MERGED never fires and these pile up. Reapable under --execute
    # like the other SAFE-PRUNE-* classes (NOT orphan-gated — nothing is lost since
    # the commits are on origin). Wins over the OPEN_PR keep below precisely because
    # an open PR is exactly the preserved-on-remote state we now reclaim.
    if [ "$ORIGIN_REACHABLE" = "1" ]; then
        CLASS="SAFE-PRUNE-PUSHED"
        REASON="HEAD reachable from origin/* (pushed; work preserved on remote)"
        [ "$OPEN_PR" = "1" ] && REASON="$REASON; open PR"
        [ "$STALE_LOCK" = "1" ] && REASON="$REASON; stale lock ignored"
        return 0
    fi

    if [ "$OPEN_PR" = "1" ]; then
        CLASS="UNSAFE-KEEP"; REASON="unmerged branch with open PR"; return 0
    fi

    # Idle check
    local idle_days="${PWT_WORKTREE_IDLE_DAYS:-7}"
    if [ -n "$LAST_COMMIT_AGE_DAYS" ] && [ "$LAST_COMMIT_AGE_DAYS" -ge "$idle_days" ] && [ "$OPEN_PR" = "0" ]; then
        CLASS="SAFE-PRUNE-IDLE"
        REASON="no commits in ${LAST_COMMIT_AGE_DAYS}d (threshold ${idle_days}d), no open PR"
        [ "$STALE_LOCK" = "1" ] && REASON="$REASON; stale lock ignored"
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

# ─── preserve-then-reap (AC6) ─────────────────────────────────────────────
# Before any --force removal, back up REAL (non-policy per AC2's ignore set)
# uncommitted work to a timestamped patch under .claude/state/hygiene-backups/ so an
# aggressive reap can never silently lose unique work. Two cases:
#   • git worktree (own toplevel == wt_path): dump `git diff HEAD` + a porcelain
#     untracked/modified list, both filtered to NON-ignored paths.
#   • git-unregistered orphan dir (AC5b): `git -C` resolves to the main repo, so we
#     can't diff; instead dump a `find` manifest of non-ignored files AND copy those
#     files into the backup so nothing real is lost. (node_modules/.claude/etc are
#     ignored, so a typical orphan dir holding only deps preserves nothing — correct.)
# Contract (echoed to STDERR only; never stdout — remove_one parses stdout):
#   return 0  → nothing real to preserve, OR preserved successfully → safe to remove
#   return 1  → content existed but the backup write FAILED → caller MUST skip rm
# bash 3.2 + zsh safe.
# preserve_then_reap() MOVED to .claude/scripts/plan-w-team-dirty-ignore-lib.sh
# (sourced at the top of this script). It reads the $MAIN_CHECKOUT global set
# above and returns non-zero to mean "backup failed — do NOT remove"; remove_one
# below honors that. The per-merge ship path calls the same function, so both
# destructive paths back up authored work identically.

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
    # AC6 preserve-then-reap: back up any REAL uncommitted delta BEFORE the
    # destructive --force. Fail-safe — a failed backup SKIPS removal (echo "0 0").
    # EXCEPTION (Part B): a valid `.pwt-shipped` worktree's content is provably on
    # the default branch via its ship tag, so backing up its (stale, post-ship)
    # uncommitted artifacts would just move the ~600 MB bloat into a backup patch —
    # defeating the reclaim. Skip the backup; the tag is the durable copy.
    if shipped_marker_valid "$wt_path"; then
        : # post-ship — tag on default branch is the durable copy; no backup needed
    elif ! preserve_then_reap "$wt_path"; then
        echo "0 0"
        return 0
    fi
    # Release any lingering lock first so a single `--force` succeeds even on a
    # locked worktree (otherwise git refuses a locked tree without a double
    # --force; the rm -rf fallback below still covers that case).
    git -C "$MAIN_CHECKOUT" worktree unlock "$wt_path" 2>/dev/null || true
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
        SAFE-PRUNE-MERGED|SAFE-PRUNE-IDLE|SAFE-PRUNE-PUSHED|SAFE-PRUNE-SHIPPED)
            # SAFE-PRUNE-PUSHED (AC1) and SAFE-PRUNE-SHIPPED (Part B) are reaped like
            # the other SAFE-PRUNE-* classes — NOT orphan-gated, because the work is
            # preserved on origin / provably on the default branch via the ship tag.
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
        case "$CLASS" in
            SAFE-PRUNE-MERGED|SAFE-PRUNE-IDLE|SAFE-PRUNE-PUSHED)
                : # would-have-removed (dry-run)
                ;;
            *)
                KEPT=$((KEPT+1))
                ;;
        esac
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
    "locked": sys.argv[18] == "1",
    "stale_lock": sys.argv[19] == "1",
    "in_use_source": sys.argv[20] or None,
    "origin_reachable": sys.argv[21] == "1",
    "orphan_dir": sys.argv[22] == "1",
    "live_query_failed": sys.argv[23] == "1",
    # veto telemetry (2026-07-30 data-loss fix)
    "uncommitted_tracked": sys.argv[24] == "1",
    "lock_pid": int(sys.argv[25]) if sys.argv[25].isdigit() else None,
    "lock_pid_alive": sys.argv[26] == "1",
    "lock_unverifiable": sys.argv[27] == "1",
    "age_minutes": int(sys.argv[28]) if sys.argv[28].isdigit() else None,
    "newborn": sys.argv[29] == "1",
}
sys.stdout.write(json.dumps(row))
' "$wt_path" "$name" "$BRANCH" "$CLASS" "$REASON" "$ACTION" \
  "$REMOVED_WT" "$REMOVED_BRANCH" "$UNCOMMITTED" "$MERGED" "$OPEN_PR" \
  "$IN_USE" "$ACTIVE_RUN" "${LAST_COMMIT_AGE_DAYS:-?}" "$MERGE_SOURCE" "${MERGED_BY:-}" "${ORIGIN_GONE:-0}" \
  "${LOCKED:-0}" "${STALE_LOCK:-0}" "${IN_USE_SOURCE:-}" "${ORIGIN_REACHABLE:-0}" "${ORPHAN_DIR:-0}" \
  "${LIVE_QUERY_FAILED:-0}" "${UNCOMMITTED_TRACKED:-0}" "${LOCK_PID:-}" "${LOCK_PID_ALIVE:-0}" \
  "${LOCK_UNVERIFIABLE:-0}" "${AGE_MINUTES:-}" "${NEWBORN:-0}" >> "$RESULTS_JSON_TMP"

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
