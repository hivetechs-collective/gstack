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
FALLBACK_STATE_DIR="$PROJECT_ROOT/.claude/state"
PWD_STATE_DIR="$PWD/.claude/state"

# Worktree-aware state lookup: check $PWD/.claude/state first (the case when
# /plan-w-team is running in a worktree), fall back to project root. We
# aggregate goal files from both locations so the evaluator catches active
# goals regardless of where they were written. See 2026-05-20 holistic-check
# retro for the failure this fixes.
shopt -s nullglob
declare -a GOAL_FILES=()
if [ -d "$PWD_STATE_DIR" ] && [ "$PWD_STATE_DIR" != "$FALLBACK_STATE_DIR" ]; then
    for f in "$PWD_STATE_DIR"/plan-w-team-goal-*.json; do
        GOAL_FILES+=("$f")
    done
fi
for f in "$FALLBACK_STATE_DIR"/plan-w-team-goal-*.json; do
    GOAL_FILES+=("$f")
done
shopt -u nullglob

# Pick effective STATE_DIR for any downstream writes: prefer $PWD if it holds a
# matching goal, else fall back. (Used by terminal-state persistence below.)
if [ -d "$PWD_STATE_DIR" ] && [ "$PWD_STATE_DIR" != "$FALLBACK_STATE_DIR" ] && \
   compgen -G "$PWD_STATE_DIR/plan-w-team-goal-*.json" >/dev/null 2>&1; then
    STATE_DIR="$PWD_STATE_DIR"
else
    STATE_DIR="$FALLBACK_STATE_DIR"
fi

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

    # No (4) TIME_OR_TURN_CAP: removed by design. Only goal-success and hard-gate
    # escalations are valid terminal states (see shared/goal-conditions.md). If the
    # evaluator never returns success, the supervisor's low-confidence streak signal
    # (state 3) is the human-attention trigger, not a wall-clock or turn fallback.

    # (4) PARENT-CHILD PROPAGATION: when this goal has spawned workers (via
    # pwt-goal.sh --launch or similar), the worker's retro-complete anchors
    # land in the WORKER's transcript, not the parent's. Transcript-only
    # detection therefore stalls the parent indefinitely (2026-05-20 incident:
    # parent stalled 13 min after worker shipped).
    #
    # The spawned-children registry (.claude/state/plan-w-team-spawned-children-
    # <PARENT_SLUG>.jsonl) authoritatively records which workers this run
    # spawned. Each worker maintains its own goal state file. When every
    # registered worker has a non-null terminal_state, propagate the
    # worst-precedence state to the parent.
    #
    # Precedence (low → high severity):
    #   SUCCESS < LOW_CONFIDENCE_STREAK < USER_ESCALATION_HALT
    # A halted worker must halt the parent (surface to user). A clean worker
    # satisfies parent SUCCESS. Mixed signals win toward the more severe.
    #
    # Fail-open: missing/corrupt worker state never falsely terminates the
    # parent. Self-referential registry rows (slug == parent SLUG) are
    # skipped to prevent infinite hold-open.
    if [ -z "$TERMINAL" ]; then
        REGISTRY="${STATE_DIR}/plan-w-team-spawned-children-${SLUG}.jsonl"
        if [ ! -f "$REGISTRY" ] && [ "$STATE_DIR" != "$FALLBACK_STATE_DIR" ]; then
            REGISTRY="${FALLBACK_STATE_DIR}/plan-w-team-spawned-children-${SLUG}.jsonl"
        fi
        if [ -f "$REGISTRY" ]; then
            CHILD_SLUGS=$(jq -r 'select(.slug != null and .slug != "") | .slug' "$REGISTRY" 2>/dev/null \
                | sort -u)
            if [ -n "$CHILD_SLUGS" ]; then
                ALL_TERMINAL=true
                WORST_STATE=""
                WORST_REASON=""
                CHECKED_COUNT=0
                while IFS= read -r CHILD_SLUG; do
                    [ -z "$CHILD_SLUG" ] && continue
                    # Self-reference guard: prevent infinite hold-open if a
                    # registry row accidentally references the parent itself.
                    [ "$CHILD_SLUG" = "$SLUG" ] && continue

                    CHILD_STATE="${STATE_DIR}/plan-w-team-goal-${CHILD_SLUG}.json"
                    if [ ! -f "$CHILD_STATE" ] && [ "$STATE_DIR" != "$FALLBACK_STATE_DIR" ]; then
                        CHILD_STATE="${FALLBACK_STATE_DIR}/plan-w-team-goal-${CHILD_SLUG}.json"
                    fi

                    if [ ! -f "$CHILD_STATE" ]; then
                        # Child hasn't written its goal state yet — not terminal.
                        ALL_TERMINAL=false
                        continue
                    fi

                    if ! jq -e . "$CHILD_STATE" >/dev/null 2>&1; then
                        # Corrupt child state — warn and skip. Do NOT count
                        # toward ALL_TERMINAL=false; a corrupt file would
                        # otherwise pin the parent forever.
                        echo "[goal-evaluator] WARN: corrupt child state at $CHILD_STATE; skipping" >&2
                        continue
                    fi

                    CHILD_TERMINAL=$(jq -r '.terminal_state // ""' "$CHILD_STATE")
                    if [ -z "$CHILD_TERMINAL" ]; then
                        ALL_TERMINAL=false
                        continue
                    fi
                    CHECKED_COUNT=$((CHECKED_COUNT+1))

                    # Worst-precedence selection.
                    case "$CHILD_TERMINAL" in
                        USER_ESCALATION_HALT)
                            WORST_STATE="USER_ESCALATION_HALT"
                            WORST_REASON=$(jq -r '.terminal_reason // ""' "$CHILD_STATE")
                            ;;
                        LOW_CONFIDENCE_STREAK)
                            if [ "$WORST_STATE" != "USER_ESCALATION_HALT" ]; then
                                WORST_STATE="LOW_CONFIDENCE_STREAK"
                                WORST_REASON=$(jq -r '.terminal_reason // ""' "$CHILD_STATE")
                            fi
                            ;;
                        SUCCESS)
                            if [ -z "$WORST_STATE" ]; then
                                WORST_STATE="SUCCESS"
                                WORST_REASON=$(jq -r '.terminal_reason // ""' "$CHILD_STATE")
                            fi
                            ;;
                    esac
                done <<< "$CHILD_SLUGS"

                if [ "$ALL_TERMINAL" = "true" ] && [ "$CHECKED_COUNT" -gt 0 ] && [ -n "$WORST_STATE" ]; then
                    TERMINAL="$WORST_STATE"
                    REASON="parent SLUG=$SLUG: all $CHECKED_COUNT spawned worker(s) terminal; worst-precedence=$WORST_STATE; worker_reason=$WORST_REASON"
                fi
            fi
        fi
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
            BLOCK_REASON="/plan-w-team SLUG=$SLUG not yet terminal. Continue pipeline. Need ONE of: status block with stage=retro-complete + workflow_lock=done; pending_escalations containing a hard-gate site (push-ack/secret-scan-allow/scope-unlock-for-drift); low_confidence_routes>=3."
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
