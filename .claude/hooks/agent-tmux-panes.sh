#!/bin/bash
# Agent Tmux Panes — Visual orchestration for parallel builder agents
#
# Creates colored tmux panes for subagents during parallel execution.
# Each builder gets its own pane with colored border, name label, and live timer.
#
# SubagentStart: creates new pane with unique color + running timer
# SubagentStop: flashes completion status, then closes pane after delay
#
# Layout: main-vertical — orchestrator 60% left, builder panes stacked right
# Graceful: exits silently if not inside tmux or tmux not installed
#
# Disable: CLAUDE_AGENT_PANES=0

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils/hook-profile.sh"
hook_gate "subagent:tmux-panes" "standard,strict"

# Opt-out switch
[ "${CLAUDE_AGENT_PANES:-1}" = "0" ] && { cat >/dev/null; exit 0; }

# Graceful degradation: not in tmux or tmux missing
if [ -z "$TMUX" ] || ! command -v tmux &>/dev/null; then
    cat >/dev/null
    exit 0
fi

PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PANE_DIR="$PROJECT_ROOT/.claude/state/agent-panes"
mkdir -p "$PANE_DIR"

# Read JSON input from Claude Code
INPUT=$(cat 2>/dev/null || echo "{}")

# Parse input fields
if command -v jq &>/dev/null; then
    AGENT_NAME=$(echo "$INPUT" | jq -r '.agent_name // .name // "agent"' 2>/dev/null)
    AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // .id // ""' 2>/dev/null)
    TASK_DESC=$(echo "$INPUT" | jq -r '.description // .task // .prompt // ""' 2>/dev/null | head -c 60)
