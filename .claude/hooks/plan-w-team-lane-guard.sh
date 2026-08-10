#!/bin/bash
# plan-w-team Lane Guard — PreToolUse hook (Bash|Write|Edit|MultiEdit)
#
# PWT-LANE1 (2026-08-09, cleanscale incident): while a /goal-spawned
# /plan-w-team worker holds a lane, NOTHING at the tool layer stopped the
# supervising session from implementing the work itself. The Stop-hook
# evaluator gates termination — never behavior — and after a compaction the
# supervisor role ("observe and steer, never implement") is exactly the kind
# of procedural scaffolding a summary drops while keeping the objective. The
# result: the origin chat edited product code in the main checkout while the
# lane's worker ran in its worktree, forking the work and corrupting the run.
#
# This hook makes the lane BINDING instead of advisory:
#   1. The owning WORKER (session SID prefix == goal's worker_sid) is never
#      restricted — the pipeline's own gates govern it.
#   2. A SUPERVISOR session bound to a live lane is denied mutating tool calls
#      against the repo the lane owns: Edit/Write/MultiEdit anywhere in the
#      main checkout outside .claude/state/, git write-subcommands, file
#      mutators with provable repo targets, build/test runners, and shell
#      redirects into the repo. Its legitimate duties — reading, state
#      bookkeeping under .claude/state/, running .claude/scripts/ helpers,
#      steering via stop/resume — all pass untouched.
#   3. ANY non-worker session (bound or not) is denied writes into the lane's
#      worktree and denied forging the artifacts the Stop evaluator trusts
#      (plan-w-team-ship-verdict-<slug>.json, plan-w-team-test-green-<slug>.json).
#      A BOUND session is additionally denied tampering with the lane's
#      goal-state file and the release valve itself.
#
# Every deny RE-TEACHES the role in its message, so the first violating call
# after a compaction restores the contract the summary dropped — enforcement
# doubles as context restoration.
#
# Binding sources for "this session supervises lane L":
#   a. PLAN_W_TEAM_SUPERVISOR_SESSION=1 (bg supervisor launch env; workers get
#      an explicit =0 forced by pwt-goal.sh, so this can never mark a worker)
#   b. goal-state supervisor_sid == this session (seeded by pwt-goal.sh)
#   c. pwt-launches.jsonl row: this session spawned the lane's worker
#
# Lane liveness = goal-state exists, terminal_state null, mtime younger than
# PWT_GOAL_STALE_HOURS (default 24h; matches the evaluator's stale-skip), and
# no release file. Release valve (USER-only, written outside the bound
# session): .claude/state/plan-w-team-lane-release-<slug>.json.
#
# HOOK ENFORCEMENT CONTRACT (block-protected-paths.sh precedent):
#   exit 0 → allow.  exit 2 + reason on stderr → BLOCK.
# Fail-open on every infrastructure error (no jq, unreadable state, no SID):
# a guard that bricks sessions is worse than one that under-detects. Denies
# are only ever issued on POSITIVE evidence.
#
# Kill switch: PLAN_W_TEAM_DISABLE_LANE_GUARD=1
# Audit trail: .claude/state/plan-w-team-lane-guard-audit.jsonl (denies only)
# Spec: docs/operations/lane-enforcement.md

set -u

[ "${PLAN_W_TEAM_DISABLE_LANE_GUARD:-}" = "1" ] && exit 0

INPUT=$(cat 2>/dev/null || echo '{}')
command -v jq >/dev/null 2>&1 || exit 0

SELF_SID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
SELF8="${SELF_SID:0:8}"
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$CWD" ] || CWD="$PWD"

# Nothing to evaluate for non-mutating tools (defensive; settings.json should
# only wire us to Bash/Write/Edit/MultiEdit).
case "$TOOL" in
    Bash|Write|Edit|MultiEdit|NotebookEdit) : ;;
    *) exit 0 ;;
esac

