#!/usr/bin/env bash
# account-advice.sh
#
# Emits a minified-JSON advisory of which registered Claude account to MOVE TO (the
# one with the most 5h/7d headroom) versus the account this machine is logged in as.
# The statusline renders it as a passive "👉 next: <email>" / "⚠ switch → <email>"
# reminder for multi-account users. The decision itself lives in the accounts skill
# (`accounts.sh advise`); this wrapper adds a machine-wide cache, a DETACHED bounded
# singleton refresh and fail-open — the same shape as the sibling plan-usage.sh.
#
# Output shape (labels/numbers only — NEVER a token):
#   {"best":"...","best_email":"...","best_5h":n,"best_7d":n,"current":"...",
#    "current_email":"...","current_5h":n,"current_7d":n,"switch":bool,"current_hot":bool}
#
# Why advisory: interactive Claude Code ties account identity (status line, /usage,
# Remote Control, ~/.claude.json) to the keychain /login — a CLAUDE_CODE_OAUTH_TOKEN
# env token cannot switch it (2026-08-31 finding). So the reminder points the human
# at `/login`; only the fleet/bg workers auto-rotate (lane_cred.py).
#
# Why detached (2026-09-02): `advise` probes EVERY registered account over the
# network (serially), and this wrapper ran it INLINE in the status-line render with
# a 4 s bound. Claude Code cancels an in-flight status-line command when the next
# trigger fires, so under load the render died inside the probe: the display froze
# on the last completed render and the cache never committed. Now the render only
# reads a file; the probe runs in its own bounded process group.
#
# USAGE
#   account-advice.sh [<live-login-email>] [--sync]
#     $1        the caller's LIVE keychain-login email (statusline passes the value
#               it renders in the 👤 segment). The advisory is login-specific, so a
#               cache computed for a different login is NEVER served (AC13) — a
#               `/login` invalidates it the instant it happens. Without $1 the cache
#               is pure-TTL (backward compatible).
#     --sync    refresh inline (bounded), then serve — deterministic for tests.
#
# ENV
#   PWT_ACCT_ADVICE_CACHE       cache file ($HOME/.config/claude-pattern/account-advice.json)
#   PWT_ACCT_ADVICE_TTL         seconds before a refresh is started (120)
#   PWT_ACCT_ADVICE_STALE_MAX   max age still served while a refresh is pending (1800)
#   PWT_ACCT_ADVICE_TIMEOUT     refresh bound, seconds (25 — N serial probes)
#   PWT_ACCT_ADVICE_COLD_WAIT   cold/mismatch wait for the detached refresh (3)
#
# === FAIL-OPEN ===
# On ANY failure (no accounts CLI, dormant registry, no python3, timeout, parse
# fail) → `{}` on stdout, exit 0. The statusline then shows no advice segment.
#
# === SECURITY ===
# - Delegates to accounts.sh, which never prints a token; this wrapper never touches one.
# - Cache file holds only the token-free advisory JSON.
#
# bash 3.2 (mac-mini /bin/bash): no `declare -A`, no mapfile.

set -u

LIVE_EMAIL=""; MODE=serve
for a in "$@"; do
  case "$a" in
    --sync) MODE=sync ;;
    --refresh) MODE=refresh ;;
    -*) ;;
    *) [ -z "$LIVE_EMAIL" ] && LIVE_EMAIL="$a" ;;
  esac
done

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -z "$PROJECT_ROOT" ] && { echo '{}'; exit 0; }
# The accounts CLI: this repo's copy first; else the claude-pattern SOURCE (same
# resolution as session-start.sh: $CLAUDE_PATTERN_ROOT or a `claude-pattern` sibling).
# Repos that never carry the /plan-w-team skill (statusline-bundle-only consumers)
# still get the full advisory this way, and every pane on the machine shares ONE
# cache, so a pane with no CLI at all still renders whatever a sibling pane computed.
ACCOUNTS_CLI="$PROJECT_ROOT/.claude/commands/plan-w-team/accounts/accounts.sh"
if [ ! -x "$ACCOUNTS_CLI" ]; then
  _src="${CLAUDE_PATTERN_ROOT:-$(dirname "$PROJECT_ROOT")/claude-pattern}"
  [ -x "$_src/.claude/commands/plan-w-team/accounts/accounts.sh" ] && ACCOUNTS_CLI="$_src/.claude/commands/plan-w-team/accounts/accounts.sh"
fi

CACHE="${PWT_ACCT_ADVICE_CACHE:-$HOME/.config/claude-pattern/account-advice.json}"
LOCK="$CACHE.lock"
CACHE_TTL="${PWT_ACCT_ADVICE_TTL:-120}"
STALE_CACHE_MAX="${PWT_ACCT_ADVICE_STALE_MAX:-1800}"
ADVICE_TIMEOUT="${PWT_ACCT_ADVICE_TIMEOUT:-25}"
COLD_WAIT="${PWT_ACCT_ADVICE_COLD_WAIT:-3}"
case "$CACHE_TTL$STALE_CACHE_MAX$ADVICE_TIMEOUT$COLD_WAIT" in *[!0-9]*) CACHE_TTL=120; STALE_CACHE_MAX=1800; ADVICE_TIMEOUT=25; COLD_WAIT=3 ;; esac

