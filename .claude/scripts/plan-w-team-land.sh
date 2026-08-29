#!/usr/bin/env bash
# plan-w-team-land.sh — the landing predicate, its artifact, and the scripted
# resume-to-land remediation.  (RC4 / F6 core + F8; skill 2.13.0)
#
# THE PROBLEM THIS SOLVES
# -----------------------
# The lead-in-worktree model (PWT-WT1) made merge-to-default an HONOR-SYSTEM step:
# the manifest's own wording was "ExitWorktree happens implicitly when the session
# ends (or explicitly after Step 8 retro **if you want** the main checkout to
# inherit the merge)".  For an autonomous `--worker-only` run whose done-when
# includes a LANDED version+tag, "if you want" is a prose rule with no enforcement
# — precisely the class the Rule-Enforcement Invariant bans.
#
# The 2026-08-19 field instance: a 15-hour run emitted `retro-complete`, captured a
# retro, created a tag — and landed NOTHING.  The worktree branch sat 31 commits
# ahead of master, local master and origin/master had none of them, the tag existed
# only locally, and `terminal_state` stayed null.  The ending is DETERMINISTIC, not
# occasional: the bg worker's stdin is `/dev/null` (the Bug-A backstop), so the
# ship-stage `git push` permission prompt AUTO-REJECTS with no visible trace.
# `PLAN_W_TEAM_AUTO_APPROVE_PUSH=1` clears only the SKILL's push-ack gate, one
# layer above the harness permission that was never granted.
#
# WHAT THIS SCRIPT IS
# -------------------
# The single place that answers "did this run LAND?".  Both consumers need the
# same answer and would drift if each computed its own:
#   * F6 — `.claude/hooks/plan-w-team-goal-evaluator.sh` ANDs the landing artifact
#     into SUCCESS for worktree-isolated runs.
#   * F8 — `resume` below refuses when the run is already landed.
#   * F7 — `.claude/scripts/plan-w-team-await-terminal.sh` consults the artifact so
#     a transcript-only SUCCESS cannot outrun the landing.
#
# THE PREDICATE (four checks, computed from git — never from caller assertions)
#   merged         the run's work is on the default branch, by ancestry OR by an
#                  identical tree (squash/rebase landings)
#   tag_reachable  every tag pointing at the run sha is an ancestor of the default
#                  branch ref that was used
#   pushed         the landing sha is contained in <remote>/<default>
#   remote         no remote configured  ->  pushed = "n/a", predicate passes on the
#                  merge alone (a local-only repo must still be able to land)
#
# USAGE
#   plan-w-team-land.sh status --slug <slug> [opts]      # print the verdict, write nothing
#   plan-w-team-land.sh verify --slug <slug> [opts]      # status + write the artifact when LANDED
#   plan-w-team-land.sh merge  --slug <slug> [opts]      # dirty-tree-safe integrate before the push
#   plan-w-team-land.sh resume --slug <slug> [--dry-run] # F8 remediation via pwt-steer.sh
#
#   opts: --sha <sha> --branch <b> --default-branch <d> --remote <r>
#         --tag <t> --state-dir <dir> --repo <dir> --no-fetch --json
#
# EXIT CODES (contract — the evaluator, the watcher and the tests depend on these)
#   0   LANDED (status/verify) | remediation launched (resume)
#   10  NOT LANDED — stdout names the first failed check
#   6   refused — nothing was mutated (resume: already landed / already terminal /
#       no worker session to resume)
#   2   usage error
#   3   environment error (no git / no jq / unresolvable repo)
#
# WHAT THIS SCRIPT MUST NEVER DO
#   Write `terminal_state`.  Observed live 2026-08-19: the lane guard REFUSES a
#   supervisor write to that field as self-termination spoofing — correctly.  The
#   flip must come from the resumed pipeline session's OWN Stop evaluator, or from
#   the user's lane-release file.  Asserted by tests/skill/cases/landing-gate.bats.
#
# bash 3.2 (mac-mini /bin/bash): no `declare -A`, no mapfile, no `${v,,}`.
# `set -u` only — every git probe is allowed to fail and be classified.
#
# Spec:  docs/specs/pwt-host-load-and-stall-protection.md  (#ADDENDUM, F6/F8)
# Tests: tests/skill/cases/landing-gate.bats
# Docs:  docs/operations/plan-w-team-landing-gate.md

