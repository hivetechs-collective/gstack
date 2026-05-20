#!/usr/bin/env bash
# plan-w-team-orchestrator-route.sh
#
# Router for /plan-w-team orchestrator-interception. Classifies the call site,
# routes the pause to the right handler (orchestrator agent, user ASK, or
# inline rule), and (for orchestrator routes) appends a JSONL row to the
# per-SLUG decision log.
#
# Spec:        docs/specs/plan-w-team-orchestrator-interception-upgrade.md
# Classifier:  .claude/commands/plan-w-team/shared/orchestrator-interception.md
# Tests:       .claude/scripts/plan-w-team-orchestrator-route.test.sh
# Registry:    .claude/commands/plan-w-team/shared/state-artifacts.md
#
# Usage:
#   route_orchestrator <call-site-label> <slug> [evidence-args...]
#   route_orchestrator --resume <slug>                    (legacy backward-compat)
#
# Exit codes:
#   0   — routed successfully (chosen option on stdout)
#   1   — UnknownCallSiteError or runtime failure (detail on stderr)
#   127 — invocation error (missing required arg)
#
# Rollback toggle:
#   PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1   → every site uses legacy ask_user_question
#
# Backward compat:
#   `--resume <slug>` with no existing decision log file → legacy ASK silently
#     (slug pre-dates the upgrade; no JSONL is created, no agent is spawned,
#     no warnings are emitted).
#
# Shimming for tests:
#   `agent_invoke` and `ask_user_question` are external commands resolved via
#   PATH. The test harness prepends a mock-bin to PATH; in production these
#   resolve to the real Claude Agent SDK shims installed by /plan-w-team
#   pre-flight. The router never embeds the SDK directly — it always calls
#   through the named-command boundary.

set -uo pipefail
# NOTE: -e is intentionally NOT set so we can capture non-zero exits from
#       agent_invoke / ask_user_question and route on them. Each subprocess
#       call captures `$?` explicitly.

