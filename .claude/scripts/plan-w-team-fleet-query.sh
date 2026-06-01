#!/bin/bash
# plan-w-team Fleet State Reader
#
# Subcommands:
#   next-spawnable <slug>  → JSON array of task IDs ready to spawn (deps complete)
#   running       <slug>   → JSON array of {agent_id, task_id?, spawned_at}
#   completed     <slug>   → JSON array of {agent_id, task_id?, completed_at, duration_s}
#   summary       <slug>   → object: {spawned, completed, failed, running, max_concurrent}
#                            (parallelism % is computed by 07-retro.md from raw timeline)
#
# Reads:
#   .claude/state/plan-w-team-fleet-<slug>.jsonl         (event log from hook)
#   .claude/state/plan-w-team-fleet-intent-<slug>.jsonl  (agent_id↔task_id sidecar from lead)
#   ~/.claude/tasks/<list>/<id>.json                     (task store with blockedBy)
#
# Spec: docs/specs/pwt-supervisor-goal.md
# Kill switch: PLAN_W_TEAM_FLEET_DISABLE=1 → returns empty arrays/zero counts
# Graceful: missing files → empty; corrupt rows → skip + stderr warn

set -u

usage() {
    cat >&2 <<EOF
Usage: $0 <subcommand> <slug>
  next-spawnable <slug>   Task IDs whose deps are all complete
  running        <slug>   Currently-running agents
  completed      <slug>   Completed agents with duration
  summary        <slug>   Counts + parallelism efficiency
EOF
}

SUBCOMMAND="${1:-}"
SLUG="${2:-}"

if [ -z "$SUBCOMMAND" ] || [ -z "$SLUG" ]; then
    usage
    exit 1
fi

if [ "${PLAN_W_TEAM_FLEET_DISABLE:-}" = "1" ]; then
    case "$SUBCOMMAND" in
        summary) echo '{"spawned":0,"completed":0,"failed":0,"running":0,"parallelism_pct":0}' ;;
        *)       echo '[]' ;;
    esac
    exit 0
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
STATE_DIR="$PROJECT_ROOT/.claude/state"
FLEET_FILE="$STATE_DIR/plan-w-team-fleet-${SLUG}.jsonl"
INTENT_FILE="$STATE_DIR/plan-w-team-fleet-intent-${SLUG}.jsonl"

# Worktree-aware fallback: a run's fleet events are written INTO its worktree's
# .claude/state/, so a reader invoked from the MAIN checkout finds nothing here.
# The canonical manifest (always in the main checkout) records worktree_path —
# use it to re-point at the worktree's state dir when the main copy is absent.
# Belt-and-suspenders with pwt status, which can also pass CLAUDE_PROJECT_DIR.
if [ ! -f "$FLEET_FILE" ]; then
    __mani="$(dirname "$0")/pwt-manifest.sh"
    if [ -x "$__mani" ]; then
        __wt="$("$__mani" read --slug "$SLUG" 2>/dev/null \
            | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("worktree_path","") or "")' 2>/dev/null || echo "")"
        if [ -n "$__wt" ] && [ -f "$__wt/.claude/state/plan-w-team-fleet-${SLUG}.jsonl" ]; then
            STATE_DIR="$__wt/.claude/state"
            FLEET_FILE="$STATE_DIR/plan-w-team-fleet-${SLUG}.jsonl"
            INTENT_FILE="$STATE_DIR/plan-w-team-fleet-intent-${SLUG}.jsonl"
        fi
    fi
fi

LIST_ID="${CLAUDE_CODE_TASK_LIST_ID:-$(basename "$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_ROOT")")}"
TASKS_DIR="${HOME}/.claude/tasks/${LIST_ID}"

if ! command -v jq >/dev/null 2>&1; then
    echo "[fleet-query] ERROR: jq is required" >&2
    case "$SUBCOMMAND" in
        summary) echo '{"spawned":0,"completed":0,"failed":0,"running":0,"parallelism_pct":0}' ;;
        *)       echo '[]' ;;
    esac
    exit 0
fi

# Read fleet log into JSON array, skipping corrupt rows (warn to stderr)
read_fleet() {
    if [ ! -f "$FLEET_FILE" ]; then
        echo '[]'
        return
    fi
    local rows=0 skipped=0 out='[]'
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if echo "$line" | jq -e . >/dev/null 2>&1; then
            out=$(jq --argjson row "$line" '. + [$row]' <<<"$out")
            rows=$((rows + 1))
        else
            skipped=$((skipped + 1))
        fi
    done < "$FLEET_FILE"
    [ "$skipped" -gt 0 ] && echo "[fleet-query] WARN: skipped $skipped corrupt row(s) in $FLEET_FILE" >&2
    echo "$out"
}

read_intent() {
    if [ ! -f "$INTENT_FILE" ]; then
        echo '[]'
        return
    fi
    local out='[]'
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if echo "$line" | jq -e . >/dev/null 2>&1; then
            out=$(jq --argjson row "$line" '. + [$row]' <<<"$out")
        fi
    done < "$INTENT_FILE"
    echo "$out"
}

