#!/usr/bin/env bash
# pwt-watch.sh
#
# Background completion watcher for a /plan-w-team autonomous session.
# Polls ~/.claude/jobs/<session_id>/state.json until state becomes "stopped"
# (or a configurable timeout), then fires a macOS notification.
#
# Spawned by .claude/hooks/plan-w-team-route-prompt.sh after a successful
# auto-launch. One watcher per session. Self-exits when done — no daemon.
#
# Usage: pwt-watch.sh <session_id> [poll_interval_sec] [max_minutes]
#   session_id        — 8-char or full UUID
#   poll_interval_sec — default 30
#   max_minutes       — default 720 (12h) — sanity cap, not a /plan-w-team cap
#
# Silent on success/failure. Logs to /tmp/pwt-watch-<sid>.log for forensics.

set -u

SESSION_ID="${1:-}"
POLL="${2:-30}"
MAX_MIN="${3:-720}"

[ -z "$SESSION_ID" ] && exit 0

LOG="/tmp/pwt-watch-${SESSION_ID}.log"
exec >>"$LOG" 2>&1
echo "[$(date '+%F %T')] pwt-watch starting for session=$SESSION_ID poll=${POLL}s max=${MAX_MIN}m"

# Resolve full UUID from 8-char short form by scanning jobs dir
JOBS_DIR="$HOME/.claude/jobs"
RESOLVED=""
for candidate in "$JOBS_DIR/$SESSION_ID" "$JOBS_DIR/${SESSION_ID}"*; do
    if [ -d "$candidate" ]; then
        RESOLVED=$(basename "$candidate")
        break
    fi
done

if [ -z "$RESOLVED" ]; then
    echo "[$(date '+%F %T')] could not resolve session_id to jobs dir — initial wait"
    # claude --bg may not have created the dir yet; wait a bit then try again
    sleep 10
    for candidate in "$JOBS_DIR/$SESSION_ID" "$JOBS_DIR/${SESSION_ID}"*; do
        if [ -d "$candidate" ]; then
            RESOLVED=$(basename "$candidate")
            break
        fi
    done
fi

if [ -z "$RESOLVED" ]; then
    echo "[$(date '+%F %T')] jobs dir never appeared — abandoning watch"
    exit 0
fi

STATE_FILE="$JOBS_DIR/$RESOLVED/state.json"
echo "[$(date '+%F %T')] watching $STATE_FILE"

START=$(date +%s)
MAX_SEC=$((MAX_MIN * 60))

