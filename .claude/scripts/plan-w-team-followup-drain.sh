#!/usr/bin/env bash
# plan-w-team-followup-drain.sh — spawn ONE /plan-w-team worker against the
# oldest open row in the recursive-followup ledger.
#
# WHY THIS IS ALLOWED TO BE SCHEDULED. A previous scheduled timer (the friction-log
# triage nudge) was removed over the "actor problem": a scheduled WRITER with no
# actor is theatre — it appends a reminder nobody executes. This is different. A
# `pwt-goal.sh --worker-only` run IS an actor: it picks up one row and works it.
# That distinction is the entire justification; do not generalise it into
# scheduled digests or notifications.
#
# DEFAULT OFF. Enable either way (the file form exists because launchd does not
# reliably inherit an interactive shell's environment):
#   PWT_FOLLOWUP_DRAIN_ENABLE=1
#   touch .claude/state/pwt-followup-drain-enabled
#
# ONE row per invocation, never a batch. The ledger is a backlog of deferrals,
# most of them LOW severity; draining it in parallel would spend a weekly Max
# budget on the least important work in the repo.
#
# CAPACITY CHAIN — every gate must return SPAWN_OK before anything spawns:
#   ram-budget.sh --bg-only   RAM headroom for another bg session (~1.5-2 GB)
#   disk-budget.sh            free-GB headroom for another worktree (~2.5 GB)
#   pwt-fair-share.sh         this repo's share of machine-wide worker capacity
# Plus: refuse if a worker for this repo is already live (no self-competition),
# and refuse inside a worker (PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1) — that is the
# PWT-DS2 cascade boundary and this script must never be the thing that crosses it.
#
# Usage:
#   plan-w-team-followup-drain.sh --dry-run   report the decision, spawn nothing
#   plan-w-team-followup-drain.sh             spawn if every gate passes
#   plan-w-team-followup-drain.sh --status    print enabled/disabled + next row
#
# Fail-closed on spawning, fail-open on erroring: any unexpected condition
# results in NO spawn and exit 0, so a scheduled invocation never pages you.

set -u

REPO_ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPTS="$REPO_ROOT/.claude/scripts"
LEDGER="$REPO_ROOT/.claude/state/plan-w-team-recursive-followups.jsonl"
MARKER="$REPO_ROOT/.claude/state/pwt-followup-drain-enabled"
MODE="${1:-run}"

_say() { printf '[followup-drain] %s\n' "$1" >&2; }
_skip() { _say "SKIP — $1"; exit 0; }

# ── enabled? ────────────────────────────────────────────────────────────────
ENABLED=0
[ "${PWT_FOLLOWUP_DRAIN_ENABLE:-0}" = "1" ] && ENABLED=1
[ -f "$MARKER" ] && ENABLED=1

# ── cascade boundary ────────────────────────────────────────────────────────
# A worker must never spawn another worker from here. PWT-DS2 exists because of
# four recorded production cascades; this script is additive to that guard, not
# an exception to it.
if [ "${PLAN_W_TEAM_DISABLE_PROMPT_ROUTE:-}" = "1" ]; then
    _skip "inside a /plan-w-team worker — the cascade boundary (PWT-DS2) is not crossed from here"
fi