# Build agent_id → task_id mapping from intent sidecar
agent_to_task_map() {
    read_intent | jq 'map({(.agent_id): .task_id}) | add // {}'
}

# Build task_id → blockedBy[] mapping from task store (TaskCreate writes these)
task_deps_map() {
    if [ ! -d "$TASKS_DIR" ]; then
        echo '{}'
        return
    fi
    local out='{}'
    for f in "$TASKS_DIR"/*.json; do
        [ -f "$f" ] || continue
        if jq -e . "$f" >/dev/null 2>&1; then
            local task_id deps status
            task_id=$(jq -r '.id' "$f")
            deps=$(jq -c '.blockedBy // []' "$f")
            status=$(jq -r '.status // "pending"' "$f")
            out=$(jq --arg id "$task_id" --argjson d "$deps" --arg s "$status" \
                '. + {($id): {blockedBy: $d, status: $s}}' <<<"$out")
        fi
    done
    echo "$out"
}

case "$SUBCOMMAND" in
    running)
        FLEET=$(read_fleet)
        MAP=$(agent_to_task_map)
        # Agents with spawn but no matching complete (or error)
        echo "$FLEET" | jq --argjson map "$MAP" '
            [.[] | select(.event == "spawn") | .agent_id] as $spawned
            | [.[] | select(.event == "complete" or .event == "error") | .agent_id] as $done
            | [$spawned[] | select(. as $a | $done | index($a) | not)]
            | map({agent_id: ., task_id: ($map[.] // null)})
        '
        ;;

    completed)
        FLEET=$(read_fleet)
        MAP=$(agent_to_task_map)
        echo "$FLEET" | jq --argjson map "$MAP" '
            [.[] | select(.event == "spawn")] as $spawns
            | [.[] | select(.event == "complete")] as $completes
            | [$completes[] as $c
               | ($spawns[] | select(.agent_id == $c.agent_id) | .ts) as $start
               | {agent_id: $c.agent_id,
                  task_id: ($map[$c.agent_id] // null),
                  completed_at: $c.ts,
                  spawned_at: $start}]
        '
        ;;

    next-spawnable)
        FLEET=$(read_fleet)
        MAP=$(agent_to_task_map)
        DEPS=$(task_deps_map)
        # tasks_done = union of {task store status=completed} and {fleet complete event → task_id via sidecar}
        FLEET_DONE=$(echo "$FLEET" | jq --argjson map "$MAP" '
            [.[] | select(.event == "complete") | .agent_id]
            | map($map[.]) | map(select(. != null))
        ')
        STORE_DONE=$(echo "$DEPS" | jq '[to_entries[] | select(.value.status == "completed") | .key]')
        TASKS_DONE=$(jq -n --argjson a "$FLEET_DONE" --argjson b "$STORE_DONE" '$a + $b | unique')
        TASKS_RUNNING=$(echo "$FLEET" | jq --argjson map "$MAP" '
            [.[] | select(.event == "spawn") | .agent_id] as $sp
            | [.[] | select(.event == "complete" or .event == "error") | .agent_id] as $dn
            | [$sp[] | select(. as $a | $dn | index($a) | not)]
            | map($map[.]) | map(select(. != null))
        ')
        echo "$DEPS" | jq --argjson done "$TASKS_DONE" --argjson running "$TASKS_RUNNING" '
            to_entries
            | map(select(.value.status == "pending"))
            | map(select(.key as $k | $running | index($k) | not))
            | map(select(.value.blockedBy as $bb
                         | $bb | all(. as $dep | $done | index($dep))))
            | map(.key)
        '
        ;;

    summary)
        FLEET=$(read_fleet)
        SPAWNED=$(echo "$FLEET" | jq '[.[] | select(.event == "spawn")] | length')
        COMPLETED=$(echo "$FLEET" | jq '[.[] | select(.event == "complete")] | length')
        FAILED=$(echo "$FLEET" | jq '[.[] | select(.event == "error")] | length')
        RUNNING=$((SPAWNED - COMPLETED - FAILED))
        [ "$RUNNING" -lt 0 ] && RUNNING=0

        # Max concurrent agents observed: walk the timeline of spawn/complete events
        MAX_CONCURRENT=$(echo "$FLEET" | jq '
            [.[] | select(.event == "spawn" or .event == "complete")
                 | {ts: .ts, delta: (if .event == "spawn" then 1 else -1 end)}]
            | sort_by(.ts)
            | reduce .[] as $e ({cur: 0, max: 0};
                {cur: (.cur + $e.delta),
                 max: ([.max, (.cur + $e.delta)] | max)})
            | .max
        ')
        jq -n --argjson sp "$SPAWNED" --argjson co "$COMPLETED" \
              --argjson fa "$FAILED" --argjson ru "$RUNNING" --argjson mc "$MAX_CONCURRENT" \
            '{spawned: $sp, completed: $co, failed: $fa, running: $ru, max_concurrent: $mc}'
        ;;

    *)
        usage
        exit 1
        ;;
esac