else
    AGENT_NAME=$(echo "$INPUT" | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d.get('agent_name',d.get('name','agent')))" 2>/dev/null || echo "agent")
    AGENT_ID=$(echo "$INPUT" | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d.get('agent_id',d.get('id','')))" 2>/dev/null || echo "")
    TASK_DESC=$(echo "$INPUT" | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(d.get('description',d.get('task',d.get('prompt','')))[:60])" 2>/dev/null || echo "")
fi

SHORT_ID="${AGENT_ID:0:8}"
[ -z "$SHORT_ID" ] && SHORT_ID="$(date +%s | tail -c 8)"

# 8-color palette — cycles for each new agent
# Ordered for max visual distinction between adjacent panes
BORDER_COLORS=("colour196" "colour46" "colour33" "colour208" "colour129" "colour226" "colour51" "colour201")
LABELS=(       "RED"       "GRN"      "BLU"      "ORG"       "PRP"       "YLW"       "CYN"      "MAG")

EVENT="$1"  # "start", "stop", or "cleanup"

case "$EVENT" in

# ─── SUBAGENT START ─────────────────────────────────────────────────────────
start)
    # Prune stale pane state from crashed/compacted sessions
    for pf in "$PANE_DIR"/*.pane; do
        [ -f "$pf" ] || continue
        OLD_PANE=$(head -1 "$pf" 2>/dev/null || echo "")
        [ -z "$OLD_PANE" ] && { rm -f "$pf" "${pf%.pane}.sh"; continue; }
        if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qF "$OLD_PANE"; then
            rm -f "$pf" "${pf%.pane}.sh" 2>/dev/null
        fi
    done

    # Pick next color from palette
    COUNT=$(find "$PANE_DIR" -name "*.pane" 2>/dev/null | wc -l | tr -d ' ')
    IDX=$((COUNT % ${#BORDER_COLORS[@]}))
    COLOR="${BORDER_COLORS[$IDX]}"
    LABEL="${LABELS[$IDX]}"

    # Write per-pane display script (avoids shell escaping in tmux split-window)
    cat > "$PANE_DIR/${SHORT_ID}.sh" << 'PANESCRIPT'
#!/bin/bash
LBL="$1"; NM="$2"; DSC="$3"; T0=$(date +%s)
tput civis 2>/dev/null  # hide cursor
trap 'tput cnorm 2>/dev/null; exit 0' EXIT TERM INT
while true; do
    E=$(( $(date +%s) - T0 )); M=$((E/60)); S=$((E%60))
    printf '\033[H\033[J'  # cursor home + clear screen
    printf '\n'
    printf '  \033[1m[%s]\033[0m %s\n' "$LBL" "$NM"
    [ -n "$DSC" ] && printf '  \033[2m%s\033[0m\n' "$DSC"
    printf '\n'
    printf '  \033[32m●\033[0m RUNNING  %02d:%02d\n' "$M" "$S"
    printf '\n'
    sleep 1
done
PANESCRIPT
    chmod +x "$PANE_DIR/${SHORT_ID}.sh"

    # Create the tmux pane
    if [ "$COUNT" -eq 0 ]; then
        # First builder: horizontal split — orchestrator keeps 60% left
        tmux set-option -w main-pane-width '60%' 2>/dev/null || true
        NEW_PANE=$(tmux split-window -h -d -P -F '#{pane_id}' \
            "bash '${PANE_DIR}/${SHORT_ID}.sh' '$LABEL' '$AGENT_NAME' '$TASK_DESC'" 2>/dev/null) || true
    else
        # Subsequent builders: split last builder's pane vertically (stack on right)
        LAST_FILE=$(ls -t "$PANE_DIR"/*.pane 2>/dev/null | head -1)
        TARGET=""
        [ -n "$LAST_FILE" ] && [ -f "$LAST_FILE" ] && TARGET=$(head -1 "$LAST_FILE")
        if [ -n "$TARGET" ]; then
            NEW_PANE=$(tmux split-window -v -t "$TARGET" -d -P -F '#{pane_id}' \
                "bash '${PANE_DIR}/${SHORT_ID}.sh' '$LABEL' '$AGENT_NAME' '$TASK_DESC'" 2>/dev/null) || \
            NEW_PANE=$(tmux split-window -v -d -P -F '#{pane_id}' \
                "bash '${PANE_DIR}/${SHORT_ID}.sh' '$LABEL' '$AGENT_NAME' '$TASK_DESC'" 2>/dev/null) || true
        else
            NEW_PANE=$(tmux split-window -v -d -P -F '#{pane_id}' \
                "bash '${PANE_DIR}/${SHORT_ID}.sh' '$LABEL' '$AGENT_NAME' '$TASK_DESC'" 2>/dev/null) || true
        fi
    fi

    # If split failed (terminal too small?), exit gracefully
    [ -z "$NEW_PANE" ] && exit 0

    # Style pane border with agent's unique color
    tmux set-option -p -t "$NEW_PANE" pane-border-style "fg=$COLOR" 2>/dev/null || true
    tmux set-option -p -t "$NEW_PANE" pane-active-border-style "fg=$COLOR" 2>/dev/null || true

    # Show agent name in pane border header
    tmux set-option -w pane-border-status top 2>/dev/null || true
    tmux set-option -p -t "$NEW_PANE" pane-border-format \
        " #[fg=${COLOR},bold][${LABEL}]#[default] ${AGENT_NAME} " 2>/dev/null || true

    # Rebalance: main-vertical keeps orchestrator wide on left, builders stacked right
    tmux select-layout main-vertical 2>/dev/null || true

    # Return focus to orchestrator pane
    tmux select-pane -t 0 2>/dev/null || true

    # Persist pane state for stop/cleanup
    printf '%s\n%s\n%s\n%s\n' "$NEW_PANE" "$AGENT_NAME" "$LABEL" "$COLOR" \
        > "$PANE_DIR/${SHORT_ID}.pane"
    ;;

# ─── SUBAGENT STOP ──────────────────────────────────────────────────────────
stop)
    PANE_FILE="$PANE_DIR/${SHORT_ID}.pane"

    # Fallback: match by agent name if ID lookup missed
    if [ ! -f "$PANE_FILE" ]; then
        for pf in "$PANE_DIR"/*.pane; do
            [ -f "$pf" ] || continue
            if sed -n '2p' "$pf" 2>/dev/null | grep -qF "$AGENT_NAME"; then
                PANE_FILE="$pf"
                SHORT_ID=$(basename "$pf" .pane)
                break
            fi
        done
    fi

    [ ! -f "$PANE_FILE" ] && exit 0

    PANE_ID=$(sed -n '1p' "$PANE_FILE")
    LABEL=$(sed -n '3p' "$PANE_FILE")
    COLOR=$(sed -n '4p' "$PANE_FILE")

    # Flash completion status in the pane (replaces running timer)
    tmux respawn-pane -t "$PANE_ID" -k \
        "printf '\\n  \\033[1m[${LABEL}]\\033[0m ${AGENT_NAME}\\n\\n  \\033[36m✓\\033[0m COMPLETED\\n'; sleep 5" \
        2>/dev/null || {
        # Fallback if respawn-pane not supported: just kill immediately
        tmux kill-pane -t "$PANE_ID" 2>/dev/null || true
        rm -f "$PANE_FILE" "$PANE_DIR/${SHORT_ID}.sh" 2>/dev/null || true
        exit 0
    }

    # Update border to show completion checkmark
    tmux set-option -p -t "$PANE_ID" pane-border-format \
        " #[fg=${COLOR},bold][${LABEL}]#[fg=green,bold] ✓#[default] ${AGENT_NAME} " 2>/dev/null || true

    # Background: close pane after delay, clean state, rebalance remaining
    (
        sleep 6
        tmux kill-pane -t "$PANE_ID" 2>/dev/null || true
        rm -f "$PANE_FILE" "$PANE_DIR/${SHORT_ID}.sh" 2>/dev/null || true
        if find "$PANE_DIR" -name "*.pane" 2>/dev/null | grep -q .; then
            tmux select-layout main-vertical 2>/dev/null || true
        fi
    ) &
    disown 2>/dev/null || true
    ;;

# ─── MANUAL CLEANUP ─────────────────────────────────────────────────────────
cleanup)
    for pf in "$PANE_DIR"/*.pane; do
        [ -f "$pf" ] || continue
        tmux kill-pane -t "$(head -1 "$pf")" 2>/dev/null || true
    done
    rm -f "$PANE_DIR"/*.pane "$PANE_DIR"/*.sh 2>/dev/null || true
    ;;

esac

exit 0