set -u

SCHEMA="plan-w-team-landed/v1"

SUB="${1:-}"
[ -n "$SUB" ] && shift || true

SLUG=""
ARG_SHA=""
ARG_BRANCH=""
ARG_DEFAULT=""
ARG_REMOTE=""
ARG_TAG=""
STATE_DIR_OVERRIDE=""
REPO_OVERRIDE=""
NO_FETCH="${PWT_LAND_NO_FETCH:-0}"
JSON_OUT=0
DRY_RUN=0
STEER_BIN_OVERRIDE=""

usage() {
    cat >&2 <<'EOF'
usage: plan-w-team-land.sh <status|verify|merge|resume> --slug <slug> [options]

  status  evaluate the landing predicate and print the verdict (writes nothing)
  verify  status, and write .claude/state/plan-w-team-landed-<slug>.json when LANDED
  merge   dirty-tree-safe integration of the default branch into the run branch
          (stash by unique tag → merge → apply by SHA → drop by tag), so the
          landing push is a fast-forward; refuses on a real conflict
  resume  F8 remediation: resume the run's session with a landing directive

options
  --sha <sha>              the run's head commit (default: the worktree's HEAD)
  --branch <name>          the run branch (default: resolved from the worktree)
  --default-branch <name>  landing target (default: origin/HEAD, else main, else master)
  --remote <name>          remote name (default: origin)
  --tag <name>             tag that must be reachable (default: tags pointing at --sha)
  --state-dir <dir>        pin state resolution (tests / explicit operator override)
  --repo <dir>             the git worktree to read (default: $PWD)
  --no-fetch               skip `git fetch` before the remote checks
  --json                   emit the verdict as JSON on stdout
  --dry-run                (resume) validate and print the plan; mutate nothing

exit: 0 landed | 10 not landed | 6 refused | 2 usage | 3 environment
EOF
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --slug)           SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --sha)            ARG_SHA="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --branch)         ARG_BRANCH="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --default-branch) ARG_DEFAULT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --remote)         ARG_REMOTE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --tag)            ARG_TAG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --state-dir)      STATE_DIR_OVERRIDE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --repo)           REPO_OVERRIDE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --steer-bin)      STEER_BIN_OVERRIDE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        --no-fetch)       NO_FETCH=1; shift ;;
        --json)           JSON_OUT=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        usage ;;
        *) echo "✗ unknown argument: $1" >&2; usage ;;
    esac
done

case "$SUB" in
    status|verify|merge|resume) : ;;
    *) echo "✗ subcommand must be one of: status verify merge resume" >&2; usage ;;
esac
[ -n "$SLUG" ] || { echo "✗ --slug is required" >&2; usage; }

command -v git >/dev/null 2>&1 || { echo "✗ git not found" >&2; exit 3; }
command -v jq  >/dev/null 2>&1 || { echo "✗ jq not found" >&2; exit 3; }

# ── repo + state resolution ──────────────────────────────────────────────────
# REPO is the worktree we read the run's refs from.  MAIN is the primary
# checkout, resolved through git-common-dir exactly as pwt-manifest.sh does — a
# worktree's .git file points at <main>/.git, so no env var is needed.  Reads are
# safe from either side: worktrees share one object database.
REPO="${REPO_OVERRIDE:-$PWD}"
[ -d "$REPO" ] || { echo "✗ --repo is not a directory: $REPO" >&2; exit 3; }

g() { git -C "$REPO" "$@"; }

g rev-parse --git-dir >/dev/null 2>&1 || { echo "✗ not a git repository: $REPO" >&2; exit 3; }

