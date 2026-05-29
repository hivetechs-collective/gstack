#!/usr/bin/env bash
# plan-w-team-orphan-session-reaper.sh — reap orphaned `claude --bg` sessions.
#
# Gap exposed 2026-05-29: the ONLY automatic stopper of bg children is retro
# §8j-sexies (child-cleanup.sh), which fires ONLY when a run reaches Step 8. A
# worker that crashes, is abandoned, hits an un-retro'd halt, or is a stray test
# spawn leaves an orphan `claude --bg` PROCESS alive — no catch-all reaps it (the
# worktree GC reclaims dirs + companion procs, but not the bg sessions). This is
# the unhappy-path complement to the retro reaper; it runs from the daily GC timer.
#
# Usage:
#   plan-w-team-orphan-session-reaper.sh            # DRY-RUN (default): list, stop nothing
#   plan-w-team-orphan-session-reaper.sh --execute  # stop the orphans
#   plan-w-team-orphan-session-reaper.sh --json     # machine output
#
# An orphan = a `kind:background` session that is ALL of:
#   • cwd under THIS repo (incl. its worktrees) — never another repo's session
#   • NOT the current session ($CLAUDE_CODE_SESSION_ID)
#   • status != busy (never stop an actively-working session)
#   • idle: its transcript mtime is older than PWT_ORPHAN_IDLE_MIN (default 30 min)
# If the transcript can't be located, the session is SKIPPED (conservative — we
# never reap a session whose idleness we can't verify).
#
# Env:
#   PWT_ORPHAN_IDLE_MIN          idle-minutes threshold (default 30)
#   PWT_ORPHAN_REAPER_DISABLE=1  skip entirely
#   PWT_PROJECT_ROOT_OVERRIDE    repo root (default: git toplevel / pwd)
#   CLAUDE_PROJECTS_DIR          transcripts dir (default ~/.claude/projects) [test]
#   CLAUDE_AGENTS_JSON_STUB      file used in place of `claude agents --json` [test]
#   ORPHAN_REAPER_STOP_CMD       command used to stop a sid (default: claude stop) [test]
#
# Fail-open: any error warns to stderr and exits 0 — janitorial, never blocking.

set -u

EXECUTE=0; JSON=0
for a in "$@"; do case "$a" in --execute) EXECUTE=1 ;; --json) JSON=1 ;; esac; done
[ "${PWT_ORPHAN_REAPER_DISABLE:-0}" = "1" ] && { echo "[orphan-reaper] disabled (PWT_ORPHAN_REAPER_DISABLE=1)" >&2; exit 0; }

REPO_ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SELF="${CLAUDE_CODE_SESSION_ID:-}"
IDLE_MIN="${PWT_ORPHAN_IDLE_MIN:-30}"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
NOW=$(date +%s)

if [ -n "${CLAUDE_AGENTS_JSON_STUB:-}" ]; then
    AGENTS=$(cat "$CLAUDE_AGENTS_JSON_STUB" 2>/dev/null || echo "[]")
else
    AGENTS=$("${CLAUDE_BIN:-claude}" agents --json 2>/dev/null || echo "[]")
fi

# Classify in python (jq may be absent; python is the repo's portable choice).
CLASSIFIED=$(printf '%s' "$AGENTS" | \
    REPO_ROOT="$REPO_ROOT" SELF="$SELF" IDLE_MIN="$IDLE_MIN" PROJECTS_DIR="$PROJECTS_DIR" NOW="$NOW" \
    python3 -c '
import sys, json, os, glob
repo = os.environ["REPO_ROOT"]; self_sid = os.environ["SELF"]
idle_min = int(os.environ["IDLE_MIN"]); proj = os.environ["PROJECTS_DIR"]; now = int(os.environ["NOW"])
try: d = json.load(sys.stdin)
except Exception: d = []
agents = d if isinstance(d, list) else d.get("agents", d.get("sessions", []))
reap, skip = [], []
for x in agents:
    if x.get("kind") != "background":
        continue
    sid = x.get("sessionId") or x.get("id") or x.get("sid") or ""
    cwd = str(x.get("cwd", ""))
    st  = x.get("status", x.get("state", ""))
    if not sid:
        continue
    # scope: only this repo (its root or a path beneath it, incl. worktrees)
    if not (cwd == repo or cwd.startswith(repo + "/")):
        skip.append([sid[:8], "other-repo"]); continue
    if self_sid and (sid == self_sid or sid.startswith(self_sid[:8])):
        skip.append([sid[:8], "self"]); continue
    if st == "busy":
        skip.append([sid[:8], "busy"]); continue
    # idle gate: newest transcript mtime for this sid
    tx = glob.glob(os.path.join(proj, "*", sid + ".jsonl")) or glob.glob(os.path.join(proj, "*", sid + "*.jsonl"))
    tx = [f for f in tx if os.path.exists(f)]
    if not tx:
        skip.append([sid[:8], "no-transcript(unverifiable)"]); continue
    age = int((now - max(os.path.getmtime(f) for f in tx)) / 60)
    if age >= idle_min:
        reap.append([sid[:8], age, st])
    else:
        skip.append([sid[:8], "active(idle %dm<%d)" % (age, idle_min)])
print(json.dumps({"reap": reap, "skip": skip}))
' 2>/dev/null) || { echo "[orphan-reaper] classify failed — fail-open" >&2; exit 0; }

# Extract reap sids (bash; avoid jq dependency).
REAP_SIDS=$(printf '%s' "$CLASSIFIED" | python3 -c 'import sys,json; print(" ".join(r[0] for r in json.load(sys.stdin).get("reap",[])))' 2>/dev/null)
REAP_COUNT=$(printf '%s' "$REAP_SIDS" | wc -w | tr -d ' ')
SKIP_COUNT=$(printf '%s' "$CLASSIFIED" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("skip",[])))' 2>/dev/null || echo 0)

STOPPED=0
if [ "$EXECUTE" = "1" ] && [ -n "$REAP_SIDS" ]; then
    STOP_CMD="${ORPHAN_REAPER_STOP_CMD:-${CLAUDE_BIN:-claude} stop}"
    for sid in $REAP_SIDS; do
        if $STOP_CMD "$sid" >/dev/null 2>&1; then
            STOPPED=$((STOPPED + 1)); echo "[orphan-reaper] stopped orphan $sid" >&2
        else
            echo "[orphan-reaper] stop failed for $sid (non-fatal)" >&2
        fi
    done
fi

MODE=$([ "$EXECUTE" = "1" ] && echo executed || echo dry-run)
if [ "$JSON" = "1" ]; then
    printf '{"mode":"%s","orphans_found":%s,"stopped":%d,"skipped":%s,"idle_min":%s}\n' \
        "$MODE" "${REAP_COUNT:-0}" "$STOPPED" "${SKIP_COUNT:-0}" "$IDLE_MIN"
else
    echo "[orphan-reaper] $MODE: ${REAP_COUNT:-0} orphan bg session(s)${REAP_SIDS:+ [$REAP_SIDS]}, stopped $STOPPED, skipped ${SKIP_COUNT:-0} (busy/self/other-repo/active)"
fi
exit 0