# ── MAIN-checkout resolution (same idiom as plan-w-team-goal-evaluator.sh) ───
# PWT_PROJECT_ROOT_OVERRIDE wins (hermetic test contract); else the common git
# dir of the session's cwd; else CLAUDE_PROJECT_DIR's. A worktree's git file
# points at the common dir, so this lands on the MAIN checkout either way.
__main_root_of() {
    local from="$1" cdir
    cdir=$(git -C "$from" rev-parse --git-common-dir 2>/dev/null || echo "")
    case "$cdir" in
        "") echo "" ;;
        /*) (cd "$(dirname "$cdir")" 2>/dev/null && pwd) || echo "" ;;
        *)  (cd "$from/$(dirname "$cdir")" 2>/dev/null && pwd) || echo "" ;;
    esac
}
MAIN_ROOT=""
if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    MAIN_ROOT="$PWT_PROJECT_ROOT_OVERRIDE"
else
    MAIN_ROOT=$(__main_root_of "$CWD")
    [ -z "$MAIN_ROOT" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && MAIN_ROOT=$(__main_root_of "$CLAUDE_PROJECT_DIR")
fi
[ -n "$MAIN_ROOT" ] && [ -d "$MAIN_ROOT" ] || exit 0
# Canonicalize through cd+pwd so prefix comparisons use the same spelling as
# __abs_path's output. Without this, a MAIN_ROOT carrying a double slash (macOS
# TMPDIR ends with "/", so mktemp-derived roots do) never prefix-matches the
# normalized file path and every path-scoped deny silently allows.
MAIN_ROOT=$(cd "$MAIN_ROOT" 2>/dev/null && pwd) || exit 0
STATE_DIR="$MAIN_ROOT/.claude/state"
[ -d "$STATE_DIR" ] || exit 0

# ── Tool-input extraction ────────────────────────────────────────────────────
FILE_PATH=""
CMD=""
if [ "$TOOL" = "Bash" ]; then
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
    [ -n "$CMD" ] || exit 0
else
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
    [ -n "$FILE_PATH" ] || exit 0
fi

# Absolutize + normalize a path (bash-3.2-safe; no readlink -f on macOS).
# Prefers `cd dirname && pwd` (parent almost always exists, even for a new
# file); falls back to python3 normpath; else a crude join. A path we cannot
# resolve returns empty — callers treat that as "no positive evidence".
__abs_path() {
    local p="$1" d b
    case "$p" in /*) : ;; *) p="$CWD/$p" ;; esac
    d=$(dirname "$p"); b=$(basename "$p")
    if [ -d "$d" ]; then
        printf '%s/%s' "$(cd "$d" 2>/dev/null && pwd)" "$b"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.normpath(sys.argv[1]))' "$p" 2>/dev/null
    else
        case "$p" in *..*) echo "" ;; *) printf '%s' "$p" ;; esac
    fi
}

__under() {  # $1=path  $2=dir  → 0 if path is dir or inside dir
    case "$1" in "$2"|"$2"/*) return 0 ;; esac
    return 1
}

FILE_ABS=""
[ -n "$FILE_PATH" ] && FILE_ABS=$(__abs_path "$FILE_PATH")

# ── Deny plumbing ────────────────────────────────────────────────────────────
AUDIT="$STATE_DIR/plan-w-team-lane-guard-audit.jsonl"
__audit() {  # $1=kind $2=slug $3=target
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$SELF8" \
        --arg tool "$TOOL" --arg kind "$1" --arg slug "$2" --arg target "$3" \
        '{ts:$ts, sid:$sid, tool:$tool, decision:"deny", kind:$kind, slug:$slug, target:$target}' \
        >> "$AUDIT" 2>/dev/null || true
}

__deny_role() {  # $1=slug $2=worker8 $3=worktree $4=target
    __audit "supervisor-implementing" "$1" "$4"
    cat >&2 <<MSGEOF
⛔ LANE GUARD (PWT-LANE1): this session is the SUPERVISOR of live /plan-w-team lane '$1' (worker ${2}, worktree: ${3:-main checkout}). Supervisors observe and steer — they NEVER implement, run builds, or commit. This $TOOL call (${4}) is the lane's work and is denied.

Do instead:
  • Inspect the lane:  .claude/scripts/pwt-status.sh  /  .claude/scripts/plan-w-team-fleet-query.sh
  • Steer the worker:  stop it and resume by session UUID from inside its worktree with revised instructions (see docs/operations/ + memory: bg-worker steering) — never do its work in parallel
  • Queue follow-ups:  write a brief under .claude/state/ (allowed) for the worker/retro to drain
  • Lane truly wedged: escalate to the user; only the USER releases a lane (.claude/state/plan-w-team-lane-release-$1.json, written outside this session)

A supervisor that implements while its lane is live forks the work and corrupts the run (2026-08-09 cleanscale incident). This block IS your role contract — if a compaction dropped it, you have it back now. Operator kill switch: PLAN_W_TEAM_DISABLE_LANE_GUARD=1.
MSGEOF
    exit 2
}

__deny_worktree() {  # $1=slug $2=worker8 $3=worktree $4=target
    __audit "foreign-worktree-write" "$1" "$4"
    cat >&2 <<MSGEOF
⛔ LANE GUARD (PWT-LANE1): ${4} is inside the worktree of live /plan-w-team lane '$1', owned by worker ${2} — and this session (${SELF8:-unknown}) is not that worker. Two writers in one lane worktree corrupt the run. Steer the owning worker instead (stop + resume with instructions), or escalate to the user.
MSGEOF
    exit 2
}

__deny_artifact() {  # $1=slug $2=basename $3=why
    __audit "trusted-artifact-tamper" "$1" "$2"
    cat >&2 <<MSGEOF
⛔ LANE GUARD (PWT-LANE1): ${2} is a terminal-decision artifact for live lane '$1' — the Stop evaluator TRUSTS it, so only the pipeline may produce it (${3}). Hand-building it would mark the goal done without the work being done. If the run must end: escalate to the user; only the USER releases or halts a lane from outside the supervising session.
MSGEOF
    exit 2
}

# ── Bash command classifiers (bound-supervisor policy) ───────────────────────
# Separators before a command word: start, ;, &, |, $( or backtick. Deliberate
# scope: catch the natural drift shapes, not an adversary — the file-tool path
# is hard-denied and these close the common Bash long tail.
SEP='(^|[;&|]|\$\(|`)[[:space:]]*(sudo[[:space:]]+)?'
GIT_WRITE_RE="${SEP}git([[:space:]]+(-C|-c|--git-dir(=[^[:space:]]+)?|--work-tree(=[^[:space:]]+)?)([[:space:]]+[^[:space:]]+)?)*[[:space:]]+(add|commit|merge|rebase|cherry-pick|apply|am|revert|reset|restore|checkout|switch|stash|push|pull|mv|rm|clean|tag|worktree)([[:space:]]|$)"
BUILDER_RE="${SEP}(make|gradle|gradlew|\./gradlew|mvn|\./mvnw|xcodebuild|cargo|npm|npx|pnpm|yarn|bun|dotnet|tsc|jest|vitest|pytest|bats|flutter|fastlane)([[:space:]]|$)"
GO_BUILD_RE="${SEP}go[[:space:]]+(build|run|test|install|get|generate)([[:space:]]|$)"
SKILL_SUITE_RE="tests/skill/run(-scenarios)?\.sh"
MUTATOR_RE="${SEP}(rm|mv|cp|ln|truncate|dd|rsync|shred|unlink|install)([[:space:]]|$)"
EXEC_MUTATOR_RE="-(exec|execdir)[[:space:]]+(rm|mv|cp)([[:space:]]|;)|xargs([[:space:]]+-[^[:space:]]+)*[[:space:]]+(rm|mv|cp)([[:space:]]|$)"
INPLACE_RE="sed[[:space:]]+(-[a-zA-Z]*i|--in-place)|perl[[:space:]]+[^|;&]*-[a-zA-Z]*i([[:space:]]|$)"

# A redirect / tee / mutator target is ALLOWED when it provably lands outside
# the main checkout (tmp, /dev, $HOME dotfiles, other repos) or inside
# .claude/state/ minus the trusted-artifact families. Only PROVABLE repo
# targets deny — variables and unresolvable tokens pass (fail-open; the
# file-tool layer is the hard wall).
__protected_basename() {  # $1=basename $2=slug → 0 if trusted family for slug
    case "$1" in
        "plan-w-team-ship-verdict-$2.json"|"plan-w-team-test-green-$2.json"|\
        "plan-w-team-goal-$2.json"|"plan-w-team-lane-release-$2.json") return 0 ;;
    esac
    return 1
}
__bash_target_denied() {  # $1=raw target token  $2=slug → 0 if deny
    local t="$1" abs base
    # Strip simple quoting; a token still carrying $ or backticks is
    # unresolvable → allow (no positive evidence).
    t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"
    case "$t" in ''|*'$'*|*'`'*) return 1 ;; esac
    case "$t" in /dev/*) return 1 ;; esac
    abs=$(__abs_path "$t")
    [ -n "$abs" ] || return 1
    __under "$abs" "$MAIN_ROOT" || return 1
    if __under "$abs" "$STATE_DIR"; then
        base=$(basename "$abs")
        __protected_basename "$base" "$2" && return 0
        return 1
    fi
    return 0
}
# Extract redirect targets (skips fd-dups like 2>&1 — & can't start a target).
__redirect_targets() {
    printf '%s' "$CMD" | grep -oE '[0-9]*>>?[[:space:]]*[^[:space:]<>;&|)]+' 2>/dev/null \
        | sed -E 's/^[0-9]*>>?[[:space:]]*//'
}
__tee_targets() {
    printf '%s' "$CMD" | grep -oE 'tee[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*[^;&|<>]+' 2>/dev/null \
        | sed -E 's/^tee[[:space:]]+//; s/-[a-zA-Z]+[[:space:]]+//g'
}