__resolve_main() {
    local cdir mc
    cdir="$(g rev-parse --git-common-dir 2>/dev/null || echo "")"
    case "$cdir" in
        "") mc="" ;;
        /*) mc="$(dirname "$cdir")" ;;
        *)  mc="$(cd "$REPO/$(dirname "$cdir")" 2>/dev/null && pwd || echo "")" ;;
    esac
    [ -n "$mc" ] || mc="$(g rev-parse --show-toplevel 2>/dev/null || echo "")"
    printf '%s' "$mc"
}
MAIN_CHECKOUT="$(__resolve_main)"

if [ -n "$STATE_DIR_OVERRIDE" ]; then
    STATE_DIR="$STATE_DIR_OVERRIDE"
elif [ -n "$MAIN_CHECKOUT" ] && [ -d "$MAIN_CHECKOUT/.claude/state" ]; then
    STATE_DIR="$MAIN_CHECKOUT/.claude/state"
else
    STATE_DIR="$REPO/.claude/state"
fi

GOAL_FILE="$STATE_DIR/plan-w-team-goal-${SLUG}.json"
MANIFEST_FILE="$STATE_DIR/plan-w-team-manifest-${SLUG}.json"
LANDED_FILE="$STATE_DIR/plan-w-team-landed-${SLUG}.json"
AUDIT_FILE="$STATE_DIR/plan-w-team-land-audit.jsonl"
# base_sha (Governor Contract phase 1, §6b): the commit the run's worktree branched from, so the
# ancestor landing check can tell a genuine landing from an UNDIVERGED branch (SHA==default tip,
# no unique commits) — which git alone reads as vacuously "landed".
BASE_SHA=""
[ -f "$MANIFEST_FILE" ] && BASE_SHA=$(jq -r '.base_sha // ""' "$MANIFEST_FILE" 2>/dev/null || echo "")

ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── the predicate ────────────────────────────────────────────────────────────
# Populates: SHA BRANCH DEFAULT_BRANCH REMOTE DEFAULT_REF LANDED_SHA
#            MERGED MERGED_VIA TAGS TAG_REACHABLE PUSHED VERDICT REASON
__evaluate() {
    REMOTE="${ARG_REMOTE:-origin}"
    g remote get-url "$REMOTE" >/dev/null 2>&1 && HAS_REMOTE=1 || HAS_REMOTE=0

    # default branch: explicit > remote HEAD > main > master > "main"
    if [ -n "$ARG_DEFAULT" ]; then
        DEFAULT_BRANCH="$ARG_DEFAULT"
    else
        DEFAULT_BRANCH="$(g symbolic-ref --short "refs/remotes/${REMOTE}/HEAD" 2>/dev/null | sed "s|^${REMOTE}/||")"
        if [ -z "$DEFAULT_BRANCH" ]; then
            if g show-ref --verify --quiet refs/heads/main; then
                DEFAULT_BRANCH="main"
            elif g show-ref --verify --quiet refs/heads/master; then
                DEFAULT_BRANCH="master"
            else
                DEFAULT_BRANCH="main"
            fi
        fi
    fi

    SHA="${ARG_SHA:-$(g rev-parse HEAD 2>/dev/null || echo "")}"
    BRANCH="${ARG_BRANCH:-$(g rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}"
    if [ -z "$SHA" ]; then
        VERDICT="NOT_LANDED"; REASON="NO_HEAD: could not resolve a head commit in $REPO"
        MERGED=false; MERGED_VIA=""; PUSHED=false; TAG_REACHABLE=""; TAGS=""
        LANDED_SHA=""; DEFAULT_REF=""
        return 0
    fi

    # Refresh the remote view unless told not to.  A stale origin/<default> is the
    # difference between "not pushed" and "pushed 10 minutes ago" — never guess.
    if [ "$HAS_REMOTE" = "1" ] && [ "$NO_FETCH" != "1" ]; then
        g fetch --quiet "$REMOTE" "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
        g fetch --quiet --tags "$REMOTE" >/dev/null 2>&1 || true
    fi

    REMOTE_REF="refs/remotes/${REMOTE}/${DEFAULT_BRANCH}"
    LOCAL_REF="refs/heads/${DEFAULT_BRANCH}"
    HAS_REMOTE_REF=0; HAS_LOCAL_REF=0
    g show-ref --verify --quiet "$REMOTE_REF" && HAS_REMOTE_REF=1
    g show-ref --verify --quiet "$LOCAL_REF"  && HAS_LOCAL_REF=1

    # ── merged ───────────────────────────────────────────────────────────────
    # Two landing shapes must both count, or the gate would refuse the pipeline's
    # own sanctioned paths:
    #   ancestry    §6h-0 verified fast-forward (HEAD becomes the default tip)
    #   tree-equal  §6g-ter `gh pr merge --squash` (a NEW commit carries the work,
    #               so the branch tip is not an ancestor of anything)
    MERGED=false; MERGED_VIA=""; DEFAULT_REF=""; LANDED_SHA=""
    for ref in "$REMOTE_REF" "$LOCAL_REF"; do
        case "$ref" in
            "$REMOTE_REF") [ "$HAS_REMOTE_REF" = "1" ] || continue ;;
            "$LOCAL_REF")  [ "$HAS_LOCAL_REF"  = "1" ] || continue ;;
        esac
        if g merge-base --is-ancestor "$SHA" "$ref" 2>/dev/null; then
            # UNDIVERGED guard (§6b, 2026-08-29): `--is-ancestor` is vacuously TRUE when SHA==ref
            # (a branch that never diverged), so a run that landed NOTHING reported LANDED — the false
            # positive that made a supervisor's watcher exit on false success. When the manifest
            # recorded a base_sha, require ≥1 commit beyond it (a real landing puts the run's commits
            # on the default branch). No base_sha → today's behaviour (do not regress older runs).
            # Kill switch: PWT_LAND_ALLOW_UNDIVERGED=1.
            if [ "${PWT_LAND_ALLOW_UNDIVERGED:-0}" != "1" ] && [ -n "$BASE_SHA" ]; then
                _ahead_base=$(g rev-list --count "${BASE_SHA}..${SHA}" 2>/dev/null || echo "")
                if [ "${_ahead_base:-0}" = "0" ]; then
                    VERDICT="NOT_LANDED"
                    REASON="UNDIVERGED: ${SHA} has no commit beyond the run's base ${BASE_SHA} — nothing was landed"
                    MERGED=false; MERGED_VIA=""; PUSHED=false; TAG_REACHABLE=""; TAGS=""; DEFAULT_REF="$ref"; LANDED_SHA=""
                    return 0
                fi
            fi
            MERGED=true; MERGED_VIA="ancestor"; DEFAULT_REF="$ref"; LANDED_SHA="$SHA"
            break
        fi
        if g diff --quiet "$ref" "$SHA" -- 2>/dev/null; then
            MERGED=true; MERGED_VIA="tree-equal"; DEFAULT_REF="$ref"
            LANDED_SHA="$(g rev-parse "$ref" 2>/dev/null || echo "")"
            break
        fi
    done

    if [ "$MERGED" != "true" ]; then
        VERDICT="NOT_LANDED"
        REASON="NOT_MERGED: ${SHA} is neither an ancestor of ${DEFAULT_BRANCH} nor tree-identical to it (checked ${REMOTE}/${DEFAULT_BRANCH} and local ${DEFAULT_BRANCH})"
        PUSHED=false; TAG_REACHABLE=""; TAGS=""
        return 0
    fi

    # ── tag reachability ─────────────────────────────────────────────────────
    if [ -n "$ARG_TAG" ]; then
        TAGS="$ARG_TAG"
    else
        TAGS="$(g tag --points-at "$SHA" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    fi
    TAG_REACHABLE="n/a"
    if [ -n "$TAGS" ]; then
        TAG_REACHABLE="true"
        for t in $TAGS; do
            if ! g merge-base --is-ancestor "${t}^{commit}" "$DEFAULT_REF" 2>/dev/null; then
                if [ "$MERGED_VIA" = "tree-equal" ]; then
                    # A squash landing legitimately leaves the tag on the pre-squash
                    # commit; the CONTENT is on the default branch, which is what the
                    # gate is actually protecting.  Record it rather than failing.
                    TAG_REACHABLE="n/a-squash"
                else
                    TAG_REACHABLE="false"
                    VERDICT="NOT_LANDED"
                    REASON="TAG_UNREACHABLE: tag ${t} is not reachable from ${DEFAULT_BRANCH}"
                    PUSHED=false
                    return 0
                fi
            fi
        done
    fi

    # ── pushed ───────────────────────────────────────────────────────────────
    if [ "$HAS_REMOTE" != "1" ]; then
        PUSHED="n/a"
    elif [ "$HAS_REMOTE_REF" != "1" ]; then
        PUSHED=false
        VERDICT="NOT_LANDED"
        REASON="NOT_PUSHED: ${REMOTE}/${DEFAULT_BRANCH} does not exist — nothing was pushed"
        return 0
    elif g merge-base --is-ancestor "$LANDED_SHA" "$REMOTE_REF" 2>/dev/null; then
        PUSHED=true
    else
        PUSHED=false
        VERDICT="NOT_LANDED"
        REASON="NOT_PUSHED: ${LANDED_SHA} is on local ${DEFAULT_BRANCH} but not on ${REMOTE}/${DEFAULT_BRANCH}"
        return 0
    fi

    VERDICT="LANDED"
    REASON="landed=${LANDED_SHA} on ${DEFAULT_BRANCH} (merged_via=${MERGED_VIA}, pushed=${PUSHED}, tags=${TAGS:-none}, tag_reachable=${TAG_REACHABLE})"
    return 0
}

# Informational only — never part of the verdict.  `ahead=0` on a LANDED verdict
# means one of two very different things: the run landed by fast-forward, or the
# run produced nothing to land.  Distinguishing those is §6g's empty-ship
# loop-breaker's job, not this gate's; recording the number keeps the verdict
# self-explaining instead of silently ambiguous.
__commits_ahead() {
    [ -n "${DEFAULT_REF:-}" ] && [ -n "${SHA:-}" ] || { printf '%s' ""; return 0; }
    g rev-list --count "${DEFAULT_REF}..${SHA}" 2>/dev/null || printf '%s' ""
}

__verdict_json() {
    jq -n \
        --arg schema "$SCHEMA" \
        --arg slug "$SLUG" \
        --arg verdict "$VERDICT" \
        --arg reason "$REASON" \
        --arg sha "$SHA" \
        --arg landed_sha "$LANDED_SHA" \
        --arg branch "$BRANCH" \
        --arg default_branch "$DEFAULT_BRANCH" \
        --arg default_ref "$DEFAULT_REF" \
        --arg remote "$REMOTE" \
        --arg merged_via "$MERGED_VIA" \
        --arg tags "$TAGS" \
        --arg tag_reachable "$TAG_REACHABLE" \
        --arg pushed "$PUSHED" \
        --arg merged "$MERGED" \
        --arg commits_ahead "$(__commits_ahead)" \
        --arg ts "$(ts_now)" \
        '{schema:$schema, slug:$slug, verdict:$verdict, reason:$reason,
          sha:$sha, landed_sha:$landed_sha, branch:$branch,
          default_branch:$default_branch, default_ref:$default_ref, remote:$remote,
          merged:$merged, merged_via:$merged_via,
          tags:$tags, tag_reachable:$tag_reachable, pushed:$pushed,
          commits_ahead:$commits_ahead, verified_at:$ts}'
}

__audit() {
    # Best-effort; an audit failure must never change a verdict.
    local action="$1" detail="$2" line
    line=$(jq -nc --arg ts "$(ts_now)" --arg slug "$SLUG" --arg action "$action" \
                  --arg verdict "${VERDICT:-}" --arg detail "$detail" \
                  --arg sha "${SHA:-}" --arg landed_sha "${LANDED_SHA:-}" \
        '{ts:$ts, slug:$slug, action:$action, verdict:$verdict, sha:$sha, landed_sha:$landed_sha, detail:$detail}' 2>/dev/null) || return 0
    mkdir -p "$(dirname "$AUDIT_FILE")" 2>/dev/null || return 0
    printf '%s\n' "$line" >> "$AUDIT_FILE" 2>/dev/null || true
}

__emit_and_exit() {
    if [ "$JSON_OUT" = "1" ]; then
        __verdict_json
    elif [ "$VERDICT" = "LANDED" ]; then
        echo "✅ LANDED slug=$SLUG landed=$LANDED_SHA branch=$BRANCH default=$DEFAULT_BRANCH merged_via=$MERGED_VIA pushed=$PUSHED tags=${TAGS:-none}"
    else
        echo "✗ NOT LANDED slug=$SLUG — $REASON"
    fi
    [ "$VERDICT" = "LANDED" ] && exit 0
    exit 10
}

# ─────────────────────────────────────────────────────────────────────────────
# status
# ─────────────────────────────────────────────────────────────────────────────
if [ "$SUB" = "status" ]; then
    __evaluate
    __emit_and_exit
fi

# ─────────────────────────────────────────────────────────────────────────────
# verify — status, plus the artifact on a TRUE verdict only
# ─────────────────────────────────────────────────────────────────────────────
if [ "$SUB" = "verify" ]; then
    __evaluate
    if [ "$VERDICT" = "LANDED" ]; then
        ART="$(__verdict_json)"
        if [ -n "$ART" ]; then
            # Dual-write, mirroring the goal-state's own dual-seed: the evaluator and
            # the watcher may read from EITHER the worktree's state dir or MAIN's,
            # depending on which side they run from.  An artifact only one of them can
            # see is the same blindness the 2026-07-31 seed-path incident produced.
            for d in "$STATE_DIR" "$REPO/.claude/state"; do
                [ -n "$d" ] || continue
                mkdir -p "$d" 2>/dev/null || continue
                printf '%s\n' "$ART" > "$d/plan-w-team-landed-${SLUG}.json" 2>/dev/null || true
            done
        fi
        __audit "verify" "artifact written to $LANDED_FILE"
    else
        # Never leave a stale PASS behind a now-false predicate.
        rm -f "$LANDED_FILE" "$REPO/.claude/state/plan-w-team-landed-${SLUG}.json" 2>/dev/null || true
        __audit "verify" "not landed — artifact absent"
    fi
    __emit_and_exit
fi

# ─────────────────────────────────────────────────────────────────────────────
# merge — dirty-tree-safe integration of the default branch into the run branch,
# so the subsequent push is a FAST-FORWARD and never a force-push.
#
# This is CODE and not prose on purpose.  The addendum's AC8 requires the
# dirty-tree case to be "asserted by content comparison", and prose in a stage
# file cannot be asserted — it can only be re-typed, differently, by the next
# reader.  The 2026-08-19 recovery did this by hand ("merge → dirty-tree caution
# → …"), which is exactly the undocumented-runbook-in-one-supervisor's-context
# problem RC4 names.
#
# THE STASH STACK IS SHARED across every worktree of the repo, and other Claude
# sessions push and pop it concurrently.  So: never bare `git stash`, never
# `git stash pop`.  Push with a unique tag, capture the entry's SHA immediately,
# APPLY by SHA, and drop by re-finding the entry by tag (indices shift when a
# sibling session pushes).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$SUB" = "merge" ]; then
    if [ -n "$ARG_DEFAULT" ]; then
        MERGE_TARGET="$ARG_DEFAULT"
    else
        __evaluate
        MERGE_TARGET="$DEFAULT_BRANCH"
    fi

    STASH_TAG="pwt-land-${SLUG}-$$"
    STASH_SHA=""
    if [ -n "$(g -c core.quotePath=false status --porcelain 2>/dev/null)" ]; then
        if g stash push -u -m "$STASH_TAG" >/dev/null 2>&1; then
            STASH_SHA=$(g stash list --format='%H %gs' 2>/dev/null | grep -F "$STASH_TAG" | head -1 | cut -d' ' -f1)
            if [ -z "$STASH_SHA" ]; then
                # Pushed but unfindable: restoring is impossible by SHA, so refuse
                # loudly rather than merging on top of work we cannot give back.
                echo "✗ stashed dirt as '$STASH_TAG' but could not resolve its SHA — refusing to merge." >&2
                echo "  Recover manually: git stash list | grep $STASH_TAG" >&2
                exit 3
            fi
            echo "  stashed pre-existing dirt as $STASH_TAG (${STASH_SHA})"
        fi
    fi

    if g merge "$MERGE_TARGET" --no-edit >/dev/null 2>&1; then
        MERGE_RC=0
    else
        MERGE_RC=1
        g merge --abort >/dev/null 2>&1 || true
    fi

    if [ -n "$STASH_SHA" ]; then
        # apply, never pop — a pop on a shared stack can drop a sibling's entry
        if g stash apply "$STASH_SHA" >/dev/null 2>&1; then
            STASH_IDX=$(g stash list --format='%gd %gs' 2>/dev/null | grep -F "$STASH_TAG" | head -1 | cut -d' ' -f1)
            [ -n "$STASH_IDX" ] && g stash drop "$STASH_IDX" >/dev/null 2>&1 || true
            echo "  restored pre-existing dirt from $STASH_TAG"
        else
            echo "⚠ could not re-apply $STASH_TAG automatically — your work is SAFE in the stash." >&2
            echo "  Recover with: git stash list | grep $STASH_TAG   then: git stash apply <sha>" >&2
            __audit "merge" "stash-apply-failed tag=$STASH_TAG sha=$STASH_SHA"
            exit 3
        fi
    fi

    if [ "$MERGE_RC" != "0" ]; then
        echo "✗ merge of '$MERGE_TARGET' hit a real conflict — aborted, tree restored." >&2
        echo "  Resolve by hand inside the worktree, then re-run the landing." >&2
        __audit "merge" "conflict target=$MERGE_TARGET"
        exit 10
    fi

    echo "✅ integrated '$MERGE_TARGET' — the landing push is now a fast-forward"
    __audit "merge" "ok target=$MERGE_TARGET"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# resume — F8 remediation.  Ordering IS the safety property: every refusal is
# evaluated BEFORE anything is touched, so a refused resume leaves the run
# completely untouched.
# ─────────────────────────────────────────────────────────────────────────────
__evaluate

if [ "$VERDICT" = "LANDED" ]; then
    echo "✗ refusing to resume: slug=$SLUG is ALREADY LANDED (landed=$LANDED_SHA on $DEFAULT_BRANCH)." >&2
    echo "  Nothing to remediate. Run 'plan-w-team-land.sh status --slug $SLUG' to see the verdict." >&2
    __audit "resume-refused" "already-landed"
    exit 6
fi

if [ -f "$GOAL_FILE" ]; then
    EXISTING_TERMINAL=$(jq -r '.terminal_state // ""' "$GOAL_FILE" 2>/dev/null || echo "")
    if [ -n "$EXISTING_TERMINAL" ] && [ "$EXISTING_TERMINAL" != "null" ]; then
        echo "✗ refusing to resume: slug=$SLUG is already terminal (terminal_state=$EXISTING_TERMINAL)." >&2
        echo "  A terminal run is not remediated by resuming it — land it by hand, or start a new run." >&2
        __audit "resume-refused" "already-terminal:$EXISTING_TERMINAL"
        exit 6
    fi
    WORKER_SID=$(jq -r '.worker_sid // ""' "$GOAL_FILE" 2>/dev/null || echo "")
else
    WORKER_SID=""
fi

if [ -z "$WORKER_SID" ]; then
    echo "✗ refusing to resume: no worker_sid recorded for slug=$SLUG (looked in $GOAL_FILE)." >&2
    echo "  Without the 36-char session UUID a resume strands at a picker — see pwt-steer.sh W6." >&2
    __audit "resume-refused" "no-worker-sid"
    exit 6
fi

WORKTREE_PATH=""
[ -f "$MANIFEST_FILE" ] && WORKTREE_PATH=$(jq -r '.worktree_path // ""' "$MANIFEST_FILE" 2>/dev/null || echo "")

STEER_BIN="${STEER_BIN_OVERRIDE:-$MAIN_CHECKOUT/.claude/scripts/pwt-steer.sh}"
if [ ! -x "$STEER_BIN" ]; then
    echo "✗ refusing to resume: pwt-steer.sh not executable at $STEER_BIN" >&2
    echo "  The resume mechanics (36-char UUID, resume-from-inside-the-worktree, delivery" >&2
    echo "  verification, watcher teardown) live there and are NOT reimplemented here." >&2
    __audit "resume-refused" "no-steer-bin"
    exit 6
fi

LAND_DIRECTIVE="LANDING DIRECTIVE (plan-w-team-land.sh, RC4/F8). This run completed its \
pipeline but did NOT land: ${REASON}. Do ONLY the landing, then stop. \
(1) From inside the run's worktree, integrate the default branch (git merge ${DEFAULT_BRANCH}) \
so the landing is a fast-forward, never a force-push; if a pre-existing modified file \
collides, stash it with a unique tag, merge, restore it, and verify its content is unchanged \
— never discard user dirt. (2) Assert origin/${DEFAULT_BRANCH} is an ancestor of HEAD. \
(3) git push origin HEAD:${DEFAULT_BRANCH} and push the tag. (4) Re-verify by ancestor check \
rather than trusting the push exit code. (5) Run \
.claude/scripts/plan-w-team-land.sh verify --slug ${SLUG} and emit the landed=<sha> anchor via \
.claude/scripts/plan-w-team-surface-status.sh ${SLUG} ship. (6) Re-emit the retro-complete \
status block so your OWN Stop evaluator flips the goal terminal — do not write terminal_state \
by hand, the lane guard refuses that as self-termination spoofing."

if [ "$DRY_RUN" = "1" ]; then
    echo "plan-w-team-land.sh resume — DRY RUN (nothing mutated)"
    echo "  slug:          $SLUG"
    echo "  verdict:       $VERDICT ($REASON)"
    echo "  worker_sid:    $WORKER_SID"
    echo "  worktree:      ${WORKTREE_PATH:-<unresolved — pwt-steer will resolve it>}"
    echo "  steer bin:     $STEER_BIN"
    echo "  would run:     $STEER_BIN --slug $SLUG --env PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 --message <landing directive>"
    echo "  directive:     $LAND_DIRECTIVE"
    __audit "resume-dry-run" "planned"
    exit 0
fi

echo "→ resuming slug=$SLUG worker=${WORKER_SID:0:8} with the landing directive"
"$STEER_BIN" --slug "$SLUG" \
    --env PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 \
    --message "$LAND_DIRECTIVE"
STEER_RC=$?
__audit "resume" "pwt-steer rc=$STEER_RC"

if [ "$STEER_RC" = "0" ]; then
    echo "✅ landing directive delivered — the resumed session lands and flips its own terminal."
    echo "   Re-arm the watcher, then confirm with:"
    echo "     .claude/scripts/plan-w-team-land.sh status --slug $SLUG"
    exit 0
fi

echo "⚠ pwt-steer.sh exited $STEER_RC — see its output above for the attribution policy." >&2
exit "$STEER_RC"
