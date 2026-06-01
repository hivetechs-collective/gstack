#!/bin/bash
# pwt-status — diagnostic + rollup view for /plan-w-team runs
#
# Read-only. Two modes:
#
#   pwt-status.sh                 list every active run, one row each, enriched
#                                 with the live stage from the canonical manifest.
#   pwt-status.sh <slug>          ROLLUP for one run: joins the manifest ×
#   pwt-status.sh --detail <slug> claude-agents-extended (lead session + nested
#                                 builder subagents) × fleet-query (builder
#                                 roster), so a human sees "worker X, stage Y,
#                                 N builders in [tasks]" — the thing claude
#                                 agents --json alone can never show.
#   pwt-status.sh --json [<slug>] machine-readable (all runs, or one rollup).
#
# WHY THE MANIFEST: a worker writes its live state into its worktree, so a poll
# of the MAIN checkout used to see only the spawn record, never the stage. The
# manifest (pwt-manifest.sh) is the one main-checkout-relative artifact that
# records {stage, strategy, worktree, tasks, builder_count}; this tool reads it
# and drills into the worktree for the builder roster.
#
# Spec: docs/specs/pwt-status-utility.md
# Usage: pwt-status.sh [-h|--help] | [<slug>] | [--detail <slug>] | [--json [<slug>]]
# Exit: 0 = listing/rollup emitted (incl. "no active runs")
#       2 = missing dependency (jq) or bad usage
#       3 = --detail/<slug> given but no manifest/run for that slug

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_EXTENDED="$SCRIPT_DIR/claude-agents-extended.sh"
FLEET_QUERY="$SCRIPT_DIR/plan-w-team-fleet-query.sh"
MANIFEST="$SCRIPT_DIR/pwt-manifest.sh"

usage() {
    cat <<'EOF'
Usage: pwt-status.sh [-h|--help] | [<slug>] | [--detail <slug>] | [--json [<slug>]]

Modes:
  (no args)        List active /plan-w-team runs, one row each.
  <slug>           Rollup for one run (manifest × agents × builder roster).
  --detail <slug>  Same as <slug>.
  --json [<slug>]  Machine-readable (all runs, or one rollup object).

Read-only: makes no state modifications.

Columns: (list mode)
  SLUG          — feature slug
  STAGE         — live stage from the canonical run manifest (or '-')
  LOCK          — active (PID alive) | stale (PID dead) | missing
  LOCK_PID      — owning process ID, or '-'
  GOAL_TERMINAL — SUCCESS | USER_ESCALATION_HALT | LOW_CONFIDENCE_STREAK | pending

Exits 0 always (including the no-runs case) unless jq is missing (2) or a
named slug has no manifest (3).
EOF
}

MODE="list"
WANT_JSON=0
WANT_SLUG=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --json)    WANT_JSON=1; shift ;;
        --detail)  MODE="detail"; WANT_SLUG="${2:-}"; shift 2 ;;
        --*)       echo "pwt-status: unknown option $1" >&2; usage; exit 2 ;;
        *)         MODE="detail"; WANT_SLUG="$1"; shift ;;
    esac
done

if ! command -v jq >/dev/null 2>&1; then
    echo "pwt-status: jq required — install with 'brew install jq'" >&2
    exit 2
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
STATE_DIR="$PROJECT_ROOT/.claude/state"

# ── helpers ──────────────────────────────────────────────────────────────────
manifest_for() { # echo the manifest JSON for a slug, or empty
    [ -x "$MANIFEST" ] || return 0
    # Pin the manifest reader to the SAME state dir this tool scans, so the
    # listing and the manifest read never disagree (matters when CLAUDE_PROJECT_DIR
    # differs from the git root, e.g. tests or unusual invocations).
    PWT_MANIFEST_STATE_DIR="$STATE_DIR" "$MANIFEST" read --slug "$1" 2>/dev/null || true
}

stage_of() { # $1=manifest JSON (possibly empty) → stage or "-"
    local s
    s=$(printf '%s' "${1:-}" | jq -r '.current_stage // "-"' 2>/dev/null | head -n1)
    [ -n "$s" ] && printf '%s' "$s" || printf '%s' "-"
}

