#!/usr/bin/env bash
# account-info.sh
#
# Emits minified JSON describing the currently-logged-in Claude account,
# read from ~/.claude.json. Used by the statusline so the user can tell at
# a glance which account is active (matters when juggling Max subscriptions).
#
# Output: {"email":"...","display_name":"...","tier":"...","org":"..."}
# Fail-open: emits {} on any error.
#
# Cache: none — file read is local and cheap.
set -u
trap 'echo "{}"; exit 0' ERR

CONFIG="$HOME/.claude.json"
[ -f "$CONFIG" ] || { echo '{}'; exit 0; }

command -v python3 >/dev/null 2>&1 || { echo '{}'; exit 0; }

python3 - "$CONFIG" <<'PY' 2>/dev/null || echo '{}'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    acct = d.get("oauthAccount") or {}
    out = {
        "email":        acct.get("emailAddress", "") or "",
        "display_name": acct.get("displayName", "") or "",
        "tier":         (acct.get("organizationType", "") or "").replace("claude_", ""),
        "org":          acct.get("organizationName", "") or "",
    }
    if not out["email"] and not out["display_name"]:
        print("{}")
    else:
        print(json.dumps(out, separators=(",", ":")))
except Exception:
    print("{}")
PY
