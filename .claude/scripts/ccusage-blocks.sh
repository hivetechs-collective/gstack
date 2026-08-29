#!/usr/bin/env bash
# ccusage-blocks.sh — bounded, singleton, cached `ccusage blocks --json`.
#
# WHY THIS EXISTS (2026-08-19 incident — docs/specs/pwt-host-load-and-stall-protection.md)
#   `statusline.sh` called `ccusage blocks --json` inline, per render:
#       if   command -v timeout  → timeout 5s ccusage …
#       elif command -v gtimeout → gtimeout 5s ccusage …
#       else                     → ccusage …          ← UNBOUNDED
#   macOS ships no `timeout`, so on a host without GNU coreutils the last
#   branch was the live one — its comment ("ccusage should be fast") was the
#   only bound. Meanwhile `ccusage` re-parses the whole transcript corpus on
#   every invocation, so its cost grows with the run's own output, and a
#   pipeline worker re-renders the statusline on every tool-call turn. The
#   feedback loop measured 200–330% CPU and ~1.8 GB RSS per instance, load 24–27
#   on 12 cores, sustained for hours — the run starving itself.
#
#   Three properties close it, and this file exists so they live in ONE place
#   instead of being inlined into a render path:
#     1. REAL BOUND — a `timeout` binary is REQUIRED. No binary ⇒ no call. The
#        unbounded fallback is deleted, not hidden behind a flag.
#     2. SINGLETON — an atomic `mkdir` lock. A live refresh ⇒ serve the cache;
#        never stack a second process.
#     3. CACHE — one bounded invocation per TTL per checkout, shared by every
#        session's renders.
#
#   Plus the lean gate: a `/plan-w-team` pipeline session (PWT_LEAN_STATUSLINE=1,
#   exported by pwt-goal.sh at every bg spawn site) spawns ZERO — it is the
#   per-turn spawn machine, and it has no human watching its status line.
#
# SHAPE
#   Same contract as the other statusline helpers (plan-usage.sh,
#   usage-breakdown.sh, account-info.sh): an executable that prints JSON to
#   stdout and fails open (empty output, exit 0). statusline.sh must never
#   branch on our failure.
#
# USAGE
#   ccusage-blocks.sh [--sync]
#     (default)  serve the cache; refresh in a DETACHED bounded process if stale
#     --sync     refresh inline and print the result (deterministic; used by the
#                bats corpus and handy from a terminal)
#
# ENV
#   PWT_LEAN_STATUSLINE=1        pipeline session ⇒ print nothing, spawn nothing
#   PWT_DISABLE_LEAN_STATUSLINE=1  kill switch — reverts the lean gate (F1)
#   PWT_CCUSAGE_CACHE_TTL        seconds, default 60
#   PWT_CCUSAGE_TIMEOUT_S        bound in seconds, default 5
#   PWT_CCUSAGE_TIMEOUT_BIN      explicit path to the bound binary (else probe
#                                gtimeout, then timeout)
#   PWT_CCUSAGE_STATE_DIR        cache/lock directory, default $PWD/.claude/state
#
# bash 3.2 (mac-mini /bin/bash): no `declare -A`, no `${v,,}`, no mapfile.

set -u

SYNC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sync) SYNC=1; shift ;;
    -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

# ── (1) Lean gate — FIRST, before any probing ───────────────────────────────
# Deliberately ahead of the `command -v ccusage` lookup: a lean session should
# not even pay for the PATH search, and "spawns zero" must be true by
# construction rather than by the binary happening to be absent.
if [ "${PWT_LEAN_STATUSLINE:-0}" = "1" ] && [ "${PWT_DISABLE_LEAN_STATUSLINE:-0}" != "1" ]; then
  exit 0
fi

CACHE_TTL="${PWT_CCUSAGE_CACHE_TTL:-60}"
BOUND_S="${PWT_CCUSAGE_TIMEOUT_S:-5}"
STATE_DIR="${PWT_CCUSAGE_STATE_DIR:-$PWD/.claude/state}"
CACHE="$STATE_DIR/ccusage-blocks-cache.json"
LOCK="$STATE_DIR/ccusage-blocks.lock"

# Portable mtime age in seconds. Missing file ⇒ a very large age (always stale).
__age_s() {
  local f="$1" m
  [ -f "$f" ] || [ -d "$f" ] || { echo 999999; return 0; }
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")
  case "$m" in ''|*[!0-9]*) echo 999999; return 0 ;; esac
  echo $(( $(date +%s) - m ))
}

