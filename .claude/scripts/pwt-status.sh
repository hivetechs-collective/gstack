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
        --detail)  MODE="detail"; WANT_SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
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
single_json() { # $1=captured output, $2=fallback → exactly ONE valid JSON document
    # Helper output is NOT safe to interpolate directly. Two traps, both live:
    #
    #  1. `$(helper || echo FALLBACK)` CONCATENATES when the helper prints its
    #     payload AND exits non-zero — which claude-agents-extended.sh does by
    #     design ("here is what I have, but I learned nothing reliable", exit 1).
    #     The capture then holds TWO documents, e.g. `[]\n[]`.
    #  2. `jq -e .` does NOT reject that: a multi-document stream is valid jq
    #     input, so the old guard passed it through. Downstream, `--argjson`
    #     died ("invalid JSON text") and `... | length` emitted one number PER
    #     document, so `[ "$N" -gt 0 ]` got `0\n0` → "integer expression
    #     expected" (pwt-status rollup, both human and --json modes).
    #
    # Slurping is the check AND the repair: `jq -s` reads the whole stream into
    # an array, so `length == 1` is a true single-document assertion, and on a
    # multi-document capture we keep the LAST document (the helper's real
    # payload precedes any appended fallback). Anything unparseable → fallback.
    local raw="${1:-}" fallback="${2:-}" n
    [ -n "$raw" ] || { printf '%s' "$fallback"; return 0; }
    n=$(printf '%s' "$raw" | jq -s 'length' 2>/dev/null) || { printf '%s' "$fallback"; return 0; }
    case "$n" in
        1) printf '%s' "$raw" ;;
        ''|0) printf '%s' "$fallback" ;;
        *) printf '%s' "$raw" | jq -c -s '.[-1]' 2>/dev/null || printf '%s' "$fallback" ;;
    esac
}

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
        FLEET=$(single_json "$(CLAUDE_PROJECT_DIR="$FQ_ENV" "$FLEET_QUERY" summary "$WANT_SLUG" 2>/dev/null)" \
                            '{"spawned":0,"completed":0,"failed":0,"running":0}')
    fi

    # Live sessions in the worktree (lead + nested builder subagents).
    # Test seam: PWT_STATUS_AGENTS_OVERRIDE supplies the registry JSON directly
    # (skips the claude call), the same convention as PWT_LIVE_SESSION_CWDS_OVERRIDE.
    AGENTS='[]'
    if [ -n "${PWT_STATUS_AGENTS_OVERRIDE:-}" ]; then
        AGENTS=$(single_json "$PWT_STATUS_AGENTS_OVERRIDE" '[]')
    elif [ -x "$AGENTS_EXTENDED" ] && [ -n "$WT" ]; then
        AGENTS=$(single_json "$("$AGENTS_EXTENDED" --cwd "$WT" 2>/dev/null)" '[]')
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

    # Live sessions: lead (kind background/interactive), builders (subagent),
    # and dynamic-Workflow lens-agents (workflow). Lead = anything that is NOT a
    # sub-tier agent, so exclude BOTH subagent and workflow kinds.
    # O1 (2026-08-29): corroborate each LEAD row's registry liveness with pid
    # evidence before counting it live. `claude agents --json` is intermittently
    # empty-but-exit-0 under load AND lingers stale rows after a steer — a
    # supervisor reading "3 lead busy" at face value would chase rival workers
    # that no longer exist (the founder-relayed incident). A lead row whose pid is
    # dead is marked stale-registry; a row with no numeric pid cannot be disproven,
    # so it is counted live (fail-open — an empty registry stays 0 lead, unchanged).
    # subagentType defaults to "-" (never empty): a tab is IFS-whitespace, so an
    # empty MIDDLE field would collapse under `read` and shift pid into the wrong
    # variable. pid is last, so an empty pid is safe (trailing-field trimming).
    ROWS=$(echo "$AGENTS" | jq -r '.[] | [(.kind//"?"),(.sessionId//"?"),(.status//"?"),(.subagentType // "-"),(.pid//"")] | @tsv' 2>/dev/null)
    LEAD_LIVE=0; LEAD_STALE=0; SUB_N=0; WF_N=0; LISTING=""
    while IFS="$(printf '\t')" read -r RKIND RSID RSTAT RSUB RPID; do
        [ -n "$RKIND" ] || continue
        case "$RKIND" in
            subagent) SUB_N=$((SUB_N + 1)); LISTING="${LISTING}    [${RKIND}] ${RSID}  ${RSTAT}  ${RSUB}
" ;;
            workflow) WF_N=$((WF_N + 1)); LISTING="${LISTING}    [${RKIND}] ${RSID}  ${RSTAT}  ${RSUB}
" ;;
            *)  MARK=""
                case "$RPID" in
                    ''|*[!0-9]*) LEAD_LIVE=$((LEAD_LIVE + 1)) ;;   # no numeric pid → cannot disprove → live
                    *) if kill -0 "$RPID" 2>/dev/null; then LEAD_LIVE=$((LEAD_LIVE + 1)); else LEAD_STALE=$((LEAD_STALE + 1)); MARK="  [stale-registry]"; fi ;;
                esac
                LISTING="${LISTING}    [${RKIND}] ${RSID}  ${RSTAT}  ${RSUB}${MARK}
" ;;
        esac
    done <<EOF_ROWS
$ROWS
EOF_ROWS
    STALE_NOTE=""
    [ "$LEAD_STALE" -gt 0 ] && STALE_NOTE=" ($LEAD_STALE stale-registry)"
    if [ "${WF_N:-0}" -gt 0 ]; then
        printf '  sessions: %s lead%s, %s builder-subagent(s), %s workflow lens-agent(s) live\n' "$LEAD_LIVE" "$STALE_NOTE" "$SUB_N" "$WF_N"
    else
        printf '  sessions: %s lead%s, %s builder-subagent(s) live\n' "$LEAD_LIVE" "$STALE_NOTE" "$SUB_N"
    fi
    printf '%s' "$LISTING"

    # C3 (BRIEF §4.4): the ONE liveness truth for THIS run's worker — live_by_process /
    # live_by_registry from the process-corroborated predicate (extends the O1 pid corroboration
    # above with a single named verdict). exit 2 (cannot-determine) prints "unknown", never "live".
    # Kill switch: PWT_DISABLE_STATUS_LANE_ALIVE=1.
    if [ "${PWT_DISABLE_STATUS_LANE_ALIVE:-0}" != "1" ]; then
        LA_BIN="${PWT_LANE_ALIVE_BIN:-$(dirname "$0")/pwt-lane-alive.sh}"
        if [ -x "$LA_BIN" ]; then
            LA_JSON=$("$LA_BIN" "$WANT_SLUG" --json 2>/dev/null); LA_RC=$?
            case "$LA_RC" in 0) LA_V="alive" ;; 1) LA_V="not-alive" ;; *) LA_V="unknown" ;; esac
            LA_LP=$(printf '%s' "$LA_JSON" | jq -r '.live_by_process // "?"' 2>/dev/null || echo "?")
            LA_LR=$(printf '%s' "$LA_JSON" | jq -r '.live_by_registry // "?"' 2>/dev/null || echo "?")
            printf '  lane-alive: %s (live_by_process=%s live_by_registry=%s)\n' "$LA_V" "$LA_LP" "$LA_LR"
        fi
    fi

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