lock_state() { # $1=slug → "state pid"
    local dir="$STATE_DIR/plan-w-team-workflow-${1}.lock" st="missing" pid="-"
    if [ -d "$dir" ]; then
        pid=$(cat "$dir/pid" 2>/dev/null || echo "?")
        if [ "$pid" != "?" ] && kill -0 "$pid" 2>/dev/null; then st="active"; else st="stale"; fi
    fi
    printf '%s %s' "$st" "$pid"
}

goal_terminal() { # $1=slug → terminal/pending/(corrupt)/(no goal file)
    local gf="$STATE_DIR/plan-w-team-goal-${1}.json"
    if [ -f "$gf" ]; then
        if jq -e . "$gf" >/dev/null 2>&1; then jq -r '.terminal_state // "pending"' "$gf"
        else echo "(corrupt)"; fi
    else echo "(no goal file)"; fi
}

collect_slugs() {
    {
        find "$STATE_DIR" -maxdepth 1 -type d -name 'plan-w-team-workflow-*.lock' \
            -exec basename {} .lock \; 2>/dev/null | sed 's/^plan-w-team-workflow-//'
        find "$STATE_DIR" -maxdepth 1 -type f -name 'plan-w-team-goal-*.json' \
            -exec basename {} .json \; 2>/dev/null | sed 's/^plan-w-team-goal-//'
        find "$STATE_DIR" -maxdepth 1 -type f -name 'plan-w-team-manifest-*.json' \
            -exec basename {} .json \; 2>/dev/null | sed 's/^plan-w-team-manifest-//'
    } | sort -u
}

# ── detail / rollup mode ─────────────────────────────────────────────────────
if [ "$MODE" = "detail" ]; then
    [ -n "$WANT_SLUG" ] || { echo "pwt-status: --detail needs a slug" >&2; exit 2; }
    MAN="$(manifest_for "$WANT_SLUG")"
    if [ -z "$MAN" ]; then
        echo "pwt-status: no manifest for slug '$WANT_SLUG'" >&2
        exit 3
    fi
    WT=$(echo "$MAN" | jq -r '.worktree_path // ""')

    # Fleet summary — point fleet-query at the worktree so it finds the run's log.
    FLEET='{"spawned":0,"completed":0,"failed":0,"running":0}'
    if [ -x "$FLEET_QUERY" ]; then
        FQ_ENV="$PROJECT_ROOT"; [ -n "$WT" ] && [ -d "$WT" ] && FQ_ENV="$WT"
        FLEET=$(CLAUDE_PROJECT_DIR="$FQ_ENV" "$FLEET_QUERY" summary "$WANT_SLUG" 2>/dev/null || echo "$FLEET")
        echo "$FLEET" | jq -e . >/dev/null 2>&1 || FLEET='{"spawned":0,"completed":0,"failed":0,"running":0}'
    fi

    # Live sessions in the worktree (lead + nested builder subagents).
    AGENTS='[]'
    if [ -x "$AGENTS_EXTENDED" ] && [ -n "$WT" ]; then
        AGENTS=$("$AGENTS_EXTENDED" --cwd "$WT" 2>/dev/null || echo '[]')
        echo "$AGENTS" | jq -e . >/dev/null 2>&1 || AGENTS='[]'
    fi

    if [ "$WANT_JSON" = "1" ]; then
        jq -n --argjson m "$MAN" --argjson f "$FLEET" --argjson a "$AGENTS" \
            '{manifest:$m, fleet:$f, sessions:$a}'
        exit 0
    fi

    # Human rollup
    echo "═══ /plan-w-team run: $(echo "$MAN" | jq -r '.slug')"
    printf '  stage:    %s   strategy: %s   terminal: %s\n' \
        "$(echo "$MAN" | jq -r '.current_stage // "?"')" \
        "$(echo "$MAN" | jq -r '.strategy // "?"')" \
        "$(echo "$MAN" | jq -r '.terminal_state // "pending"')"
    printf '  run_sid:  %s   worktree: %s\n' \
        "$(echo "$MAN" | jq -r '.run_sid // "?"')" "${WT:-"-"}"
    printf '  builders: %s declared | spawned=%s running=%s completed=%s failed=%s\n' \
        "$(echo "$MAN" | jq -r '.builder_count // 0')" \
        "$(echo "$FLEET" | jq -r '.spawned // 0')" \
        "$(echo "$FLEET" | jq -r '.running // 0')" \
        "$(echo "$FLEET" | jq -r '.completed // 0')" \
        "$(echo "$FLEET" | jq -r '.failed // 0')"

    # Live sessions: lead (kind background/interactive) then builders (subagent)
    LEAD_N=$(echo "$AGENTS" | jq '[.[] | select(.kind!="subagent")] | length')
    SUB_N=$(echo "$AGENTS" | jq '[.[] | select(.kind=="subagent")] | length')
    printf '  sessions: %s lead, %s builder-subagent(s) live\n' "${LEAD_N:-0}" "${SUB_N:-0}"
    echo "$AGENTS" | jq -r '.[] | "    [\(.kind)] \(.sessionId // "?")  \(.status // "?")  \(.subagentType // "")"' 2>/dev/null

    # Tasks
    TASK_N=$(echo "$MAN" | jq '.tasks | length')
    if [ "${TASK_N:-0}" -gt 0 ]; then
        echo "  tasks:"
        echo "$MAN" | jq -r '.tasks[] | "    \(.id)  \(.status)  owner=\(.owner_builder_sid // "-")"'
    fi

    # Stage history (last 6 transitions)
    EV="$STATE_DIR/plan-w-team-stage-events-${WANT_SLUG}.jsonl"
    if [ -f "$EV" ]; then
        HIST=$(tail -6 "$EV" 2>/dev/null | jq -r '.stage' 2>/dev/null | paste -sd'>' - 2>/dev/null | sed 's/>/ → /g')
        [ -n "$HIST" ] && echo "  stages:   $HIST"
    fi
    exit 0