# ── next row ────────────────────────────────────────────────────────────────
# The ledger is APPEND-ONLY: closing a row appends a resolution row carrying
# `closes_index` and never rewrites the original, so the original keeps
# `status:"open"` forever. Selecting on `.status` alone — as this did until
# 1.65.1 — treats every closed row as open, so the drain would keep re-spawning
# runs for work that is already done, and the backlog head would stick on a
# resolved row permanently. $cidx is the DISTINCT set of closed indices (pre-fix
# ledgers carry duplicate closures). Kept in lockstep with the same resolution
# in plan-w-team-followups.sh; see shared/state-artifacts.md for the contract.
_JQ_OPEN='
  (map(.closes_index // empty) | map(tonumber? // empty) | unique) as $cidx
  | to_entries
  | map(select(.value | has("closes_index") | not))
  | map(select(.key as $k | ($cidx | index($k)) == null))
  | map(select(.value.status == "open"))
'
NEXT_IDX=""; NEXT_SLUG=""; NEXT_TEXT=""; OPEN_N=0
if [ -f "$LEDGER" ] && command -v jq >/dev/null 2>&1; then
    OPEN_N=$(jq -rs "$_JQ_OPEN"' | length' "$LEDGER" 2>/dev/null || echo 0)
    # Oldest open row: the backlog head, not the newest arrival.
    read -r NEXT_IDX NEXT_SLUG <<EOF
$(jq -rs "$_JQ_OPEN"'
          | sort_by(.value.ts // .value.timestamp // "9999")
          | first // empty
          | "\(.key) \(.value.slug // "unknown")"' "$LEDGER" 2>/dev/null || echo "")
EOF
    if [ -n "${NEXT_IDX:-}" ]; then
        NEXT_TEXT=$(jq -rs --argjson i "$NEXT_IDX" '(.[$i].text // .[$i].note // "") | gsub("\n";" ")' "$LEDGER" 2>/dev/null || echo "")
    fi
fi

if [ "$MODE" = "--status" ]; then
    printf 'enabled: %s\n' "$([ "$ENABLED" = "1" ] && echo yes || echo "no (set PWT_FOLLOWUP_DRAIN_ENABLE=1 or touch $MARKER)")"
    printf 'open rows: %s\n' "$OPEN_N"
    printf 'next: %s\n' "${NEXT_IDX:-none}${NEXT_SLUG:+ [$NEXT_SLUG]}"
    exit 0
fi

[ "$ENABLED" = "1" ] || _skip "disabled by default (PWT_FOLLOWUP_DRAIN_ENABLE=1 or $MARKER to enable)"
[ -n "${NEXT_IDX:-}" ] || _skip "no open follow-up rows"

# ── capacity chain ──────────────────────────────────────────────────────────
_action() {
    # $1 script, $2... args. Reads recommended_action, falling back to
    # recommendation (pwt-fair-share.sh uses the latter).
    local s="$1"; shift
    [ -x "$s" ] || { echo "MISSING"; return 0; }
    "$s" "$@" 2>/dev/null \
      | grep -oE '"(recommended_action|recommendation)"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed -E 's/.*"([^"]+)"$/\1/'
}

for gate in "ram-budget.sh --bg-only" "disk-budget.sh" "pwt-fair-share.sh"; do
    set -- $gate
    g="$1"; shift
    act=$(_action "$SCRIPTS/$g" "$@")
    case "$act" in
        SPAWN_OK) ;;
        "" |MISSING) _skip "capacity gate $g unreadable — failing closed (no spawn)" ;;
        *)          _skip "capacity gate $g says $act" ;;
    esac
done

