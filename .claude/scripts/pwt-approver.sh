#!/usr/bin/env bash
# pwt-approver.sh — Governor Contract phase 2 (C4): the delegated file-mode approver
# for /plan-w-team hard-gate pause sites.
#
# THE PROBLEM
# -----------
# The three hard gates (push-ack, secret-scan-allow, scope-unlock-for-drift) halt for a
# HUMAN at a terminal. A 24/7 governor (CleanRev's Shipyard CE) holds the founder's
# standing grants and can answer within policy — but only through FILES + EXIT CODES,
# never by importing skill code. This script is that protocol.
#
# GOVERNED-ONLY. Ungoverned (no PWT_GOVERNOR/manifest) or no file-mode approver in the
# manifest → exit 10 (NOT APPLICABLE) and the caller falls back to the human prompt.
# It NEVER auto-approves: a refused/escaping approver dir, a missing decision, an
# escalate, or a malformed decision all leave the gate CLOSED.
#
# PROTOCOL (see docs/specs/governor-contract-phase-2-*.md §4):
#   await:  resolve+validate approver dir → write <slug>.<gate>.request.json (pwt-pause/1)
#           → emit the pause event → poll for <slug>.<gate>.decision.json → consume it.
#   consume: read+validate a decision → act (approve creates the gate's operator file;
#            deny takes the deny path; escalate/silence/malformed stay halted) → audit
#            with `by` + `grant_ref` → emit the decision event.
#
# A one-way-door approve WITHOUT `grant_ref` is refused (escalated) — an irreversible
# action requires a named grant. Self-approval is blocked by the lane guard, which denies
# the worker + bound supervisor writing the decision file: the FILE-TOOL (Write/Edit) path
# is the hard, resolved-path wall; the Bash-command path is BEST-EFFORT (it catches the
# natural drift shapes, like the guard's other classifiers, but a decision file written via
# an indirect Bash construction is not guaranteed to be caught — see governor-contract.md).
# This script's decision validation ("ignored loudly") is the second layer.
#
# Exit codes:
#   0   approved  — operator file created, proceed
#   20  denied    — take the existing deny / stand-down path
#   30  halted    — escalate / silence (no decision) / malformed / one-way-without-grant
#   10  not applicable (ungoverned / no file-mode approver) — caller uses human prompt
#   4   refused   — approver dir git-tracked or escaping the repo — caller uses human prompt
#   2   usage error
#
# Kill switch: PWT_APPROVER_DISABLE=1 → exit 10 (protocol off, human prompt).
# Spec: docs/specs/governor-contract-phase-2-c1-observability-c4-approver.md
# Tests: .claude/scripts/pwt-approver.test.sh

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SELF_DIR/pwt-governor-lib.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "pwt-approver: jq required" >&2; exit 2
fi

# ── args ──────────────────────────────────────────────────────────────────────
SUB="${1:-}"; [ -n "$SUB" ] && shift || true
SLUG=""; GATE=""; RISK="two-way"; PROPOSED=""; POLL_S="${PWT_APPROVER_POLL_S:-15}"
MAX_POLLS=1; BLOCK=0; OPERATOR_STATE_DIR=""; APPROVER_DIR_OVERRIDE=""
declare -a EVIDENCE=(); declare -a POLICY_REFS=()

# Value-consuming arms use `shift; [ $# -gt 0 ] && shift` (NOT `shift 2`): a bare
# `shift 2` on a value-less trailing flag shifts nothing and spins forever under a
# tolerant `"${2:-}"` (argparse-shift2-lint enforces this corpus-wide).
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)             SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --gate)             GATE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --risk)             RISK="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --proposed-action)  PROPOSED="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --evidence)         EVIDENCE+=("${2:-}"); shift; [ $# -gt 0 ] && shift ;;
    --policy-ref)       POLICY_REFS+=("${2:-}"); shift; [ $# -gt 0 ] && shift ;;
    --poll-seconds)     POLL_S="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --max-polls)        MAX_POLLS="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --block)            BLOCK=1; shift ;;
    --operator-state-dir) OPERATOR_STATE_DIR="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --approver-dir)     APPROVER_DIR_OVERRIDE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;   # test seam
    -h|--help)          SUB="help"; shift ;;
    *)                  shift ;;
  esac
