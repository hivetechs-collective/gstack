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
# `claude` session (or `claude -p "<paste>"`) to start an autonomous run.
#
# Usage:
#   pwt-goal.sh "ship payment API with stripe webhooks"
#   pwt-goal.sh -i "ship payment API"          # interactive: prompt for extra DoD
#   pwt-goal.sh --launch "ship payment API"    # auto-launches `claude -p` for you
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
Claude Code session, or use --launch to auto-invoke 'claude -p'.
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
    # Resolve state-dir root. Preference: explicit override → git toplevel → PWD.
    if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
        __pwt_overflow_root="$PWT_PROJECT_ROOT_OVERRIDE"
    else
        __pwt_overflow_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
    fi
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
(halt sites + closing note) is ~600 chars, leaving ~$((GOAL_MAX - 600))
chars for the user-provided content.

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
if [ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-0}" = "1" ] \
        && [ "${PLAN_W_TEAM_FORCE_SPAWN:-0}" != "1" ] \
        && { [ "$WORKER_ONLY" = "1" ] || [ "$LAUNCH" = "1" ]; }; then
    cat >&2 <<CASCADE_GUARD
✗ Worker-cascade refused: cannot spawn /plan-w-team from inside a worker session.

  Signal: PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 is set, which means this process
  inherited environment from a parent pwt-goal.sh bg worker spawn.

  A worker's goal text contains "Use /plan-w-team to..." (verbatim). When the
  worker's LLM reads its own goal, the trigger phrase fires the skill manifest's
  routing logic, prompting another pwt-goal.sh call. That creates a recursive
  cascade.

  If you intentionally need a sub-worker from inside an orchestrator running
  inside a worker, set PLAN_W_TEAM_FORCE_SPAWN=1 and retry.

  Caught 2026-05-22 via worker 85420913's own LLM spawning a duplicate, and
  worker c00b9887's --launch call producing 8cf9b873 + 752e86c4.
CASCADE_GUARD
    exit 4
fi

# ─── DETERMINISTIC DOUBLE-SPAWN GUARD (PWT-DS1) ─────────────────────────────
# If the UserPromptSubmit route hook already spawned a worker for this turn,
# refuse to spawn another. The hook writes a flag file at:
#   .claude/state/plan-w-team-hook-spawn-<parent_sid_short>.flag
# Flag is fresh if mtime is within 60s. Skip when --worker-only mode is NOT
# active because direct invocations from a shell are intentional.
#
# Override (escape hatch): PLAN_W_TEAM_FORCE_SPAWN=1 bypasses the guard.
# Use only if you've manually confirmed the hook's prior spawn is dead/stopped.
if [ "$WORKER_ONLY" = "1" ] && [ "${PLAN_W_TEAM_FORCE_SPAWN:-0}" != "1" ]; then
    GUARD_PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-${PWT_PROJECT_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
    GUARD_DIR="$GUARD_PROJECT_ROOT/.claude/state"
    if [ -d "$GUARD_DIR" ]; then
        # Find any fresh hook-spawn flag (mtime within 60s)
        FRESH_FLAG=$(find "$GUARD_DIR" -maxdepth 1 -name 'plan-w-team-hook-spawn-*.flag' -mmin -1 2>/dev/null | head -1)
        if [ -n "$FRESH_FLAG" ]; then
            EXISTING_WORKER=$(grep '^worker_sid=' "$FRESH_FLAG" 2>/dev/null | head -1 | cut -d= -f2)
            EXISTING_AT=$(grep '^spawned_iso=' "$FRESH_FLAG" 2>/dev/null | head -1 | cut -d= -f2)
            cat >&2 <<GUARD
✗ Double-spawn refused: the route hook already spawned worker $EXISTING_WORKER
  at $EXISTING_AT for this user turn.

  Flag: $FRESH_FLAG (auto-expires after 60s)

  Why this guard exists: the manifest's Step 3a check ("if you see the
  systemMessage marker, skip Step 3b") depends on the LLM noticing the
  marker in its context. When the LLM misses it (verified 2026-05-22),
  it calls pwt-goal.sh --worker-only and produces a duplicate worker.
  This guard prevents that at the process level.

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
    USER_SID="${CLAUDE_JOB_DIR:-}"
    USER_SID="${USER_SID##*/}"
    [ -z "$USER_SID" ] && USER_SID="${PWT_PARENT_SID:-}"
    USER_SID="${USER_SID:0:8}"

    REQUEST_SAFE=$(printf '%s' "$REQUEST" | head -c 200 | sed 's/"/\\"/g')

    echo "Launching /plan-w-team autonomous run (supervisor + worker)..." >&2
    [ -n "$LAUNCH_ENV" ] && echo "  with env: $LAUNCH_ENV" >&2

    # ─── Spawn WORKER first so we know its sid for the supervisor bootstrap ──
    WORKER_OUT_FILE=$(mktemp -t pwt-goal-worker.XXXXXX 2>/dev/null || echo "")
    [ -z "$WORKER_OUT_FILE" ] && {
        echo "FATAL: mktemp failed; cannot launch" >&2
        exit 1
    }

    # LAUNCH_ENV always contains PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1; the bare
    # `claude --bg` branch is unreachable but kept as a safety net.
    if [ -n "$LAUNCH_ENV" ]; then
        env $LAUNCH_ENV claude --bg "$GOAL_TEXT" >"$WORKER_OUT_FILE" 2>&1
        LAUNCH_RC=$?
    else
        env PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 claude --bg "$GOAL_TEXT" >"$WORKER_OUT_FILE" 2>&1
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

1. **Observe** by polling `claude agents --json` and `claude logs __WORKER_SID__ --tail 200` every ~60s. Use `until` loops or ScheduleWakeup; don't burn cache by polling too fast.

2. **Wait for terminal state.** Done when ANY of:
   - **SUCCESS:** transcript contains `stage="retro-complete"` block with `workflow_lock="done"`
   - **ESCALATION:** a hard-gate pause site fires (`push-ack`, `secret-scan-allow`, `scope-unlock-for-drift`)
   - **LOW-CONFIDENCE:** 3 consecutive supervisor decisions log `confidence=low`
   - **DEAD:** `claude agents --json` no longer lists session __WORKER_SID__

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

1. Confirm worker is alive: `claude agents --json | jq '.[] | select(.sessionId | startswith("__WORKER_SID__"))'`.
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
        env $LAUNCH_ENV claude --bg "$SUPERVISOR_BOOTSTRAP" >"$SUP_OUT_FILE" 2>&1
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
        env $LAUNCH_ENV claude --bg "$SUPERVISOR_BOOTSTRAP" >&2 || true
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
