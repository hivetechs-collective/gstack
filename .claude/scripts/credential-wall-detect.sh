#!/usr/bin/env bash
# credential-wall-detect.sh — pure, testable detector for CLI non-interactive
# credential / token walls hit by a deploy CLI during /plan-w-team Step 3 execute
# or Step 6 ship.
#
# WHY THIS EXISTS (brief: credential-wall-escalation, 2026-06-02):
#   shared/secret-safety.md §REQ-5 escalates BROWSER vendor/SSO console walls but
#   has no equivalent for CLI non-interactive token walls — e.g. wrangler:
#     "In a non-interactive environment, it's necessary to set a
#      CLOUDFLARE_API_TOKEN environment variable"
#   Those slip through: the deploy step is silently skipped / left incomplete and
#   the specific missing secret is never surfaced. This detector is the REAL
#   mechanism (not prose) that recognizes such a wall and names the missing secret.
#
# This script is intentionally pure: it decides + extracts, it does not write
# state or escalate. The hook (plan-w-team-credential-wall-detect.sh) and the gate
# (plan-w-team-credential-wall-gate.sh) compose it. That keeps it trivially unit
# testable.
#
# Usage:
#   credential-wall-detect.sh --command "<cmd>" --output "<combined stdout+stderr>"
#   echo "<hook JSON payload>" | credential-wall-detect.sh --stdin-json
#   credential-wall-detect.sh --output-file <path> [--command "<cmd>"]
#
# Output (on detection): a single JSON object on stdout:
#   {"provider":"cloudflare","missing_secret":"CLOUDFLARE_API_TOKEN",
#    "matched_signature":"non-interactive … CLOUDFLARE_API_TOKEN"}
#
# Exit codes:
#   0  credential wall detected (JSON printed)
#   1  no credential wall (nothing printed)
#   2  bad arguments / internal error
#
# bash 3.2 safe. No bashisms beyond 3.2 (no declare -A, no mapfile).

set -u

COMMAND=""
OUTPUT=""
MODE="args"

while [ $# -gt 0 ]; do
    case "$1" in
        --command)     COMMAND="${2:-}"; shift 2 ;;
        --output)      OUTPUT="${2:-}"; shift 2 ;;
        --output-file) OUTPUT="$(cat "${2:-/dev/null}" 2>/dev/null || true)"; shift 2 ;;
        --stdin-json)  MODE="stdin-json"; shift ;;
        --stdin)       MODE="stdin"; shift ;;
        -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             echo "credential-wall-detect: unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── Gather the text to scan ───────────────────────────────────────────────────
if [ "$MODE" = "stdin-json" ]; then
    # A Claude Code PostToolUse / PostToolUseFailure payload. We do not trust the
    # exact field layout across versions, so we extract command from
    # tool_input.command AND scan the WHOLE raw payload for wall signatures (the
    # stdout/stderr live somewhere in tool_response regardless of field naming).
    PAYLOAD="$(cat 2>/dev/null || true)"
    EXTRACTED_CMD="$(printf '%s' "$PAYLOAD" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get('tool_input', {}) or {}
print(ti.get('command', '') or '')
" 2>/dev/null || true)"
    [ -n "$EXTRACTED_CMD" ] && COMMAND="$EXTRACTED_CMD"
    # Pull the actual command output (stdout/stderr) so the matched_signature is
    # the real error line, not the JSON envelope. tool_response shape varies across
    # versions and can be a dict or a bare string, so collect every plausible text
    # field. Fall back to the raw payload if extraction yields nothing (robust to
    # an unknown field layout — we still detect, just with a coarser signature).
    EXTRACTED_OUT="$(printf '%s' "$PAYLOAD" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
parts = []
tr = d.get('tool_response', d.get('toolResponse', d.get('result', None)))
def collect(x):
    if x is None: return
    if isinstance(x, str): parts.append(x)
    elif isinstance(x, dict):
        for k in ('stdout','stderr','output','content','text','error','message'):
            v = x.get(k)
            if isinstance(v, str): parts.append(v)
            elif isinstance(v, (list,dict)): collect(v)
    elif isinstance(x, list):
        for it in x: collect(it)
collect(tr)
print('\n'.join(p for p in parts if p))
" 2>/dev/null || true)"
    if [ -n "$EXTRACTED_OUT" ]; then OUTPUT="$EXTRACTED_OUT"; else OUTPUT="$PAYLOAD"; fi
elif [ "$MODE" = "stdin" ]; then
    OUTPUT="$(cat 2>/dev/null || true)"
fi

# Combined haystack: command + output. Lowercased copy for case-insensitive
# signature matching; the original is kept for secret-name extraction (case
# matters there — env vars are upper-case).
HAY="$COMMAND
$OUTPUT"
HAY_LC="$(printf '%s' "$HAY" | tr '[:upper:]' '[:lower:]')"

