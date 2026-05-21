#!/usr/bin/env bash
# plan-usage.sh
#
# Fetches Claude plan usage from Anthropic's OAuth endpoint — the same
# data backing the interactive `/usage` slash command. Outputs minified
# JSON with five_hour + seven_day utilization + reset times.
#
# Endpoint: https://api.anthropic.com/api/oauth/usage
# Auth:     Bearer token from macOS keychain entry "Claude Code-credentials"
#
# Cache TTL: 60s default. Statusline calls this on every render; without
# the cache we'd hit the API 30+ times a minute, which is rude and likely
# to trigger throttling.
#
# === FAIL-OPEN ===
# On any failure (no token, network error, parse failure, rate limit) →
# emit `{}` to stdout and exit 0. Statusline degrades to no plan-usage
# display rather than breaking.
#
# === SECURITY ===
# - Never logs the bearer token.
# - Cache file contains only the API response (no auth credentials).
# - 5s curl timeout to keep statusline render snappy.

set -u

fail_open() { echo '{}'; exit 0; }
trap fail_open ERR

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -z "$PROJECT_ROOT" ] && { echo '{}'; exit 0; }

STATE_DIR="$PROJECT_ROOT/.claude/state"
mkdir -p "$STATE_DIR" 2>/dev/null
CACHE="$STATE_DIR/plan-usage-cache.json"

CACHE_TTL="${PLAN_USAGE_CACHE_TTL:-60}"

# Return cache if fresh
if [ -f "$CACHE" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$CACHE_TTL" ]; then
        cat "$CACHE"
        exit 0
    fi
fi

# Need security (macOS keychain) and curl
command -v security >/dev/null 2>&1 || { echo '{}'; exit 0; }
command -v curl >/dev/null 2>&1 || { echo '{}'; exit 0; }

# Extract OAuth access token from keychain. The keychain entry is a JSON
# blob; we parse out claudeAiOauth.accessToken with python3 (jq would also
# work but python3 is more universally available on macOS).
KEYCHAIN_JSON=$(security find-generic-password \
    -s "Claude Code-credentials" \
    -a "$USER" \
    -w 2>/dev/null) || { echo '{}'; exit 0; }
[ -z "$KEYCHAIN_JSON" ] && { echo '{}'; exit 0; }

TOKEN=$(printf '%s' "$KEYCHAIN_JSON" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get("claudeAiOauth", {}).get("accessToken", ""))
except Exception:
    pass
' 2>/dev/null)

[ -z "$TOKEN" ] && { echo '{}'; exit 0; }

# Hit the usage endpoint. anthropic-beta header matches what Claude Code
# itself sends (oauth-2025-04-20 confirmed working 2026-05-20).
RESPONSE=$(curl -sS \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    --max-time 5 \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

# Validate the response looks like JSON with the expected shape
if [ -z "$RESPONSE" ] || ! printf '%s' "$RESPONSE" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert "five_hour" in d and "utilization" in d["five_hour"]
' 2>/dev/null; then
    # Bad response — don't poison the cache, just emit {} for this turn
    echo '{}'
    exit 0
fi

# Atomically write cache
printf '%s' "$RESPONSE" > "$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE" 2>/dev/null
printf '%s' "$RESPONSE"
