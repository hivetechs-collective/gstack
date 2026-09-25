#!/bin/bash
# plan-w-team Surface Status — emits the standard ```status block for /goal evaluator
#
# Called by every lead-driven stage at end-of-stage, plus the retro at completion.
# The Haiku evaluator behind /goal (PWT-T5) cannot call tools; this helper is its
# primary sensor for judging pipeline progress.
#
# Spec: docs/specs/pwt-t5-goal-wrapper.md
# Schema: shared/goal-conditions.md §Status-Block Schema
# Kill switch: PLAN_W_TEAM_DISABLE_GOAL=1 (does NOT silence this helper; the helper
#              is observability, the kill switch only affects /goal invocation in
#              the skill md top-of-pipeline section)
#
# Usage: plan-w-team-surface-status.sh <slug> [stage_label]
# Exit:  0 = block emitted to stdout
#        1 = invocation error (missing slug)

set -u

usage() {
    cat >&2 <<EOF
Usage: $0 <slug> [stage_label]
Emits a fenced \`\`\`status block to stdout summarizing /plan-w-team run state
for the /goal evaluator. Reads workflow lock + supervisor-actions log + fleet log.
Graceful: any missing state surfaces as null / empty fields.
EOF
}

SLUG="${1:-}"
STAGE="${2:-unknown}"

if [ -z "$SLUG" ]; then
    usage
    exit 1
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
FALLBACK_STATE_DIR="$PROJECT_ROOT/.claude/state"
PWD_STATE_DIR="$PWD/.claude/state"

# Worktree-aware state lookup: prefer $PWD/.claude/state when /plan-w-team is
# running in a worktree distinct from the project root. Fall back to the
# canonical project root state dir otherwise. Picks whichever holds the active
# workflow lock for this SLUG; if neither does, defaults to $PWD path (where a
# new run will write its state). See 2026-05-20 holistic-check retro: state
# written in a worktree was invisible to status emitters and goal evaluator
# running in the main checkout.
if [ -d "$PWD_STATE_DIR/plan-w-team-workflow-${SLUG}.lock" ] && [ "$PWD_STATE_DIR" != "$FALLBACK_STATE_DIR" ]; then
    STATE_DIR="$PWD_STATE_DIR"
elif [ -d "$FALLBACK_STATE_DIR/plan-w-team-workflow-${SLUG}.lock" ]; then
    STATE_DIR="$FALLBACK_STATE_DIR"
elif [ -d "$PWD_STATE_DIR" ] && [ "$PWD_STATE_DIR" != "$FALLBACK_STATE_DIR" ]; then
    STATE_DIR="$PWD_STATE_DIR"
else
    STATE_DIR="$FALLBACK_STATE_DIR"
fi

LOCK_DIR="$STATE_DIR/plan-w-team-workflow-${SLUG}.lock"

# Kill-switch bypass ledger (recursive-followup row 27): this is the per-stage
# chokepoint every stage already calls, so snapshotting the session's active
# kill switches here covers the whole family with no per-gate edit. The first
# snapshot also writes the ledger's init row (tamper evidence for the retro).
# Resolved beside THIS script (not $PROJECT_ROOT) so a worktree run never calls
# the main checkout's copy. Every byte of output is discarded and failure is
# ignored: the status block below must stay byte-identical — the goal evaluator
# reads it.
"$(dirname "$0")/plan-w-team-killswitch-ledger.sh" snapshot \
    --slug "$SLUG" --state-dir "$STATE_DIR" --site "$STAGE" >/dev/null 2>&1 || true

SUP_LOG="$STATE_DIR/plan-w-team-supervisor-actions-${SLUG}.jsonl"
FLEET_LOG="$STATE_DIR/plan-w-team-fleet-${SLUG}.jsonl"
QUERY_SH="$PROJECT_ROOT/.claude/scripts/plan-w-team-fleet-query.sh"

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Mirror the stage into the canonical run manifest (main-checkout-relative), so a
# supervisor/human polling `pwt-status.sh` sees the live stage without reaching
# into the worktree. This is the deterministic per-stage chokepoint — every stage
# already calls this emitter, so the manifest stays current with no extra worker
# step. Best-effort: never let manifest bookkeeping affect the status block.
__MANIFEST_SH="$PROJECT_ROOT/.claude/scripts/pwt-manifest.sh"
if [ -x "$__MANIFEST_SH" ]; then
    __WT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    "$__MANIFEST_SH" set --slug "$SLUG" --stage "$STAGE" \
        ${__WT_ROOT:+--worktree "$__WT_ROOT"} >/dev/null 2>&1 || true
fi

# 0 when the workflow lock's `owner` record ($1) is this caller — the pre-flight's
# re-entry test (row 191): the same session id, or the same claude process, i.e.
# `kind=claude` whose pid= is this tool shell's CLAUDE_PID and whose start= (when
# recorded) is still that pid's start time (a reused pid is someone else). A symlinked
# or missing record is nobody's.
__lk_owner_is_caller() {
    local f="$1" o_sid o_pid o_start o_kind cur
    [ -f "$f" ] && [ ! -L "$f" ] || return 1
    o_sid="$(sed -n 's/^session=//p' "$f" 2>/dev/null | head -n 1)"
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ "$o_sid" = "$CLAUDE_CODE_SESSION_ID" ]; then
        return 0
    fi
    o_kind="$(sed -n 's/^kind=//p' "$f" 2>/dev/null | head -n 1)"
    o_pid="$(sed -n 's/^pid=//p' "$f" 2>/dev/null | head -n 1)"
    o_start="$(sed -n 's/^start=//p' "$f" 2>/dev/null | head -n 1)"
    # a kind=parent owner is matched by session id only (an unidentified parent may host
    # more than one lead's shells), and only a decimal pid above 1 names one process
    [ "$o_kind" = "claude" ] || return 1
    case "$o_pid" in ""|0*|1|*[!0-9]*) return 1 ;; esac
    [ "$o_pid" = "${CLAUDE_PID:-}" ] || return 1
    [ -n "$o_start" ] || return 0
    cur="$(TZ=UTC LC_ALL=C ps -o lstart= -p "$o_pid" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')"
    [ "$cur" = "$o_start" ]
}

# Workflow lock state
if [ -d "$LOCK_DIR" ]; then
    __LK_OWN="$LOCK_DIR/owner"
    if [ "$STAGE" = "retro-complete" ]; then
        LOCK_STATE="done"
        # Release point (recursive-followup row 191). The pre-flight lock has a durable
        # owner and no EXIT trap, so the run's end is where it lets go: `released` lets
        # another session take the SLUG while this lead lives on. The dir stays, so a
        # re-emit still reads `done`; the same session's next pre-flight re-activates it.
        # Only the owner releases: a late re-emit from a session that no longer holds
        # the lock (another session took it over since) leaves it held. A lock whose
        # owner record names no session (a legacy `pid`-only lock, or a lead with no
        # session id) is released by its run's end, as before.
        __LK_OSID=""
        [ -f "$__LK_OWN" ] && __LK_OSID="$(sed -n 's/^session=//p' "$__LK_OWN" 2>/dev/null | head -n 1)"
        if [ -z "$__LK_OSID" ] || __lk_owner_is_caller "$__LK_OWN"; then
            printf 'released\n' >| "$LOCK_DIR/state" 2>/dev/null || true
        fi
    else
        LOCK_STATE="active"
        # Heartbeat (row 191): the owner's own stage emissions keep `owner`
        # heartbeat= current, so the pre-flight asks the live-session oracle about the
        # owner only once it has emitted no stage for the whole stale bound. Only the
        # recorded owner (same session, or same claude process) refreshes it, never a
        # released lock; silent, fail-open.
        if [ "$(cat "$LOCK_DIR/state" 2>/dev/null)" != "released" ] \
           && __lk_owner_is_caller "$__LK_OWN"; then
            __LK_TMP="$LOCK_DIR/.owner.$$"
            if sed "s/^heartbeat=.*/heartbeat=$(date +%s)/" "$__LK_OWN" > "$__LK_TMP" 2>/dev/null; then
                mv -f "$__LK_TMP" "$__LK_OWN" 2>/dev/null || rm -f "$__LK_TMP" 2>/dev/null
            else
                rm -f "$__LK_TMP" 2>/dev/null
            fi
        fi
    fi
else
    LOCK_STATE="missing"
fi

# Ship-readiness gate — search supervisor log for a recent ship marker, otherwise n/a
SHIP_GATE="n/a"
if [ -f "$SUP_LOG" ]; then
    if grep -q '"call_site":"ship-readiness-gate"' "$SUP_LOG" 2>/dev/null; then
        SHIP_GATE=$(jq -r 'select(.event=="route_delegation" and .call_site=="ship-readiness-gate") | .router_choice' "$SUP_LOG" 2>/dev/null | tail -1 || echo "n/a")
        [ -z "$SHIP_GATE" ] && SHIP_GATE="n/a"
    elif [ "$STAGE" = "ship" ] || [ "$STAGE" = "post-ship" ] || [ "$STAGE" = "retro-complete" ]; then
        SHIP_GATE="pending"
    fi
fi

# Fleet summary
if [ -f "$FLEET_LOG" ] && [ -x "$QUERY_SH" ] && command -v jq >/dev/null 2>&1; then
    FLEET=$("$QUERY_SH" summary "$SLUG" 2>/dev/null || echo '{}')
    # Guard against empty/malformed
    echo "$FLEET" | jq -e . >/dev/null 2>&1 || FLEET='{}'
else
    FLEET='{}'
fi

# Pending escalations + low-confidence routes from supervisor-actions log
#
# Fix 4 (task #36, harden-plan-w-team-...): pending_escalations is computed by
# per-call_site "last row wins in FILE ORDER" pairing of escalation vs
# escalation_resolved rows — ts is metadata only, never an ordering key (repo
# timestamps are 1-second granularity; a same-second resolve-then-re-escalate
# must re-pend). For the four HARD-GATE call_sites, a resolution row counts
# ONLY when its reason is in the closed enum (user_ack / auto_approve_env);
# any other reason is IGNORED (the site's prior state, if any, is unchanged) —
# this makes escalation_resolved spoof-resistant for the sites that matter
# most. Non-hard-gate sites resolve on any escalation_resolved row.
#
# Parse is deliberately per-line resilient: `jq -R 'fromjson? // empty'`
# drops a single corrupt JSONL line instead of failing `jq -s` for the WHOLE
# file, which previously blanked pending_escalations to '[]' — a fail-OPEN
# outcome for what is otherwise a hard-gate signal. Output shape is
# unchanged (sorted unique array) so legacy logs (escalation rows only, no
# resolution rows) render byte-identically.
PENDING_ESC='[]'
LOW_CONF=0
if [ -f "$SUP_LOG" ] && command -v jq >/dev/null 2>&1; then
    PENDING_ESC=$(jq -R 'fromjson? // empty' "$SUP_LOG" 2>/dev/null | jq -s '
        def hard_gate_sites: ["push-ack","secret-scan-allow","scope-unlock-for-drift","credential-wall","regression-halt"];
        def valid_reason: (. == "user_ack" or . == "auto_approve_env");
        [ .[] | select((.event=="escalation" or .event=="escalation_resolved")
                       and (.call_site | type == "string")) ]
        | reduce .[] as $row ({};
            if $row.event == "escalation" then
                .[$row.call_site] = "pending"
            elif (hard_gate_sites | index($row.call_site)) then
                if ($row.reason | valid_reason) then
                    .[$row.call_site] = "resolved"
                else
                    .
                end
            else
                .[$row.call_site] = "resolved"
            end
          )
        | [ to_entries[] | select(.value == "pending") | .key ]
        | unique
    ' 2>/dev/null) || PENDING_ESC='[]'
    [ -z "$PENDING_ESC" ] && PENDING_ESC='[]'
    # Same per-line resilient parse as pending_escalations (Step-5 fix, G1): the
    # whole-file `jq -s` form blanked this to 0 on one corrupt line — fail-OPEN
    # for the "3 consecutive low-confidence decisions" goal HALT signal.
    LOW_CONF=$(jq -R 'fromjson? // empty' "$SUP_LOG" 2>/dev/null | jq -s '[.[] | select(.event=="route_delegation" and .router_confidence=="low")] | length' 2>/dev/null || echo 0)
    [ -z "$LOW_CONF" ] && LOW_CONF=0
fi

# Landing anchor (F6, RC4 2026-08-19) — the sha on the default branch that carries
# this run's work, or empty when the run has not landed.
#
# READ, never asserted: the value comes from the deterministic artifact that
# `plan-w-team-land.sh verify` writes, and that script recomputes the predicate
# from git before writing.  This emitter cannot mint a landing, which is the whole
# point — the RC4 failure was a run that LOOKED finished on every observability
# surface while its 31 commits sat unmerged, unpushed and untagged on a worktree
# branch.  Both state dirs are consulted for the same reason `verify` dual-writes
# to them: worktree-side and MAIN-side readers see different halves.
LANDED_SHA=""
for __ld in "$STATE_DIR/plan-w-team-landed-${SLUG}.json" \
            "$FALLBACK_STATE_DIR/plan-w-team-landed-${SLUG}.json" \
            "$PWD_STATE_DIR/plan-w-team-landed-${SLUG}.json"; do
    [ -f "$__ld" ] || continue
    if command -v jq >/dev/null 2>&1; then
        __v=$(jq -r 'select(.verdict=="LANDED") | .landed_sha // ""' "$__ld" 2>/dev/null || echo "")
        __s=$(jq -r '.slug // ""' "$__ld" 2>/dev/null || echo "")
        # A foreign-slug artifact must never be reported as this run's landing.
        if [ -n "$__v" ] && [ "$__s" = "$SLUG" ]; then
            LANDED_SHA="$__v"
            break
        fi
    fi
done

# Emit the fenced status block — JSON is built via jq so quoting is safe
STATUS_JSON=$(jq -n \
    --arg slug "$SLUG" \
    --arg stage "$STAGE" \
    --arg ts "$TS" \
    --arg lock "$LOCK_STATE" \
    --arg ship "$SHIP_GATE" \
    --arg landed "$LANDED_SHA" \
    --argjson fleet "$FLEET" \
    --argjson esc "$PENDING_ESC" \
    --argjson low "$LOW_CONF" \
    '{slug:$slug, stage:$stage, ts:$ts, workflow_lock:$lock, ship_readiness_gate:$ship, landed:(if $landed == "" then null else $landed end), fleet:$fleet, pending_escalations:$esc, low_confidence_routes:$low}' \
    2>/dev/null) || STATUS_JSON='{"slug":"'"$SLUG"'","stage":"'"$STAGE"'","ts":"'"$TS"'","error":"jq-failed"}'

# The grep-able anchor the addendum specifies, on its own line so a plain
# `grep -o 'landed=[0-9a-f]*'` finds it without JSON parsing.  Printed ONLY when a
# real landing artifact backs it.
[ -n "$LANDED_SHA" ] && printf '\nlanded=%s\n' "$LANDED_SHA"

printf '\n```status\n%s\n```\n' "$STATUS_JSON"

exit 0