done

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' >&2
}

[ "$SUB" = "help" ] && { usage; exit 0; }
case "$SUB" in await|consume) : ;; *) echo "pwt-approver: subcommand must be await|consume" >&2; usage; exit 2 ;; esac
[ -n "$SLUG" ] || { echo "pwt-approver: --slug required" >&2; exit 2; }
[ -n "$GATE" ] || { echo "pwt-approver: --gate required" >&2; exit 2; }

if [ "${PWT_APPROVER_DISABLE:-0}" = "1" ]; then
  echo "pwt-approver: PWT_APPROVER_DISABLE=1 → not applicable (human prompt)" >&2; exit 10
fi

# Operator state dir = where the gate's operator file (the human touch target) lives.
# The ship gate reads .claude/state/plan-w-team-ack-$SLUG relative to the run CWD.
[ -n "$OPERATOR_STATE_DIR" ] || OPERATOR_STATE_DIR="$PWD/.claude/state"
AUDIT="$OPERATOR_STATE_DIR/plan-w-team-approver-audit-$SLUG.jsonl"

# Map a gate → the operator file basename a human would touch.
gate_operator_file() {
  case "$1" in
    push-ack)               echo "plan-w-team-ack-$SLUG" ;;
    secret-scan-allow)      echo "plan-w-team-secret-scan-allow-$SLUG" ;;
    scope-unlock-for-drift) echo "plan-w-team-scope-unlock-$SLUG" ;;
    *)                      echo "" ;;   # unknown gate → no operator file (refuse to invent one)
  esac
}

ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Source the governor lib for detection + event emission (fail-open if absent).
GOV_OK=0
if [ -r "$LIB" ]; then
  # shellcheck disable=SC1090
  . "$LIB" 2>/dev/null && GOV_OK=1
fi

# Resolve the approver dir (request/decision live here). The --approver-dir override
# BYPASSES pwt_governor_approver_dir's tracked/escaping validation, so it is a TEST-ONLY
# seam gated behind PWT_APPROVER_ALLOW_DIR_OVERRIDE=1 — a production caller cannot point
# request/decision I/O at an arbitrary dir.
resolve_approver_dir() {
  if [ -n "$APPROVER_DIR_OVERRIDE" ] && [ "${PWT_APPROVER_ALLOW_DIR_OVERRIDE:-0}" = "1" ]; then
    echo "$APPROVER_DIR_OVERRIDE"; return 0
  fi
  if [ -n "$APPROVER_DIR_OVERRIDE" ]; then
    echo "pwt-approver: --approver-dir requires PWT_APPROVER_ALLOW_DIR_OVERRIDE=1 (test-only seam)" >&2
    echo ""; return 1
  fi
  [ "$GOV_OK" = "1" ] || { echo ""; return 1; }
  command -v pwt_governor_approver_dir >/dev/null 2>&1 || { echo ""; return 1; }
  local d rc
  d=$(pwt_governor_approver_dir); rc=$?
  echo "$d"; return $rc
}

emit_event() {   # $1 = detail json — governed-only, fail-open
  [ "$GOV_OK" = "1" ] || return 0
  command -v pwt_governor_emit_event >/dev/null 2>&1 || return 0
  pwt_governor_emit_event "$SLUG" "$1" 2>/dev/null || true
}

audit() {   # $1=decision $2=by $3=grant_ref $4=outcome $5=reason
  mkdir -p "$OPERATOR_STATE_DIR" 2>/dev/null || true
  jq -cn --arg ts "$(ts_now)" --arg slug "$SLUG" --arg gate "$GATE" \
     --arg decision "${1:-}" --arg by "${2:-}" --arg grant_ref "${3:-}" \
     --arg outcome "${4:-}" --arg reason "${5:-}" \
     '{ts:$ts, slug:$slug, gate:$gate, decision:$decision, by:$by, grant_ref:$grant_ref, outcome:$outcome, reason:$reason}' \
     >> "$AUDIT" 2>/dev/null || true
}

REQUEST_PATH=""; DECISION_PATH=""

