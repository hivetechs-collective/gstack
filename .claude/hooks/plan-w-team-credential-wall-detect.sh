#!/usr/bin/env bash
# plan-w-team-credential-wall-detect.sh — PostToolUse / PostToolUseFailure hook
# that turns a CLI non-interactive credential wall into a durable, escalated,
# never-skipped /plan-w-team halt (brief: credential-wall-escalation, 2026-06-02).
#
# THE DEFECT THIS CLOSES:
#   A deploy CLI (wrangler/gh/vercel/eas/flyctl/aws) hits a non-interactive
#   credential wall — e.g. wrangler "set a CLOUDFLARE_API_TOKEN environment
#   variable". The run loses the credential context: the specific missing secret
#   is never surfaced or persisted, and the deploy step is silently skipped /
#   left incomplete. shared/secret-safety.md §REQ-5 covers BROWSER consoles but
#   NOT CLI token walls; no-github-actions.md documents the deploy-secret standard
#   but nothing ENFORCED escalate-not-skip.
#
# WHAT THIS DOES on a detected wall:
#   1. Persists the EXACT missing secret + the repo's documented operator action
#      (from docs/operations/DEPLOY_RUNBOOK.md when present) to a DURABLE state
#      artifact that survives compaction:
#        .claude/state/plan-w-team-credwall-<SLUG>.json  (resolved=false)
#   2. Emits a `blocked-external` USER_ESCALATION_HALT escalation block to
#      systemMessage, naming the missing secret + operator action, with a
#      `credential-wall` pending-escalations site label (goal-evaluator halts).
#   3. The companion gate (plan-w-team-credential-wall-gate.sh, wired ENFORCING in
#      05-ship.md §6a-quinquies) then fails closed so the deploy/ship step can
#      NEVER be marked complete while the artifact is unresolved.
#
# This hook itself is FAIL-OPEN (a detector bug must never break an unrelated
# command); the step is held closed by the gate, not by this hook blocking.
#
# Kill switch: PLAN_W_TEAM_DISABLE_CREDWALL_GUARD=1
# bash 3.2 safe.

set -u

[ "${PLAN_W_TEAM_DISABLE_CREDWALL_GUARD:-}" = "1" ] && exit 0

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$PROJECT_ROOT" ] || PROJECT_ROOT="$PWD"

# State dir: prefer the cwd's worktree state dir if it has /plan-w-team-* files,
# else the project root's. (Mirrors surface-status.sh resolution.)
PWD_STATE_DIR="$PWD/.claude/state"
ROOT_STATE_DIR="$PROJECT_ROOT/.claude/state"
STATE_DIR="$ROOT_STATE_DIR"
if [ -d "$PWD_STATE_DIR" ]; then STATE_DIR="$PWD_STATE_DIR"; fi
mkdir -p "$STATE_DIR" 2>/dev/null || true

PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

# Pull the command for the deploy-shaped pre-filter (cheap reject of the 99% of
# Bash calls that are not deploys, before invoking the detector at all).
COMMAND="$(printf '%s' "$PAYLOAD" | python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print((d.get('tool_input',{}) or {}).get('command','') or '')
" 2>/dev/null || true)"

# Deploy-shaped pre-filter. If the command is clearly not a deploy/auth-bearing
# CLI, skip — keeps the detector off ordinary shell work. We are deliberately
# inclusive (login/auth too) so a bare `wrangler login` wall is caught.
case "$COMMAND" in
    *wrangler*|*vercel*|*" gh "*|gh\ *|*"gh "*|*eas\ *|*" eas "*|*flyctl*|*" fly "*|fly\ *|*" aws "*|aws\ *|*deploy*|*" login"*|*"auth login"*) : ;;
    *) exit 0 ;;
esac

DETECT="$(dirname "$0")/../scripts/credential-wall-detect.sh"
[ -x "$DETECT" ] || DETECT="$PROJECT_ROOT/.claude/scripts/credential-wall-detect.sh"
[ -x "$DETECT" ] || exit 0   # fail-open: no detector → no-op

RESULT="$(printf '%s' "$PAYLOAD" | "$DETECT" --stdin-json 2>/dev/null || true)"
[ -n "$RESULT" ] || exit 0   # exit 1 from detector (no wall) → no-op

# ── Parse detector JSON ───────────────────────────────────────────────────────
PROVIDER="$(printf '%s' "$RESULT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('provider','unknown'))" 2>/dev/null || echo unknown)"
MISSING="$(printf '%s' "$RESULT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('missing_secret','UNKNOWN_DEPLOY_TOKEN'))" 2>/dev/null || echo UNKNOWN_DEPLOY_TOKEN)"
SIG="$(printf '%s' "$RESULT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('matched_signature',''))" 2>/dev/null || echo "")"

# ── Resolve the active SLUG (best-effort; gate globs all artifacts regardless) ─
SLUG=""
if [ -n "${PLAN_W_TEAM_SLUG:-}" ]; then
    SLUG="$PLAN_W_TEAM_SLUG"
else
    NEWEST=""
    for f in "$STATE_DIR"/plan-w-team-goal-*.json; do
        [ -e "$f" ] || continue
        TERM="$(python3 -c "import sys,json;print(json.load(open('$f')).get('terminal_state') or '')" 2>/dev/null || echo "")"
        [ -n "$TERM" ] && continue   # already terminal — skip
        if [ -z "$NEWEST" ] || [ "$f" -nt "$NEWEST" ]; then NEWEST="$f"; fi
    done
    if [ -n "$NEWEST" ]; then
        SLUG="$(python3 -c "import sys,json;print(json.load(open('$NEWEST')).get('slug') or '')" 2>/dev/null || echo "")"
    fi