fi

# ── list mode ────────────────────────────────────────────────────────────────
if [ ! -d "$STATE_DIR" ]; then
    [ "$WANT_JSON" = "1" ] && echo '[]' || echo "No active /plan-w-team runs"
    exit 0
fi

SLUGS=$(collect_slugs)
if [ -z "$SLUGS" ]; then
    [ "$WANT_JSON" = "1" ] && echo '[]' || echo "No active /plan-w-team runs"
    exit 0
fi

if [ "$WANT_JSON" = "1" ]; then
    OUT='[]'
    while IFS= read -r SLUG; do
        [ -z "$SLUG" ] && continue
        read -r LS LP <<<"$(lock_state "$SLUG")"
        GT="$(goal_terminal "$SLUG")"
        MAN="$(manifest_for "$SLUG")"
        STG=$(stage_of "$MAN")
        OUT=$(jq --arg s "$SLUG" --arg st "$STG" --arg l "$LS" --arg p "$LP" --arg g "$GT" \
            '. + [{slug:$s, stage:$st, lock:$l, lock_pid:$p, goal_terminal:$g}]' <<<"$OUT")
    done <<< "$SLUGS"
    echo "$OUT"
    exit 0
fi

printf '%-30s  %-12s  %-8s  %-10s  %s\n' "SLUG" "STAGE" "LOCK" "LOCK_PID" "GOAL_TERMINAL"
printf '%-30s  %-12s  %-8s  %-10s  %s\n' "----" "-----" "----" "--------" "-------------"
while IFS= read -r SLUG; do
    [ -z "$SLUG" ] && continue
    read -r LS LP <<<"$(lock_state "$SLUG")"
    GT="$(goal_terminal "$SLUG")"
    MAN="$(manifest_for "$SLUG")"
    STG=$(stage_of "$MAN")
    printf '%-30s  %-12s  %-8s  %-10s  %s\n' "$SLUG" "$STG" "$LS" "$LP" "$GT"
done <<< "$SLUGS"

exit 0