# ── consume: validate + act on a decision.json ──────────────────────────────────
do_consume() {
  local dfile="$DECISION_PATH"
  if [ ! -f "$dfile" ]; then
    echo "pwt-approver: no decision for $SLUG.$GATE — silence, staying HALTED" >&2
    audit "" "" "" "halted" "silence-no-decision-file"
    return 30
  fi
  if ! jq -e . "$dfile" >/dev/null 2>&1; then
    echo "pwt-approver: decision $dfile does not parse — IGNORED (loud), staying HALTED" >&2
    audit "" "" "" "halted" "malformed-unparseable-decision"
    return 30
  fi
  local decision by grant_ref reason
  decision=$(jq -r '.decision // ""' "$dfile" 2>/dev/null)
  by=$(jq -r '.by // ""' "$dfile" 2>/dev/null)
  grant_ref=$(jq -r '.grant_ref // ""' "$dfile" 2>/dev/null)
  reason=$(jq -r '.reason // ""' "$dfile" 2>/dev/null)

  # Risk comes from the REQUEST (what the run proposed), not the decision (untrusted).
  local risk="$RISK"
  if [ -n "$REQUEST_PATH" ] && [ -f "$REQUEST_PATH" ]; then
    local rr; rr=$(jq -r '.risk // ""' "$REQUEST_PATH" 2>/dev/null)
    [ -n "$rr" ] && risk="$rr"
    # Replay guard: a decision whose ts predates the request it answers is a stale
    # leftover — ignore it and stay HALTED. Enforced only when both timestamps exist
    # (ISO8601 UTC → lexicographic compare is chronological); fail-open otherwise.
    local req_since dec_ts
    req_since=$(jq -r '.since // ""' "$REQUEST_PATH" 2>/dev/null)
    dec_ts=$(jq -r '.ts // ""' "$dfile" 2>/dev/null)
    if [ -n "$req_since" ] && [ -n "$dec_ts" ] && [ "$dec_ts" \< "$req_since" ]; then
      echo "pwt-approver: decision $dfile (ts=$dec_ts) predates its request (since=$req_since) — STALE, ignored, staying HALTED" >&2
      audit "$decision" "$by" "$grant_ref" "halted" "stale-decision-predates-request"
      return 30
    fi
  fi

  case "$decision" in
    approve)
      if [ -z "$by" ]; then
        echo "pwt-approver: approve without 'by' — IGNORED (loud), staying HALTED" >&2
        audit "approve" "" "$grant_ref" "halted" "approve-without-by"
        emit_event "$(jq -cn --arg gate "$GATE" '{event:"decision", gate:$gate, decision:"escalate", by:"", grant_ref:""}')"
        return 30
      fi
      if [ "$risk" = "one-way" ] && [ -z "$grant_ref" ]; then
        echo "pwt-approver: one-way approve without grant_ref — ESCALATING, staying HALTED" >&2
        audit "approve" "$by" "" "escalated" "one-way-approve-without-grant_ref"
        emit_event "$(jq -cn --arg gate "$GATE" --arg by "$by" '{event:"decision", gate:$gate, decision:"escalate", by:$by, grant_ref:""}')"
        return 30
      fi
      local opfile; opfile=$(gate_operator_file "$GATE")
      if [ -z "$opfile" ]; then
        echo "pwt-approver: unknown gate '$GATE' has no operator file — staying HALTED" >&2
        audit "approve" "$by" "$grant_ref" "halted" "unknown-gate-no-operator-file"
        return 30
      fi
      mkdir -p "$OPERATOR_STATE_DIR" 2>/dev/null || true
      : > "$OPERATOR_STATE_DIR/$opfile" 2>/dev/null || {
        echo "pwt-approver: could not create operator file $OPERATOR_STATE_DIR/$opfile — staying HALTED" >&2
        audit "approve" "$by" "$grant_ref" "halted" "operator-file-write-failed"
        return 30
      }
      echo "✓ pwt-approver: $GATE APPROVED by $by (grant_ref=${grant_ref:-none}) → touched $opfile" >&2
      audit "approve" "$by" "$grant_ref" "approved" "$reason"
      emit_event "$(jq -cn --arg gate "$GATE" --arg by "$by" --arg gr "$grant_ref" '{event:"decision", gate:$gate, decision:"approve", by:$by, grant_ref:$gr}')"
      return 0 ;;
    deny)
      echo "✗ pwt-approver: $GATE DENIED by ${by:-?} — taking the deny/stand-down path" >&2
      audit "deny" "$by" "$grant_ref" "denied" "$reason"
      emit_event "$(jq -cn --arg gate "$GATE" --arg by "$by" '{event:"decision", gate:$gate, decision:"deny", by:$by, grant_ref:""}')"
      return 20 ;;
    escalate)
      echo "⚠ pwt-approver: $GATE ESCALATED by ${by:-?} — staying HALTED for the human" >&2
      audit "escalate" "$by" "$grant_ref" "escalated" "$reason"
      emit_event "$(jq -cn --arg gate "$GATE" --arg by "$by" '{event:"decision", gate:$gate, decision:"escalate", by:$by, grant_ref:""}')"
      return 30 ;;
    *)
      echo "pwt-approver: invalid decision value '${decision}' — IGNORED (loud), staying HALTED" >&2
      audit "$decision" "$by" "$grant_ref" "halted" "invalid-decision-value"
      return 30 ;;
  esac
}

