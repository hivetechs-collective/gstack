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

# Anchor all tmux operations to the orchestrator's pane/window.
# $TMUX_PANE is inherited from the Claude Code process — it stays correct
# even if the user clicks to a different tmux tab before the hook fires.
ORCHESTRATOR_PANE="${TMUX_PANE:-}"
ORCHESTRATOR_WINDOW=""
if [ -n "$ORCHESTRATOR_PANE" ]; then
    ORCHESTRATOR_WINDOW=$(tmux display-message -t "$ORCHESTRATOR_PANE" -p '#{window_id}' 2>/dev/null || echo "")
fi

# Read JSON input from Claude Code
INPUT=$(cat 2>/dev/null || echo "{}")

# Parse fields from SubagentStart/SubagentStop event schema:
#   SubagentStart: { session_id, agent_id, agent_type, cwd, hook_event_name }
#   SubagentStop:  { ...start fields, agent_transcript_path, last_assistant_message, permission_mode }
if command -v jq &>/dev/null; then
    AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)
    AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "agent"' 2>/dev/null)
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
    AGENT_CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
    TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.agent_transcript_path // ""' 2>/dev/null)
else
    AGENT_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_id',''))" 2>/dev/null || echo "")
    AGENT_TYPE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_type','agent'))" 2>/dev/null || echo "agent")
    SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
    AGENT_CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")
    TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_transcript_path',''))" 2>/dev/null || echo "")
fi

# ─── Construct transcript path for live tailing ────────────────────────────
# Subagent transcripts: ~/.claude/projects/<project-hash>/<session_id>/subagents/agent-<agent_id>.jsonl
if [ -z "$TRANSCRIPT_PATH" ] && [ -n "$SESSION_ID" ] && [ -n "$AGENT_ID" ] && [ -n "$AGENT_CWD" ]; then
    PROJECT_HASH=$(echo "$AGENT_CWD" | sed 's|/|-|g')
    TRANSCRIPT_PATH="$HOME/.claude/projects/${PROJECT_HASH}/${SESSION_ID}/subagents/agent-${AGENT_ID}.jsonl"
fi

SHORT_ID="${AGENT_ID:0:8}"
[ -z "$SHORT_ID" ] && SHORT_ID="$(date +%s | tail -c 8)"

# ─── Look up agent definition from .claude/agents/ by agent_type ────────────
# Agent definitions have frontmatter with `name:` and `color:` fields
AGENTS_DIR="$PROJECT_ROOT/.claude/agents"
AGENT_DEF=""
if [ -n "$AGENT_TYPE" ] && [ "$AGENT_TYPE" != "agent" ]; then
    # Search all subdirs for matching agent definition file
    AGENT_DEF=$(find "$AGENTS_DIR" -name "${AGENT_TYPE}.md" -type f 2>/dev/null | head -1)
fi

# Extract name and color from agent definition frontmatter
AGENT_LABEL=""
AGENT_COLOR=""
if [ -n "$AGENT_DEF" ] && [ -f "$AGENT_DEF" ]; then
    AGENT_LABEL=$(grep '^name:' "$AGENT_DEF" | head -1 | sed 's/^name:[[:space:]]*//')
    AGENT_COLOR=$(grep '^color:' "$AGENT_DEF" | head -1 | sed 's/^color:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr '[:upper:]' '[:lower:]')
fi

# Fallback label: agent_type as-is (e.g. "builder", "general-purpose")
[ -z "$AGENT_LABEL" ] && AGENT_LABEL="$AGENT_TYPE"

# Map color names from agent definitions to tmux colour codes
# Map agent color name → bright (border) + dark (pane background) tmux codes
# Returns: "bright_tmux dark_tmux fg_tmux" (space-separated)
#   bright = border color, dark = pane background, fg = text color on dark bg
map_color() {
    case "$1" in
        red)     echo "colour196 colour52 colour255"  ;;
        green)   echo "colour46 colour22 colour255"   ;;
        blue)    echo "colour33 colour17 colour255"   ;;
        orange)  echo "colour208 colour94 colour255"  ;;
        purple)  echo "colour129 colour53 colour255"  ;;
        yellow)  echo "colour226 colour58 colour255"  ;;
        cyan)    echo "colour51 colour23 colour255"   ;;
        magenta) echo "colour201 colour90 colour255"  ;;
        pink)    echo "colour213 colour125 colour255" ;;
        black)   echo "colour240 colour233 colour250" ;;
        *)       echo ""                              ;;
    esac
}

