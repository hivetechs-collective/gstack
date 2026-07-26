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
NEXT_IDX=""; NEXT_SLUG=""; NEXT_TEXT=""; OPEN_N=0
if [ -f "$LEDGER" ] && command -v jq >/dev/null 2>&1; then
    OPEN_N=$(jq -rs '[.[] | select(.status=="open")] | length' "$LEDGER" 2>/dev/null || echo 0)
    # Oldest open row: the backlog head, not the newest arrival.
    read -r NEXT_IDX NEXT_SLUG <<EOF
$(jq -rs 'to_entries | map(select(.value.status=="open"))
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

# ── no self-competition ─────────────────────────────────────────────────────
# A live worker for this repo means the backlog is already being worked; a second
# one would race it for the same files.
if [ -x "$SCRIPTS/claude-agents-extended.sh" ]; then
    LIVE=$("$SCRIPTS/claude-agents-extended.sh" --json --bg-only 2>/dev/null \
           | grep -c '"kind"[[:space:]]*:[[:space:]]*"background"' || echo 0)
    [ "${LIVE:-0}" -gt 0 ] && _skip "$LIVE background session(s) already live for this repo"
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
cd "$REPO_ROOT" || _skip "cannot cd to repo root"
"$SCRIPTS/pwt-goal.sh" --worker-only --brief "$BRIEF" \
    "resolve recursive-followup row $NEXT_IDX ($NEXT_SLUG): ${NEXT_TEXT:0:200}" \
    || _say "pwt-goal.sh returned nonzero — no run started (fail-open)"
exit 0