fi
[ -n "$SLUG" ] || SLUG="active"

# ── Resolve the documented operator action ────────────────────────────────────
# Prefer the repo's DEPLOY_RUNBOOK.md (grep the section naming the secret or the
# `<provider> login` step). Fall back to a provider→action map so the operator is
# never left without a next step.
RUNBOOK="$PROJECT_ROOT/docs/operations/DEPLOY_RUNBOOK.md"
[ -f "$RUNBOOK" ] || RUNBOOK="$PWD/docs/operations/DEPLOY_RUNBOOK.md"
OPERATOR_ACTION=""
RUNBOOK_REF=""
if [ -f "$RUNBOOK" ]; then
    RUNBOOK_REF="docs/operations/DEPLOY_RUNBOOK.md"
    # Find the most relevant line mentioning the secret or "<provider> login".
    HIT="$(grep -niE "$MISSING|${PROVIDER} login|${PROVIDER}_api_token|non-interactive" "$RUNBOOK" 2>/dev/null | head -1 || true)"
    if [ -n "$HIT" ]; then
        OPERATOR_ACTION="See ${RUNBOOK_REF} (matched: $(printf '%s' "$HIT" | sed 's/^[0-9]*://' | sed 's/^[[:space:]]*//' | cut -c1-160))"
    else
        OPERATOR_ACTION="See ${RUNBOOK_REF} for the documented operator step to provision ${MISSING}."
    fi
fi
if [ -z "$OPERATOR_ACTION" ]; then
    case "$PROVIDER" in
        cloudflare) OPERATOR_ACTION="Operator: run \`wrangler login\` (OAuth in your browser) OR provision ${MISSING} into ~/.config/<project>/deploy.env (0600) per shared/no-github-actions.md §\"Deploy Secret Access\", then re-run the deploy." ;;
        vercel)     OPERATOR_ACTION="Operator: run \`vercel login\` OR set ${MISSING} in the deploy.env (0600) per the headless deploy-credential standard, then re-run." ;;
        gh)         OPERATOR_ACTION="Operator: run \`gh auth login\` OR export ${MISSING} from the deploy.env (0600), then re-run." ;;
        fly)        OPERATOR_ACTION="Operator: run \`fly auth login\` OR provision ${MISSING} into deploy.env (0600), then re-run." ;;
        expo)       OPERATOR_ACTION="Operator: run \`eas login\` OR provision ${MISSING} into deploy.env (0600), then re-run." ;;
        aws)        OPERATOR_ACTION="Operator: configure AWS credentials (${MISSING}/AWS_SECRET_ACCESS_KEY) in deploy.env (0600) per the headless deploy-credential standard, then re-run." ;;
        *)          OPERATOR_ACTION="Operator: provision ${MISSING} (least-privilege, single target) into the headless deploy.env (0600) per shared/no-github-actions.md §\"Deploy Secret Access\", then re-run the deploy." ;;
    esac
fi

# ── Write the durable artifact (atomic temp+rename) ───────────────────────────
ART="$STATE_DIR/plan-w-team-credwall-${SLUG}.json"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
STAGE="${PLAN_W_TEAM_STAGE:-execute-or-ship}"
TMP="${ART}.tmp.$$"
python3 -c "
import json, sys
obj = {
  'slug': sys.argv[1],
  'detected_at': sys.argv[2],
  'stage': sys.argv[3],
  'provider': sys.argv[4],
  'missing_secret': sys.argv[5],
  'command': sys.argv[6][:500],
  'matched_signature': sys.argv[7][:300],
  'operator_action': sys.argv[8],
  'runbook_ref': sys.argv[9],
  'resolved': False,
}
open(sys.argv[10],'w').write(json.dumps(obj, indent=2) + '\n')
" "$SLUG" "$NOW" "$STAGE" "$PROVIDER" "$MISSING" "$COMMAND" "$SIG" "$OPERATOR_ACTION" "$RUNBOOK_REF" "$TMP" 2>/dev/null \
  && mv -f "$TMP" "$ART" 2>/dev/null || { rm -f "$TMP" 2>/dev/null; }

# ── Emit the blocked-external USER_ESCALATION_HALT surface ─────────────────────
# systemMessage carries the operator-facing block. The literal token
# `credential-wall` is the pending-escalations site label the goal-evaluator keys
# its USER_ESCALATION_HALT detection on. `decision:block` is NOT used (PostToolUse
# cannot block); the gate is what fails closed.
ESCALATION="$(cat <<EOF
⛔ USER_ESCALATION_HALT (blocked-external · site=credential-wall)

A deploy CLI hit a NON-INTERACTIVE credential wall. This step is BLOCKED and will
NOT be marked complete or skipped (gate: plan-w-team-credential-wall-gate.sh).

  Provider:        ${PROVIDER}
  Missing secret:  ${MISSING}
  Signature:       ${SIG}
  Stage:           ${STAGE}

Operator action:
  ${OPERATOR_ACTION}

Persisted (survives compaction): ${ART#$PROJECT_ROOT/}
Resolve by provisioning the secret (headless deploy.env standard) OR completing
the documented login, then set "resolved": true in that artifact (or delete it)
and re-run the deploy. See shared/secret-safety.md §REQ-6.
EOF
)"

python3 -c "
import json, sys
print(json.dumps({'systemMessage': sys.argv[1]}))
" "$ESCALATION" 2>/dev/null || printf '{"systemMessage":"USER_ESCALATION_HALT blocked-external credential-wall: missing %s — %s"}\n' "$MISSING" "$OPERATOR_ACTION"

# Also surface on stderr so headless `claude -p` runs (no systemMessage rendering)
# still capture the escalation in their logs.
printf '%s\n' "$ESCALATION" >&2

exit 0