# 0 = the cached advisory is valid for the current login; 1 = it was computed for a
# different login (stale regardless of age). A dormant `{}` is login-agnostic.
_cache_login_ok() {
  [ -z "$LIVE_EMAIL" ] && return 0
  case "$1" in
    '{}'|'') return 0 ;;
    *"\"current_email\":\"$LIVE_EMAIL\""*) return 0 ;;
    *"\"current_email\": \"$LIVE_EMAIL\""*) return 0 ;;
    *) return 1 ;;
  esac
}
__age_s() {
  local f="$1" m
  [ -e "$f" ] || { echo 999999; return 0; }
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")
  case "$m" in ''|*[!0-9]*) echo 999999; return 0 ;; esac
  echo $(( $(date +%s) - m ))
}
# Serve the cache when it is valid for this login and younger than $1 seconds.
__serve_if_ok() {
  local max="$1" cached
  [ -s "$CACHE" ] || return 1
  [ "$(__age_s "$CACHE")" -lt "$max" ] 2>/dev/null || return 1
  cached=$(cat "$CACHE" 2>/dev/null) || return 1
  _cache_login_ok "$cached" || return 1
  printf '%s' "$cached"
  return 0
}
__lock() {
  mkdir -p "$(dirname "$CACHE")" 2>/dev/null || return 1
  if mkdir "$LOCK" 2>/dev/null; then return 0; fi
  if [ "$(__age_s "$LOCK")" -gt $(( ADVICE_TIMEOUT * 2 )) ] 2>/dev/null; then
    rm -rf "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null && return 0
  fi
  return 1
}
__unlock() { rm -rf "$LOCK" 2>/dev/null; }
__timeout_bin() {
  if command -v gtimeout >/dev/null 2>&1; then echo gtimeout
  elif command -v timeout >/dev/null 2>&1; then echo timeout
  else echo ""; fi
}
__refresh() {  # under the lock; failures leave the cache untouched
  local out tb
  tb=$(__timeout_bin)
  if [ -n "$tb" ]; then out=$("$tb" "${ADVICE_TIMEOUT}s" bash "$ACCOUNTS_CLI" advise 2>/dev/null) || out=""
  else out=$(bash "$ACCOUNTS_CLI" advise 2>/dev/null) || out=""; fi
  [ -n "$out" ] || return 0
  printf '%s' "$out" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' >/dev/null 2>&1 || return 0
  printf '%s' "$out" > "$CACHE.tmp.$$" 2>/dev/null && mv -f "$CACHE.tmp.$$" "$CACHE" 2>/dev/null
  rm -f "$CACHE.tmp.$$" 2>/dev/null
  return 0
}
# Wait until a login-valid, not-too-stale cache exists or $1 seconds elapse. Keyed on
# VALIDITY, not on mtime: a /login inside the same second as the previous write
# would otherwise satisfy an mtime check with the OLD login's verdict.
__await_ok() {
  local max="$1" i=0
  while [ "$i" -lt $(( max * 5 )) ]; do
    __serve_if_ok "$STALE_CACHE_MAX" >/dev/null 2>&1 && return 0
    sleep 0.2 2>/dev/null || sleep 1
    i=$(( i + 1 ))
  done
  return 1
}

# No CLI anywhere ⇒ read-only: serve the shared cache if it is valid for this login.
if [ ! -x "$ACCOUNTS_CLI" ]; then __serve_if_ok "$STALE_CACHE_MAX" || echo '{}'; exit 0; fi

case "$MODE" in
  refresh) trap '__unlock' EXIT INT TERM; __refresh; exit 0 ;;
  sync)
    if __lock; then trap '__unlock' EXIT INT TERM; __refresh
    else __await_ok "$ADVICE_TIMEOUT" || true; fi
    __serve_if_ok "$STALE_CACHE_MAX" || echo '{}'
    exit 0 ;;
esac

# Fresh and login-valid ⇒ serve, spawn nothing.
__serve_if_ok "$CACHE_TTL" && exit 0

# Otherwise start ONE detached bounded refresh (a live lock ⇒ someone else's is
# in flight) and render this pass from what we already hold.
if __lock; then
  TB=$(__timeout_bin)
  (
    set -m 2>/dev/null
    if [ -n "$TB" ]; then nohup "$TB" "$(( ADVICE_TIMEOUT + 5 ))s" bash "$0" "$LIVE_EMAIL" --refresh </dev/null >/dev/null 2>&1 &
    else nohup bash "$0" "$LIVE_EMAIL" --refresh </dev/null >/dev/null 2>&1 & fi
  ) 2>/dev/null
fi
# A not-too-stale cache for THIS login beats a blank segment while the refresh lands…
__serve_if_ok "$STALE_CACHE_MAX" && exit 0
# …but a cold cache or a /login change waits briefly so the first render after a
# switch is not silent (and never replays the previous login's verdict).
__await_ok "$COLD_WAIT" || true
__serve_if_ok "$STALE_CACHE_MAX" && exit 0
echo '{}'
exit 0