# ── Evaluate each live lane ──────────────────────────────────────────────────
shopt -s nullglob
for GF in "$STATE_DIR"/plan-w-team-goal-*.json; do
    jq -e . "$GF" >/dev/null 2>&1 || continue
    [ -n "$(jq -r '.terminal_state // ""' "$GF" 2>/dev/null)" ] && continue

    # Stale lanes never restrict anyone (mirrors evaluator PWT-STALE-SKIP; a
    # dead worker's lane is auto-released on the next Stop via DEAD propagation,
    # and this age gate is the backstop when that never fires).
    MTIME=$(stat -f %m "$GF" 2>/dev/null || stat -c %Y "$GF" 2>/dev/null || echo "")
    if [ -n "$MTIME" ] && [ "$MTIME" -gt 0 ] 2>/dev/null; then
        AGE=$(( $(date -u +%s) - MTIME ))
        [ "$AGE" -ge $(( ${PWT_GOAL_STALE_HOURS:-24} * 3600 )) ] 2>/dev/null && continue
    fi

    SLUG=$(jq -r '.slug // ""' "$GF" 2>/dev/null)
    [ -n "$SLUG" ] || continue
    [ -f "$STATE_DIR/plan-w-team-lane-release-${SLUG}.json" ] && continue

    WSID=$(jq -r '.worker_sid // ""' "$GF" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$WSID" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;
        *) continue ;;   # no provable worker → no lane split → guard N/A
    esac
    W8="${WSID:0:8}"

    # The owning worker is never restricted by its own lane.
    [ -n "$SELF8" ] && [ "$SELF8" = "$W8" ] && continue

    # SID-less harness (old Claude Code): we cannot prove this session is NOT
    # the worker, so per-session rules would misfire on the worker itself.
    # Only the env-flagged bg supervisor (which pwt-goal.sh guarantees is
    # never a worker) keeps its policy; everything else fails open.
    if [ -z "$SELF8" ] && [ "${PLAN_W_TEAM_SUPERVISOR_SESSION:-0}" != "1" ]; then
        continue
    fi

    # Lane worktree (manifest is authoritative; always in the main checkout).
    WT=$(jq -r '.worktree_path // ""' "$STATE_DIR/plan-w-team-manifest-${SLUG}.json" 2>/dev/null)
    # Same canonicalization as MAIN_ROOT — prefix tests need one spelling.
    if [ -n "$WT" ] && [ -d "$WT" ]; then
        WT=$(cd "$WT" 2>/dev/null && pwd) || WT=""
    fi
    [ "$WT" = "$MAIN_ROOT" ] && WT=""   # main-checkout runs have no separate zone

    # Is THIS session bound to the lane as its supervisor?
    BOUND=0
    [ "${PLAN_W_TEAM_SUPERVISOR_SESSION:-0}" = "1" ] && BOUND=1
    if [ "$BOUND" = "0" ] && [ -n "$SELF8" ]; then
        SSID=$(jq -r '.supervisor_sid // ""' "$GF" 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        [ -n "$SSID" ] && [ "${SSID:0:8}" = "$SELF8" ] && BOUND=1
    fi
    if [ "$BOUND" = "0" ] && [ -n "$SELF8" ] && [ -f "$STATE_DIR/pwt-launches.jsonl" ]; then
        if jq -r --arg w "$W8" 'select(((.sid // "") | ascii_downcase | startswith($w))) | (.parent_sid // "")' \
             "$STATE_DIR/pwt-launches.jsonl" 2>/dev/null \
             | tr '[:upper:]' '[:lower:]' | cut -c1-8 | grep -qFx "$SELF8"; then
            BOUND=1
        fi
    fi

    if [ "$TOOL" != "Bash" ]; then
        [ -n "$FILE_ABS" ] || continue
        BASE=$(basename "$FILE_ABS")
        # (1) Any non-worker session: hands off the lane's worktree.
        if [ -n "$WT" ] && __under "$FILE_ABS" "$WT"; then
            __deny_worktree "$SLUG" "$W8" "$WT" "$FILE_ABS"
        fi
        # (2) Any non-worker session: never forge the evaluator's evidence.
        case "$BASE" in
            "plan-w-team-ship-verdict-${SLUG}.json")
                __deny_artifact "$SLUG" "$BASE" "Step 6 writes it only after every §6 ENFORCING gate passes" ;;
            "plan-w-team-test-green-${SLUG}.json")
                __deny_artifact "$SLUG" "$BASE" "plan-w-team-test-green.sh writes it from a real suite run" ;;
        esac
        # (3) Bound supervisor: goal-state + release valve are also off-limits,
        #     and so is the rest of the repo outside .claude/state/.
        if [ "$BOUND" = "1" ]; then
            case "$BASE" in
                "plan-w-team-goal-${SLUG}.json")
                    __deny_artifact "$SLUG" "$BASE" "the Stop evaluator owns terminal_state; a supervisor writing it is self-termination spoofing" ;;
                "plan-w-team-lane-release-${SLUG}.json")
                    __deny_artifact "$SLUG" "$BASE" "the release valve is USER-only; a supervisor releasing its own lane defeats the guard" ;;
            esac
            if __under "$FILE_ABS" "$MAIN_ROOT" && ! __under "$FILE_ABS" "$STATE_DIR"; then
                __deny_role "$SLUG" "$W8" "$WT" "$FILE_ABS"
            fi
        fi
    else
        # (2') Any non-worker session: Bash that WRITES a trusted artifact for
        # this lane is forgery. Reading it (cat/jq, even with 2>/dev/null fd
        # redirects) stays legal — only a redirect TARGET naming the family, or
        # a write-verb followed by it, denies.
        for FAM in "plan-w-team-ship-verdict-${SLUG}" "plan-w-team-test-green-${SLUG}"; do
            FORGE=0
            while IFS= read -r TGT; do
                case "$TGT" in *"$FAM"*) FORGE=1; break ;; esac
            done <<EOF_FAMR
