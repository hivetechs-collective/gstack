#!/bin/bash
# pwt-goal — natural-language → /goal command derivation helper
#
# Wraps a feature request into a properly-formatted Anthropic /goal command
# that drives an autonomous /plan-w-team run with explicit definition-of-done
# anchors and hard-gate escalations.
#
# No wall-clock or turn caps: the only stopping points are goal-success
# (terminal SUCCESS anchors) and hard-gate halts (push-ack, secret-scan-allow,
# scope-unlock-for-drift, 3-consecutive low-confidence).
#
# Workflow: run this in your terminal, copy the output, paste into a fresh
# `claude` session (or `claude --bg "<paste>"`) to start an autonomous run.
#
# Usage:
#   pwt-goal.sh "ship payment API with stripe webhooks"
#   pwt-goal.sh -i "ship payment API"          # interactive: prompt for extra DoD
#   pwt-goal.sh --launch "ship payment API"    # auto-launches `claude --bg` for you
#   pwt-goal.sh --worker-only "ship payment API"  # spawn worker only (no bg supervisor);
#                                              # caller (e.g. UserPromptSubmit hook or
#                                              # origin chat) acts as the live supervisor.
#                                              # Emits worker SID on stdout.
#   pwt-goal.sh --type refactor "extract auth"  # variant template (refactor/bugfix/docs)
#   pwt-goal.sh -h                              # help
#
# Output: the /goal command string on stdout, ready to copy.

set -u

usage() {
    cat <<EOF
Usage: $0 [options] <request>

Wraps a natural-language feature request into a /goal command that drives an
autonomous /plan-w-team run with explicit done criteria and hard-gate exits.

Options:
  -i, --interactive    Prompt for additional DoD criteria beyond defaults
  -t, --type TYPE      Template variant: feature (default), refactor, bugfix, docs
      --launch         AUTO-LAUNCH: spawn 'claude --bg' with the derived /goal.
                       User monitors via 'claude agents'. Implies --auto-push.
                       Also spawns a separate bg supervisor session for
                       detached / shell-driven runs (legacy mode; AC7).
      --worker-only    Spawn ONLY the worker bg session (no bg supervisor).
                       Worker SID is emitted on stdout as
                         "worker_sid=<SID>"
                       The caller is expected to act as the live supervisor
                       (e.g. UserPromptSubmit hook injecting additionalContext
                       so the origin assistant turn observes the worker).
                       Implies --auto-push unless --no-auto-push is given.
      --supervisor-goal  Same as --worker-only PLUS mirror the worker's goal
                       state file to the ORIGIN repo's .claude/state/. Use when
                       the origin chat session is itself running under /goal
                       (multi-hour autonomous pattern): the origin's goal
                       evaluator needs a non-null plan-w-team-goal-*.json to
                       track the worker's progress.
                       Mutually exclusive with --launch.
      --auto-push      Auto-approve push-ack hard-gate during the run (sets
                       PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 for child session).
                       Trades safety for autonomy — only push-ack auto-approves;
                       secret-scan-allow and scope-unlock-for-drift still halt.
      --no-auto-push   Explicit opt-out even with --launch (require push confirm)
  -h, --help           Show this help

Examples:
  $0 "ship payment API with stripe webhooks"
  $0 -i "refactor auth middleware to remove duplication"
  $0 --type refactor "extract notification service"
  $0 --launch "fix the login redirect bug"

Note: --hours / --turns flags accepted (warning) but no-op — /plan-w-team has
no wall-clock or turn caps by design. Only goal-success and hard-gate halts
are valid terminal states.

The output is a /goal command. Copy it and paste at the start of a fresh
Claude Code session, or use --launch to auto-invoke 'claude --bg'.
EOF
}

# Defaults
INTERACTIVE=0
LAUNCH=0
WORKER_ONLY=0    # spawn only the worker bg session; caller is the supervisor
SUPERVISOR_GOAL=0  # like --worker-only, plus mirror goal state to origin .claude/state/
AUTO_PUSH=0      # auto-approve push-ack hard-gate during autonomous run
TYPE="feature"
REQUEST=""

# ─── --resume-staleness-check (AC4 — bg-worker resume staleness self-exit) ───
# The bg-session daemon auto-resumes persisted `claude --bg` workers on restart
# (e.g. after a CLI version bump) with no completion check, so an already-shipped
# directive re-runs and risks a duplicate/conflicting push to the open PR. This
# mode reconciles "is this directive already terminal/shipped?" so a SessionStart
# guard (plan-w-team-bg-resume-guard.sh) can self-exit a resumed-but-done worker.
#
# Usage:
#   pwt-goal.sh --resume-staleness-check [--sid <8hex>] [--slug <slug>]
#                                        [--branch <b>] [--state-dir <d>] [--json]
# Exit codes (tie to shared/goal-conditions.md terminal anchors):
#   0  STALE     — goal-state terminal_state is non-null OR target branch merged /
#                  carries an open PR with the shipped commits → worker should self-exit.
#   1  LIVE      — no terminal signal; the directive is still in flight → proceed.
#   2  UNKNOWN   — could not resolve goal-state/branch (fail-open → caller proceeds).
if [ "${1:-}" = "--resume-staleness-check" ]; then
    shift
    RSC_SID=""; RSC_SLUG=""; RSC_BRANCH=""; RSC_STATE_DIR=""; RSC_JSON=0; RSC_BRANCH_EXPLICIT=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --sid)       RSC_SID="${2:-}"; shift 2 || break ;;
            --slug)      RSC_SLUG="${2:-}"; shift 2 || break ;;
            --branch)    RSC_BRANCH="${2:-}"; RSC_BRANCH_EXPLICIT=1; shift 2 || break ;;
            --state-dir) RSC_STATE_DIR="${2:-}"; shift 2 || break ;;
            --json)      RSC_JSON=1; shift ;;
            *) shift ;;
        esac
    done

    __rsc_emit() {  # $1 verdict, $2 reason, $3 exit
        if [ "$RSC_JSON" = "1" ]; then
            printf '{"verdict":"%s","reason":"%s","slug":"%s","sid":"%s","branch":"%s"}\n' \
                "$1" "$2" "$RSC_SLUG" "$RSC_SID" "$RSC_BRANCH"
        else
            echo "resume-staleness: $1 — $2" >&2
        fi
        exit "$3"
    }

    # Resolve candidate state dirs: explicit → project root → main → worktree glob.
    RSC_ROOT="${RSC_STATE_DIR:+}"
    RSC_PRIMARY="${PWT_PROJECT_ROOT_OVERRIDE:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
    RSC_STATE_DIRS=""
    [ -n "$RSC_STATE_DIR" ] && RSC_STATE_DIRS="$RSC_STATE_DIR"
    [ -d "$RSC_PRIMARY/.claude/state" ] && RSC_STATE_DIRS="$RSC_STATE_DIRS
$RSC_PRIMARY/.claude/state"
    # main-checkout (climb from common dir) + worktree-isolated state dirs
    RSC_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
    if [ -n "$RSC_COMMON" ]; then
        RSC_MAIN="$(dirname "$(realpath "$RSC_COMMON" 2>/dev/null || echo "$RSC_COMMON")")"
        [ -d "$RSC_MAIN/.claude/state" ] && RSC_STATE_DIRS="$RSC_STATE_DIRS
$RSC_MAIN/.claude/state"
        for d in "$RSC_MAIN"/.claude/worktrees/*/.claude/state; do
            [ -d "$d" ] && RSC_STATE_DIRS="$RSC_STATE_DIRS
$d"
        done
    fi

    # Locate the goal-state file: prefer slug; else match worker_sid prefix.
    RSC_GOAL_FILE=""
    while IFS= read -r sd; do
        [ -z "$sd" ] && continue
        if [ -n "$RSC_SLUG" ] && [ -f "$sd/plan-w-team-goal-${RSC_SLUG}.json" ]; then
            RSC_GOAL_FILE="$sd/plan-w-team-goal-${RSC_SLUG}.json"; break
        fi
        if [ -n "$RSC_SID" ]; then
            for f in "$sd"/plan-w-team-goal-*.json; do
                [ -f "$f" ] || continue
                if grep -q "\"worker_sid\"[[:space:]]*:[[:space:]]*\"${RSC_SID}" "$f" 2>/dev/null; then
                    RSC_GOAL_FILE="$f"; break 2
                fi
            done
        fi
    done <<RSC_DIRS
$RSC_STATE_DIRS
RSC_DIRS

    # (1) terminal_state in the goal-state file → STALE.
    if [ -n "$RSC_GOAL_FILE" ] && [ -f "$RSC_GOAL_FILE" ]; then
        RSC_TERM="$(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(""); sys.exit(0)
v=d.get("terminal_state")
print(v if v not in (None,"") else "")' "$RSC_GOAL_FILE" 2>/dev/null)"
        [ -z "$RSC_SLUG" ] && RSC_SLUG="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("slug") or "")
except Exception: print("")' "$RSC_GOAL_FILE" 2>/dev/null)"
        if [ -n "$RSC_TERM" ]; then
            __rsc_emit STALE "goal-state terminal_state=$RSC_TERM (already terminal)" 0
        fi
    fi

    # Gate: a bare --sid that matched NO goal-state is not a recognized pwt worker —
    # do NOT run branch checks against an arbitrary session's cwd (false-positive
    # guard). Only proceed to branch checks when a goal-state matched, OR the caller
    # gave an explicit --slug / --branch.
    if [ -z "$RSC_GOAL_FILE" ] && [ -z "$RSC_SLUG" ] && [ "$RSC_BRANCH_EXPLICIT" != "1" ]; then
        __rsc_emit UNKNOWN "no goal-state matched sid=$RSC_SID and no explicit slug/branch (fail-open)" 2
    fi

    # (2) target branch already shipped — merged to default OR open PR carries HEAD.
    [ -z "$RSC_BRANCH" ] && RSC_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
    if [ -n "$RSC_BRANCH" ] && [ "$RSC_BRANCH" != "HEAD" ]; then
        RSC_DEFAULT="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
        [ -z "$RSC_DEFAULT" ] && RSC_DEFAULT="main"
        if git branch --merged "$RSC_DEFAULT" 2>/dev/null | sed 's/^[* +]*//' | grep -qxF "$RSC_BRANCH"; then
            __rsc_emit STALE "branch $RSC_BRANCH already merged to $RSC_DEFAULT" 0
        fi
        if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
            RSC_PR_STATE="$(gh pr list --head "$RSC_BRANCH" --state all --json state -q '.[0].state' 2>/dev/null || echo "")"
            if [ "$RSC_PR_STATE" = "MERGED" ]; then
                __rsc_emit STALE "branch $RSC_BRANCH PR already MERGED" 0
            fi
        fi
    fi

    # (3) nothing resolved at all → fail-open UNKNOWN; a found-but-non-terminal
    # state → LIVE (genuinely in flight).
    if [ -z "$RSC_GOAL_FILE" ]; then
        __rsc_emit UNKNOWN "no goal-state found for sid=$RSC_SID slug=$RSC_SLUG (fail-open)" 2
    fi
    __rsc_emit LIVE "goal-state present, terminal_state null, branch not shipped" 1
fi

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -i|--interactive) INTERACTIVE=1; shift ;;
        --launch) LAUNCH=1; AUTO_PUSH=1; shift ;;
        --worker-only) WORKER_ONLY=1; LAUNCH=1; AUTO_PUSH=1; shift ;;
        --supervisor-goal) SUPERVISOR_GOAL=1; WORKER_ONLY=1; LAUNCH=1; AUTO_PUSH=1; shift ;;
        --auto-push) AUTO_PUSH=1; shift ;;
        --no-auto-push) AUTO_PUSH=0; shift ;;
        -t|--type) TYPE="$2"; shift 2 ;;
        --hours|--turns)
            echo "Note: $1 removed by design — /plan-w-team has no wall-clock or turn caps. Ignoring '$1 $2'." >&2
            shift 2 ;;
        --) shift; REQUEST="$*"; break ;;
        -*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
        *) REQUEST="$*"; break ;;
    esac
done

if [ -z "$REQUEST" ]; then
    echo "Error: no request provided" >&2
    usage
    exit 1
