#!/usr/bin/env bash
# plan-w-team-companion-gc.sh
#
# Garbage-collect orphan COMPANION processes spawned by /plan-w-team that watch
# subagents / bg sessions but are never killed when their target dies:
#
#   * pane-display.py  — per-subagent tmux pane spinner that tails the agent's
#                        JSONL transcript. Spawned on subagent start, never
#                        killed on subagent end. Orphan when the agent has a
#                        tool_result in the parent transcript OR its worktree
#                        (.claude/worktrees/agent-<id>/) no longer exists.
#   * pwt-watch.sh     — per-bg-session completion watcher. Orphan when the
#                        session no longer appears in claude-agents-extended.sh
#                        --bg-only.
#
# For each orphan pane-display.py we ALSO `tmux kill-pane` the pane it occupies
# (mapped via `tmux list-panes -F '#{pane_id} #{pane_pid}'`).
#
# Usage:
#   plan-w-team-companion-gc.sh                 # dry-run table (default)
#   plan-w-team-companion-gc.sh --execute       # kill orphan processes + panes
#   plan-w-team-companion-gc.sh --json          # machine-readable output
#   plan-w-team-companion-gc.sh --sid <SID>     # restrict to one agent/session id
#
# Safety:
#   * WHITELIST-ONLY: only processes whose argv contains the exact path
#     `.claude/hooks/utils/pane-display.py` or `.claude/scripts/pwt-watch.sh`
#     are ever candidates. Nothing else is touched.
#   * SAME-UID-ONLY: never signals a process owned by another user.
#   * IDEMPOTENT: re-running with no orphans = no-op, exit 0.
#   * Never kills a companion whose target is still live.
#
# Environment:
#   PWT_COMPANION_GC_DISABLE=1        no-op (exit 0)
#   PWT_COMPANION_GC_TEST_PS         path to a file with canned `ps` output (tests)
#   PWT_COMPANION_GC_TEST_LIVE_SIDS  newline list of bg sids treated as live (tests)
#   PWT_COMPANION_GC_TEST_NO_KILL=1  classify only; never actually kill (tests)
#   CLAUDE_PROJECT_DIR                main checkout (fallback when not in git)
#
# Spec: docs/specs/worktree-lifecycle-cleanup.md
# Callers: SubagentStop hook, Step 8 retro, weekly launchd job
# Tests: .claude/scripts/plan-w-team-companion-gc.test.sh

set -u
set -o pipefail

if [ "${PWT_COMPANION_GC_DISABLE:-0}" = "1" ]; then
    printf '{"skipped":true,"reason":"PWT_COMPANION_GC_DISABLE=1","companions":[]}\n'
    exit 0
fi

MODE_EXECUTE=0
MODE_JSON=0
SCOPE_SID=""

while [ $# -gt 0 ]; do
    case "$1" in
        --execute) MODE_EXECUTE=1; shift ;;
        --json)    MODE_JSON=1; shift ;;
        --sid)     SCOPE_SID="${2:-}"; shift 2 || { echo "missing --sid value" >&2; exit 2; } ;;
        --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ "${PWT_COMPANION_GC_TEST_NO_KILL:-0}" = "1" ] && MODE_EXECUTE=0

# ─── resolve main checkout ────────────────────────────────────────────────
COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
if [ -n "$COMMON_DIR" ]; then
    MAIN_CHECKOUT="$(dirname "$(realpath "$COMMON_DIR" 2>/dev/null || echo "$COMMON_DIR")")"
else
    MAIN_CHECKOUT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
fi
WORKTREES_DIR="$MAIN_CHECKOUT/.claude/worktrees"

PANE_DISPLAY_MARKER=".claude/hooks/utils/pane-display.py"
PWT_WATCH_MARKER=".claude/scripts/pwt-watch.sh"

MY_UID="$(id -u)"

# ─── gather ps output (pid, uid, full args) ──────────────────────────────
get_ps() {
    if [ -n "${PWT_COMPANION_GC_TEST_PS:-}" ] && [ -f "${PWT_COMPANION_GC_TEST_PS}" ]; then
        cat "$PWT_COMPANION_GC_TEST_PS"
    else
        # pid, ruid, then full command. -ww = unlimited width.
        ps -axww -o pid=,uid=,args= 2>/dev/null || true
    fi
}

