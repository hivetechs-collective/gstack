#!/bin/bash
# plan-w-team Fleet State Writer Hook
#
# Fired by SubagentStart and SubagentStop to record agent lifecycle events
# into .claude/state/plan-w-team-fleet-<SLUG>.jsonl. The SLUG is derived from
# the active workflow lock so the hook participates in /plan-w-team runs
# without requiring lead-side env wiring.
#
# Spec: docs/specs/pwt-supervisor-goal.md
# Reader: .claude/scripts/plan-w-team-fleet-query.sh
# Kill switch: PLAN_W_TEAM_FLEET_DISABLE=1
#
# Contract: NEVER block agent workflow. All error paths exit 0.

set -u

[ "${PLAN_W_TEAM_FLEET_DISABLE:-}" = "1" ] && exit 0

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
STATE_DIR="$PROJECT_ROOT/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

INPUT=$(cat 2>/dev/null || echo "{}")
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if command -v jq >/dev/null 2>&1; then
    EVENT_NAME=$(echo "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null)
    AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)
    AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null)
    CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
    LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null | head -c 100 | tr -d '\n\r' | sed 's/"/\\"/g')
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
else
    EVENT_NAME=""
    AGENT_ID=""
    AGENT_TYPE=""
    CWD=""
    LAST_MSG=""
    # The session id decides which run (if any) takes the subagent, so it is read even
    # without jq. A quote inside a JSON string is escaped, so this cannot match text.
    SESSION_ID=$(printf '%s' "$INPUT" | tr -d '\n\r' \
        | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9-]*\)".*/\1/p' | head -n 1)
fi
# A Claude Code session id is a UUID. Anything else is not compared.
case "$SESSION_ID" in *[!A-Za-z0-9-]*) SESSION_ID="" ;; esac

# Fall back to positional arg ($1 = start|stop) when hook_event_name absent
if [ -z "$EVENT_NAME" ]; then
    case "${1:-}" in
        start) EVENT_NAME="SubagentStart" ;;
        stop)  EVENT_NAME="SubagentStop"  ;;
    esac
fi

case "$EVENT_NAME" in
    SubagentStart) EVENT="spawn"    ;;
    SubagentStop)  EVENT="complete" ;;
    *)             exit 0           ;;
esac

# Derive SLUG from active workflow lock(s)
SLUG=""
shopt -s nullglob
LOCK_DIRS=("$STATE_DIR"/plan-w-team-workflow-*.lock)
shopt -u nullglob

# Recursive-followup row 191 + review r3: the lock is held for the whole run and left
# behind at retro-complete with state=released, and a crashed run leaves one whose owner
# is gone. A subagent is credited to a run only when BOTH hold:
#   - this hook's `session_id` is the lock owner's `session=` (the lead's
#     CLAUDE_CODE_SESSION_ID, which is the session id Claude Code puts in the lead's
#     SubagentStart/SubagentStop input). Any live lock used to take every subagent in the
#     checkout, so another session's subagents were logged into the run's fleet and kept
#     its state family fresh for the janitor.
#   - the lock is held, as the janitor reads it: not released, and an owner pid that is
#     present with the recorded `start=` (a reused pid is someone else). A pid that is not
#     a decimal above 1 proves nothing either way (`kill -0 0` succeeds for anyone), so
#     it counts as held; the session match still has to decide.
# No credit when the lock cannot be tied to a session: no `owner` record (pre-row-191,
# when the pre-flight's EXIT trap removed the lock before any subagent ran, so such a lock
# names no running workflow), an owner with an empty `session=` (the pre-flight had no
# CLAUDE_CODE_SESSION_ID), or an input without a usable `session_id`.
if [ "${#LOCK_DIRS[@]}" -gt 0 ]; then
    LIVE_LOCKS=()
    for __lk in "${LOCK_DIRS[@]}"; do
        [ -n "$SESSION_ID" ] || break
        [ "$(cat "$__lk/state" 2>/dev/null)" = "released" ] && continue
        [ -f "$__lk/owner" ] || continue
        __ls=$(sed -n 's/^session=//p' "$__lk/owner" 2>/dev/null | head -n 1)
        [ "$__ls" = "$SESSION_ID" ] || continue
        __lp=$(sed -n 's/^pid=//p' "$__lk/owner" 2>/dev/null | head -n 1)
        case "$__lp" in
            ""|0*|1|*[!0-9]*) ;;
            *)
                if ! kill -0 "$__lp" 2>/dev/null \
                   && [ -z "$(ps -o pid= -p "$__lp" 2>/dev/null)" ]; then
                    continue
                fi
                __lst=$(sed -n 's/^start=//p' "$__lk/owner" 2>/dev/null | head -n 1)
                if [ -n "$__lst" ]; then
                    __lcur=$(TZ=UTC LC_ALL=C ps -o lstart= -p "$__lp" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')
                    [ -n "$__lcur" ] && [ "$__lcur" != "$__lst" ] && continue
                fi ;;
        esac
        LIVE_LOCKS+=("$__lk")
    done
    LOCK_DIRS=(${LIVE_LOCKS[@]+"${LIVE_LOCKS[@]}"})
fi

if [ "${#LOCK_DIRS[@]}" -eq 0 ]; then
    exit 0
elif [ "${#LOCK_DIRS[@]}" -eq 1 ]; then
    LOCK_BASENAME=$(basename "${LOCK_DIRS[0]}")
    SLUG="${LOCK_BASENAME#plan-w-team-workflow-}"
    SLUG="${SLUG%.lock}"
else
    NEWEST_LOCK=$(ls -t -d "${LOCK_DIRS[@]}" 2>/dev/null | head -1)
    LOCK_BASENAME=$(basename "$NEWEST_LOCK")
    SLUG="${LOCK_BASENAME#plan-w-team-workflow-}"
    SLUG="${SLUG%.lock}"
    echo "[fleet-writer] WARN: ${#LOCK_DIRS[@]} active workflow locks; using newest ($SLUG)" >&2
fi

FLEET_FILE="$STATE_DIR/plan-w-team-fleet-${SLUG}.jsonl"

# If agent_id is missing, write an error row so retro can surface the gap
if [ -z "$AGENT_ID" ]; then
    printf '{"ts":"%s","event":"error","slug":"%s","reason":"missing agent_id in %s payload"}\n' \
        "$TS" "$SLUG" "$EVENT_NAME" >> "$FLEET_FILE" 2>/dev/null
    exit 0
fi

if [ "$EVENT" = "spawn" ]; then
    printf '{"ts":"%s","event":"spawn","slug":"%s","agent_id":"%s","agent_type":"%s","cwd":"%s"}\n' \
        "$TS" "$SLUG" "$AGENT_ID" "$AGENT_TYPE" "$CWD" >> "$FLEET_FILE" 2>/dev/null
else
    printf '{"ts":"%s","event":"complete","slug":"%s","agent_id":"%s","last_msg":"%s"}\n' \
        "$TS" "$SLUG" "$AGENT_ID" "$LAST_MSG" >> "$FLEET_FILE" 2>/dev/null
fi

exit 0
