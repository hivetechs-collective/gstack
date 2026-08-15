#!/usr/bin/env bash
# plan-w-team-zombie-prune.sh — reap orphaned `blocked` /plan-w-team worker
# sessions (Bug D, 2026-08-15).
#
# A worker that cannot flip terminal sits `blocked` at its goal-evaluator Stop
# hook forever (parts field incident: 23 accumulated). Those zombies then (i)
# false-positived the double-spawn liveness guard for the NEXT run (Bug C, fixed
# separately) and (ii) cluttered `claude agents`. Bug B fixes the *birth* of new
# zombies (a completed run now flips terminal and its worker exits); Bug C stops
# existing ones blocking spawns. This is the janitor for the ones ALREADY
# accumulated — a first-class prune, as the field report asked for.
#
# It stops a session ONLY when ALL of these hold (positive confirmation on every
# gate; any uncertainty → KEEP):
#   1. state == "blocked"  (busy/idle are alive; `done` self-clears).
#   2. In scope: the session's cwd is under --cwd/root (or cwd is empty).
#   3. It is a KNOWN /plan-w-team worker — its sid appears in this project's
#      pwt-launches.jsonl or a plan-w-team-spawned-children-*.jsonl. A random
#      non-PWT blocked bg session is NEVER touched.
#   4. It has NO LIVE goal-state — no plan-w-team-goal-*.json (root state OR any
#      worktree state dir) owned by this sid with terminal_state == null. An
#      active run is thus protected even if momentarily blocked.
#   5. It is aged past --min-age-min (default 30) — a just-spawned worker may be
#      transiently blocked at startup; never reap a fresh one.
#
# Stop mechanism: `claude stop <sid>` (fire-and-forget, same as
# plan-w-team-child-cleanup.sh — a non-zero exit usually means it already ended).
#
# Usage:
#   plan-w-team-zombie-prune.sh                 # dry-run table (default) — stops NOTHING
#   plan-w-team-zombie-prune.sh --execute       # actually `claude stop` the PRUNE set
#   plan-w-team-zombie-prune.sh --cwd PATH      # scope to another project root
#   plan-w-team-zombie-prune.sh --min-age-min N # override the freshness gate (default 30)
#   plan-w-team-zombie-prune.sh --json          # machine-readable output
#
# Test seams:
#   PWT_ZOMBIE_PRUNE_AGENTS_JSON=FILE  supply the agents listing (bypass `claude`)
#   PWT_ZOMBIE_PRUNE_TEST_MODE=1       record stops to PWT_ZOMBIE_STOP_LOG instead
#                                      of calling `claude stop`
#   PWT_ZOMBIE_STOP_LOG=FILE           append stopped sids here under TEST_MODE
#
# Exit codes:
#   0  success (classified; with --execute, stops attempted)
#   2  dependency missing (jq)
#   3  agents listing unavailable/invalid → nothing classified (fail-safe: no stops)
set -u

EXECUTE=0
JSON_OUT=0
MIN_AGE_MIN="${PWT_ZOMBIE_MIN_AGE_MIN:-30}"
ROOT_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --execute)      EXECUTE=1; shift ;;
        --json)         JSON_OUT=1; shift ;;
        --cwd)          ROOT_ARG="${2:-}"; shift 2 || break ;;
        --min-age-min)  MIN_AGE_MIN="${2:-30}"; shift 2 || break ;;
        -h|--help)      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              echo "zombie-prune: unknown arg: $1" >&2; exit 2 ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo "zombie-prune: jq required" >&2; exit 2; }

# ── Resolve project root ────────────────────────────────────────────────────
ROOT="$ROOT_ARG"
[ -n "$ROOT" ] || ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="$ROOT/.claude/state"

# ── Acquire the agents listing (fixture seam OR canonical live view) ─────────
AGENTS_RAW=""
if [ -n "${PWT_ZOMBIE_PRUNE_AGENTS_JSON:-}" ]; then
    AGENTS_RAW=$(cat "$PWT_ZOMBIE_PRUNE_AGENTS_JSON" 2>/dev/null || echo "")