fi

# --supervisor-goal MUST imply --worker-only (set during parse) and cannot
# coexist with the bg-supervisor mode of --launch. The parser sets both
# WORKER_ONLY and LAUNCH so the existing --worker-only spawn path takes the
# branch; this guard just defends against future flag-handling drift.
if [ "$SUPERVISOR_GOAL" = "1" ] && [ "$WORKER_ONLY" != "1" ]; then
    echo "Error: --supervisor-goal requires --worker-only semantics (cannot combine with detached --launch)" >&2
    exit 1
fi

# ─── PREAMBLE STRIP ────────────────────────────────────────────────────────
# When a user message starts with a route-hook trigger phrase (e.g. "Use
# /plan-w-team to ship X"), the verbatim REQUEST already contains the
# wrapper this script is about to add. Without stripping, GOAL_TEXT becomes
# "/goal Use /plan-w-team to use /plan-w-team to ship X" — a doubled prefix
# that confuses the worker LLM and bloats the /goal directive.
#
# Strip leading whitespace, then any of the 6 known trigger phrases
# (case-insensitive). After a trigger that does not end with "to", also
# strip a leading "to " — so `using /plan-w-team to do X` → `do X`.
#
# Triggers must be tried longest-first to avoid `use /plan-w-team to`
# being short-circuited by a substring match against a less-specific
# trigger. We hand-order them below.
__pwt_strip_preamble() {
    local input="$1"
    # Strip leading whitespace
    local trimmed="${input#"${input%%[![:space:]]*}"}"
    local lower
    lower=$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')

    # Longest-first ordering: "now use /plan-w-team to" must be checked
    # before "use /plan-w-team to" so the "now" prefix is consumed.
    local triggers=(
        'now use /plan-w-team to'
        'start a /plan-w-team run to'
        'kick off /plan-w-team for'
        'use /plan-w-team to'
        'using /plan-w-team'
        'with /plan-w-team'
    )

    local t tlen rest
    for t in "${triggers[@]}"; do
        tlen=${#t}
        if [ "${lower:0:$tlen}" = "$t" ]; then
            rest="${trimmed:$tlen}"
            # Strip a single leading space after the trigger if present.
            rest="${rest#" "}"
            # If the trigger does not already end with "to" and the
            # remainder starts with "to " (case-insensitive), strip that too.
            if [ "${t: -3}" != " to" ]; then
                local rest_lower
                rest_lower=$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')
                if [ "${rest_lower:0:3}" = "to " ]; then
                    rest="${rest:3}"
                fi
            fi
            printf '%s' "$rest"
            return 0
        fi
    done
    printf '%s' "$input"
}
REQUEST=$(__pwt_strip_preamble "$REQUEST")
if [ -z "$REQUEST" ]; then
    echo "Error: REQUEST is empty after stripping trigger preamble" >&2
    exit 1
fi

# Preserve the user's original directive content. The overflow path below
# rewrites $REQUEST to a "Read full directive at ..." pointer; without this
# snapshot, downstream slug derivation would produce useless slugs like
# "read-full-directive-at-users-veronelazio-developer-private-claud" instead
# of slugs that describe the actual feature. See docs/specs/supervisor-mirror-lifecycle.md.
ORIGINAL_REQUEST="$REQUEST"

# ─── SAFE SLUG DERIVATION ──────────────────────────────────────────────────
# Production failure (2026-05-23): launching --supervisor-goal with 2700+ char
# directives produced 'File name too long' on the supervisor mirror file and
# spawned-children-registry filename. Root cause: ad-hoc `tr | sed | cut -c1-64`
# pipeline truncated PER-LINE and let embedded newlines through, yielding
# multi-line slugs that violated OS NAME_MAX (255 bytes) and the no-newline
# constraint when interpolated into a filename.
#
# This helper sanitizes a REQUEST string into a filesystem-safe slug:
#   1. Replace newlines/tabs with spaces, collapse multi-spaces
#   2. Strip leading/trailing whitespace
#   3. Lowercase
#   4. Replace any non-[a-z0-9-] run with a single hyphen
#   5. Collapse hyphen runs; trim leading/trailing hyphens
#   6. Truncate combined body to 80 characters
#   7. Append "-<8-char-sha256>" of the FULL ORIGINAL request so that two
#      distinct long inputs sharing an 80-char prefix still differ.
#
# Output is bounded: 80 (body) + 1 (sep) + 8 (hash) = 89 chars. Plus typical
# ".jsonl" = 94 chars, comfortably under NAME_MAX.
#
# Empty / whitespace-only / non-ASCII-only inputs fall back to a deterministic
# "_unsourced-<hash>" so callers never see an empty slug.
#
# See docs/specs/pwt-goal-safe-slug.md and docs/specs/supervisor-mirror-lifecycle.md.
__pwt_safe_slug() {
    local request="${1:-}"
    local body
    body=$(printf '%s' "$request" \
        | tr '\n\t' '  ' \
        | tr -s ' ' \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-80 \
        | sed -E 's/-+$//')   # re-trim if cut left a trailing hyphen
    if [ -z "$body" ]; then
        body="_unsourced"
    fi
    local hash
    hash=$(printf '%s' "$request" | shasum -a 256 2>/dev/null | cut -c1-8)
    [ -z "$hash" ] && hash="00000000"
    printf '%s-%s\n' "$body" "$hash"
}

# ─── MAIN-REPO ROOT (worktree-robust) ───────────────────────────────────────
# Resolve the PRIMARY checkout root — the directory under which
# `claude --bg --worktree <name>` materializes worktrees (git registers every
# worktree against the COMMON git dir, so the worktree always lives at
# <main-repo>/.claude/worktrees/<name>, regardless of the CWD the launcher was
# invoked from).
#
# THIS IS THE ROOT-CAUSE FIX for the 2026-06-07 "stops short of ship" incident
# (run 10ac5920): the --worker-only seed previously used PROJECT_ROOT, resolved
# via `git rev-parse --show-toplevel`, which returns the CALLER's worktree when
# the launcher runs from inside a stale sibling worktree (pwt-evaluate-...). The
# goal-state seed then landed in the wrong worktree and the worker's anti-skip
# anchor was inert. `--git-common-dir` resolves the main checkout correctly even
# from inside a sibling worktree (verified: returns <main>/.git absolute), so
# the seed reaches the worktree the worker will actually run in.
#
# Resolution order:
#   1. $PWT_PROJECT_ROOT_OVERRIDE (test-only; the sandbox IS the main repo)
#   2. dirname(git --git-common-dir)  — worktree-robust main checkout
#   3. git --show-toplevel            — last-resort (not in a worktree)
#   4. $PROJECT_ROOT / $PWD           — fail-open
__pwt_main_repo_root() {
    if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
        printf '%s\n' "$PWT_PROJECT_ROOT_OVERRIDE"
        return 0
    fi
    local cdir root
    cdir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    if [ -n "$cdir" ]; then
        case "$cdir" in
            /*) root=$(dirname "$cdir") ;;
            *)  root=$(cd "$(dirname "$cdir")" 2>/dev/null && pwd || echo "") ;;
        esac
    fi
    if [ -z "${root:-}" ] || [ ! -e "$root/.git" ]; then
        root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    fi
    [ -z "$root" ] && root="${PROJECT_ROOT:-$PWD}"
    printf '%s\n' "$root"
}

# ─── SKILL VERSION + COMMIT SHA ─────────────────────────────────────────────
# Captures which /plan-w-team release produced this run so any bug surfaced
# after the fact can be traced back to the exact skill version. Recorded into
# the run's goal-state JSON + a sidecar file across all spawn paths
# (--launch, --worker-only, --supervisor-goal).
#
# VERSION lives at .claude/commands/plan-w-team/VERSION (semver, one line).
# COMMIT_SHA is the short SHA of the current HEAD of the repo containing this
# script. In a worktree we still want the worktree's HEAD (post-pwt-version-tracking
# branch), not origin/main, so we use `git -C <script-dir>` rather than git from
# PWD.
#
# Both values gracefully degrade to "unknown" if their source is missing.
__pwt_resolve_skill_version() {
    local version_file="$(dirname "$0")/../commands/plan-w-team/VERSION"
    if [ -f "$version_file" ]; then
        head -1 "$version_file" 2>/dev/null | tr -d '[:space:]' || echo "unknown"
    else
        echo "unknown"
    fi
}

__pwt_resolve_skill_commit_sha() {
    local script_dir
    script_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
    if [ -n "$script_dir" ]; then
        git -C "$script_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Cached at process start so every write within this invocation uses the same
# values (even if HEAD moves mid-run, which would be pathological but possible).
SKILL_VERSION=$(__pwt_resolve_skill_version)
SKILL_COMMIT_SHA=$(__pwt_resolve_skill_commit_sha)
export PWT_SKILL_VERSION="$SKILL_VERSION"
export PWT_SKILL_COMMIT_SHA="$SKILL_COMMIT_SHA"

# Write the spawn-time skill-version sidecar to the origin's .claude/state/.
# Called from the spawn flow once SLUG_GUESS and the origin-root resolution
# have produced a valid target directory.
#
# Args:
#   $1 = state directory (must exist)
#   $2 = slug
#   $3 = spawn path label ("launch" | "worker-only" | "supervisor-goal")
# Always exits 0 — never fail the spawn over a sidecar write.
__pwt_write_skill_version_sidecar() {
    local state_dir="${1:-}"
    local slug="${2:-}"
    local spawn_path="${3:-unknown}"
    [ -z "$state_dir" ] && return 0
    [ -z "$slug" ] && return 0
    [ -d "$state_dir" ] || return 0
    local sidecar="${state_dir}/plan-w-team-skill-version-${slug}.json"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Use jq if available for proper escaping; else fall back to printf with
    # minimal escaping (these fields are all controlled values).
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg slug "$slug" \
            --arg skill_version "$SKILL_VERSION" \
            --arg skill_commit_sha "$SKILL_COMMIT_SHA" \
            --arg recorded_at "$now" \
            --arg spawn_path "$spawn_path" \
            '{slug:$slug, skill_version:$skill_version, skill_commit_sha:$skill_commit_sha, recorded_at:$recorded_at, spawn_path:$spawn_path}' \
            > "$sidecar" 2>/dev/null || true
    else
        printf '{"slug":"%s","skill_version":"%s","skill_commit_sha":"%s","recorded_at":"%s","spawn_path":"%s"}\n' \
            "$slug" "$SKILL_VERSION" "$SKILL_COMMIT_SHA" "$now" "$spawn_path" \
            > "$sidecar" 2>/dev/null || true
    fi
    return 0
}

# Initialise the canonical run-manifest at spawn so the supervisor/human view has
# one main-checkout-relative place to read the live stage from turn zero. The
# worker fills in worktree_path/strategy/stage/tasks as the lifecycle proceeds.
# Fail-open: never block the spawn over manifest bookkeeping.
# Args: $1 = origin state dir (target), $2 = slug, $3 = run sid (worker session id)
__pwt_init_manifest() {
    local state_dir="${1:-}" slug="${2:-}" run_sid="${3:-}"
    [ -z "$state_dir" ] && return 0
    [ -z "$slug" ] && return 0
    local helper="$(dirname "$0")/pwt-manifest.sh"
    [ -x "$helper" ] || return 0
    PWT_MANIFEST_STATE_DIR="$state_dir" "$helper" init \
        --slug "$slug" --run-sid "$run_sid" --stage "0-spawn" --strategy "unresolved" \
        >/dev/null 2>&1 || true
    return 0
}

# Validate type
case "$TYPE" in
    feature|refactor|bugfix|docs) ;;
    *) echo "Unknown --type: $TYPE (allowed: feature, refactor, bugfix, docs)" >&2; exit 1 ;;
esac

# Type-specific done criteria
case "$TYPE" in
    feature)
        DONE_CRITERIA='  - stage="retro-complete" appears in transcript with workflow_lock="done"
  - every AC<N>: PASS line from the generated spec'\''s Acceptance Criteria contract appears in transcript
  - ship-readiness-gate verdict is PASS in a status block (Step 6)
  - test suite passes (Step 6 reports 100% of tests passing)'
        ;;
    refactor)
        DONE_CRITERIA='  - stage="retro-complete" with workflow_lock="done"
  - all existing tests still pass (no regression)
  - no behavior change (refactor only — code shape changes, contracts identical)
  - ship-readiness-gate PASS in Step 6 status block'
        ;;
    bugfix)
        DONE_CRITERIA='  - stage="retro-complete" with workflow_lock="done"
  - new regression test added that fails before the fix and passes after
  - existing tests still pass
  - ship-readiness-gate PASS in Step 6 status block'
        ;;
    docs)
        DONE_CRITERIA='  - stage="retro-complete" with workflow_lock="done"
  - docs cross-reference check passes in Step 7
  - no code changes (docs-only — verify diff scope)
  - CHANGELOG entry added if user-visible'
        ;;
esac

# Optional interactive DoD additions
EXTRA_DONE=""
if [ "$INTERACTIVE" = "1" ]; then
    echo "Enter additional done criteria, one per line. Empty line to finish:" >&2
    while IFS= read -r line; do
        [ -z "$line" ] && break
        EXTRA_DONE="${EXTRA_DONE}
  - ${line}"
    done
fi

# ─── Build the /goal command ────────────────────────────────────────────────
# This is wrapped in a helper so we can rebuild after directive overflow
# (see "Directive overflow to disk" below) without duplicating the heredoc.
__pwt_build_goal_text() {
    local req="$1"
    read -r -d '' GOAL_TEXT <<EOF_GOAL_TEXT || true
/goal Use /plan-w-team to ${req}.
Ground in repo docs first (GRD).

Pipeline is complete when ALL of:
${DONE_CRITERIA}${EXTRA_DONE}

Halt and surface to user when ANY of:
  - push-ack pause site reached (irreversible push to remote)
  - secret-scan-allow pause site reached (security allowlist edit)
  - scope-unlock-for-drift pause site reached (mid-flight scope change)
  - 3 consecutive supervisor decisions log confidence=low (PWT-T4 escalation)

There is no wall-clock or turn cap by design: keep working until one of the
ALL-of completion conditions OR one of the halt conditions above fires.
On stop, state which terminal condition was reached and quote the transcript
line that demonstrates it.
EOF_GOAL_TEXT
}

__pwt_build_goal_text "$REQUEST"

# ─── DIRECTIVE OVERFLOW TO DISK ─────────────────────────────────────────────
# When a user's REQUEST (or the wrapped goal text) is too large for /goal's
# 4000-char cap, persist the full REQUEST to a hash-named file under
# .claude/state/ and replace REQUEST in the /goal text with a short pointer.
# The worker's first action is then to Read the pointed file — no shorten/retry
# friction, larger specs fit, durable audit trail.
#
# Threshold: GOAL_TEXT length > PLAN_W_TEAM_OVERFLOW_THRESHOLD (default 3000)
# Filename:  .claude/state/plan-w-team-directive-<sha256-first-12-hex>.txt
# Lifecycle: persisted as an audit-trail artifact (state-artifacts.md entry)
# Idempotency: same REQUEST content → same hash → existing file reused.
#
# Skipped when REQUEST is the empty string (cannot reach this point — earlier
# guard exits) or when threshold env explicitly set to a very large number.
GOAL_BYTES=${#GOAL_TEXT}
OVERFLOW_THRESHOLD="${PLAN_W_TEAM_OVERFLOW_THRESHOLD:-3000}"
if [ "$GOAL_BYTES" -gt "$OVERFLOW_THRESHOLD" ]; then
    # Resolve state-dir root via the worktree-robust main-repo resolver
    # (__pwt_main_repo_root: override → git-common-dir main checkout →
    # toplevel → PWD). Using the MAIN checkout matters: `--show-toplevel`
    # from inside a stale sibling worktree would park the directive file in
    # a dir the worktree GC can reap mid-run, dangling the worker's
    # "Read full directive at <path>" pointer (same failure family as the
    # goal-state seed root-cause — see __pwt_main_repo_root's rationale).
    __pwt_overflow_root=$(__pwt_main_repo_root)
    __pwt_overflow_dir="$__pwt_overflow_root/.claude/state"
    mkdir -p "$__pwt_overflow_dir" 2>/dev/null || true

    # Hash the original REQUEST (pre-pointer) so idempotency depends only on
    # the user's content, not on a pointer that itself contains a path.
    if command -v shasum >/dev/null 2>&1; then
        __pwt_hash=$(printf '%s' "$REQUEST" | shasum -a 256 | awk '{print substr($1,1,12)}')
    elif command -v sha256sum >/dev/null 2>&1; then
        __pwt_hash=$(printf '%s' "$REQUEST" | sha256sum | awk '{print substr($1,1,12)}')
    else
        echo "FATAL: neither shasum nor sha256sum available; cannot compute overflow hash" >&2
        exit 5
    fi

    __pwt_overflow_file="$__pwt_overflow_dir/plan-w-team-directive-${__pwt_hash}.txt"

    # Idempotent write: only write if the file doesn't already exist with the
    # same content. We don't recompute and compare — the hash already uniquely
    # identifies content, so "exists" implies "same content".
    if [ ! -f "$__pwt_overflow_file" ]; then
        printf '%s' "$REQUEST" > "$__pwt_overflow_file"
    fi

    # Replace REQUEST with the pointer text and rebuild GOAL_TEXT.
    REQUEST="Read full directive at ${__pwt_overflow_file} and execute it as a /plan-w-team run with standard halt conditions (push-ack, secret-scan-allow, scope-unlock-for-drift, 3-consecutive low-confidence). Done conditions per the directive file."
    __pwt_build_goal_text "$REQUEST"
    GOAL_BYTES=${#GOAL_TEXT}

    echo "INFO: directive overflow — wrote $(wc -c < "$__pwt_overflow_file" | tr -d ' ') bytes to $__pwt_overflow_file (hash=$__pwt_hash; goal now $GOAL_BYTES chars)" >&2
fi

# Enforce Anthropic's /goal 4000-char cap BEFORE spawning. Without this guard
# the worker bg session spawns, /goal silently rejects the directive, and the
# worker sits idle at the prompt forever — caught 2026-05-21 with a 4442-char
# directive (worker SID 5fb781c2 wedged for an hour before supervisor diagnosed).
# The supervisor heredoc has its own size guard (pwt-goal-heredoc-size.test.sh);
# this guards the user-facing goal directive.
GOAL_MAX="${PLAN_W_TEAM_GOAL_MAX:-4000}"
if [ "$GOAL_BYTES" -gt "$GOAL_MAX" ]; then
    cat >&2 <<EOM
✗ /goal directive is ${GOAL_BYTES} chars — exceeds Anthropic's ${GOAL_MAX}-char runtime cap.

If \`claude --bg "/goal …"\` were spawned with this text, /goal would
silently reject it ("Goal condition is limited to ${GOAL_MAX} characters")
and the worker would idle indefinitely.

Shorten the REQUEST or DONE_CRITERIA arguments. The skeleton overhead
(halt sites + GRD grounding clause + closing note) is ~650 chars, leaving
~$((GOAL_MAX - 650)) chars for the user-provided content.

To override (e.g. when Anthropic raises the cap), set:
  PLAN_W_TEAM_GOAL_MAX=<new-cap> ${0##*/} ...
EOM
    exit 2
fi

# ─── DETERMINISTIC WORKER-CASCADE GUARD (PWT-DS2) ───────────────────────────
# If we're running INSIDE a bg worker session (PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1
# was set by the parent pwt-goal.sh spawn), refuse to spawn another worker.
# Workers reading their own goal text — which contains "Use /plan-w-team to..." —
# would otherwise have their LLM trigger the manifest's routing logic and call
# pwt-goal.sh AGAIN, creating a recursive cascade.
#
# Covers BOTH --launch and --worker-only paths (the LLM may pick either).
#
# Override: PLAN_W_TEAM_FORCE_SPAWN=1 bypasses (rare: e.g. an orchestrator
# inside a worker that legitimately needs a sub-worker for a sub-goal).
#
# Caught 2026-05-22: worker 85420913's goal text contained "Use /plan-w-team to..."
# (verbatim from pwt-goal.sh's GOAL_TEXT template). Its LLM fired the manifest's
# Step 3b spawn path. Worker c00b9887 then called pwt-goal.sh --launch (not
# --worker-only), bypassing PWT-DS1.
# ─── C6: in-worker FORCE_SPAWN must be OUT-OF-BAND ──────────────────────────
# A worker's own LLM can self-set PLAN_W_TEAM_FORCE_SPAWN=1 — indeed the cascade
# guard's stderr below USED to tell the reader to "set FORCE_SPAWN and retry",
# which a worker dutifully follows, defeating the guard (audit C6). So inside a
# worker (PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1) the bypass requires the separate
# PLAN_W_TEAM_OPERATOR_FORCE_SPAWN=1 — an out-of-band signal a human operator
# sets, never named in worker-facing goal text. Interactive/main keeps the
# familiar PLAN_W_TEAM_FORCE_SPAWN escape hatch (the operator is at the keyboard).
_PWT_BYPASS=0
if [ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-0}" = "1" ]; then
    [ "${PLAN_W_TEAM_OPERATOR_FORCE_SPAWN:-0}" = "1" ] && _PWT_BYPASS=1
else
    { [ "${PLAN_W_TEAM_FORCE_SPAWN:-0}" = "1" ] || [ "${PLAN_W_TEAM_OPERATOR_FORCE_SPAWN:-0}" = "1" ]; } && _PWT_BYPASS=1
fi

if [ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-0}" = "1" ] \
        && [ "$_PWT_BYPASS" != "1" ] \
        && { [ "$WORKER_ONLY" = "1" ] || [ "$LAUNCH" = "1" ]; }; then
    cat >&2 <<CASCADE_GUARD
✗ Worker-cascade refused: cannot spawn /plan-w-team from inside a worker session.

  Signal: PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 is set, which means this process
  inherited environment from a parent pwt-goal.sh bg worker spawn.

  A worker's goal text contains "Use /plan-w-team to..." (verbatim). When the
  worker's LLM reads its own goal, the trigger phrase fires the skill manifest's
  routing logic, prompting another pwt-goal.sh call. That creates a recursive
  cascade.

  If a sub-worker is genuinely needed from inside an orchestrator running inside
  a worker, a HUMAN OPERATOR (outside this worker) sets
  PLAN_W_TEAM_OPERATOR_FORCE_SPAWN=1 — an out-of-band signal this worker cannot
  self-authorize. Do NOT set it from inside the worker (audit C6).

  Caught 2026-05-22 via worker 85420913's own LLM spawning a duplicate, and
  worker c00b9887's --launch call producing 8cf9b873 + 752e86c4.
CASCADE_GUARD
    exit 4
fi

# ─── DETERMINISTIC DOUBLE-SPAWN GUARD (PWT-DS1) ─────────────────────────────
# If the UserPromptSubmit route hook already spawned a worker for this turn,
# refuse to spawn another. The hook writes a flag file at:
#   .claude/state/plan-w-team-hook-spawn-<parent_sid_short>.flag
# Flag is fresh if its mtime is within PWT_DOUBLE_SPAWN_WINDOW_MIN minutes
# (default 3 — generous enough to span a full assistant turn between the
# route-hook spawn and a same-turn manual invocation).
#
# Covers BOTH --worker-only AND --launch. The --launch gap was the root cause of
# the 2026-05-27 double-spawn: the route hook spawns via --supervisor-goal
# (worker-only semantics) and writes the flag, then the assistant ALSO ran
# `pwt-goal.sh --launch` in the same turn — the old `WORKER_ONLY=1`-only guard
# let that detached --launch through, producing a duplicate run (route-created
# b3578658 vs manual 48adde90) that clobbered the same skill files. Extending to
# --launch closes it. (Safe: the route hook calls pwt-goal BEFORE writing the
# flag, so the hook's own spawn never trips this; only later calls do.)
#
# Override (escape hatch): PLAN_W_TEAM_FORCE_SPAWN=1 bypasses the guard from an
# interactive/main session; from INSIDE a worker the out-of-band
# PLAN_W_TEAM_OPERATOR_FORCE_SPAWN=1 is required (see the C6 $_PWT_BYPASS block).
# Use only if you've manually confirmed the hook's prior spawn is dead/stopped.
if { [ "$WORKER_ONLY" = "1" ] || [ "$LAUNCH" = "1" ]; } && [ "$_PWT_BYPASS" != "1" ]; then
    GUARD_PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-${PWT_PROJECT_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
    GUARD_DIR="$GUARD_PROJECT_ROOT/.claude/state"
    if [ -d "$GUARD_DIR" ]; then
        # Find any hook-spawn flag fresh within the double-spawn window.
        DS_WINDOW_MIN="${PWT_DOUBLE_SPAWN_WINDOW_MIN:-3}"
        FRESH_FLAG=$(find "$GUARD_DIR" -maxdepth 1 -name 'plan-w-team-hook-spawn-*.flag' -mmin "-${DS_WINDOW_MIN}" 2>/dev/null | head -1)
        if [ -n "$FRESH_FLAG" ]; then
            EXISTING_WORKER=$(grep '^worker_sid=' "$FRESH_FLAG" 2>/dev/null | head -1 | cut -d= -f2)
            EXISTING_AT=$(grep '^spawned_iso=' "$FRESH_FLAG" 2>/dev/null | head -1 | cut -d= -f2)
            cat >&2 <<GUARD
✗ Double-spawn refused: the route hook already spawned worker $EXISTING_WORKER
  at $EXISTING_AT for this user turn.

  Flag: $FRESH_FLAG (treated as fresh within ${DS_WINDOW_MIN} min via mtime; override PWT_DOUBLE_SPAWN_WINDOW_MIN — the flag is not auto-deleted)

  Why this guard exists: the manifest's Step 3a check ("if you see the
  systemMessage marker, skip Step 3b") depends on the LLM noticing the
  marker in its context. When the LLM misses it, it calls pwt-goal.sh
  (--worker-only OR --launch) and produces a duplicate worker — verified
  2026-05-22 (--worker-only cascade) and 2026-05-27 (--launch double-spawn:
  route-created run + manual --launch clobbering the same files). This
  guard prevents both at the process level.

  If you've confirmed the prior worker is dead or you want to spawn
  another deliberately, set PLAN_W_TEAM_FORCE_SPAWN=1 and retry.
GUARD
            # Still emit the existing worker SID so the caller can act as
            # supervisor on the prior worker instead.
            echo "worker_sid=$EXISTING_WORKER"
            exit 3
        fi
    fi
fi

# ─── RAM CAPACITY GATE (PWT-RAM1) ────────────────────────────────────────────
# Refuses to spawn another bg session when host RAM is below the safety
# threshold. Catches OOM scenarios before they happen: each Claude Code bg
# session costs ~1.5–2 GB resident, and parallel /plan-w-team runs can
# OOM-kill each other on workstations.
#
# Reads .claude/scripts/ram-budget.sh; refuses on AT_CAPACITY or REDUCE_PARALLEL.
# Soft errors (missing script, unsupported platform, recommended_action=null)
# fall through to spawn — the gate is advisory, not load-bearing for correctness.
#
# Override: PLAN_W_TEAM_DISABLE_RAM_GATE=1 bypasses entirely.
# Tune: RAM_BUDGET_SESSION_COST_GB and RAM_BUDGET_SAFETY_FACTOR are forwarded
#       to ram-budget.sh via inherited environment.
#
# See shared/ram-budget.md for the capacity model and tuning guidance.
if [ "${PLAN_W_TEAM_DISABLE_RAM_GATE:-0}" != "1" ] \
        && { [ "$LAUNCH" = "1" ] || [ "$WORKER_ONLY" = "1" ]; }; then
    RAM_BUDGET_SCRIPT="$(dirname "$0")/ram-budget.sh"
    if [ -x "$RAM_BUDGET_SCRIPT" ]; then
        RAM_JSON=$("$RAM_BUDGET_SCRIPT" 2>/dev/null || echo "")
        if [ -n "$RAM_JSON" ]; then
            RAM_ACTION=$(printf '%s' "$RAM_JSON" \
                | grep -oE '"recommended_action": *"[^"]*"' \
                | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
            # Refuse only on explicit non-OK actions. SPAWN_OK or empty/null → fall through.
            if [ -n "$RAM_ACTION" ] && [ "$RAM_ACTION" != "SPAWN_OK" ]; then
                FREE_GB=$(printf '%s' "$RAM_JSON"   | grep -oE '"free_gb": *[^,}]*'           | head -1 | sed -E 's/.*: *//')
                BG_COUNT=$(printf '%s' "$RAM_JSON"  | grep -oE '"bg_session_count": *[0-9]+'  | head -1 | sed -E 's/.*: *//')
                EST_COST=$(printf '%s' "$RAM_JSON"  | grep -oE '"estimated_session_cost_gb": *[0-9.]+' | head -1 | sed -E 's/.*: *//')
                CAPACITY=$(printf '%s' "$RAM_JSON"  | grep -oE '"capacity_for_new_sessions": *[^,}]*' | head -1 | sed -E 's/.*: *//')
                cat >&2 <<RAM_GATE
✗ RAM gate refused: $RAM_ACTION

  free_gb=$FREE_GB
  bg_session_count=$BG_COUNT (each ~${EST_COST}GB)
  capacity_for_new_sessions=$CAPACITY

  Spawning another bg session would risk exceeding host RAM and OOM-kill
  the running sessions. Stop or wait for an existing session to terminate.

  Override (use only if you have manually confirmed available RAM):
    PLAN_W_TEAM_DISABLE_RAM_GATE=1

  Tune the model (see shared/ram-budget.md):
    RAM_BUDGET_SESSION_COST_GB=<gb>     # default 1.8
    RAM_BUDGET_SAFETY_FACTOR=<n>        # default 1.5
RAM_GATE
                exit 5
            fi
        fi
    fi
fi

# ─── DISK CAPACITY GATE (PWT-DISK1) ─────────────────────────────────────────
# Mirror of the RAM gate for the disk dimension. The 2026-05-29 cleanscale
# incident (67 worktrees / 64 GB → 0 bytes free → ENOSPC) had NO disk gate.
# Reads disk-budget.sh; refuses on BLOCK (free_gb below floor / inode exhaustion)
# or AT_CAPACITY, warns on REDUCE. Heavy-build directives (pod install, gradlew,
# xcodebuild, pnpm install, …) raise the free-GB floor automatically. Gates on
# absolute free GB, not %, because APFS % counts the whole shared container.
# Fail-open (null / missing script) → proceed. Override: PLAN_W_TEAM_DISABLE_DISK_GATE=1.
if [ "${PLAN_W_TEAM_DISABLE_DISK_GATE:-0}" != "1" ] \
        && { [ "$LAUNCH" = "1" ] || [ "$WORKER_ONLY" = "1" ]; }; then
    DISK_BUDGET_SCRIPT="$(dirname "$0")/disk-budget.sh"
    if [ -x "$DISK_BUDGET_SCRIPT" ]; then
        DISK_JSON=$(PWT_DISK_DIRECTIVE="${ORIGINAL_REQUEST:-${REQUEST:-}}" "$DISK_BUDGET_SCRIPT" 2>/dev/null || echo "")
        if [ -n "$DISK_JSON" ]; then
            DISK_ACTION=$(printf '%s' "$DISK_JSON" | grep -oE '"recommended_action": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
            DISK_FREE=$(printf '%s' "$DISK_JSON"   | grep -oE '"free_gb": *[^,}]*'                  | head -1 | sed -E 's/.*: *//')
            DISK_MINF=$(printf '%s' "$DISK_JSON"   | grep -oE '"min_free_gb": *[^,}]*'              | head -1 | sed -E 's/.*: *//')
            DISK_CAP=$(printf '%s' "$DISK_JSON"    | grep -oE '"capacity_for_new_worktrees": *[^,}]*' | head -1 | sed -E 's/.*: *//')
            if [ "$DISK_ACTION" = "BLOCK" ] || [ "$DISK_ACTION" = "AT_CAPACITY" ]; then
                cat >&2 <<DISK_GATE
✗ Disk gate refused: $DISK_ACTION

  free_gb=$DISK_FREE  min_free_gb=$DISK_MINF  capacity_for_new_worktrees=$DISK_CAP

  Spawning another worktree risks ENOSPC (the 2026-05-29 cleanscale failure mode).
  Reclaim first — merge open PRs, or:
    .claude/scripts/plan-w-team-worktree-gc.sh --execute

  Override (only with manually confirmed free disk): PLAN_W_TEAM_DISABLE_DISK_GATE=1
  Tune (shared/disk-budget.md): PWT_DISK_MIN_FREE_GB (15) / PWT_DISK_MIN_FREE_GB_BUILD (25)
DISK_GATE
                exit 5
            elif [ "$DISK_ACTION" = "REDUCE" ]; then
                echo "[disk-budget] REDUCE: free_gb=$DISK_FREE near floor $DISK_MINF — proceeding, but reclaim soon (worktree-gc)." >&2
            fi
        fi
    fi
fi

# ─── WORKTREE COUNT CAP (PWT-DISK2) — disk-aware, auto-GC-retry (AC3) ────────
# A raw count cap (PWT_MAX_WORKTREES) decoupled from real `df` dead-ends every
# spawn once N worktrees accrue, even with tens of GB free (cleanscale tripped at
# 14/10 with 77 GiB free). The count is now a SOFT NUDGE, not a wall:
#   (a) when the cap trips, auto-run the IMPROVED GC (--execute; reaps SAFE-PRUNE-
#       PUSHED + broadened-dirty per Fix #1/#2) ONCE and re-count;
#   (b) if still at/above the cap, consult disk-budget.sh: hard-refuse (exit 5)
#       ONLY on real disk pressure (BLOCK / AT_CAPACITY); if df is healthy
#       (SPAWN_OK / REDUCE / fail-open null) ALLOW the spawn with a warning.
# Override: PLAN_W_TEAM_DISABLE_WORKTREE_CAP=1 (or raise PWT_MAX_WORKTREES).
# Knobs: PWT_CAP_GC_RETRY_DISABLE=1 skips the auto-GC step (tests / debugging).
if [ "${PLAN_W_TEAM_DISABLE_WORKTREE_CAP:-0}" != "1" ] \
        && { [ "$LAUNCH" = "1" ] || [ "$WORKER_ONLY" = "1" ]; }; then
    WT_CAP="${PWT_MAX_WORKTREES:-10}"
    # Resolve the worktree root self-contained — do NOT depend on GUARD_PROJECT_ROOT,
    # which is only set inside the double-spawn guard block (skipped when that guard
    # is bypassed, e.g. PLAN_W_TEAM_FORCE_SPAWN=1), leaving the cap silently counting
    # $(pwd)'s worktrees instead of the target repo's. Canonical precedence matches
    # the PROJECT_ROOT resolver below: test override → session project dir → git top.
    WT_ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
    WT_DIR="$WT_ROOT/.claude/worktrees"
    if [ -d "$WT_DIR" ]; then
        WT_COUNT=$(find "$WT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        if [ "${WT_COUNT:-0}" -ge "$WT_CAP" ]; then
            # (a) auto-GC-retry once — reclaim merged/pushed/idle worktrees in place.
            if [ "${PWT_CAP_GC_RETRY_DISABLE:-0}" != "1" ]; then
                CAP_GC_SCRIPT="$(dirname "$0")/plan-w-team-worktree-gc.sh"
                if [ -x "$CAP_GC_SCRIPT" ]; then
                    echo "[cap] worktree count $WT_COUNT/$WT_CAP — auto-GC-retry (plan-w-team-worktree-gc.sh --execute) before refusing" >&2
                    ( cd "$WT_ROOT" && "$CAP_GC_SCRIPT" --execute >/dev/null 2>&1 ) || true
                    WT_COUNT=$(find "$WT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
                    echo "[cap] post-GC worktree count: $WT_COUNT/$WT_CAP" >&2
                fi
            fi
            # (b) still over the cap → disk-aware decision (count alone never walls).
            if [ "${WT_COUNT:-0}" -ge "$WT_CAP" ]; then
                CAP_DISK_SCRIPT="$(dirname "$0")/disk-budget.sh"
                CAP_DISK_ACTION=""
                if [ -x "$CAP_DISK_SCRIPT" ]; then
                    CAP_DISK_JSON=$(PWT_DISK_DIRECTIVE="${ORIGINAL_REQUEST:-${REQUEST:-}}" "$CAP_DISK_SCRIPT" 2>/dev/null || echo "")
                    CAP_DISK_ACTION=$(printf '%s' "$CAP_DISK_JSON" | grep -oE '"recommended_action": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
                fi
                if [ "$CAP_DISK_ACTION" = "BLOCK" ] || [ "$CAP_DISK_ACTION" = "AT_CAPACITY" ]; then
                    cat >&2 <<WT_CAP_MSG
✗ Worktree cap reached AND disk under pressure: $WT_COUNT/$WT_CAP, disk=$CAP_DISK_ACTION

  Auto-GC reaped nothing reclaimable and real disk is low — refusing the spawn
  to avoid the ENOSPC failure mode (2026-05-29). Merge open PRs or free disk:
    .claude/scripts/plan-w-team-worktree-gc.sh --execute --orphans-ok

  Override: PLAN_W_TEAM_DISABLE_WORKTREE_CAP=1  (or raise PWT_MAX_WORKTREES)
WT_CAP_MSG
                    exit 5
                fi
                # Disk healthy (SPAWN_OK / REDUCE / null) → the count cap is advisory.
                echo "[cap] worktree count $WT_COUNT/$WT_CAP but disk healthy (${CAP_DISK_ACTION:-unknown}) — allowing spawn (soft nudge: reclaim soon)." >&2
            else
                echo "[cap] auto-GC reclaimed below cap ($WT_COUNT/$WT_CAP) — proceeding." >&2
            fi
        fi
    fi
fi

# ─── SPAWN DRY-RUN (test/diagnostic capacity check) ─────────────────────────
# When PWT_SPAWN_DRY_RUN=1, all capacity gates (RAM / disk / worktree-cap /
# fair-share) above have run; short-circuit BEFORE the real `claude --bg` spawn
# and report that the gates passed. Lets tests assert the allow-path without
# launching a session. Only meaningful for the spawn modes.
if [ "${PWT_SPAWN_DRY_RUN:-0}" = "1" ] \
        && { [ "$LAUNCH" = "1" ] || [ "$WORKER_ONLY" = "1" ]; }; then
    echo "SPAWN_DRY_RUN_OK"
    exit 0
fi

# ─── FAIR-SHARE GATE (PWT-RAM2) ─────────────────────────────────────────────
# Refuses to spawn when this repo is at/above its fair share AND another repo
# has demand. Runs AFTER the RAM gate (which checks aggregate capacity), so we
# only get here if the machine has room. The fair-share gate just ensures
# room is divided fairly across repos with demand.
#
# Bypass: PWT_RUN_PRIORITY=critical
# Default: normal (fair-share applies)
# Yield-first: background (yields under any contention)
#
# Override: PLAN_W_TEAM_DISABLE_FAIR_SHARE=1 bypasses entirely.
#
# See shared/supervisor-protocol.md §FAIR SHARE CHECK.
if [ "${PLAN_W_TEAM_DISABLE_FAIR_SHARE:-0}" != "1" ] \
        && { [ "$LAUNCH" = "1" ] || [ "$WORKER_ONLY" = "1" ]; }; then
    FAIR_SHARE_SCRIPT="$(dirname "$0")/pwt-fair-share.sh"
    if [ -x "$FAIR_SHARE_SCRIPT" ]; then
        FS_JSON=$("$FAIR_SHARE_SCRIPT" 2>/dev/null || echo "")
        if [ -n "$FS_JSON" ]; then
            FS_RECO=$(printf '%s' "$FS_JSON" \
                | grep -oE '"recommendation": *"[^"]*"' \
                | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
            if [ -n "$FS_RECO" ] \
                    && [ "$FS_RECO" != "SPAWN_OK" ] \
                    && [ "$FS_RECO" != "NO_CAPACITY" ]; then
                # NO_CAPACITY would also have been caught by the RAM gate; if we
                # got past RAM and the fair-share script reports NO_CAPACITY,
                # treat it as a fail-open advisory (don't double-refuse).
                MY_REPO_J=$(printf '%s' "$FS_JSON" | grep -oE '"my_repo": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
                MY_CURRENT_J=$(printf '%s' "$FS_JSON" | grep -oE '"my_repo_current": *[0-9]+' | head -1 | sed -E 's/.*: *//')
                MY_ALLOWED_J=$(printf '%s' "$FS_JSON" | grep -oE '"my_repo_allowed_max": *[^,}]*' | head -1 | sed -E 's/.*: *//' | tr -d ' ')
                FAIR_J=$(printf '%s' "$FS_JSON" | grep -oE '"fair_share_per_repo": *[^,}]*' | head -1 | sed -E 's/.*: *//' | tr -d ' ')
                NACTIVE_J=$(printf '%s' "$FS_JSON" | grep -oE '"n_active_repos": *[0-9]+' | head -1 | sed -E 's/.*: *//')
                REPOS_LINE=$(printf '%s' "$FS_JSON" | grep -oE '"repos_with_active_workers": *\{[^}]*\}' | head -1 | sed -E 's/^"repos_with_active_workers": *//')
                cat >&2 <<FAIR_SHARE_GATE
✗ Fair-share gate refused: $FS_RECO

  my_repo=$MY_REPO_J
  my_repo_current=$MY_CURRENT_J / fair_share=$FAIR_J (n_active_repos=$NACTIVE_J)
  active workers: $REPOS_LINE

  Spawning would push this repo above its fair share of machine capacity.
  Another repo on this machine is at or below its share — yielding gives
  it room to spawn.

  Bypass (use only if this repo's run is genuinely time-critical):
    PWT_RUN_PRIORITY=critical $0 $REQUEST

  Disable fair-share entirely (not recommended):
    PLAN_W_TEAM_DISABLE_FAIR_SHARE=1
FAIR_SHARE_GATE
                exit 6
            fi
        fi
    fi
fi

if [ "$LAUNCH" = "1" ]; then
    # Auto-launch: spawn TWO new background claude sessions.
    #
    #   1. WORKER     — runs /plan-w-team for the /goal (the actual work).
    #   2. SUPERVISOR — observer process. Watches the worker, writes a
    #                   completion summary to .claude/state/, surfaces
    #                   hard-gate escalations via macOS notification.
    #                   Does NOT modify code.
    #
    # The two-process split makes the supervisor role VISIBLE in
    # `claude agents` so the statusline can categorize it as
    # "🛠 supervisor" and the user sees orchestration happening
    # rather than a single opaque bg session. Worker's parent_sid is
    # chained to supervisor's sid so the statusline transitively pulls
    # both into the "mine" set.
    # PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1: belt-and-braces recursion kill switch.
    # Every bg session this script spawns has the route-prompt hook disabled
    # so it cannot re-trigger /plan-w-team routing on its own first prompt or
    # any subsequent prompt. The slash-guard at the head of route-prompt.sh
    # already catches `/goal …` bootstraps, but the supervisor bootstrap starts
    # with `#` (markdown heading) and embeds the verbatim user request — which
    # without this env var would trigger natural-language detection on the
    # quoted "use /plan-w-team to …" inside the supervisor's own bootstrap.
    # Observed in production 2026-05-21 (sids 0b5856d7 → 4bbb2cb8 cascade).
    LAUNCH_ENV="PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1"
    if [ "$AUTO_PUSH" = "1" ]; then
        LAUNCH_ENV="$LAUNCH_ENV PLAN_W_TEAM_AUTO_APPROVE_PUSH=1"
    fi
    # PWT-WF1 workflow guard: bg workers/supervisor run headless, where the
    # Dynamic-Workflows tool (/workflows) can auto-run — and the literal token
    # "workflow" appears dozens of times in /plan-w-team prose (workflow lock,
    # "autonomous workflow", …), so an incidental token could spawn a nested
    # fan-out that bypasses gated dispatch + the RAM-budget gate. Disable it in
    # every bg session this script spawns. Env-var name verified present in the
    # CLI 2.1.156 binary (string table: CLAUDE_CODE_DISABLE_WORKFLOWS, alongside
    # the full CLAUDE_CODE_DISABLE_* catalog). Headless/bg only — interactive
    # sessions are untouched and may still author workflows.
    LAUNCH_ENV="$LAUNCH_ENV CLAUDE_CODE_DISABLE_WORKFLOWS=1"

    # PWT-P3 no-caps guarantee: Claude Code defaults the consecutive-Stop-hook
    # block cap to 8. A full /plan-w-team run blocks the Stop hook far more than
    # 8 times (the goal-evaluator blocks every turn until terminal), so without
    # a raised cap the bg worker this launcher spawns is silently force-stopped
    # mid-pipeline after ~8 evaluator blocks — defeating BOTH P3 ("no turn cap")
    # and P12 ("one bg worker for a multi-hour run") for the canonical autonomous
    # path. The interactive mitigation (~/.zshrc) never reaches a --bg/headless
    # session (it does not source ~/.zshrc), so propagate the cap into the worker
    # env here. Also set repo-wide in .claude/settings.json env (covers
    # interactive + synced consumers); belt-and-braces. See
    # docs/operations/pwt-principles-enforcement-audit-2026-06-02.md (P3/C1).
    LAUNCH_ENV="$LAUNCH_ENV CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=${PWT_STOP_HOOK_BLOCK_CAP:-200}"

    # Spec-fanout override forwarding (1.50.0 AUTO mode): §1b-pre defaults to
    # AUTO in-stage (fires on non-trivial specs) with NO env needed. Forward the
    # operator's explicit override ONLY when set, so `=0` (hard off) and `=1`
    # (force on) reach bg workers too — one knob, every path. Unset → nothing
    # forwarded → worker resolves AUTO from the stage file.
    if [ -n "${PLAN_W_TEAM_SPEC_FANOUT:-}" ]; then
        LAUNCH_ENV="$LAUNCH_ENV PLAN_W_TEAM_SPEC_FANOUT=${PLAN_W_TEAM_SPEC_FANOUT}"
    fi

    # PWT-SUP-YIELD safety: force PLAN_W_TEAM_SUPERVISOR_SESSION=0 in the worker so
    # it can NEVER inherit a supervisor=1 marker from a spawning supervisor session.
    # The goal-evaluator lets a supervisor session YIELD instead of block; the
    # WORKER must always block-to-terminal, so it must never look like a supervisor.
    # `env A=0` overrides any inherited A=1. See plan-w-team-goal-evaluator.sh
    # (PWT-SUP-YIELD) + shared/supervisor-protocol.md §Wait mechanism.
    LAUNCH_ENV="$LAUNCH_ENV PLAN_W_TEAM_SUPERVISOR_SESSION=0"

    # Model pinning for bg spawns (Model Tiering v2, skill 1.51.0):
    #   --model pins the PRIMARY explicitly so bg fleets NEVER silently inherit
    #   an expensive interactive session default (2026-07 incident: a Fable 5
    #   user default silently upgraded every bg worker/supervisor — ~2x Opus
    #   burn per token, two-account weekly-limit lockout). Brain tier = Opus 4.8.
    #   --fallback-model: BEST-EFFORT only — `claude --help` documents the flag
    #   for print/headless runs and the 2026-06-28 regression probe recorded it
    #   as likely inert under --bg. Do NOT rely on it for capacity exhaustion;
    #   the load-bearing protection is the explicit --model primary pin above.
    #   Default fallback claude-sonnet-5 (near-Opus coding, same tokenizer,
    #   separate Max Sonnet bucket) is kept as belt-and-suspenders; the durable
    #   lever, if degradation is ever needed, is settings.json fallbackModel.
    #   Override via PWT_PRIMARY_MODEL / PWT_FALLBACK_MODEL. Threaded into both
    #   bg spawn sites below (worker + supervisor).
    PWT_PRIMARY_MODEL="${PWT_PRIMARY_MODEL:-claude-opus-4-8}"
    PWT_FALLBACK_MODEL="${PWT_FALLBACK_MODEL:-claude-sonnet-5}"

    # Resolve PROJECT_ROOT to the active worktree, not the main checkout.
    # When CLAUDE_PROJECT_DIR is inherited from a parent process, it can point
    # to the main repo while the user's session runs in a worktree under
    # .claude/worktrees/. The statusline reads from $PWD's state dir, so writes
    # must land in the same place. Preference order:
    #   1. $PWT_PROJECT_ROOT_OVERRIDE (test-only override; takes precedence)
    #   2. git rev-parse --show-toplevel (handles worktree correctly)
    #   3. script-relative ../.. (when not in a git checkout)
    #   4. $CLAUDE_PROJECT_DIR (last-resort fallback)
    if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
        PROJECT_ROOT="$PWT_PROJECT_ROOT_OVERRIDE"
    else
        PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
        if [ -z "$PROJECT_ROOT" ]; then
            PROJECT_ROOT=$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)
        fi
        [ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-}"
    fi

    # ─── Fix B: assert the PRIMARY checkout sits on the default branch ────────
    # PWT mutates branches only inside .claude/worktrees/ — the primary (main,
    # non-worktree) checkout should always sit on the default branch. A human or
    # agent that left it parked on a stale feature label (0 unique commits) makes
    # post-merge re-sync impossible and accumulates drift. This launch-time guard
    # auto-restores ONLY the provably-safe case (clean tree + 0 unique commits);
    # anything with real local work is warned-about but never touched. It targets
    # the MAIN checkout (resolved via --git-common-dir), never the current
    # worktree, so running --launch from inside a worktree leaves that worktree's
    # feature branch alone.
    __assert_primary_on_default() {
        local base cdir root def head ahead
        base="${PROJECT_ROOT:-$PWD}"
        cdir="$(git -C "$base" rev-parse --git-common-dir 2>/dev/null || echo "")"
        if [ -n "$cdir" ]; then
            case "$cdir" in
                /*) root="$(dirname "$cdir")" ;;
                *)  root="$(dirname "$(cd "$base" 2>/dev/null && realpath "$cdir" 2>/dev/null || echo "$base/$cdir")")" ;;
            esac
        fi
        [ -n "${root:-}" ] && [ -e "$root/.git" ] || \
            root="$(git -C "$base" rev-parse --show-toplevel 2>/dev/null || echo "$base")"

        def="$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
        [ -n "$def" ] || def=main
        head="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || echo DETACHED)"
        [ "$head" = "$def" ] && return 0

        # Refresh origin/<default> first so the 0-unique-commits test is accurate.
        git -C "$root" fetch --quiet origin "$def" 2>/dev/null || true
        ahead="$(git -C "$root" rev-list --count "origin/$def..HEAD" 2>/dev/null || echo 1)"
        if [ -z "$(git -C "$root" status --porcelain 2>/dev/null)" ] && [ "$ahead" = "0" ]; then
            echo "pwt: primary checkout was on '$head' (0 unique commits) — restoring to '$def'" >&2
            git -C "$root" switch "$def" 2>/dev/null && git -C "$root" merge --ff-only "origin/$def" 2>/dev/null || true
        else
            echo "WARNING pwt: primary checkout is on '$head', not '$def' (has local work or is dirty)." >&2
            echo "        PWT runs in isolated worktrees; the primary should sit on '$def'." >&2
            echo "        Resolve manually before/after this run to avoid drift." >&2
        fi
    }
    __assert_primary_on_default
    # ─── end Fix B ───────────────────────────────────────────────────────────

    # Resolve absolute path to the claude binary once via locate-claude.sh.
    # Without this, bare `claude --bg` fails with "env: claude: No such file
    # or directory" when the harness-inherited $PATH lacks the install dir
    # (e.g. /Users/$USER/.local/bin). Production incident 2026-05-23.
    #
    # Resolution order:
    #   1. $PROJECT_ROOT/.claude/scripts/locate-claude.sh
    #   2. $(dirname "$0")/locate-claude.sh   (script-sibling — useful in worktrees)
    #   3. fallback: bare "claude" (preserves pre-refactor behavior when the
    #      helper isn't yet synced into a consumer repo or test sandbox)
    __locate_claude() {
        local locator
        for locator in \
            "$PROJECT_ROOT/.claude/scripts/locate-claude.sh" \
            "$(dirname "$0")/locate-claude.sh"; do
            if [ -x "$locator" ]; then
                "$locator" && return 0
            fi
        done
        # Graceful fallback: helper missing → use bare 'claude' which the shell
        # will resolve via $PATH. This preserves the pre-2026-05-23 behavior
        # so consumer repos that haven't synced the helper still work.
        echo "claude"
    }
    CLAUDE_BIN=$(__locate_claude)

    USER_SID="${CLAUDE_JOB_DIR:-}"
    USER_SID="${USER_SID##*/}"
    [ -z "$USER_SID" ] && USER_SID="${PWT_PARENT_SID:-}"
    # Record the FULL session id (NO 8-char truncation) as the registry's parent
    # lineage key. child-cleanup's C8 reconciliation matches parent_session_id to
    # the reaping session's id; an 8-char key let two concurrent runs whose
    # session-id prefixes collide reap each other's workers (round-2 audit §3.2).
    # The full UUID is collision-free. USER_SID is used only as a registry field
    # here (no filename), so its length is unconstrained.

    REQUEST_SAFE=$(printf '%s' "$REQUEST" | head -c 200 | sed 's/"/\\"/g')

    echo "Launching /plan-w-team autonomous run (supervisor + worker)..." >&2
    [ -n "$LAUNCH_ENV" ] && echo "  with env: $LAUNCH_ENV" >&2

    # ─── Spawn WORKER first so we know its sid for the supervisor bootstrap ──
    WORKER_OUT_FILE=$(mktemp -t pwt-goal-worker.XXXXXX 2>/dev/null || echo "")
    [ -z "$WORKER_OUT_FILE" ] && {
        echo "FATAL: mktemp failed; cannot launch" >&2
        exit 1
    }

    # ─── PWT-WT1: spawn the worker INSIDE an isolated git worktree ──────────────
    # Principle #6 (worktree isolation) MUST be deterministic for the spawned bg
    # worker — not left to the worker's own LLM calling EnterWorktree mid-session.
    # `claude --bg` WITHOUT --worktree starts in the MAIN checkout (the manifest's
    # "--bg auto-creates a worktree" claim was wrong — `claude --help` shows
    # isolation requires the explicit -w/--worktree flag). Any edit before (or
    # instead of) a mid-session EnterWorktree then lands in main, racing/clobbering
    # a concurrent in-session editor — observed 2026-06-02: a route-hook worker
    # co-edited 04/05/07 in the main checkout against an in-session change. With
    # --worktree the worker branches from HEAD into .claude/worktrees/<name>, so
    # its edits can NEVER touch the main checkout; it merges back at Step 6 ship
    # like any builder. Bash 3.2-safe string flag (word-split like $LAUNCH_ENV;
    # __pwt_safe_slug yields kebab [a-z0-9-], no spaces). Opt-out (rare — a repo
    # where worktrees are unavailable): PWT_DISABLE_WORKER_WORKTREE=1.
    WT_FLAG=""
    if [ "${PWT_DISABLE_WORKER_WORKTREE:-0}" != "1" ]; then
        WT_NAME="pwt-$(__pwt_safe_slug "$ORIGINAL_REQUEST")"
        WT_FLAG="--worktree ${WT_NAME:0:60}"
    fi

    # LAUNCH_ENV always contains PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1; the bare
    # `claude --bg` branch is unreachable but kept as a safety net.
    # Use $CLAUDE_BIN (resolved via locate-claude.sh) to avoid PATH-dependent
    # "env: claude: No such file or directory" failures.
    if [ -n "$LAUNCH_ENV" ]; then
        env $LAUNCH_ENV "$CLAUDE_BIN" --bg $WT_FLAG --model "$PWT_PRIMARY_MODEL" --fallback-model "$PWT_FALLBACK_MODEL" "$GOAL_TEXT" >"$WORKER_OUT_FILE" 2>&1
        LAUNCH_RC=$?
    else
        env PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 "$CLAUDE_BIN" --bg $WT_FLAG --model "$PWT_PRIMARY_MODEL" --fallback-model "$PWT_FALLBACK_MODEL" "$GOAL_TEXT" >"$WORKER_OUT_FILE" 2>&1
        LAUNCH_RC=$?
    fi

    WORKER_SID=""
    if [ -s "$WORKER_OUT_FILE" ]; then
        WORKER_SID=$(sed -E 's/\x1b\[[0-9;]*m//g' "$WORKER_OUT_FILE" 2>/dev/null \
            | grep -oE 'backgrounded · [a-f0-9]{8}' \
            | head -1 | awk '{print $NF}' || echo "")
    fi
    cat "$WORKER_OUT_FILE" >&2
    rm -f "$WORKER_OUT_FILE" 2>/dev/null || true

    if [ -z "$WORKER_SID" ]; then
        echo "WARN: worker session id could not be parsed; skipping supervisor launch" >&2
        exit "$LAUNCH_RC"
    fi

    echo "  worker session:     $WORKER_SID" >&2

    # ─── Compute SLUG once (used by sidecar + registry + supervisor mirror) ───
    # Slug derivation goes through __pwt_safe_slug so multi-line / long
    # ORIGINAL_REQUEST values cannot overflow NAME_MAX or embed newlines into
    # downstream filenames. Idempotent (same REQUEST → same slug); guarantees
    # non-empty output. See docs/specs/supervisor-mirror-lifecycle.md.
    SLUG_GUESS=$(__pwt_safe_slug "$ORIGINAL_REQUEST")

    # ─── Write skill-version sidecar (all spawn paths) ────────────────────────
    # Captures which /plan-w-team release produced this run for bug-tracing.
    # Lives at $PROJECT_ROOT/.claude/state/plan-w-team-skill-version-<SLUG>.json
    # The supervisor-mirror block (below, --supervisor-goal only) also writes
    # this to the resolved ORIGIN repo; that's intentional double-write since
    # PROJECT_ROOT and ORIGIN can diverge when invoked from a worktree.
    if [ -n "$PROJECT_ROOT" ] && [ -d "$PROJECT_ROOT" ]; then
        mkdir -p "$PROJECT_ROOT/.claude/state" 2>/dev/null || true
        if [ "$SUPERVISOR_GOAL" = "1" ]; then
            __PWT_SPAWN_LABEL="supervisor-goal"
        elif [ "$WORKER_ONLY" = "1" ]; then
            __PWT_SPAWN_LABEL="worker-only"
        else
            __PWT_SPAWN_LABEL="launch"
        fi
        __pwt_write_skill_version_sidecar "$PROJECT_ROOT/.claude/state" "$SLUG_GUESS" "$__PWT_SPAWN_LABEL"
        __pwt_init_manifest "$PROJECT_ROOT/.claude/state" "$SLUG_GUESS" "$WORKER_SID"
    fi

    # ─── Register claim in shared cross-repo registry (PWT-RAM2) ──────────────
    # The claim lets pwt-fair-share.sh on other machines/repos see this worker's
    # RAM occupancy. Removed by the retro cleanup hook (or supervisor sweep
    # when idle).
    CLAIM_HELPER="$(dirname "$0")/pwt-ram-claim.sh"
    if [ -x "$CLAIM_HELPER" ]; then
        # Resolve this repo's name from worktree-aware git toplevel.
        CLAIM_REPO=""
        CLAIM_TOP=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [ -n "$CLAIM_TOP" ]; then
            case "$CLAIM_TOP" in
                */.claude/worktrees/*)
                    CLAIM_REPO=$(basename "$(printf '%s' "$CLAIM_TOP" | sed -E 's|/.claude/worktrees/.*$||')")
                    ;;
                *)
                    CLAIM_REPO=$(basename "$CLAIM_TOP")
                    ;;
            esac
        fi
        [ -z "$CLAIM_REPO" ] && CLAIM_REPO=$(basename "$PROJECT_ROOT" 2>/dev/null || basename "$PWD")
        CLAIM_PRI="${PWT_RUN_PRIORITY:-normal}"
        "$CLAIM_HELPER" add "$CLAIM_REPO" "$WORKER_SID" "$CLAIM_PRI" >/dev/null 2>&1 || true
    fi

    # ─── SEED THE GOAL-STATE FILE (PWT-WT2) ──────────────────────────────────
    # Deterministically activate the self-hosted goal-evaluator's anti-skip
    # anchor for EVERY spawn path — --launch AND --worker-only/--supervisor-goal.
    # Without this, the goal-state file's existence depended entirely on the
    # worker's LLM running the manifest's PWT-T5b activation block inside its
    # worktree; when the worker idled/skipped it, the file existed NOWHERE, the
    # evaluator saw "No active goal → exit 0", and the worker could stop short
    # of its DoD with nothing blocking it (1.28.0 build-artifact worker c68e27ac
    # pushed to origin then went idle BEFORE the consumer sync — supervisor
    # finished it by hand; 2026-06-09 audit F2: the --launch path skipped this
    # seed entirely, reopening the same hole for Quick-start runs). Seeding here
    # makes the anchor active from t=0:
    #   - the worker's OWN goal-evaluator finds it via FALLBACK_STATE_DIR
    #     ($CLAUDE_PROJECT_DIR/.claude/state) → blocks premature stop;
    #   - the supervisor's await-terminal.sh resolves it (main path, or via its
    #     worktree-glob fallback) → instant terminal detection, not a 30-min
    #     heartbeat. See docs/specs/supervisor-wait-worktree-aware.md.
    # Fail-open: a failed seed never blocks the (already-succeeded) spawn — the
    # worker's PWT-T5b activation remains a second path to the file. The worker
    # injects feature_specific_done_criteria into THIS file in its Step 1 §1.5.
    #
    # ROOT-CAUSE FIX (2026-06-07, run 10ac5920): the seed previously targeted
    # $PROJECT_ROOT, resolved via `git rev-parse --show-toplevel`. When this
    # launcher runs from inside a STALE SIBLING worktree (e.g. the origin chat
    # sat in pwt-evaluate-...), --show-toplevel returns the CALLER's worktree,
    # NOT the worker's freshly-created pwt-<slug> worktree. The seed landed in
    # the wrong directory; the worker's goal-evaluator (which reads its own
    # $PWD/.claude/state and $CLAUDE_PROJECT_DIR/.claude/state) never saw it,
    # the anti-skip anchor was inert, and the worker stopped freely after
    # commit+push — never reaching Step 6 ship or Step 8 retro.
    #
    # The fix derives the worker's runtime location the SAME way
    # `claude --bg --worktree <name>` does (git-common-dir → MAIN_REPO_ROOT,
    # correct even from inside a sibling worktree) and seeds:
    #   (1) the worker's OWN runtime worktree state dir (PRIMARY) — but only
    #       when that worktree already exists on disk (claude --bg created it
    #       during startup, before returning the SID). We never pre-create it,
    #       or claude's later `git worktree add` would collide on a non-empty
    #       path. This is what the worker's evaluator finds via PWD_STATE_DIR.
    #   (2) the canonical MAIN_REPO_ROOT/.claude/state (ALWAYS) — await-terminal
    #       resolves this on its main path, and the worker's goal-evaluator
    #       resolves it via the git-common-dir MAIN lookup (defense-in-depth
    #       Fix B), so the anchor is active even if the worktree-race ever
    #       leaves (1) unwritten. The :0:60 truncation MUST match the
    #       --worktree flag (${WT_NAME:0:60}) so the path lands on the real
    #       worktree, not a truncation miss.
    MAIN_REPO_ROOT=$(__pwt_main_repo_root)
    SEED_NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Emit a goal-state JSON into a target state dir (fail-open). Defined here
    # (post-spawn) so SLUG_GUESS / WORKER_SID / SKILL_* are in scope.
    __pwt_emit_goal_state() {
        local dir="$1" file
        [ -n "$dir" ] || return 0
        mkdir -p "$dir" 2>/dev/null || return 0
        file="$dir/plan-w-team-goal-${SLUG_GUESS}.json"
        if command -v jq >/dev/null 2>&1; then
            jq -n \
                --arg slug "$SLUG_GUESS" \
                --arg started_at "$SEED_NOW_ISO" \
                --arg worker_sid "$WORKER_SID" \
                --arg skill_version "$SKILL_VERSION" \
                --arg skill_commit_sha "$SKILL_COMMIT_SHA" \
                '{slug:$slug, started_at:$started_at, terminal_state:null, terminal_reason:null, worker_sid:$worker_sid, skill_version:$skill_version, skill_commit_sha:$skill_commit_sha, feature_specific_done_criteria:[]}' \
                > "$file" 2>/dev/null || true
        else
            printf '{"slug":"%s","started_at":"%s","terminal_state":null,"terminal_reason":null,"worker_sid":"%s","skill_version":"%s","skill_commit_sha":"%s","feature_specific_done_criteria":[]}\n' \
                "$SLUG_GUESS" "$SEED_NOW_ISO" "$WORKER_SID" "$SKILL_VERSION" "$SKILL_COMMIT_SHA" \
                > "$file" 2>/dev/null || true
        fi
        [ -f "$file" ] && echo "  goal-state seed:    $file  (anti-skip anchor active)" >&2
    }

    if [ -n "$MAIN_REPO_ROOT" ]; then
        # (1) worker runtime worktree — only if it already exists (race-safe).
        if [ "${PWT_DISABLE_WORKER_WORKTREE:-0}" != "1" ] && [ -n "${WT_NAME:-}" ]; then
            WORKER_WT_ROOT="$MAIN_REPO_ROOT/.claude/worktrees/${WT_NAME:0:60}"
            if [ -d "$WORKER_WT_ROOT" ]; then
                __pwt_emit_goal_state "$WORKER_WT_ROOT/.claude/state"
            fi
        fi
        # (2) canonical main-repo state dir — always.
        __pwt_emit_goal_state "$MAIN_REPO_ROOT/.claude/state"
    fi

    # ─── --worker-only: emit SID on stdout and exit (no bg supervisor) ────────
    # In this mode the CALLER (UserPromptSubmit hook → origin assistant) acts
    # as the live supervisor. We still register the worker in pwt-launches.jsonl
    # so the statusline classifies it correctly.
    if [ "$WORKER_ONLY" = "1" ]; then
        if [ -n "$PROJECT_ROOT" ] && [ -d "$PROJECT_ROOT/.claude/state" ]; then
            REGISTRY="$PROJECT_ROOT/.claude/state/pwt-launches.jsonl"
            NOW=$(date -u +%FT%TZ)
            printf '{"sid":"%s","parent_sid":"%s","at":"%s","purpose":"%s","launched_by":"pwt-goal","role":"worker","supervisor":"origin-chat"}\n' \
                "$WORKER_SID" "$USER_SID" "$NOW" "$REQUEST_SAFE" \
                >> "$REGISTRY" 2>/dev/null || true
        fi
        REGISTER_HELPER="$(dirname "$0")/plan-w-team-register-spawn.sh"
        if [ -x "$REGISTER_HELPER" ]; then
            # SLUG_GUESS computed earlier (once) via __pwt_safe_slug.
            "$REGISTER_HELPER" "$WORKER_SID" "pwt-goal-launch" "$SLUG_GUESS" "" "pwt-goal.sh --worker-only" \
                >/dev/null 2>&1 || true
        fi

        # Goal-state seed (PWT-WT2) happens ABOVE, before this branch — it is
        # shared with the --launch path (2026-06-09 audit F2).

        # ─── --supervisor-goal: mirror goal state to origin .claude/state/ ────
        # When the origin chat session itself runs under /goal, its
        # goal-evaluator hook needs a non-null plan-w-team-goal-*.json to
        # track progress. Without this mirror, the origin's evaluator sees
        # no active goal and either no-ops or blocks indefinitely.
        #
        # Resolution order for the origin location:
        #   1. $PWT_ORIGIN_ROOT (test-friendly override)
        #   2. $CLAUDE_PROJECT_DIR (the chat session's project dir)
        #   3. $PWD if it is itself a git repo (handles direct invocations
        #      from the agent's Bash tool where neither env var is set but
        #      the script is clearly running inside a checkout — INFO log,
        #      not WARN, since this is a legitimate fallback).
        #   4. If none of the above, skip with a clear stderr message —
        #      the worker still spawned; this mirror is observability for
        #      the origin chat only.
        if [ "$SUPERVISOR_GOAL" = "1" ]; then
            ORIGIN_ROOT=""
            ORIGIN_SOURCE=""
            if [ -n "${PWT_ORIGIN_ROOT:-}" ]; then
                ORIGIN_ROOT="$PWT_ORIGIN_ROOT"
                ORIGIN_SOURCE="PWT_ORIGIN_ROOT"
            elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
                ORIGIN_ROOT="$CLAUDE_PROJECT_DIR"
                ORIGIN_SOURCE="CLAUDE_PROJECT_DIR"
            elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                # PWD is a git checkout — safe to assume this IS the origin.
                ORIGIN_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
                ORIGIN_SOURCE="PWD"
            fi

            if [ -n "$ORIGIN_ROOT" ] && [ -d "$ORIGIN_ROOT" ]; then
                ORIGIN_STATE_DIR="$ORIGIN_ROOT/.claude/state"
                mkdir -p "$ORIGIN_STATE_DIR" 2>/dev/null || true
                ORIGIN_GOAL_FILE="$ORIGIN_STATE_DIR/plan-w-team-goal-${SLUG_GUESS}.json"
                # Write a minimal goal state file the origin's evaluator can read.
                # feature_specific_done_criteria is left empty — origin sees the
                # generic SUCCESS anchors (the worker writes its own per-feature
                # criteria in its own worktree).
                NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                cat > "$ORIGIN_GOAL_FILE" <<EOF_GOAL_MIRROR
{
  "slug": "${SLUG_GUESS}",
  "started_at": "${NOW_ISO}",
  "terminal_state": null,
  "terminal_reason": null,
  "worker_sid": "${WORKER_SID}",
  "supervisor_goal_mirror": true,
  "skill_version": "${SKILL_VERSION}",
  "skill_commit_sha": "${SKILL_COMMIT_SHA}",
  "feature_specific_done_criteria": []
}
EOF_GOAL_MIRROR
                # Write the per-spawn skill-version sidecar alongside the mirror.
                __pwt_write_skill_version_sidecar "$ORIGIN_STATE_DIR" "$SLUG_GUESS" "supervisor-goal"
                __pwt_init_manifest "$ORIGIN_STATE_DIR" "$SLUG_GUESS" "${WORKER_SID:-}"
                if [ "$ORIGIN_SOURCE" = "PWD" ]; then
                    echo "INFO: --supervisor-goal: using PWD as origin (git repo); origin goal-state: $ORIGIN_GOAL_FILE" >&2
                else
                    echo "  origin goal-state:  $ORIGIN_GOAL_FILE  (source: $ORIGIN_SOURCE)" >&2
                fi

                # Register the mirror in the worker's spawned-children registry
                # so the retro cleanup contract auto-terminates the mirror
                # (07-retro §8j-sexies → plan-w-team-child-cleanup.sh) and the
                # goal-evaluator hook can propagate DEAD when the worker dies.
                # The row is distinguishable by type=supervisor_mirror; existing
                # rows without 'type' continue to be treated as worker entries.
                # See docs/specs/supervisor-mirror-lifecycle.md.
                ORIGIN_REGISTRY="$ORIGIN_STATE_DIR/plan-w-team-spawned-children-${SLUG_GUESS}.jsonl"
                MIRROR_REG_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                if command -v jq >/dev/null 2>&1; then
                    MIRROR_ROW=$(jq -cn \
                        --arg ts "$MIRROR_REG_TS" \
                        --arg session_id "$WORKER_SID" \
                        --arg parent_session_id "${USER_SID:-}" \
                        --arg purpose "pwt-goal-launch" \
                        --arg slug "$SLUG_GUESS" \
                        --arg spawned_by "pwt-goal.sh --supervisor-goal" \
                        --arg path "$ORIGIN_GOAL_FILE" \
                        --arg type "supervisor_mirror" \
                        '{ts:$ts, session_id:$session_id, parent_session_id:$parent_session_id, purpose:$purpose, slug:$slug, spawned_by:$spawned_by, type:$type, path:$path}' \
                        2>/dev/null) || MIRROR_ROW=""
                    if [ -n "$MIRROR_ROW" ]; then
                        printf '%s\n' "$MIRROR_ROW" >> "$ORIGIN_REGISTRY" 2>/dev/null || true
                    fi
                fi
            else
                echo "WARN: --supervisor-goal: PWT_ORIGIN_ROOT/CLAUDE_PROJECT_DIR unset and PWD is not a git repo; skipping origin mirror" >&2
            fi
        fi

        # Machine-readable stdout for the hook to parse.
        echo "worker_sid=$WORKER_SID"
        exit "$LAUNCH_RC"
    fi

    # ─── Build supervisor bootstrap ─────────────────────────────────────────
    # The supervisor is a separate claude --bg session whose ONLY purpose is
    # observation + summary writing. It does not modify code. We keep the
    # bootstrap narrow and deterministic so the LLM behavior is predictable.
    #
    # We use `read -r -d '' VAR <<'EOF' ... EOF` instead of `VAR=$(cat <<EOF ... EOF)`
    # because bash 3.2 — Apple's /bin/bash — has a parser bug that mishandles
    # heredocs containing single quotes or backticks when wrapped inside $(...),
    # emitting "unexpected EOF looking for matching )". The `read -d ''` form
    # is bash-3.2 safe (see GOAL_TEXT above for the same pattern). Quoted
    # heredoc (<<'SUPEOF') disables expansion; placeholders are filled via
    # bash 3.2-compatible ${var//pat/repl} parameter expansion below.
    DATE_UTC=$(date -u +%FT%TZ)
    read -r -d '' SUPERVISOR_BOOTSTRAP <<'SUPEOF' || true
# /plan-w-team Outer Supervisor

You are the **outer supervisor** for an autonomous /plan-w-team run. You exist as a separate bg session whose role is **observation and reporting**, not implementation.

## Your worker

- **Session ID:** __WORKER_SID__
- **Goal (verbatim user request):**

> __REQUEST_SAFE__

- **Started:** __DATE_UTC__

The worker is a separate `claude --bg` session executing /plan-w-team. It creates its own worktree during Step 3-4.

## Responsibilities

1. **Observe** by polling `./.claude/scripts/claude-agents-extended.sh` (or `claude agents --json` as fallback) and `claude logs __WORKER_SID__ --tail 200` every ~60s. The extended wrapper includes Agent-tool subagents (kind: "subagent") so a worker fanning out via the Agent tool stays visible. Use `until` loops or ScheduleWakeup; don't burn cache by polling too fast.

2. **Wait for terminal state.** Done when ANY of:
   - **SUCCESS:** transcript contains `stage="retro-complete"` block with `workflow_lock="done"`
   - **ESCALATION:** a hard-gate pause site fires (`push-ack`, `secret-scan-allow`, `scope-unlock-for-drift`)
   - **LOW-CONFIDENCE:** 3 consecutive supervisor decisions log `confidence=low`
   - **DEAD:** the extended wrapper (or `claude agents --json` fallback) no longer lists session __WORKER_SID__

3. **Write completion summary** to `__PROJECT_ROOT__/.claude/state/pwt-completion-summary-__WORKER_SID__.md` with sections: Outcome (SUCCESS/ESCALATION/LOW-CONFIDENCE/DEAD), Goal (verbatim above), Duration (start→end), Worktree (path or "none"), Files changed (`git -C <worktree> diff --stat HEAD~..HEAD` if applicable), AC verdict (parse `AC<N>: PASS|FAIL` lines), Highlights, Next action.

4. **Update goal-state JSON** at `__PROJECT_ROOT__/.claude/state/plan-w-team-goal-<SLUG>.json`. Find by globbing `plan-w-team-goal-*.json` where `terminal_state` is null and `started_at` is within this run window. Update fields: `terminal_state` (SUCCESS / USER_ESCALATION_HALT / LOW_CONFIDENCE_STREAK / DEAD), `terminal_reason`, `terminated_at` (ISO8601), `ac_counts` ({passed, failed, total} or null), `files_touched` (from git diff --name-only or null), `next_action` (imperative string or null). Use a temp-file + rename for atomicity. Tolerate missing file — log to stderr and continue; NEVER block on this step. Markdown summary remains the primary surface.

5. **Surface escalations** with a macOS notification: `osascript -e 'display notification "Hard-gate hit — see chat" with title "/plan-w-team supervisor"' || true`

6. **Exit when done.** After writing the summary, your job is complete.

## Hard rules

- NEVER spawn additional bg agents.
- NEVER edit code, configs, or specs.
- NEVER call /plan-w-team yourself.
- NEVER push to remote — that is the worker + user's responsibility.
- If unsure what to do, write what you observed to the summary file and exit.

## Start

1. Confirm worker is alive: `./.claude/scripts/claude-agents-extended.sh | jq '.[] | select(.sessionId | startswith("__WORKER_SID__"))'` (falls back to `claude agents --json` if the wrapper is missing).
2. Begin your polling loop.
SUPEOF

    # Template substitution (bash 3.2 compatible — uses ${var//pat/repl})
    SUPERVISOR_BOOTSTRAP="${SUPERVISOR_BOOTSTRAP//__WORKER_SID__/$WORKER_SID}"
    SUPERVISOR_BOOTSTRAP="${SUPERVISOR_BOOTSTRAP//__REQUEST_SAFE__/$REQUEST_SAFE}"
    SUPERVISOR_BOOTSTRAP="${SUPERVISOR_BOOTSTRAP//__PROJECT_ROOT__/$PROJECT_ROOT}"
    SUPERVISOR_BOOTSTRAP="${SUPERVISOR_BOOTSTRAP//__DATE_UTC__/$DATE_UTC}"

    # Length guard: /goal's bootstrap ceiling is 4000 chars. We abort at 3800
    # with a 200-char safety margin so a future placeholder growth doesn't
    # trigger silent rejection (the failure mode that caused the 2026-05-20
    # cascade — 19 background sessions accumulated before discovery).
    SUPERVISOR_LEN=${#SUPERVISOR_BOOTSTRAP}
    SUPERVISOR_LIMIT="${PWT_GOAL_SUPERVISOR_LIMIT:-3800}"
    if [ "$SUPERVISOR_LEN" -gt "$SUPERVISOR_LIMIT" ]; then
        echo "FATAL: supervisor bootstrap is $SUPERVISOR_LEN chars (limit $SUPERVISOR_LIMIT)" >&2
        echo "  /goal rejects bootstraps over ~4000 chars. Shrink the SUPERVISOR_BOOTSTRAP" >&2
        echo "  heredoc in pwt-goal.sh, or override PWT_GOAL_SUPERVISOR_LIMIT if you have" >&2
        echo "  confirmed a higher /goal ceiling." >&2
        exit 2
    fi

    # ─── Spawn SUPERVISOR ────────────────────────────────────────────────────
    # Supervisor MUST inherit PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1: its bootstrap
    # text starts with `#` (markdown), bypassing the slash-guard, and embeds
    # the verbatim user request. Without this env var the supervisor's first
    # prompt re-triggers the route hook → recursion (production incident on
    # 2026-05-21: sid 0b5856d7 → 4bbb2cb8 → f2ec9cb9 → 7a4c658b cascade).
    SUP_OUT_FILE=$(mktemp -t pwt-goal-supervisor.XXXXXX 2>/dev/null || echo "")
    if [ -n "$SUP_OUT_FILE" ]; then
        env $LAUNCH_ENV "$CLAUDE_BIN" --bg --model "${PWT_PRIMARY_MODEL:-claude-opus-4-8}" --fallback-model "${PWT_FALLBACK_MODEL:-claude-sonnet-5}" "$SUPERVISOR_BOOTSTRAP" >"$SUP_OUT_FILE" 2>&1
        SUP_RC=$?
        SUPERVISOR_SID=""
        if [ -s "$SUP_OUT_FILE" ]; then
            SUPERVISOR_SID=$(sed -E 's/\x1b\[[0-9;]*m//g' "$SUP_OUT_FILE" 2>/dev/null \
                | grep -oE 'backgrounded · [a-f0-9]{8}' \
                | head -1 | awk '{print $NF}' || echo "")
        fi
        cat "$SUP_OUT_FILE" >&2
        rm -f "$SUP_OUT_FILE" 2>/dev/null || true
    else
        SUPERVISOR_SID=""
        SUP_RC=1
        echo "WARN: mktemp failed for supervisor; spawning anyway" >&2
        env $LAUNCH_ENV "$CLAUDE_BIN" --bg --model "${PWT_PRIMARY_MODEL:-claude-opus-4-8}" --fallback-model "${PWT_FALLBACK_MODEL:-claude-sonnet-5}" "$SUPERVISOR_BOOTSTRAP" >&2 || true
    fi

    if [ -n "$SUPERVISOR_SID" ]; then
        echo "  supervisor session: $SUPERVISOR_SID" >&2
    else
        echo "WARN: supervisor session id could not be parsed; worker still running" >&2
    fi
    echo "" >&2
    echo "Monitor:  claude agents" >&2
    echo "Worker:   claude logs $WORKER_SID" >&2
    [ -n "$SUPERVISOR_SID" ] && echo "Supervisor: claude logs $SUPERVISOR_SID" >&2
    echo "" >&2

    # ─── Register both sessions in pwt-launches.jsonl ────────────────────────
    # SUPERVISOR_SID's parent is the user's interactive session (USER_SID).
    # WORKER_SID's parent is SUPERVISOR_SID (so the statusline transitively
    # pulls the worker into the "mine" set via supervisor chaining).
    if [ -n "$PROJECT_ROOT" ] && [ -d "$PROJECT_ROOT/.claude/state" ]; then
        REGISTRY="$PROJECT_ROOT/.claude/state/pwt-launches.jsonl"
        NOW=$(date -u +%FT%TZ)
        if [ -n "$SUPERVISOR_SID" ]; then
            printf '{"sid":"%s","parent_sid":"%s","at":"%s","purpose":"%s","launched_by":"pwt-goal","role":"supervisor"}\n' \
                "$SUPERVISOR_SID" "$USER_SID" "$NOW" "$REQUEST_SAFE" \
                >> "$REGISTRY" 2>/dev/null || true
            printf '{"sid":"%s","parent_sid":"%s","at":"%s","purpose":"%s","launched_by":"pwt-goal","role":"worker"}\n' \
                "$WORKER_SID" "$SUPERVISOR_SID" "$NOW" "$REQUEST_SAFE" \
                >> "$REGISTRY" 2>/dev/null || true
        else
            # Supervisor failed → record worker chained directly to user
            printf '{"sid":"%s","parent_sid":"%s","at":"%s","purpose":"%s","launched_by":"pwt-goal","role":"worker-orphan"}\n' \
                "$WORKER_SID" "$USER_SID" "$NOW" "$REQUEST_SAFE" \
                >> "$REGISTRY" 2>/dev/null || true
        fi
    fi

    # Spawned-children registry (read by 07-retro §8j-sexies cleanup) —
    # only the WORKER goes here; the supervisor cleans itself up when the
    # worker terminates (it's not a "spawned child" of the worker).
    REGISTER_HELPER="$(dirname "$0")/plan-w-team-register-spawn.sh"
    if [ -x "$REGISTER_HELPER" ]; then
        # Slug derivation goes through __pwt_safe_slug — see helper definition
        # near top of file. Idempotent + filesystem-safe + non-empty by contract.
        SLUG_GUESS=$(__pwt_safe_slug "$ORIGINAL_REQUEST")
        "$REGISTER_HELPER" "$WORKER_SID" "pwt-goal-launch" "$SLUG_GUESS" "${SUPERVISOR_SID:-}" "pwt-goal.sh" \
            >/dev/null 2>&1 || true
    fi

    exit "$LAUNCH_RC"
fi

echo "$GOAL_TEXT"