$(__redirect_targets)
EOF_FAMR
            if [ "$FORGE" = "0" ] \
               && printf '%s' "$CMD" | grep -qE "(mv|cp|rm|touch|tee)[[:space:]][^;|&]*${FAM}"; then
                FORGE=1
            fi
            [ "$FORGE" = "1" ] && __deny_artifact "$SLUG" "${FAM}.json" "only the pipeline's own gates may produce it"
        done
        # (1') Any non-worker session: mutating Bash aimed into the lane's
        # worktree — a git-write/mutator naming its literal path, or a redirect
        # whose target lands inside it. Reads (tail/cat with fd redirects) pass.
        if [ -n "$WT" ]; then
            if printf '%s' "$CMD" | grep -qF "$WT" \
               && printf '%s' "$CMD" | grep -qE "$GIT_WRITE_RE|$MUTATOR_RE"; then
                __deny_worktree "$SLUG" "$W8" "$WT" "Bash: ${CMD:0:120}"
            fi
            while IFS= read -r TGT; do
                [ -n "$TGT" ] || continue
                T_ABS=$(__abs_path "$TGT")
                if [ -n "$T_ABS" ] && __under "$T_ABS" "$WT"; then
                    __deny_worktree "$SLUG" "$W8" "$WT" "Bash redirect → $TGT"
                fi
            done <<EOF_WTREDIR