# Fallback palette: bright + dark + fg triplets
FALLBACK_TRIPLETS=(
    "colour196 colour52 colour255"
    "colour46 colour22 colour255"
    "colour33 colour17 colour255"
    "colour208 colour94 colour255"
    "colour129 colour53 colour255"
    "colour226 colour58 colour255"
    "colour51 colour23 colour255"
    "colour201 colour90 colour255"
)

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

    # Resolve pane colors: agent definition → fallback palette
    COUNT=$(find "$PANE_DIR" -name "*.pane" 2>/dev/null | wc -l | tr -d ' ')
    BRIGHT=""   # border color (bright)
    DARK=""     # pane background (dark tint)
    FG=""       # text on dark background
    if [ -n "$AGENT_COLOR" ]; then
        TRIPLET=$(map_color "$AGENT_COLOR")
        BRIGHT=$(echo "$TRIPLET" | cut -d' ' -f1)
        DARK=$(echo "$TRIPLET" | cut -d' ' -f2)
        FG=$(echo "$TRIPLET" | cut -d' ' -f3)
    fi
    if [ -z "$BRIGHT" ]; then
        IDX=$((COUNT % ${#FALLBACK_TRIPLETS[@]}))
        BRIGHT=$(echo "${FALLBACK_TRIPLETS[$IDX]}" | cut -d' ' -f1)
        DARK=$(echo "${FALLBACK_TRIPLETS[$IDX]}" | cut -d' ' -f2)
        FG=$(echo "${FALLBACK_TRIPLETS[$IDX]}" | cut -d' ' -f3)
    fi

    # ANSI code for background color on name banner (extract number from tmux colour)
    DARK_ANSI=$(echo "$DARK" | sed 's/colour//')
    BRIGHT_ANSI=$(echo "$BRIGHT" | sed 's/colour//')

    # Pane display: use Python transcript viewer if available, else bash timer
    PANE_DISPLAY="$SCRIPT_DIR/utils/pane-display.py"
    TRANSCRIPT_ARG="${TRANSCRIPT_PATH:-}"
    if [ -x "$PANE_DISPLAY" ] && command -v python3 &>/dev/null; then
        PANE_CMD="python3 '${PANE_DISPLAY}' '${AGENT_LABEL}' '${DARK_ANSI}' '${BRIGHT_ANSI}' '${TRANSCRIPT_ARG}'"
    else
        # Fallback: simple bash timer (no transcript tailing)
        cat > "$PANE_DIR/${SHORT_ID}.sh" << 'PANESCRIPT'
#!/bin/bash
NM="$1"; BG="$2"; FG="$3"; T0=$(date +%s)
tput civis 2>/dev/null
trap 'tput cnorm 2>/dev/null; exit 0' EXIT TERM INT
while true; do
    E=$(( $(date +%s) - T0 )); M=$((E/60)); S=$((E%60))
    printf '\033[H\033[J\n'
    printf '  \033[1;38;5;%s;48;5;%sm %s \033[0m  \033[2m%02d:%02d\033[0m\n\n' "$FG" "$BG" "$NM" "$M" "$S"
    printf '  \033[38;5;%sm●\033[0m RUNNING\n' "$FG"
    sleep 1
done
PANESCRIPT
        chmod +x "$PANE_DIR/${SHORT_ID}.sh"
        PANE_CMD="bash '${PANE_DIR}/${SHORT_ID}.sh' '${AGENT_LABEL}' '${DARK_ANSI}' '${BRIGHT_ANSI}'"
    fi
    if [ "$COUNT" -eq 0 ]; then
        # First agent: horizontal split — orchestrator keeps 60% left
        # Target the orchestrator's pane explicitly so the split happens in the
        # correct tmux window even if the user has clicked to another tab.
        SPLIT_TARGET="${ORCHESTRATOR_PANE:+-t $ORCHESTRATOR_PANE}"
        tmux set-option -w ${ORCHESTRATOR_WINDOW:+-t $ORCHESTRATOR_WINDOW} main-pane-width '60%' 2>/dev/null || true
        NEW_PANE=$(tmux split-window -h ${SPLIT_TARGET} -d -P -F '#{pane_id}' "$PANE_CMD" 2>/dev/null) || true
    else
        # Subsequent agents: split last agent's pane vertically (stack on right)
        LAST_FILE=$(ls -t "$PANE_DIR"/*.pane 2>/dev/null | head -1)
        TARGET=""
        [ -n "$LAST_FILE" ] && [ -f "$LAST_FILE" ] && TARGET=$(head -1 "$LAST_FILE")
        if [ -n "$TARGET" ]; then
            NEW_PANE=$(tmux split-window -v -t "$TARGET" -d -P -F '#{pane_id}' "$PANE_CMD" 2>/dev/null) || \
            NEW_PANE=$(tmux split-window -v -d -P -F '#{pane_id}' "$PANE_CMD" 2>/dev/null) || true
        else
            NEW_PANE=$(tmux split-window -v -d -P -F '#{pane_id}' "$PANE_CMD" 2>/dev/null) || true
        fi
    fi

    # If split failed (terminal too small?), exit gracefully
    [ -z "$NEW_PANE" ] && exit 0

    # Bright colored border
    tmux set-option -p -t "$NEW_PANE" pane-border-style "fg=$BRIGHT" 2>/dev/null || true
    tmux set-option -p -t "$NEW_PANE" pane-active-border-style "fg=$BRIGHT" 2>/dev/null || true

    # Agent name in pane border header (target orchestrator's window, not focused window)
    tmux set-option -w ${ORCHESTRATOR_WINDOW:+-t $ORCHESTRATOR_WINDOW} pane-border-status top 2>/dev/null || true
    tmux set-option -p -t "$NEW_PANE" pane-border-format \
        " #[fg=${BRIGHT},bold]${AGENT_LABEL}#[default] " 2>/dev/null || true

    # Rebalance: main-vertical keeps orchestrator wide on left, agents stacked right
    tmux select-layout ${ORCHESTRATOR_WINDOW:+-t $ORCHESTRATOR_WINDOW} main-vertical 2>/dev/null || true

    # Return focus to orchestrator pane (use $ORCHESTRATOR_PANE, not hardcoded 0)
    tmux select-pane ${ORCHESTRATOR_PANE:+-t $ORCHESTRATOR_PANE} 2>/dev/null || true

    # Persist pane state: pane_id, agent_label, bright_color, dark_bg, fg_color
    printf '%s\n%s\n%s\n%s\n%s\n' "$NEW_PANE" "$AGENT_LABEL" "$BRIGHT" "$DARK" "$FG" \
        > "$PANE_DIR/${SHORT_ID}.pane"
    ;;

# ─── SUBAGENT STOP ──────────────────────────────────────────────────────────
stop)
    PANE_FILE="$PANE_DIR/${SHORT_ID}.pane"

    # Fallback: find pane state by scanning all .pane files for matching agent ID
    if [ ! -f "$PANE_FILE" ]; then
        for pf in "$PANE_DIR"/*.pane; do
            [ -f "$pf" ] || continue
            PANE_FILE="$pf"
            SHORT_ID=$(basename "$pf" .pane)
            break
        done
    fi

    [ ! -f "$PANE_FILE" ] && exit 0

    PANE_ID=$(sed -n '1p' "$PANE_FILE")
    STORED_LABEL=$(sed -n '2p' "$PANE_FILE")
    BRIGHT=$(sed -n '3p' "$PANE_FILE")
    DARK=$(sed -n '4p' "$PANE_FILE")

    # ANSI codes for completion banner
    DARK_N=$(echo "$DARK" | sed 's/colour//')
    BRIGHT_N=$(echo "$BRIGHT" | sed 's/colour//')

    # Flash completion with colored banner
    tmux respawn-pane -t "$PANE_ID" -k \
        "printf '\\n  \\033[1;38;5;${BRIGHT_N};48;5;${DARK_N}m ${STORED_LABEL} \\033[0m\\n\\n  \\033[38;5;${BRIGHT_N}m✓\\033[0m COMPLETED\\n'; sleep 5" \
        2>/dev/null || {
        tmux kill-pane -t "$PANE_ID" 2>/dev/null || true
        rm -f "$PANE_FILE" "$PANE_DIR/${SHORT_ID}.sh" 2>/dev/null || true
        exit 0
    }

    # Update border to show completion checkmark
    tmux set-option -p -t "$PANE_ID" pane-border-format \
        " #[fg=${BRIGHT},bold]${STORED_LABEL} ✓#[default] " 2>/dev/null || true

    # Background: close pane after delay, clean state, rebalance in orchestrator's window
    ORCH_WIN="$ORCHESTRATOR_WINDOW"
    (
        sleep 6
        tmux kill-pane -t "$PANE_ID" 2>/dev/null || true
        rm -f "$PANE_FILE" "$PANE_DIR/${SHORT_ID}.sh" "$PANE_DIR/${SHORT_ID}.meta" 2>/dev/null || true
        if find "$PANE_DIR" -name "*.pane" 2>/dev/null | grep -q .; then
            tmux select-layout ${ORCH_WIN:+-t $ORCH_WIN} main-vertical 2>/dev/null || true
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