[ -n "$(printf '%s' "$HAY" | tr -d '[:space:]')" ] || exit 1

# ── Negative guard: an unambiguous SUCCESS must never trigger ─────────────────
# A wall signature can co-occur with success prose in contrived text; success
# markers win only when NO hard wall signature is present (checked below). Here we
# short-circuit the obvious "it worked" outputs so prose+success can't false-fire.
SUCCESS_RE='(published|deployment complete|deployed successfully|success! deployed|uploaded [0-9]|✨ +success|deploy complete)'

# ── Signature catalog (case-insensitive ERE) ─────────────────────────────────
# A CLI non-interactive credential/token wall says one of these. Kept broad but
# anchored on auth/login/non-interactive intent so ordinary prose ("we store the
# token in …") does not match.
SIG_RE='non-interactive environment|in a non-interactive|set a? ?[a-z_]*_(api_)?token|set the [a-z_]*_(api_)?token|could not authenticate|not authenticated|login required|you are not logged in|not logged in(to)?|you must be logged in|not logged into any|gh auth login|wrangler login|vercel login|flyctl auth login|fly auth login|eas login|no existing credentials found|no credentials found|missing api token|unable to authenticate|authentication required|run `?[a-z]+ login`?'

MATCH_LINE=""
if printf '%s' "$HAY_LC" | grep -qE "$SIG_RE"; then
    MATCH_LINE="$(printf '%s' "$HAY" | grep -iE "$SIG_RE" | head -1)"
fi

if [ -z "$MATCH_LINE" ]; then
    exit 1
fi

# If the ONLY thing present is a success marker and the "signature" was a benign
# co-occurrence, bail. We only reach here with a real signature line; still, guard
# the pathological "Published … (token cached)" case: a line that is itself a
# success line is not a wall.
if printf '%s' "$MATCH_LINE" | grep -qiE "$SUCCESS_RE"; then
    exit 1
fi

# ── Provider classification ───────────────────────────────────────────────────
provider="unknown"
case "$HAY_LC" in
    *wrangler*|*cloudflare*|*cloudflare_api_token*) provider="cloudflare" ;;
    *vercel*)                                       provider="vercel" ;;
    *" gh "*|*"gh auth"*|*"github hosts"*|*gh_token*) provider="gh" ;;
    *flyctl*|*" fly "*|*fly_api_token*|*fly.io*)    provider="fly" ;;
    *" eas "*|*eas\ login*|*expo*|*expo_token*)     provider="expo" ;;
    *" aws "*|*aws_access_key*|*aws_secret*)        provider="aws" ;;
esac

# ── Missing-secret extraction ─────────────────────────────────────────────────
# Prefer an explicit env-var token named in the output adjacent to set/environment
# variable. Fall back to the provider's canonical secret name.
missing_secret=""
# (1) Explicit: "set a CLOUDFLARE_API_TOKEN environment variable", "set GH_TOKEN",
#     "<NAME>_API_TOKEN environment variable", etc. Grab the first UPPER token that
#     ends in _TOKEN / _API_TOKEN / _API_KEY / _ACCESS_KEY_ID.
missing_secret="$(printf '%s' "$HAY" \
    | grep -oE '[A-Z][A-Z0-9]*(_[A-Z0-9]+)*_(API_TOKEN|API_KEY|TOKEN|ACCESS_KEY_ID)' \
    | head -1 || true)"

if [ -z "$missing_secret" ]; then
    case "$provider" in
        cloudflare) missing_secret="CLOUDFLARE_API_TOKEN" ;;
        vercel)     missing_secret="VERCEL_TOKEN" ;;
        gh)         missing_secret="GH_TOKEN" ;;
        fly)        missing_secret="FLY_API_TOKEN" ;;
        expo)       missing_secret="EXPO_TOKEN" ;;
        aws)        missing_secret="AWS_ACCESS_KEY_ID" ;;
        *)          missing_secret="UNKNOWN_DEPLOY_TOKEN" ;;
    esac
fi

# ── Emit JSON (python3 for safe escaping) ─────────────────────────────────────
SIG_TRIM="$(printf '%s' "$MATCH_LINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1-200)"
python3 -c "
import json, sys
print(json.dumps({
    'provider': sys.argv[1],
    'missing_secret': sys.argv[2],
    'matched_signature': sys.argv[3],
}))
" "$provider" "$missing_secret" "$SIG_TRIM" 2>/dev/null || {
    # Fallback hand-rolled JSON if python is unavailable (still valid for our fields).
    printf '{"provider":"%s","missing_secret":"%s","matched_signature":"%s"}\n' \
        "$provider" "$missing_secret" "$(printf '%s' "$SIG_TRIM" | sed 's/"/\\"/g')"
}
exit 0
