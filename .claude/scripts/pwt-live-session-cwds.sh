#!/usr/bin/env bash
# pwt-live-session-cwds.sh — canonical "is a live claude session owning this
# worktree?" source for the worktree GC + hygiene sweep.
#
# WHY THIS EXISTS (2026-06-07 mid-flight-reap incident):
#   A supervised `/plan-w-team` worker that PUSHES in Step 6 still has Steps 6b-8
#   (open PR + post-ship docs + retro) to run. The worktree GC's SAFE-PRUNE-PUSHED
#   class reaps any worktree whose HEAD is reachable from origin/* — so the instant
#   the worker's branch hit origin, the GC (and the hygiene sweep) deleted its
#   worktree out from under it, orphaning the run before it could open its PR.
#
#   The GC already had an is-in-use guard, but it FAILED OPEN: when the liveness
#   probe returned empty (claude binary slow / unavailable / timed out) it treated
#   EVERY worktree as "not in use" and reaped the pushed ones. The hygiene sweep was
#   worse — it matched live worktrees by grepping `ps` argv, but a `claude --bg`
#   worker's argv is `…/<ver> --bg-spare /tmp/…` and never contains the worktree
#   path, so the real owner was invisible.
#
# CONTRACT:
#   stdout = one absolute cwd path per line, for every LIVE claude session
#            (kind background|interactive, status busy|idle) per `claude agents
#            --json`. A worktree whose path equals or is under one of these is
#            owned by a live session and MUST NOT be reclaimed.
#   The single token  __QUERY_FAILED__  (alone on a line) means the liveness query
#            could not be performed (claude unavailable / non-zero / unparseable).
#            Callers MUST fail CLOSED on this token: do NOT reclaim any worktree,
#            because absence of a path no longer proves absence of a live owner.
#   exit 0 always (the signal is in stdout, not the exit code) so callers can
#            consume it with `$(...)` without `set -e` aborting.
#
# An EMPTY stdout (no paths, no __QUERY_FAILED__) is the legitimate "query
# succeeded, zero live sessions" result → safe to reclaim.
#
# Test seams:
#   PWT_LIVE_SESSION_QUERY_FAIL=1        force the __QUERY_FAILED__ path
#   PWT_LIVE_SESSION_CWDS_OVERRIDE=...   newline-separated cwd list (skip claude)
#   PWT_CLAUDE_BIN=<path>                override the claude binary name/path
#   PWT_LIVE_SESSION_TIMEOUT=<sec>       claude-query timeout (default 30)
#
# bash 3.2 + zsh safe.
set -u

if [ "${PWT_LIVE_SESSION_QUERY_FAIL:-0}" = "1" ]; then
    printf '__QUERY_FAILED__\n'
    exit 0
fi

if [ -n "${PWT_LIVE_SESSION_CWDS_OVERRIDE:-}" ]; then
    printf '%s\n' "$PWT_LIVE_SESSION_CWDS_OVERRIDE"
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
        cwd = entry.get("cwd") or ""
        if cwd:
            print(cwd)
' 2>/dev/null || printf '__QUERY_FAILED__\n'

exit 0