# ── no self-competition (live /plan-w-team WORKERS only) ────────────────────
# Earlier this counted ANY background session for the repo, which was far too
# coarse: a laptop accumulates bg sessions from ordinary work, so the drainer
# would refuse indefinitely and never run at all. What actually competes for the
# same files is a live /plan-w-team worker — a bg session named by a goal-state
# whose terminal_state is still null. Count only those.
LIVE_WORKERS=0
if [ -x "$SCRIPTS/claude-agents-extended.sh" ] && command -v jq >/dev/null 2>&1; then
    LIVE_SIDS=$("$SCRIPTS/claude-agents-extended.sh" --json --bg-only 2>/dev/null \
        | jq -r '(if type=="array" then . else (.sessions // .agents // []) end)[]
                 | select(.kind=="background") | (.sessionId // .id // "")' 2>/dev/null \
        | cut -c1-8 | sort -u)
    for sid in $LIVE_SIDS; do
        [ -n "$sid" ] || continue
        # Any unfinished goal-state naming this session => a live PWT worker.
        if grep -l "\"worker_sid\"[[:space:]]*:[[:space:]]*\"$sid" \
               "$REPO_ROOT"/.claude/state/plan-w-team-goal-*.json 2>/dev/null \
           | while read -r gf; do
                 jq -e '.terminal_state == null' "$gf" >/dev/null 2>&1 && echo hit
             done | grep -q hit; then
            LIVE_WORKERS=$((LIVE_WORKERS+1))
        fi
    done
fi
[ "$LIVE_WORKERS" -gt 0 ] && _skip "$LIVE_WORKERS live /plan-w-team worker(s) already running for this repo"

# ── cooldown ────────────────────────────────────────────────────────────────
# The drainer is invoked from BOTH a launchd timer and SessionStart (see below),
# so it needs its own rate limit or opening Claude repeatedly would spawn
# repeatedly. One run per PWT_FOLLOWUP_DRAIN_COOLDOWN_H hours (default 20, i.e.
# roughly daily without pinning to a wall-clock hour a laptop may sleep through).
STAMP="$REPO_ROOT/.claude/state/pwt-followup-drain-last-run"
COOLDOWN_H="${PWT_FOLLOWUP_DRAIN_COOLDOWN_H:-20}"
if [ -f "$STAMP" ]; then
    now=$(date +%s)
    then_=$(cat "$STAMP" 2>/dev/null || echo 0)
    case "$then_" in ''|*[!0-9]*) then_=0 ;; esac
    age_h=$(( (now - then_) / 3600 ))
    [ "$age_h" -lt "$COOLDOWN_H" ] \
        && _skip "cooldown — last run ${age_h}h ago (< ${COOLDOWN_H}h)"
fi

# ── spawn ───────────────────────────────────────────────────────────────────
BRIEF="$REPO_ROOT/.claude/state/pwt-brief-followup-drain-${NEXT_IDX}.md"
{
    printf '# Brief — draining follow-up row %s\n\n' "$NEXT_IDX"
    printf 'This run was started by the scheduled follow-up drainer, not a human.\n'
    printf 'It has exactly ONE job: resolve the single ledger row below.\n\n'
    printf '## The row\n\n- index: %s\n- slug: %s\n\n%s\n\n' "$NEXT_IDX" "$NEXT_SLUG" "$NEXT_TEXT"
    printf '## Scope\n\n'
    printf 'Do ONLY this row. Do not sweep the rest of the ledger — %s rows are open\n' "$OPEN_N"
    printf 'and draining them in one run would spend the weekly budget on the least\n'
    printf 'important work in the repo.\n\n'
    printf 'If the row turns out to be already fixed, or wrong, or not worth doing, that\n'
    printf 'is a valid outcome: close it with a reason instead of inventing work —\n'
    printf '  .claude/scripts/plan-w-team-followups.sh close %s "<reason>"\n\n' "$NEXT_IDX"
    printf '## Definition of done\n\n'
    printf 'Either the row is implemented, tested and shipped, or it is closed with a\n'
    printf 'recorded reason. Green means SUITE_EXIT=0 as the FINAL line of\n'
    printf './tests/skill/run.sh — the bats pass count alone is not green, because a\n'
    printf 'failing shell-integration phase still reports hundreds of bats passes.\n'
} > "$BRIEF" 2>/dev/null || _skip "could not write brief"

if [ "$MODE" = "--dry-run" ]; then
    _say "DRY RUN — would spawn a worker for row $NEXT_IDX [$NEXT_SLUG]"
    _say "brief: $BRIEF"
    exit 0
fi

_say "spawning worker for row $NEXT_IDX [$NEXT_SLUG]"
date +%s > "$STAMP" 2>/dev/null || true   # stamp BEFORE spawning: a crashed
                                          # spawn must not free the cooldown
cd "$REPO_ROOT" || _skip "cannot cd to repo root"
"$SCRIPTS/pwt-goal.sh" --worker-only --brief "$BRIEF" \
    "resolve recursive-followup row $NEXT_IDX ($NEXT_SLUG): ${NEXT_TEXT:0:200}" \
    || _say "pwt-goal.sh returned nonzero — no run started (fail-open)"
exit 0