# ─── parent-transcript tool_result check for an agent id ──────────────────
# Returns 0 (terminal) if the agent's .meta.json toolUseId has a tool_result in
# its parent transcript, OR the agent worktree dir is gone.
agent_is_terminal() {
    local agent_id="$1"
    # If worktree gone → terminal (companion is definitively orphaned)
    if [ ! -d "$WORKTREES_DIR/agent-$agent_id" ]; then
        return 0
    fi
    # Otherwise look for the agent's meta sidecar + tool_result in parent transcript.
    local projects_dir="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
    local meta tooluse parent
    meta="$(find "$projects_dir" -type f -name '.meta.json' -path "*agent-$agent_id*" 2>/dev/null | head -1)"
    if [ -z "$meta" ]; then
        # Fallback: look for the subagent JSONL freshness — if mtime older than
        # SUBAGENT_FRESHNESS_SEC, treat as terminal.
        local jsonl
        jsonl="$(find "$projects_dir" -type f -name "agent-$agent_id*.jsonl" 2>/dev/null | head -1)"
        [ -z "$jsonl" ] && return 0   # no transcript at all → terminal
        local fresh="${SUBAGENT_FRESHNESS_SEC:-60}"
        local mt now age
        mt="$(stat -f %m "$jsonl" 2>/dev/null || stat -c %Y "$jsonl" 2>/dev/null || echo 0)"
        now="$(date +%s)"
        age=$(( now - mt ))
        [ "$age" -ge "$fresh" ] && return 0
        return 1
    fi
    tooluse="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("toolUseId",""))' "$meta" 2>/dev/null || echo "")"
    parent="$(dirname "$(dirname "$meta")")"  # parent transcript dir
    [ -z "$tooluse" ] && return 0
    # Search parent transcript JSONLs for a tool_result carrying that toolUseId
    if grep -rqlF "$tooluse" "$parent"/*.jsonl 2>/dev/null; then
        if grep -rhF "$tooluse" "$parent"/*.jsonl 2>/dev/null | grep -q 'tool_result'; then
            return 0
        fi
    fi
    return 1
}

# ─── bg session liveness ──────────────────────────────────────────────────
LIVE_BG_SIDS=""
if [ -n "${PWT_COMPANION_GC_TEST_LIVE_SIDS:-}" ]; then
    LIVE_BG_SIDS="$PWT_COMPANION_GC_TEST_LIVE_SIDS"
else
    AGENTS_EXTENDED="${PWT_COMPANION_GC_AGENTS_EXTENDED:-$MAIN_CHECKOUT/.claude/scripts/claude-agents-extended.sh}"
    if [ -x "$AGENTS_EXTENDED" ]; then
        LIVE_BG_SIDS="$("$AGENTS_EXTENDED" --bg-only 2>/dev/null | python3 -c '
import json, sys
try:
    data=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for e in (data if isinstance(data,list) else []):
    sid=e.get("sessionId") or e.get("session_id") or e.get("id") or ""
    if sid: print(sid)
' 2>/dev/null || true)"
    fi
fi

bg_sid_is_live() {
    local sid="$1"
    [ -z "$LIVE_BG_SIDS" ] && return 1
    # match full or 8-char prefix in either direction
    while IFS= read -r live; do
        [ -z "$live" ] && continue
        case "$live" in "$sid"*) return 0 ;; esac
        case "$sid" in "$live"*) return 0 ;; esac
    done <<< "$LIVE_BG_SIDS"
    return 1
}

# ─── tmux pane map (pane_pid → pane_id) ───────────────────────────────────
tmux_pane_for_pid() {
    local target_pid="$1"
    command -v tmux >/dev/null 2>&1 || return 1
    tmux list-panes -a -F '#{pane_id} #{pane_pid}' 2>/dev/null | while read -r pane_id pane_pid; do
        if [ "$pane_pid" = "$target_pid" ]; then
            echo "$pane_id"
            return 0
        fi
    done
}

# ─── extract agent id from a pane-display.py argv ─────────────────────────
# argv: pane-display.py <name> <bg> <fg> <transcript-path>; the transcript path
# contains `agent-<id>`. Fall back to scanning the whole argv.
extract_agent_id() {
    local args="$1"
    echo "$args" | grep -oE 'agent-[0-9a-f]+' | head -1 | sed 's/^agent-//'
}

# ─── extract sid from a pwt-watch.sh argv ─────────────────────────────────
# argv: pwt-watch.sh <session_id> [poll] [max]; sid is the first arg after the script path.
extract_watch_sid() {
    local args="$1"
    # take token right after the pwt-watch.sh path
    echo "$args" | sed -E "s|.*pwt-watch\.sh[[:space:]]+([^[:space:]]+).*|\1|"
}

# ─── main scan ─────────────────────────────────────────────────────────────
RESULTS_TMP="$(mktemp)"
echo "[" > "$RESULTS_TMP"
FIRST=1
SCANNED=0
KILLED=0
KEPT=0

append_row() {
    [ "$FIRST" = "1" ] && FIRST=0 || echo "," >> "$RESULTS_TMP"
    python3 -c '
import json,sys
print(json.dumps({
  "kind": sys.argv[1], "pid": int(sys.argv[2]), "id": sys.argv[3],
  "action": sys.argv[4], "reason": sys.argv[5],
  "pane_id": sys.argv[6] or None, "killed_pane": sys.argv[7]=="1",
}), end="")
' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$RESULTS_TMP"
}

while IFS= read -r line; do
    [ -z "$line" ] && continue
    # parse: pid uid rest...
    pid="$(echo "$line" | awk '{print $1}')"
    puid="$(echo "$line" | awk '{print $2}')"
    args="$(echo "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+//')"
    [ -z "$pid" ] && continue

    kind=""
    case "$args" in
        *"$PANE_DISPLAY_MARKER"*) kind="pane-display" ;;
        *"$PWT_WATCH_MARKER"*)    kind="pwt-watch" ;;
        *) continue ;;   # WHITELIST: ignore everything else
    esac

    # SAME-UID guard
    if [ "$puid" != "$MY_UID" ]; then
        SCANNED=$((SCANNED+1)); KEPT=$((KEPT+1))
        append_row "$kind" "$pid" "" "keep" "different uid ($puid != $MY_UID)" "" "0"
        continue
    fi

    if [ "$kind" = "pane-display" ]; then
        agent_id="$(extract_agent_id "$args")"
        [ -n "$SCOPE_SID" ] && [ "$agent_id" != "$SCOPE_SID" ] && continue
        SCANNED=$((SCANNED+1))
        if [ -n "$agent_id" ] && agent_is_terminal "$agent_id"; then
            # orphan → kill process + tmux pane
            pane_id="$(tmux_pane_for_pid "$pid" || true)"
            killed_pane=0
            if [ "$MODE_EXECUTE" = "1" ]; then
                kill "$pid" 2>/dev/null || true
                if [ -n "$pane_id" ]; then
                    tmux kill-pane -t "$pane_id" 2>/dev/null && killed_pane=1 || true
                fi
                KILLED=$((KILLED+1))
                append_row "$kind" "$pid" "$agent_id" "killed" "agent terminal (worktree gone or tool_result present)" "$pane_id" "$killed_pane"
            else
                append_row "$kind" "$pid" "$agent_id" "would-kill" "agent terminal (worktree gone or tool_result present)" "$pane_id" "0"
            fi
        else
            KEPT=$((KEPT+1))
            append_row "$kind" "$pid" "$agent_id" "keep" "agent still live" "" "0"
        fi
    else
        # pwt-watch.sh
        sid="$(extract_watch_sid "$args")"
        [ -n "$SCOPE_SID" ] && [ "$sid" != "$SCOPE_SID" ] && continue
        SCANNED=$((SCANNED+1))
        if [ -n "$sid" ] && ! bg_sid_is_live "$sid"; then
            if [ "$MODE_EXECUTE" = "1" ]; then
                kill "$pid" 2>/dev/null || true
                KILLED=$((KILLED+1))
                append_row "$kind" "$pid" "$sid" "killed" "bg session no longer live" "" "0"
            else
                append_row "$kind" "$pid" "$sid" "would-kill" "bg session no longer live" "" "0"
            fi
        else
            KEPT=$((KEPT+1))
            append_row "$kind" "$pid" "$sid" "keep" "bg session still live" "" "0"
        fi
    fi
done <<< "$(get_ps)"

echo "]" >> "$RESULTS_TMP"

# ─── output ────────────────────────────────────────────────────────────────
if [ "$MODE_JSON" = "1" ]; then
    SCANNED="$SCANNED" KILLED="$KILLED" KEPT="$KEPT" EXECUTE="$MODE_EXECUTE" SCOPE_SID="$SCOPE_SID" \
    python3 -c '
import json,sys,os
items=json.load(open(sys.argv[1]))
print(json.dumps({
  "schema":"plan-w-team-companion-gc/v1",
  "mode":{"execute": os.environ.get("EXECUTE","0")=="1"},
  "scope_sid": os.environ.get("SCOPE_SID",""),
  "totals":{"scanned":int(os.environ["SCANNED"]),"killed":int(os.environ["KILLED"]),"kept":int(os.environ["KEPT"])},
  "companions": items,
}, indent=2))
' "$RESULTS_TMP"
else
    echo "  --- companion-process GC ---" >&2
    python3 -c '
import json, sys
for c in json.load(open(sys.argv[1])):
    ident = c.get("id") or "-"
    sys.stderr.write("  %-14s pid=%-8s id=%-20s %-12s %s\n" % (
        c["kind"], c["pid"], ident, c["action"], c["reason"]))
' "$RESULTS_TMP" || true
    echo "  scanned: $SCANNED  killed: $KILLED  kept: $KEPT" >&2
    [ "$MODE_EXECUTE" = "0" ] && echo "  (dry-run — re-run with --execute to kill orphans)" >&2
fi

rm -f "$RESULTS_TMP"
exit 0