else
    EXT="$ROOT/.claude/scripts/claude-agents-extended.sh"
    [ -x "$EXT" ] || EXT="$(dirname "$0")/claude-agents-extended.sh"
    if [ -x "$EXT" ]; then
        AGENTS_RAW=$(CLAUDE_AGENTS_RETRY="${CLAUDE_AGENTS_RETRY:-3}" "$EXT" --json 2>/dev/null) || AGENTS_RAW=""
    fi
    if [ -z "$AGENTS_RAW" ] || ! printf '%s' "$AGENTS_RAW" | jq empty >/dev/null 2>&1; then
        _t=0
        while [ "$_t" -lt "${CLAUDE_AGENTS_RETRY:-3}" ]; do
            _t=$((_t + 1))
            AGENTS_RAW=$(claude agents --json 2>/dev/null || echo "")
            printf '%s' "$AGENTS_RAW" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 && break
            sleep 1
        done
    fi
fi
if ! printf '%s' "$AGENTS_RAW" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "zombie-prune: agents listing unavailable/invalid — classifying nothing (fail-safe)." >&2
    exit 3
fi

# ── Collect this project's KNOWN worker sids (registry membership gate) ──────
# pwt-launches.jsonl rows carry .sid; spawned-children rows carry .session_id.
# Truncate to 8 chars to match the agents sessionId prefix comparison.
REGISTERED_SIDS=" "
if [ -f "$STATE_DIR/pwt-launches.jsonl" ]; then
    while IFS= read -r _s; do
        [ -n "$_s" ] && REGISTERED_SIDS="$REGISTERED_SIDS${_s:0:8} "
    done <<EOF
$(jq -r '.sid // empty' "$STATE_DIR/pwt-launches.jsonl" 2>/dev/null)
EOF
fi
for _reg in "$STATE_DIR"/plan-w-team-spawned-children-*.jsonl; do
    [ -f "$_reg" ] || continue
    while IFS= read -r _s; do
        [ -n "$_s" ] && REGISTERED_SIDS="$REGISTERED_SIDS${_s:0:8} "
    done <<EOF
$(jq -r '.session_id // empty' "$_reg" 2>/dev/null)
EOF
done

# ── Collect sids that OWN a LIVE (non-terminal) goal-state (active-run gate) ─
# Scan the root state dir AND every worktree state dir.
LIVE_OWNER_SIDS=" "
_collect_live_owner() {  # $1=goal_file
    [ -f "$1" ] || return 0
    local _own
    _own=$(jq -r 'select((.terminal_state // null) == null) | .worker_sid // empty' "$1" 2>/dev/null)
    [ -n "$_own" ] && LIVE_OWNER_SIDS="$LIVE_OWNER_SIDS${_own:0:8} "
}
for _gf in "$STATE_DIR"/plan-w-team-goal-*.json; do
    [ -f "$_gf" ] && _collect_live_owner "$_gf"
