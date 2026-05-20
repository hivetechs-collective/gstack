#!/bin/bash
# plan-w-team Goal Evaluator — Stop hook
#
# Replaces Anthropic's /goal wrapper with a deterministic shell evaluator.
# Fires after every Claude turn. Reads active /plan-w-team goal state file
# (created by the skill at top-of-pipeline) and decides whether the pipeline
# reached a terminal state.
#
# Why deterministic instead of Haiku-based: every terminal-state anchor in
# shared/goal-conditions.md is concrete enough to detect via grep against
# the transcript. No LLM judgment needed, no eval hallucination, no tokens.
#
# Spec: docs/specs/pwt-t5b-goal-evaluator.md (this file's spec)
# State file: .claude/state/plan-w-team-goal-<SLUG>.json
# Kill switch: PLAN_W_TEAM_DISABLE_GOAL=1 → exit 0 (let stop proceed normally)
# Block cap: default 8; set CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=200 in shell env
#            for long /plan-w-team runs

set -u

# Always read stdin (hook contract)
INPUT=$(cat 2>/dev/null || echo '{}')

# Kill switch — skip goal evaluation entirely
[ "${PLAN_W_TEAM_DISABLE_GOAL:-}" = "1" ] && exit 0

# stop_hook_active protection — if Claude Code already overrode us, don't fight
if [ "$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    exit 0
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
STATE_DIR="$PROJECT_ROOT/.claude/state"

# Find active goal state files
shopt -s nullglob
GOAL_FILES=("$STATE_DIR"/plan-w-team-goal-*.json)
shopt -u nullglob

# No active goal → let Claude stop normally
[ "${#GOAL_FILES[@]}" -eq 0 ] && exit 0

# Tools: jq required for state file parsing
if ! command -v jq >/dev/null 2>&1; then
    echo "[goal-evaluator] WARN: jq not available, skipping evaluation" >&2
    exit 0
fi

# Transcript: Claude Code passes the path in the hook input
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)

# Evaluate each active goal. If ANY hits terminal, allow stop.
# If ALL are still pending, block stop with the most recent goal's reason.
BLOCK_REASON=""
ANY_TERMINAL=false