while true; do
    if [ ! -f "$STATE_FILE" ]; then
        sleep "$POLL"; continue
    fi
    state=$(jq -r '.state // empty' "$STATE_FILE" 2>/dev/null || echo "")
    detail=$(jq -r '.detail // empty' "$STATE_FILE" 2>/dev/null || echo "")
    echo "[$(date '+%F %T')] state=$state detail=$detail"

    if [ "$state" = "stopped" ] || [ "$state" = "blocked" ]; then
        short_id=$(printf '%s' "$RESOLVED" | head -c 8)

        # ─── Build completion summary from latest retro JSON ─────────────────
        # Look at the most-recently-modified retro/postship/coupling artifact
        # under .claude/state/ to extract metrics + slug. We don't know the
        # exact slug here (the session may have named anything), so we pick
        # whichever retro was last touched within ~5 min of the session stop.
        PROJECT_DIR_GUESS=$(jq -r '.cwd // empty' "$STATE_FILE" 2>/dev/null || echo "")
        SUMMARY_HEAD="Session $short_id finished ($state${detail:+ — $detail})"
        SUMMARY_BODY=""
        SUMMARY_FILE=""
        if [ -n "$PROJECT_DIR_GUESS" ] && [ -d "$PROJECT_DIR_GUESS/.claude/state" ]; then
            STATE_GLOB="$PROJECT_DIR_GUESS/.claude/state/plan-w-team-retro-*.json"
            LATEST_RETRO=$(ls -t $STATE_GLOB 2>/dev/null | head -1)
            if [ -n "$LATEST_RETRO" ] && [ -f "$LATEST_RETRO" ]; then
                # Only consider it relevant if touched within 10 min of stop
                RETRO_AGE=$(( $(date +%s) - $(stat -f %m "$LATEST_RETRO" 2>/dev/null || echo 0) ))
                if [ "$RETRO_AGE" -lt 600 ]; then
                    SLUG=$(jq -r '.slug // empty' "$LATEST_RETRO" 2>/dev/null)
                    AC_PASS=$(jq -r '.metrics.ac_passing // empty' "$LATEST_RETRO" 2>/dev/null)
                    AC_COUNT=$(jq -r '.metrics.ac_count // empty' "$LATEST_RETRO" 2>/dev/null)
                    COMMITS=$(jq -r '.metrics.commits // empty' "$LATEST_RETRO" 2>/dev/null)
                    TASKS=$(jq -r '.metrics.tasks_completed // empty' "$LATEST_RETRO" 2>/dev/null)
                    FILES=$(jq -r '.metrics.files_changed // empty' "$LATEST_RETRO" 2>/dev/null)
                    SCORE=$(jq -r '.self_assessment.score // empty' "$LATEST_RETRO" 2>/dev/null)
                    SCORE_TEXT=$(jq -r '.self_assessment.rationale // empty' "$LATEST_RETRO" 2>/dev/null)

                    # Build headline for notification: "X/Y ACs, N commits"
                    parts=""
                    [ -n "$AC_PASS" ] && [ -n "$AC_COUNT" ] && parts="${parts}${AC_PASS}/${AC_COUNT} ACs"
                    [ -n "$COMMITS" ] && parts="${parts}${parts:+, }${COMMITS} commits"
                    [ -n "$TASKS" ] && parts="${parts}${parts:+, }${TASKS} tasks"
                    [ -n "$parts" ] && SUMMARY_HEAD="$short_id done: $parts"

                    # Build multi-line body for the file the user can read
                    SUMMARY_FILE="$PROJECT_DIR_GUESS/.claude/state/last-pwt-completion.md"
                    {
                        printf "# /plan-w-team completion — %s\n\n" "$short_id"
                        printf "**Session:** %s\n" "$RESOLVED"
                        printf "**Slug:** %s\n" "${SLUG:-unknown}"
                        printf "**Finished:** %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
                        printf "**Terminal state:** %s%s\n\n" "$state" "${detail:+ ($detail)}"
                        printf "## Metrics\n\n"
                        [ -n "$AC_PASS" ] && [ -n "$AC_COUNT" ] && printf "- Acceptance criteria: **%s of %s passing**\n" "$AC_PASS" "$AC_COUNT"
                        [ -n "$COMMITS" ] && printf "- Commits: **%s**\n" "$COMMITS"
                        [ -n "$TASKS" ] && printf "- Tasks completed: **%s**\n" "$TASKS"
                        [ -n "$FILES" ] && printf "- Files changed: **%s**\n" "$FILES"
                        [ -n "$SCORE" ] && printf "- Self-assessment: **%s/10**\n" "$SCORE"
                        printf "\n## Self-assessment\n\n"
                        [ -n "$SCORE_TEXT" ] && printf "%s\n\n" "$SCORE_TEXT"
                        printf "## Source\n\n"
                        printf "Full retro JSON: \`%s\`\n" "$LATEST_RETRO"
                        printf "Session output: \`claude logs %s\`\n" "$short_id"
                    } > "$SUMMARY_FILE" 2>/dev/null
                fi
            fi
        fi

        # ─── Fire notification ───────────────────────────────────────────────
        msg_for_notify=$(printf '%s' "$SUMMARY_HEAD" | sed 's/"/\\"/g')
        if [ -n "$SUMMARY_FILE" ]; then
            click_action="$msg_for_notify\nFull summary: $SUMMARY_FILE"
        else
            click_action="$msg_for_notify"
        fi
        osascript -e "display notification \"$click_action\" with title \"/plan-w-team\" sound name \"Glass\"" 2>/dev/null || true
        echo "[$(date '+%F %T')] notified — exiting (summary=${SUMMARY_FILE:-none})"
        exit 0
    fi

    elapsed=$(( $(date +%s) - START ))
    if [ "$elapsed" -ge "$MAX_SEC" ]; then
        osascript -e "display notification \"Session $(printf '%s' "$RESOLVED" | head -c 8) still running after ${MAX_MIN}m\" with title \"/plan-w-team\"" 2>/dev/null || true
        echo "[$(date '+%F %T')] max time reached — exiting"
        exit 0
    fi

    sleep "$POLL"
done