done
for _wt_state in "$ROOT"/.claude/worktrees/*/.claude/state; do
    [ -d "$_wt_state" ] || continue
    for _gf in "$_wt_state"/plan-w-team-goal-*.json; do
        [ -f "$_gf" ] && _collect_live_owner "$_gf"
    done
done

# ── Current time (epoch ms) for the freshness gate ──────────────────────────
NOW_MS=$(( $(date +%s) * 1000 ))
MIN_AGE_MS=$(( MIN_AGE_MIN * 60000 ))

in_list() { case "$2" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── Stop mechanism (real or test-recorded) ──────────────────────────────────
__stop_session() {  # $1=full_or_short_sid → 0 stopped/attempted, non-0 failed
    if [ "${PWT_ZOMBIE_PRUNE_TEST_MODE:-0}" = "1" ]; then
        [ -n "${PWT_ZOMBIE_STOP_LOG:-}" ] && printf '%s\n' "$1" >> "$PWT_ZOMBIE_STOP_LOG"
        return 0
    fi
    claude stop "$1" >/dev/null 2>&1
}

# ── Classify ────────────────────────────────────────────────────────────────
# Emit one TSV row per in-scope background session: verdict \t sid \t reason.
ROWS=$(printf '%s' "$AGENTS_RAW" | jq -r \
    --arg root "$ROOT" \
    --arg reg "$REGISTERED_SIDS" \
    --arg live "$LIVE_OWNER_SIDS" \
    --argjson now "$NOW_MS" \
    --argjson minage "$MIN_AGE_MS" '
    def short: (. // "")[0:8];
    .[]
    | select((.kind // "") == "background")
    | ((.sessionId // .id // "") | short) as $s
    | (.cwd // "") as $cwd
    | (.state // "") as $st
    | (.startedAt // 0) as $started
    # scope gate: cwd empty or under root
    | select(($cwd == "") or ($cwd | startswith($root)))
    | (if $st != "blocked" then "KEEP\t\($s)\tstate=\($st) (not blocked)"
       elif (($reg | contains(" \($s) ")) | not) then "KEEP\t\($s)\tnot a PWT worker (absent from registries)"
       elif ($live | contains(" \($s) ")) then "KEEP\t\($s)\tlive goal-state (active run)"
       elif ($started == 0) then "KEEP\t\($s)\tunknown age (no startedAt)"
       elif (($now - $started) < $minage) then "KEEP\t\($s)\ttoo fresh (< age gate)"
       else "PRUNE\t\($s)\torphan blocked zombie (PWT worker, no live goal-state, aged)"
       end)
    ' 2>/dev/null)

# ── Report + (optionally) execute ───────────────────────────────────────────
KEEP_N=0; PRUNE_N=0; STOP_OK=0; STOP_FAIL=0
PRUNE_SIDS=""
JSON_ROWS=""
if [ -n "$ROWS" ]; then
    while IFS="$(printf '\t')" read -r verdict sid reason; do
        [ -n "$verdict" ] || continue
        if [ "$verdict" = "PRUNE" ]; then
            PRUNE_N=$((PRUNE_N + 1)); PRUNE_SIDS="$PRUNE_SIDS $sid"
        else
            KEEP_N=$((KEEP_N + 1))
        fi
        JSON_ROWS="$JSON_ROWS$(jq -cn --arg v "$verdict" --arg s "$sid" --arg r "$reason" '{verdict:$v, sid:$s, reason:$r}')
"
    done <<EOF
$ROWS
EOF
fi

# Execute stops on the PRUNE set.
STOPPED_SIDS=""
if [ "$EXECUTE" = "1" ] && [ -n "$PRUNE_SIDS" ]; then
    for _sid in $PRUNE_SIDS; do
        if __stop_session "$_sid"; then
            STOP_OK=$((STOP_OK + 1)); STOPPED_SIDS="$STOPPED_SIDS $_sid"
        else
            STOP_FAIL=$((STOP_FAIL + 1))
        fi
    done
fi

if [ "$JSON_OUT" = "1" ]; then
    CAND_ARR=$(printf '%s' "$JSON_ROWS" | jq -s '.' 2>/dev/null || echo '[]')
    jq -n \
        --arg root "$ROOT" \
        --argjson minage "$MIN_AGE_MIN" \
        --argjson executed "$EXECUTE" \
        --argjson keep "$KEEP_N" \
        --argjson prune "$PRUNE_N" \
        --argjson stopped "$STOP_OK" \
        --argjson failed "$STOP_FAIL" \
        --argjson candidates "$CAND_ARR" \
        '{root:$root, min_age_min:$minage, executed:($executed==1), summary:{keep:$keep, prune:$prune, stopped:$stopped, failed:$failed}, candidates:$candidates}'
    exit 0
fi

MODE_LABEL="dry-run"; [ "$EXECUTE" = "1" ] && MODE_LABEL="execute"
echo "PWT zombie-prune ($MODE_LABEL) — root: $ROOT  min-age: ${MIN_AGE_MIN}m" >&2
if [ -n "$ROWS" ]; then
    printf '%s\n' "$ROWS" | while IFS="$(printf '\t')" read -r v s r; do
        [ -n "$v" ] || continue
        printf '  %-6s %s  %s\n' "$v" "$s" "$r" >&2
    done
else
    echo "  (no in-scope background sessions)" >&2
fi
if [ "$EXECUTE" = "1" ]; then
    for _sid in $STOPPED_SIDS; do echo "  STOPPED $_sid" >&2; done
    echo "Summary: $PRUNE_N prunable · $STOP_OK stopped · $STOP_FAIL failed · $KEEP_N kept." >&2
else
    echo "Summary: $PRUNE_N prunable · $KEEP_N kept.  Re-run with --execute to stop the prunable set." >&2
fi
exit 0
