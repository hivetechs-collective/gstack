#!/usr/bin/env bash
# pwt-live-session-sids.sh — canonical "which claude sessions are LIVE right now?"
# SID source for the stale-state janitor (plan-w-team-cleanup-stale-goal-states.sh).
#
# SID-emitting sibling of pwt-live-session-cwds.sh. The two share the SAME
# fail-CLOSED `claude agents --json` query/parse contract (DRY); this one emits
# session IDs (for matching a goal-state's worker_sid / a manifest's run_sid)
# where the cwds variant emits worktree paths. Kept as a thin sibling rather than
# a `--field` flag on the cwds script so the GC's cwd contract stays untouched.
#
# WHY THIS EXISTS (prong B, 2026-06-10):
#   The SUCCESS-only janitor leaves provably-orphaned NON-terminal run-state
#   families on disk forever (cleanup-eval SA-4). Reaping one safely requires
#   proving the owning worker is DEAD — i.e., its SID is not among currently-live
#   claude sessions. This script is that liveness oracle.
#
# CONTRACT (mirrors pwt-live-session-cwds.sh):
#   stdout = one session ID per line, for every LIVE claude session
#            (kind background|interactive, status busy|idle) per `claude agents
#            --json`. The emitted value is the raw sessionId as claude reports it;
#            callers that compare against an 8-hex short worker_sid truncate both
#            sides to the first 8 chars (the goal-evaluator SID convention).
#   The single token  __QUERY_FAILED__  (alone on a line) means the liveness query
#            could not be performed (claude unavailable / non-zero / unparseable).
#            Callers MUST fail CLOSED on this token: do NOT treat any worker as
#            dead, because absence of a SID no longer proves the worker is gone.
#   exit 0 always (the signal is in stdout, not the exit code) so callers can
#            consume it with $(...) without `set -e` aborting.
#
# An EMPTY stdout (no SIDs, no __QUERY_FAILED__) is the legitimate "query
# succeeded, zero live sessions" result → every candidate worker is provably dead.
#
# Test seams (identical names/semantics to the cwds sibling, SID variant):
#   PWT_LIVE_SESSION_QUERY_FAIL=1        force the __QUERY_FAILED__ path
#   PWT_LIVE_SESSION_SIDS_OVERRIDE=...   newline-separated SID list (skip claude)
#   PWT_CLAUDE_BIN=<path>                override the claude binary name/path
#   PWT_LIVE_SESSION_TIMEOUT=<sec>       claude-query timeout (default 30)
#
# bash 3.2 + zsh safe.
set -u

if [ "${PWT_LIVE_SESSION_QUERY_FAIL:-0}" = "1" ]; then
    printf '__QUERY_FAILED__\n'
    exit 0
fi

if [ -n "${PWT_LIVE_SESSION_SIDS_OVERRIDE:-}" ]; then
    printf '%s\n' "$PWT_LIVE_SESSION_SIDS_OVERRIDE"
    exit 0
fi

CLAUDE_BIN="${PWT_CLAUDE_BIN:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    printf '__QUERY_FAILED__\n'
    exit 0
fi

# `timeout` may be absent on bare macOS; degrade gracefully (run without it).
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout ${PWT_LIVE_SESSION_TIMEOUT:-30}"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout ${PWT_LIVE_SESSION_TIMEOUT:-30}"
fi

RAW="$($TIMEOUT_BIN "$CLAUDE_BIN" agents --json 2>/dev/null)"
if [ -z "$RAW" ]; then
    # Empty here means the binary produced NOTHING (error / killed by timeout).
    # A real "no sessions" answer is the 2-byte string "[]", which is non-empty.
    printf '__QUERY_FAILED__\n'
    exit 0
fi

printf '%s' "$RAW" | python3 -c '
import json, sys
LIVE_KINDS = {"background", "interactive"}
LIVE_STATUS = {"busy", "idle"}
try:
    data = json.load(sys.stdin)
except Exception:
    print("__QUERY_FAILED__")
    sys.exit(0)
if not isinstance(data, list):
    print("__QUERY_FAILED__")
    sys.exit(0)
for entry in data:
    if not isinstance(entry, dict):
        continue
    if entry.get("kind") in LIVE_KINDS and entry.get("status") in LIVE_STATUS:
        sid = entry.get("sessionId") or entry.get("session_id") or ""
        if sid:
            print(sid)
' 2>/dev/null || printf '__QUERY_FAILED__\n'

exit 0