# ── resolve the approver dir + request/decision paths ───────────────────────────
ADIR=$(resolve_approver_dir); ADIR_RC=$?
if [ "$ADIR_RC" = "4" ]; then
  echo "pwt-approver: approver dir REFUSED (git-tracked or escaping the repo) — human prompt" >&2
  exit 4
fi
if [ -z "$ADIR" ]; then
  # Not applicable (ungoverned / no file-mode approver). SILENT exit — the caller falls
  # back to the human prompt. Silence is required for P0 parity: an ungoverned run that
  # reaches this must add no new stderr line. (--debug surfaces it for diagnosis.)
  [ "${PWT_APPROVER_DEBUG:-0}" = "1" ] && echo "pwt-approver: not governed / no file-mode approver — human prompt" >&2
  exit 10
fi
REQUEST_PATH="$ADIR/$SLUG.$GATE.request.json"
DECISION_PATH="$ADIR/$SLUG.$GATE.decision.json"

case "$SUB" in
  consume)
    do_consume; exit $? ;;

  await)
    mkdir -p "$ADIR" 2>/dev/null || { echo "pwt-approver: cannot create approver dir $ADIR — human prompt" >&2; exit 10; }
    # Write the request (idempotent — do not clobber an existing one).
    if [ ! -f "$REQUEST_PATH" ]; then
      EV_JSON=$(printf '%s\n' "${EVIDENCE[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')
      PR_JSON=$(printf '%s\n' "${POLICY_REFS[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')
      jq -n --arg schema "pwt-pause/1" --arg slug "$SLUG" --arg gate "$GATE" \
            --arg since "$(ts_now)" --argjson evidence "${EV_JSON:-[]}" \
            --arg proposed "$PROPOSED" --argjson policy_refs "${PR_JSON:-[]}" --arg risk "$RISK" \
            '{schema:$schema, slug:$slug, gate:$gate, since:$since, evidence:$evidence, proposed_action:$proposed, policy_refs:$policy_refs, risk:$risk}' \
            > "$REQUEST_PATH" 2>/dev/null || { echo "pwt-approver: could not write request $REQUEST_PATH — human prompt" >&2; exit 10; }
      echo "⏸ pwt-approver: wrote pause request $REQUEST_PATH (gate=$GATE risk=$RISK) — awaiting governor decision" >&2
    fi
    # Emit the pause event once per await.
    emit_event "$(jq -cn --arg gate "$GATE" --arg risk "$RISK" '{event:"pause", gate:$gate, risk:$risk}')"

    # Poll for the decision. --block = no wall-clock cap; else --max-polls bounds it.
    polls=0
    while :; do
      if [ -f "$DECISION_PATH" ]; then
        do_consume; exit $?
      fi
      polls=$((polls + 1))
      if [ "$BLOCK" != "1" ] && [ "$polls" -ge "$MAX_POLLS" ]; then
        echo "pwt-approver: no decision after $polls poll(s) — silence, staying HALTED" >&2
        audit "" "" "" "halted" "silence-timeout-non-block"
        exit 30
      fi
      sleep "$POLL_S" 2>/dev/null || sleep 1
    done ;;
esac