# ---------------------------------------------------------------------------
# Resolve repo + script paths (worktree-cwd-safe — uses BASH_SOURCE not PWD)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLASSIFIER_DOC="$REPO_ROOT/.claude/commands/plan-w-team/shared/orchestrator-interception.md"
STATE_DIR="$REPO_ROOT/.claude/state"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
# Special form: --resume <slug>  →  legacy backward-compat path (AC7).
# Standard form: <call-site-label> <slug> [evidence...]
# ---------------------------------------------------------------------------
if [ $# -lt 1 ]; then
  echo "InvocationError: missing call-site label" >&2
  echo "  usage: route_orchestrator <call-site-label> <slug> [evidence-args...]" >&2
  echo "  usage: route_orchestrator --resume <slug>" >&2
  exit 127
fi

RESUME_MODE=0
if [ "$1" = "--resume" ]; then
  RESUME_MODE=1
  shift
  if [ $# -lt 1 ]; then
    echo "InvocationError: --resume requires a slug" >&2
    exit 127
  fi
  RESUME_SLUG="$1"
  shift
fi

# ---------------------------------------------------------------------------
# AC7 — Resume against a SLUG with no decision log → legacy ASK silently
# ---------------------------------------------------------------------------
# A SLUG that pre-dates the orchestrator-interception upgrade has no
# .claude/state/plan-w-team-orchestrator-decisions-<slug>.jsonl file. Treat
# the absence as the signal: route to legacy ask_user_question silently and
# exit. No warnings on stderr (the user did nothing wrong).
if [ "$RESUME_MODE" = "1" ]; then
  decision_log="$STATE_DIR/plan-w-team-orchestrator-decisions-${RESUME_SLUG}.jsonl"
  if [ ! -f "$decision_log" ]; then
    # Legacy SLUG — fall through silently to ASK.
    # Pass through any remaining args as the question context (none expected).
    ask_user_question "resume-legacy-slug" "$RESUME_SLUG" "$@" >/dev/null 2>&1 || true
    exit 0
  fi
  # If a decision log DOES exist, the SLUG is post-upgrade — fall through to
  # the normal flow. The remaining args become the call-site + evidence.
  if [ $# -lt 1 ]; then
    echo "InvocationError: --resume with existing decision log requires a call-site label" >&2
    exit 127
  fi
fi

if [ $# -lt 2 ]; then
  echo "InvocationError: missing slug argument" >&2
  echo "  usage: route_orchestrator <call-site-label> <slug> [evidence-args...]" >&2
  exit 127
fi

CALL_SITE="$1"
SLUG="$2"
shift 2
EVIDENCE_ARGS=("$@")

# ---------------------------------------------------------------------------
# Rollback toggle (AC2) — PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1
# ---------------------------------------------------------------------------
# When set, every call site routes to legacy ask_user_question. No agent is
# spawned, no JSONL is written, no lock is acquired. This is the kill switch
# for incidents or debugging orchestrator misbehavior.
if [ "${PLAN_W_TEAM_DISABLE_ORCHESTRATOR:-}" = "1" ]; then
  ask_user_question "$CALL_SITE" "${EVIDENCE_ARGS[@]+"${EVIDENCE_ARGS[@]}"}"
  exit $?
fi

# ---------------------------------------------------------------------------
# Classifier lookup — parses the markdown table in orchestrator-interception.md
# ---------------------------------------------------------------------------
# The classifier table rows look like:
#   | `scope-challenge-mode` | `orchestrator` | Mode selection ... |
# Parse: find the row whose first cell is `<CALL_SITE>` and return the second
# cell (the verdict).
#
# We use awk for portability — no python required for this hot path.
grep_classifier_verdict() {
  local label="$1"
  [ -f "$CLASSIFIER_DOC" ] || return 1
  awk -F '|' -v want="$label" '
    /^\| `/ {
      # Strip surrounding spaces and backticks from cells 2 and 3
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3)
      gsub(/^`|`$/, "", $2)
      gsub(/^`|`$/, "", $3)
      if ($2 == want) {
        print $3
        exit 0
      }
    }
  ' "$CLASSIFIER_DOC"
}

VERDICT="$(grep_classifier_verdict "$CALL_SITE" || true)"

# ---------------------------------------------------------------------------
# AC3 — Unknown call-site label → non-zero exit with UnknownCallSiteError
# ---------------------------------------------------------------------------
if [ -z "$VERDICT" ]; then
  echo "UnknownCallSiteError: '$CALL_SITE' not in classifier table" >&2
  echo "  classifier doc: $CLASSIFIER_DOC" >&2
  echo "  add a row to the Classifier Table or fix the caller." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Verdict dispatch
# ---------------------------------------------------------------------------
case "$VERDICT" in
  user)
    # True escalation — route to user with the evidence as context.
    # EXCEPTION: PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 (set by pwt-goal.sh --auto-push,
    # implied by --launch) auto-approves push-ack. Other user-verdict sites
    # (secret-scan-allow, scope-unlock-for-drift) still escalate — they are
    # security/scope decisions where blanket auto-approval would be reckless.
    if [ "$CALL_SITE" = "push-ack" ] && [ "${PLAN_W_TEAM_AUTO_APPROVE_PUSH:-}" = "1" ]; then
        # Log the auto-approval to the decision JSONL so retro can audit.
        AUTO_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        DECISION_LOG="$STATE_DIR/plan-w-team-orchestrator-decisions-${SLUG}.jsonl"
        mkdir -p "$STATE_DIR"
        printf '{"timestamp":"%s","call_site":"push-ack","slug":"%s","decision":{"choice":"proceed","rationale":"auto-approved by PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 (user pre-authorized via pwt-goal --launch or --auto-push)","confidence":"high"}}\n' \
            "$AUTO_TS" "$SLUG" >> "$DECISION_LOG" 2>/dev/null
        echo "[orchestrator-route] push-ack auto-approved (PLAN_W_TEAM_AUTO_APPROVE_PUSH=1)" >&2
        echo "proceed"
        exit 0
    fi
    ask_user_question "$CALL_SITE" "${EVIDENCE_ARGS[@]+"${EVIDENCE_ARGS[@]}"}"
    exit $?
    ;;

  inline-rule)
    # Reserved for deterministic shortcuts. No call site currently qualifies,
    # so default behavior is to delegate to user-ASK for safety. Future
    # opt-ins should add a case here for the specific label.
    ask_user_question "$CALL_SITE-inline-fallback" "${EVIDENCE_ARGS[@]+"${EVIDENCE_ARGS[@]}"}"
    exit $?
    ;;

  orchestrator)
    # Fall through to the orchestrator block below.
    ;;

  *)
    echo "ClassifierError: unknown verdict '$VERDICT' for call-site '$CALL_SITE'" >&2
    echo "  allowed verdicts: orchestrator | user | inline-rule" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Orchestrator route (AC1, AC4, AC5)
# ---------------------------------------------------------------------------
# Steps:
#   1. Acquire mkdir-based lock for this SLUG (serializes concurrent calls).
#   2. Spawn the orchestrator agent via `agent_invoke`.
#   3. Parse the machine-fenced decision block from its output.
#   4. On parse failure → fall through to ask_user_question with the prose
#      as preamble (AC4 — non-silent failure).
#   5. On success → append JSONL row, echo the chosen option to stdout.
#   6. Release the lock (via trap).
# ---------------------------------------------------------------------------

DECISION_LOG="$STATE_DIR/plan-w-team-orchestrator-decisions-${SLUG}.jsonl"
LOCK_DIR="$STATE_DIR/plan-w-team-orchestrator-decisions-${SLUG}.lock"

mkdir -p "$STATE_DIR"

# mkdir lock — atomic on POSIX filesystems. Spin with a short sleep.
# Guard against runaway loops with a 30s timeout (300 * 0.1s).
LOCK_ATTEMPTS=0
LOCK_MAX_ATTEMPTS=300
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  LOCK_ATTEMPTS=$(( LOCK_ATTEMPTS + 1 ))
  if [ "$LOCK_ATTEMPTS" -ge "$LOCK_MAX_ATTEMPTS" ]; then
    echo "LockTimeoutError: could not acquire $LOCK_DIR after 30s" >&2
    echo "  stale lock? rmdir it manually if no other route is running." >&2
    exit 1
  fi
  sleep 0.1
done
# Release lock on any exit (success, failure, signal).
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# Spawn orchestrator. Capture all stdout; stderr passes through.
# agent_invoke argv: <call_site> <slug> [evidence...]
AGENT_OUT="$(agent_invoke "$CALL_SITE" "$SLUG" "${EVIDENCE_ARGS[@]+"${EVIDENCE_ARGS[@]}"}")"
AGENT_RC=$?

if [ "$AGENT_RC" -ne 0 ]; then
  # Agent failed to even produce output — non-silent fall through to ASK
  # with the partial output as the preamble.
  ask_user_question "${CALL_SITE}-fallback" \
    "Orchestrator agent exited with code $AGENT_RC. Partial output:" \
    "$AGENT_OUT"
  exit $?
fi

# Parse the machine-fenced decision block.
# Pattern matches the contract in shared/orchestrator-interception.md:
#   ```decision
#   {"choice": "...", "rationale": "...", "confidence": "..."}
#   ```
# Mirrors the evaluator-verdict parser in .claude/commands/plan-w-team/03-execute.md §4b.
#
# A valid block REQUIRES an explicit closing ``` line. An unclosed fence is
# treated as malformed (fail-closed) — silently accepting JSON that the agent
# never sealed off would mask buggy prompts and weaken the AC4 guarantee.
DECISION_PARSE="$(printf '%s\n' "$AGENT_OUT" | awk '
  BEGIN { flag = 0; closed = 0; body = "" }
  /^```decision$/ { flag = 1; next }
  /^```$/         {
    if (flag) {
      closed = 1
      flag = 0
      exit
    }
  }
  flag            { body = body $0 "\n" }
  END             {
    if (closed) {
      printf "%s", body
    }
    # If !closed → print nothing. Caller treats empty as parse failure.
  }
')"

# Validate it parses as JSON.
DECISION_VALID=1
if [ -z "$DECISION_PARSE" ]; then
  DECISION_VALID=0
elif ! printf '%s' "$DECISION_PARSE" | jq -e . >/dev/null 2>&1; then
  DECISION_VALID=0
fi

DECISION_JSON="$DECISION_PARSE"

if [ "$DECISION_VALID" -ne 1 ]; then
  # AC4 — malformed decision block. Fall through to ASK with the prose
  # preamble. Non-silent: the user sees what the orchestrator tried to say.
  ask_user_question "${CALL_SITE}-fallback" \
    "Orchestrator returned a malformed decision block. Prose preamble:" \
    "$AGENT_OUT"
  exit $?
fi

# Extract chosen option (the value we'll echo to stdout for the caller).
CHOICE="$(printf '%s' "$DECISION_JSON" | jq -r '.choice // empty' 2>/dev/null)"
if [ -z "$CHOICE" ]; then
  # Block parsed as JSON but lacks `choice` — same fall-through.
  ask_user_question "${CALL_SITE}-fallback" \
    "Orchestrator decision block lacks 'choice' field. Prose preamble:" \
    "$AGENT_OUT"
  exit $?
fi

# Append JSONL row to the decision log. Use jq -nc to build the row safely
# (no string interpolation of LLM-authored content into shell).
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build the row with jq so the decision object is preserved as nested JSON.
ROW="$(jq -nc \
  --arg ts "$TIMESTAMP" \
  --arg cs "$CALL_SITE" \
  --arg slug "$SLUG" \
  --argjson decision "$DECISION_JSON" \
  '{timestamp: $ts, call_site: $cs, slug: $slug, decision: $decision}')"

if [ -z "$ROW" ]; then
  echo "JsonRowBuildError: failed to assemble decision-log row" >&2
  exit 1
fi

# Append atomically — printf + >> is line-atomic for writes under
# PIPE_BUF (4 KiB on Linux). Decision rows are well under that limit.
printf '%s\n' "$ROW" >> "$DECISION_LOG"

# Echo the chosen option for the caller to act on.
printf '%s\n' "$CHOICE"

exit 0