for GOAL_FILE in "${GOAL_FILES[@]}"; do
    if ! jq -e . "$GOAL_FILE" >/dev/null 2>&1; then
        # Corrupt state file — log and skip
        echo "[goal-evaluator] WARN: corrupt goal state at $GOAL_FILE; skipping" >&2
        continue
    fi

    SLUG=$(jq -r '.slug' "$GOAL_FILE")
    STARTED_AT=$(jq -r '.started_at' "$GOAL_FILE")
    TURNS=$(jq -r '.turns_evaluated // 0' "$GOAL_FILE")
    TURN_CAP=$(jq -r '.turn_cap // 200' "$GOAL_FILE")
    WALL_CAP_H=$(jq -r '.wall_clock_cap_h // 12' "$GOAL_FILE")
    EXISTING_TERMINAL=$(jq -r '.terminal_state // ""' "$GOAL_FILE")

    # Already marked terminal in a previous turn → allow stop
    if [ -n "$EXISTING_TERMINAL" ]; then
        ANY_TERMINAL=true
        continue
    fi

    # Read recent transcript lines (last ~500) for anchor detection
    if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
        RECENT=$(tail -500 "$TRANSCRIPT_PATH" 2>/dev/null || echo "")
    else
        RECENT=""
    fi

    TERMINAL=""
    REASON=""

    # (1) SUCCESS: status block with stage="retro-complete" AND workflow_lock="done"
    # PWT-T5b dogfood fix (2026-05-20): also require slug match to prevent
    # false positives from documentation/example text that mentions the
    # anchor strings. The status block always includes "slug":"<this-SLUG>".
    SLUG_ANCHOR="\"slug\":\"${SLUG}\""
    if echo "$RECENT" | grep -F '"stage":"retro-complete"' >/dev/null 2>&1 \
       && echo "$RECENT" | grep -F '"workflow_lock":"done"' >/dev/null 2>&1 \
       && echo "$RECENT" | grep -F "$SLUG_ANCHOR" >/dev/null 2>&1; then
        TERMINAL="SUCCESS"
        REASON="retro-complete status block emitted with workflow_lock=done for slug=$SLUG"

        # PWT-T5c: AND-check feature-specific done criteria
        CRITERIA_LEN=$(jq '.feature_specific_done_criteria // [] | length' "$GOAL_FILE")
        if [ "$CRITERIA_LEN" -gt 0 ]; then
            UNMET_DESCRIPTIONS=""
            NEW_CRITERIA=$(jq -c '.feature_specific_done_criteria' "$GOAL_FILE")
            for i in $(seq 0 $((CRITERIA_LEN - 1))); do
                PATTERN=$(echo "$NEW_CRITERIA" | jq -r ".[$i].pattern")
                ALREADY_MET=$(echo "$NEW_CRITERIA" | jq -r ".[$i].met")
                if [ "$ALREADY_MET" = "true" ]; then continue; fi
                # Validate regex compiles by attempting an empty-input grep
                if ! echo "" | grep -E "$PATTERN" >/dev/null 2>&1; then
                    : # grep returns 1 on no-match; ok. Real regex failure prints to stderr.
                fi
                if echo "$RECENT" | grep -E "$PATTERN" >/dev/null 2>&1; then
                    NEW_CRITERIA=$(echo "$NEW_CRITERIA" \
                        | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                             ".[$i].met = true | .[$i].met_at = \$ts")
                else
                    DESC=$(echo "$NEW_CRITERIA" | jq -r ".[$i].description")
                    UNMET_DESCRIPTIONS="${UNMET_DESCRIPTIONS}${UNMET_DESCRIPTIONS:+; }${DESC}"
                fi
            done
            # Persist updated criteria atomically
            jq --argjson c "$NEW_CRITERIA" '.feature_specific_done_criteria = $c' "$GOAL_FILE" \
                > "$GOAL_FILE.tmp" && mv "$GOAL_FILE.tmp" "$GOAL_FILE"
            if [ -n "$UNMET_DESCRIPTIONS" ]; then
                TERMINAL=""
                REASON=""
                # Will be picked up by the BLOCK_REASON branch below
                CRITERIA_BLOCK_REASON="Generic SUCCESS anchors present but feature-specific criteria unmet: ${UNMET_DESCRIPTIONS}. Continue pipeline until each criterion appears in transcript (typically as 'AC<N>: PASS' lines emitted by Step 5 review and Step 6 ship)."
            fi
        fi
    fi

    # (2) USER_ESCALATION_HALT: pending_escalations contains a hard-gate label
    # Slug-match defense: the status/summary block including the escalation MUST
    # carry "slug":"<SLUG>" within the same ~10 lines, otherwise the match is
    # likely from documentation text mentioning the site name.
    if [ -z "$TERMINAL" ]; then
        for SITE in push-ack secret-scan-allow scope-unlock-for-drift; do
            # grep -B/-A scope: any pending_escalations line referencing $SITE
            # must have $SLUG within 10 lines (status block size).
            if echo "$RECENT" | grep -B5 -A5 -E "\"pending_escalations\":\[[^]]*\"$SITE\"" \
                | grep -F "\"slug\":\"$SLUG\"" >/dev/null 2>&1; then
                TERMINAL="USER_ESCALATION_HALT"
                REASON="hard-gate site '$SITE' in pending_escalations for slug=$SLUG — user must respond"
                break
            fi
        done
    fi

    # (3) LOW_CONFIDENCE_STREAK: status block reports low_confidence_routes >= 3
    # Slug-match defense: extract low_confidence_routes values only from
    # transcript regions where this slug appears within ±5 lines.
    if [ -z "$TERMINAL" ]; then
        MAX_LOW=$(echo "$RECENT" \
            | grep -B5 -A5 -F "\"slug\":\"$SLUG\"" \
            | grep -oE '"low_confidence_routes":[0-9]+' \
            | grep -oE '[0-9]+$' | sort -n | tail -1)
        if [ -n "$MAX_LOW" ] && [ "$MAX_LOW" -ge 3 ]; then
            TERMINAL="LOW_CONFIDENCE_STREAK"
            REASON="low_confidence_routes=$MAX_LOW (≥3 — supervisor confidence threshold breached)"
        fi
    fi

    # (4) TIME_OR_TURN_CAP: turns + wall-clock check
    if [ -z "$TERMINAL" ]; then
        # Turn cap
        NEW_TURNS=$((TURNS + 1))
        if [ "$NEW_TURNS" -ge "$TURN_CAP" ]; then
            TERMINAL="TIME_OR_TURN_CAP"
            REASON="turn cap reached ($NEW_TURNS/$TURN_CAP)"
        else
            # Wall-clock cap
            START_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$STARTED_AT" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date -u +%s)
            ELAPSED_H=$(( (NOW_EPOCH - START_EPOCH) / 3600 ))
            if [ "$START_EPOCH" -gt 0 ] && [ "$ELAPSED_H" -ge "$WALL_CAP_H" ]; then
                TERMINAL="TIME_OR_TURN_CAP"
                REASON="wall-clock cap reached (${ELAPSED_H}h/${WALL_CAP_H}h)"
            fi
        fi

        # Persist new turn count
        jq --arg n "$NEW_TURNS" '.turns_evaluated = ($n | tonumber)' "$GOAL_FILE" \
            > "$GOAL_FILE.tmp" && mv "$GOAL_FILE.tmp" "$GOAL_FILE"
    fi

    if [ -n "$TERMINAL" ]; then
        # Persist terminal state
        jq --arg t "$TERMINAL" --arg r "$REASON" --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
           '.terminal_state = $t | .terminal_reason = $r | .terminated_at = $ts' \
           "$GOAL_FILE" > "$GOAL_FILE.tmp" && mv "$GOAL_FILE.tmp" "$GOAL_FILE"
        ANY_TERMINAL=true
        echo "[goal-evaluator] SLUG=$SLUG terminal=$TERMINAL reason=$REASON" >&2
    else
        # Build a block reason combining condition status
        # PWT-T5c: prefer the specific criteria-unmet reason when it exists
        if [ -n "${CRITERIA_BLOCK_REASON:-}" ]; then
            BLOCK_REASON="$CRITERIA_BLOCK_REASON"
        else
            BLOCK_REASON="/plan-w-team SLUG=$SLUG not yet terminal (turn $((TURNS + 1))/$TURN_CAP). Continue pipeline. Need ONE of: status block with stage=retro-complete + workflow_lock=done; pending_escalations containing a hard-gate site (push-ack/secret-scan-allow/scope-unlock-for-drift); low_confidence_routes>=3."
        fi
    fi
done

# Allow stop only if no pending blocks remain.
# (Previously: "if ANY_TERMINAL || no_block" — wrong. One goal going terminal
# must NOT suppress block emission for other still-pending goals. PWT-T5c
# dogfood fix: multi-goal isolation.)
if [ -z "$BLOCK_REASON" ]; then
    exit 0
fi

# Block stop — Claude continues with reason as guidance
jq -n --arg r "$BLOCK_REASON" '{"decision":"block","reason":$r}'
exit 0