__serve_cache() { [ -s "$CACHE" ] && cat "$CACHE" 2>/dev/null; return 0; }

# ── (2) Cache hit ⇒ serve, spawn nothing ────────────────────────────────────
if [ -s "$CACHE" ] && [ "$(__age_s "$CACHE")" -lt "$CACHE_TTL" ] 2>/dev/null; then
  __serve_cache
  exit 0
fi

# ── (3) Real bound REQUIRED ─────────────────────────────────────────────────
# An explicit PWT_CCUSAGE_TIMEOUT_BIN that does not resolve is an operator
# saying "use this one" about a binary that is not there — that is a skip, not
# a licence to fall back. Same outcome as no binary at all: we do not run.
TIMEOUT_BIN=""
if [ -n "${PWT_CCUSAGE_TIMEOUT_BIN:-}" ]; then
  if [ -x "$PWT_CCUSAGE_TIMEOUT_BIN" ] || command -v "$PWT_CCUSAGE_TIMEOUT_BIN" >/dev/null 2>&1; then
    TIMEOUT_BIN="$PWT_CCUSAGE_TIMEOUT_BIN"
  fi
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
fi
if [ -z "$TIMEOUT_BIN" ]; then
  # No bound available ⇒ never run the helper. Serve whatever the cache holds.
  __serve_cache
  exit 0
fi

command -v ccusage >/dev/null 2>&1 || { __serve_cache; exit 0; }

mkdir -p "$STATE_DIR" 2>/dev/null || { __serve_cache; exit 0; }

# ── (4) Singleton ───────────────────────────────────────────────────────────
# A lock older than 4x the bound cannot belong to a live bounded refresh, so it
# is an orphan (killed statusline, crashed shell) and is reclaimed. Worst case
# on the reclaim race is one duplicate refresh — both commit atomically via mv.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ "$(__age_s "$LOCK")" -gt $(( BOUND_S * 4 )) ] 2>/dev/null; then
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || { __serve_cache; exit 0; }
  else
    # A refresh is in flight. Serve the cache at whatever age it has and get
    # out of the way — stacking a second ccusage is the whole failure mode.
    __serve_cache
    exit 0
  fi
fi
printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null || true

__refresh() {
  local tmp="$CACHE.tmp.$$"
  # The bound is enforced by a REAL timeout binary, never by a comment.
  if "$TIMEOUT_BIN" "${BOUND_S}s" ccusage blocks --json > "$tmp" 2>/dev/null; then
    # An empty result is a failed/killed run, not "zero usage" — committing it
    # would poison the cache for a whole TTL and blank the segment for every
    # session. Keep the previous value instead.
    if [ -s "$tmp" ]; then
      mv -f "$tmp" "$CACHE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
  fi
  rm -f "$tmp" 2>/dev/null
  rm -rf "$LOCK" 2>/dev/null
}

if [ "$SYNC" = "1" ]; then
  trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM
  __refresh
  __serve_cache
  exit 0
fi

# ── (5) Detached bounded refresh (default render path) ──────────────────────
# Claude Code CANCELS an in-flight statusline command whenever a new update
# trigger fires, so a synchronous refresh that outlives the trigger gap is
# killed mid-run: the cache never commits and every render restarts cold. The
# bg-agents block at statusline.sh solved this with a detached refresh; the
# same idiom applies here, and it additionally means the render NEVER blocks on
# ccusage — the multi-second stall leaves the critical path entirely.
(
  set -m 2>/dev/null
  nohup bash -c '
    tb="$1"; bound="$2"; cache="$3"; lock="$4"; out="$cache.tmp.$$"
    if "$tb" "${bound}s" ccusage blocks --json > "$out" 2>/dev/null; then
      [ -s "$out" ] && mv -f "$out" "$cache" 2>/dev/null
    fi
    rm -f "$out" 2>/dev/null
    rm -rf "$lock" 2>/dev/null
  ' _ "$TIMEOUT_BIN" "$BOUND_S" "$CACHE" "$LOCK" </dev/null >/dev/null 2>&1 &
) 2>/dev/null

# Render THIS pass from whatever the cache already holds (possibly nothing on a
# cold start — the segment simply does not appear until the first refresh lands).
__serve_cache
exit 0
