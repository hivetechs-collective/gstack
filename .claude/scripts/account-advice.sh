#!/usr/bin/env bash
# account-advice.sh
#
# Emits a minified-JSON advisory of which registered Claude account to MOVE TO (the
# one with the most 5h/7d headroom) versus the account this machine is logged in as.
# The statusline renders it as a passive "switch → <label>" reminder for multi-account
# users. The decision itself lives in the accounts skill (`accounts.sh advise`); this
# wrapper only adds a short cache + a bounded timeout + fail-open, exactly like the
# sibling plan-usage.sh.
#
# Output shape (labels/numbers only — NEVER a token):
#   {"best":"...","best_5h":n,"best_7d":n,"current":"...","switch":bool,"current_hot":bool,...}
#
# Why advisory: interactive Claude Code ties account identity (status line, /usage,
# Remote Control, ~/.claude.json) to the keychain /login — a CLAUDE_CODE_OAUTH_TOKEN
# env token cannot switch it (2026-08-31 finding). So the reminder points the human
# at `/login`; only the fleet/bg workers auto-rotate (lane_cred.py).
#
# === FAIL-OPEN ===
# On ANY failure (no clone, dormant registry, no python3, timeout, parse fail) →
# emit `{}` to stdout and exit 0. The statusline then shows no advice segment.
#
# === SECURITY ===
# - Delegates to accounts.sh, which never prints a token; this wrapper never touches one.
# - Cache file holds only the token-free advisory JSON.
# - Bounded via timeout(1)/gtimeout when present so a stale-probe render can't hang.

set -u

fail_open() { echo '{}'; exit 0; }
trap fail_open ERR

# Optional arg $1: the caller's LIVE keychain-login email — statusline passes the
# same value it renders in the 👤 segment. The advisory is login-specific ("switch →
# X" only means anything relative to who you are logged in as), so a `/login` to a
# different account MUST invalidate the cache the instant it happens, not wait out
# CACHE_TTL. When no email is supplied we cannot gate on it → pure-TTL behavior
# (unchanged, fail-open).
LIVE_EMAIL="${1:-}"

# 0 = cached advisory is still valid for the current login; 1 = login changed since
# it was computed, so the cache is stale regardless of age. Pure-bash glob match (no
# fork); tolerant of both minified and spaced JSON.
_cache_login_ok() {
    [ -z "$LIVE_EMAIL" ] && return 0
    case "$1" in
        *"\"current_email\":\"$LIVE_EMAIL\""*) return 0 ;;
        *"\"current_email\": \"$LIVE_EMAIL\""*) return 0 ;;
        *) return 1 ;;
    esac
}

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -z "$PROJECT_ROOT" ] && { echo '{}'; exit 0; }

ACCOUNTS_CLI="$PROJECT_ROOT/.claude/commands/plan-w-team/accounts/accounts.sh"
[ -x "$ACCOUNTS_CLI" ] || { echo '{}'; exit 0; }

STATE_DIR="$PROJECT_ROOT/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null
# PWT_ACCT_ADVICE_CACHE relocates the cache file (tests point it into a sandbox so a
# run can never touch the operator's live cache; operators may also move it off a
# read-only state dir). Defaults to the state dir alongside the sibling helpers.
CACHE="${PWT_ACCT_ADVICE_CACHE:-$STATE_DIR/account-advice-cache.json}"

CACHE_TTL="${PWT_ACCT_ADVICE_TTL:-300}"
# Max age (seconds) at which a stale cache is still preferred over `{}` when the
# fresh decision errors/times out. Headroom changes slowly; a few-minutes-old read
# is far more useful than a flickering empty segment.
STALE_CACHE_MAX="${PWT_ACCT_ADVICE_STALE_MAX:-1800}"
ADVICE_TIMEOUT="${PWT_ACCT_ADVICE_TIMEOUT:-4}"

# Serve a fresh cache without shelling out — but only when it was computed for the
# account we are still logged in as. A /login change makes the cached verdict wrong
# ("switch → the account you're already on"), so it must recompute, not serve stale.
if [ -f "$CACHE" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$CACHE_TTL" ]; then
        cached=$(cat "$CACHE" 2>/dev/null || echo "")
        if _cache_login_ok "$cached"; then
            printf '%s' "$cached"
            exit 0
        fi
    fi
fi

# Bound the decision — advise may probe a stale account over the network.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
fi

if [ -n "$TIMEOUT_BIN" ]; then
    OUT=$("$TIMEOUT_BIN" "$ADVICE_TIMEOUT" bash "$ACCOUNTS_CLI" advise 2>/dev/null) || OUT=""
else
    OUT=$(bash "$ACCOUNTS_CLI" advise 2>/dev/null) || OUT=""
fi

# Accept only well-formed JSON; on anything else prefer a not-too-stale cache.
if [ -n "$OUT" ] && printf '%s' "$OUT" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' >/dev/null 2>&1; then
    printf '%s' "$OUT" > "$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE" 2>/dev/null
    printf '%s' "$OUT"
    exit 0
fi

# Prefer a not-too-stale cache over `{}` when the fresh decision errors/times out —
# but never one from a different login (that would advise switching to the current
# account). On a login mismatch, stay silent instead of showing a wrong reminder.
if [ -f "$CACHE" ]; then
    stale_age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
    if [ "$stale_age" -lt "$STALE_CACHE_MAX" ]; then
        cached=$(cat "$CACHE" 2>/dev/null || echo "")
        if _cache_login_ok "$cached"; then
            printf '%s' "$cached"
            exit 0
        fi
    fi
fi
echo '{}'