$(__redirect_targets | grep -v '[$`]' || true)
EOF_WTREDIR
        fi
        # (3') Bound supervisor: implementing/building/shipping shapes.
        if [ "$BOUND" = "1" ]; then
            if printf '%s' "$CMD" | grep -qE "$GIT_WRITE_RE"; then
                __deny_role "$SLUG" "$W8" "$WT" "Bash git-write: ${CMD:0:120}"
            fi
            if printf '%s' "$CMD" | grep -qE "$BUILDER_RE|$GO_BUILD_RE|$SKILL_SUITE_RE"; then
                __deny_role "$SLUG" "$W8" "$WT" "Bash build/test: ${CMD:0:120}"
            fi
            if printf '%s' "$CMD" | grep -qE "$INPLACE_RE"; then
                __deny_role "$SLUG" "$W8" "$WT" "Bash in-place edit: ${CMD:0:120}"
            fi
            if printf '%s' "$CMD" | grep -qE "$MUTATOR_RE|$EXEC_MUTATOR_RE"; then
                # Deny only on a provable repo target (fail-open on $vars).
                DENIED=0
                while IFS= read -r TOK; do
                    [ -n "$TOK" ] || continue
                    case "$TOK" in -*) continue ;; esac
                    if __bash_target_denied "$TOK" "$SLUG"; then DENIED=1; break; fi
                done <<EOF_TOKENS
$(printf '%s' "$CMD" | tr ' ' '\n' | grep -vE '^(sudo|rm|mv|cp|ln|truncate|dd|rsync|shred|unlink|install|xargs|find)$' | head -40)
EOF_TOKENS
                [ "$DENIED" = "1" ] && __deny_role "$SLUG" "$W8" "$WT" "Bash mutator: ${CMD:0:120}"
            fi
            # Redirect / tee targets that provably land in the repo.
            while IFS= read -r TGT; do
                [ -n "$TGT" ] || continue
                if __bash_target_denied "$TGT" "$SLUG"; then
                    __deny_role "$SLUG" "$W8" "$WT" "Bash redirect → $TGT"
                fi
            done <<EOF_REDIR
$(__redirect_targets)
EOF_REDIR
            while IFS= read -r TGT; do
                [ -n "$TGT" ] || continue
                for ONE in $TGT; do
                    if __bash_target_denied "$ONE" "$SLUG"; then
                        __deny_role "$SLUG" "$W8" "$WT" "Bash tee → $ONE"
                    fi
                done
            done <<EOF_TEE
$(__tee_targets)
EOF_TEE
        fi
    fi
done
shopt -u nullglob

exit 0
