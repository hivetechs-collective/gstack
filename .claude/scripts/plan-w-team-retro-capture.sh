#!/usr/bin/env bash
# plan-w-team-retro-capture.sh
#
# Recursive-improvement capture for the Step 8 retro (Deliverable 3,
# docs/specs/dogfood-retro-safe-prompt-fixes.md). Runs on EVERY full /plan-w-team
# run — not only when self-assessment <8 — so weaknesses/struggles/gaps and
# best-practice REGRESSIONS are captured and fed back as queued follow-ups, making
# recursive improvement a guaranteed property of the skill rather than an
# optional, remembered-only step.
#
# WHY (eval report F-series + brief Deliverable 3): the retro already scores many
# SUCCESS-oriented quality signals (§8j-bis…octies) and logs friction ONLY when
# self-assessment <8 (§8i). It never (a) captures struggles/gaps when the run felt
# fine, nor (b) checks this run's best-practice adherence against the PRIOR run to
# flag a regression. This helper closes both: it ALWAYS emits a capture record
# (empty arrays are valid, not a skipped block), compares adherence vs the last
# run, and queues follow-ups into a durable cross-run log the next preflight reads.
#
# Strictly ADDITIVE: it consumes the retro JSON that §8j sections already wrote and
# never mutates existing retro outputs. Advisory (R10): never fails the retro.
#
# Usage:
#   plan-w-team-retro-capture.sh --slug <slug>
#     [--state-dir <dir>]                # default: <git-root>/.claude/state
#     [--retro-state <path>]             # default: $STATE_DIR/plan-w-team-retro-<slug>.json
#     [--self-assessment <0-10|null>]    # default: read from retro-state, else null
#     [--weakness "<text>"]...           # repeatable
#     [--gap "<text>"]...                # repeatable
#     [--struggle "<text>"]...           # repeatable
#     [--follow-up "<text>"]...          # repeatable
#     [--history <path>]                 # default: $STATE_DIR/plan-w-team-retro-capture-history.jsonl
#     [--out <path>]                     # default: $STATE_DIR/plan-w-team-retro-capture-<slug>.json
#     [--followups-log <path>]           # default: $STATE_DIR/plan-w-team-recursive-followups.jsonl
#     [--quiet]
#
# Exit: 0 always (advisory). Missing --slug → 2 (caller bug).
set -uo pipefail

SLUG=""
STATE_DIR_OVERRIDE=""
RETRO_STATE_OVERRIDE=""
SELF_ASSESSMENT="auto"
HISTORY_OVERRIDE=""
OUT_OVERRIDE=""
FOLLOWUPS_OVERRIDE=""
QUIET=0
WEAKNESSES=()
GAPS=()
STRUGGLES=()
FOLLOWUPS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --slug)            SLUG="${2:-}"; shift 2 ;;
    --state-dir)       STATE_DIR_OVERRIDE="${2:-}"; shift 2 ;;
    --retro-state)     RETRO_STATE_OVERRIDE="${2:-}"; shift 2 ;;
    --self-assessment) SELF_ASSESSMENT="${2:-}"; shift 2 ;;
    --weakness)        WEAKNESSES+=("${2:-}"); shift 2 ;;
    --gap)             GAPS+=("${2:-}"); shift 2 ;;
    --struggle)        STRUGGLES+=("${2:-}"); shift 2 ;;
    --follow-up)       FOLLOWUPS+=("${2:-}"); shift 2 ;;
    --history)         HISTORY_OVERRIDE="${2:-}"; shift 2 ;;
    --out)             OUT_OVERRIDE="${2:-}"; shift 2 ;;
    --followups-log)   FOLLOWUPS_OVERRIDE="${2:-}"; shift 2 ;;
    --quiet)           QUIET=1; shift ;;
    *)                 shift ;;
  esac
done

if [ -z "$SLUG" ]; then
  echo "✗ plan-w-team-retro-capture.sh: --slug is required" >&2
  exit 2
fi

# jq is required for JSON assembly; degrade fail-open (R10) if absent.
if ! command -v jq >/dev/null 2>&1; then
  [ "$QUIET" = "1" ] || echo "⚠ retro-capture: jq unavailable — skipping (advisory)" >&2
  exit 0
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${STATE_DIR_OVERRIDE:-$PROJECT_ROOT/.claude/state}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

RETRO_STATE="${RETRO_STATE_OVERRIDE:-$STATE_DIR/plan-w-team-retro-${SLUG}.json}"
HISTORY="${HISTORY_OVERRIDE:-$STATE_DIR/plan-w-team-retro-capture-history.jsonl}"
OUT="${OUT_OVERRIDE:-$STATE_DIR/plan-w-team-retro-capture-${SLUG}.json}"
FOLLOWUPS_LOG="${FOLLOWUPS_OVERRIDE:-$STATE_DIR/plan-w-team-recursive-followups.jsonl}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Best-practice adherence: read the signal scores §8j sections wrote ─────────
ADHERENCE='{}'
if [ -f "$RETRO_STATE" ]; then
  ADHERENCE=$(jq '{
      bypass_rate:       (.quality_signals.bypass_rate.score // null),
      doc_hygiene:       (.quality_signals.doc_hygiene // null),
      untracked_hygiene: (.untracked_hygiene.score // null)
    }' "$RETRO_STATE" 2>/dev/null || echo '{}')
fi
[ -n "$ADHERENCE" ] || ADHERENCE='{}'

# ── Self-assessment: explicit arg wins; else read from retro-state; else null ──
if [ "$SELF_ASSESSMENT" = "auto" ]; then
  if [ -f "$RETRO_STATE" ]; then
    SELF_ASSESSMENT=$(jq -r '.self_assessment // .quality_signals.self_assessment // "null"' "$RETRO_STATE" 2>/dev/null || echo "null")
  else
    SELF_ASSESSMENT="null"
  fi
fi
[ -n "$SELF_ASSESSMENT" ] || SELF_ASSESSMENT="null"

# ── Regression check vs the most-recent prior capture record ──────────────────
REGRESSED='[]'
if [ -f "$HISTORY" ]; then
  PRIOR_LINE=$(tail -n 1 "$HISTORY" 2>/dev/null || echo "")
  if [ -n "$PRIOR_LINE" ]; then
    PRIOR_ADH=$(printf '%s' "$PRIOR_LINE" | jq -c '.best_practice_adherence // {}' 2>/dev/null || echo '{}')
    [ -n "$PRIOR_ADH" ] || PRIOR_ADH='{}'
    REGRESSED=$(jq -n --argjson cur "$ADHERENCE" --argjson prev "$PRIOR_ADH" '
      [ $cur | to_entries[]
        | .key as $k | .value as $cv
        | select($cv != null and ($prev[$k] != null) and ($cv < $prev[$k]))
        | {signal: $k, prior: $prev[$k], current: $cv} ]' 2>/dev/null || echo '[]')
  fi
fi
[ -n "$REGRESSED" ] || REGRESSED='[]'
REG_COUNT=$(printf '%s' "$REGRESSED" | jq 'length' 2>/dev/null || echo 0)
if [ "${REG_COUNT:-0}" -gt 0 ]; then REG_FLAG=true; else REG_FLAG=false; fi

# ── Helper: turn a bash array into a JSON string array (empty → []) ────────────
to_json_array() {
  if [ "$#" -eq 0 ]; then
    echo '[]'
  else
    printf '%s\n' "$@" | jq -R . | jq -s . 2>/dev/null || echo '[]'
  fi
}
WEAK_JSON=$(to_json_array ${WEAKNESSES[@]+"${WEAKNESSES[@]}"})
GAP_JSON=$(to_json_array ${GAPS[@]+"${GAPS[@]}"})
STRUGGLE_JSON=$(to_json_array ${STRUGGLES[@]+"${STRUGGLES[@]}"})

# ── Auto follow-ups: self-assessment <8 (investigate-and-update) + regressions ─
INVESTIGATE="null"
AUTO_FOLLOWUPS=()
if printf '%s' "$SELF_ASSESSMENT" | grep -qE '^[0-9]+$'; then
  if [ "$SELF_ASSESSMENT" -lt 8 ]; then
    INVESTIGATE="self-assessment ${SELF_ASSESSMENT}<8: investigate the lowest-scoring signal, update the relevant stage file or shared/ doc, and queue the fix — do not record the number alone."
    AUTO_FOLLOWUPS+=("investigate self-assessment ${SELF_ASSESSMENT}<8 and update the responsible stage file before the next run")
  fi
fi
if [ "$REG_FLAG" = "true" ]; then
  REG_SIGNALS=$(printf '%s' "$REGRESSED" | jq -r '[.[].signal] | join(", ")' 2>/dev/null || echo "")
  AUTO_FOLLOWUPS+=("best-practice regression vs prior run in: ${REG_SIGNALS} — investigate and restore")
fi

ALL_FOLLOWUPS=()
[ "${#FOLLOWUPS[@]}" -gt 0 ] && ALL_FOLLOWUPS+=("${FOLLOWUPS[@]}")
[ "${#AUTO_FOLLOWUPS[@]}" -gt 0 ] && ALL_FOLLOWUPS+=("${AUTO_FOLLOWUPS[@]}")
FOLLOWUP_JSON=$(to_json_array ${ALL_FOLLOWUPS[@]+"${ALL_FOLLOWUPS[@]}"})

# ── Compose the capture record ────────────────────────────────────────────────
if [ "$SELF_ASSESSMENT" = "null" ]; then SELF_JSON='null'; else SELF_JSON="$SELF_ASSESSMENT"; fi
if [ "$INVESTIGATE" = "null" ]; then INV_ARG='null'; else INV_ARG=$(jq -n --arg s "$INVESTIGATE" '$s'); fi

RECORD=$(jq -n \
  --arg slug "$SLUG" \
  --arg ts "$TS" \
  --argjson self "$SELF_JSON" \
  --argjson weaknesses "$WEAK_JSON" \
  --argjson gaps "$GAP_JSON" \
  --argjson struggles "$STRUGGLE_JSON" \
  --argjson adherence "$ADHERENCE" \
  --argjson regression_flag "$REG_FLAG" \
  --argjson regressed "$REGRESSED" \
  --argjson follow_ups "$FOLLOWUP_JSON" \
  --argjson investigate "$INV_ARG" \
  '{
    slug: $slug,
    ts: $ts,
    self_assessment: $self,
    weaknesses: $weaknesses,
    gaps: $gaps,
    struggles: $struggles,
    best_practice_adherence: $adherence,
    regression_flag: $regression_flag,
    regressed_signals: $regressed,
    follow_ups: $follow_ups,
    investigate_and_update: $investigate
  }' 2>/dev/null || echo '')

if [ -z "$RECORD" ]; then
  [ "$QUIET" = "1" ] || echo "⚠ retro-capture: failed to assemble record — skipping (advisory)" >&2
  exit 0
fi

# ── Persist: capture record (atomic), append to history + cross-run follow-ups ─
TMP="${OUT}.tmp.$$"
printf '%s\n' "$RECORD" > "$TMP" 2>/dev/null && mv "$TMP" "$OUT" 2>/dev/null || rm -f "$TMP"
printf '%s\n' "$(printf '%s' "$RECORD" | jq -c .)" >> "$HISTORY" 2>/dev/null || true

# Append each follow-up as a durable, open cross-run task line.
FU_COUNT=$(printf '%s' "$FOLLOWUP_JSON" | jq 'length' 2>/dev/null || echo 0)
if [ "${FU_COUNT:-0}" -gt 0 ]; then
  printf '%s' "$FOLLOWUP_JSON" | jq -r '.[]' 2>/dev/null | while IFS= read -r fu; do
    [ -z "$fu" ] && continue
    jq -cn --arg ts "$TS" --arg slug "$SLUG" --arg text "$fu" \
      '{ts:$ts, slug:$slug, source:"retro-capture", status:"open", text:$text}' \
      >> "$FOLLOWUPS_LOG" 2>/dev/null || true
  done
fi

# ── Human-readable summary ────────────────────────────────────────────────────
if [ "$QUIET" != "1" ]; then
  W=$(printf '%s' "$WEAK_JSON" | jq 'length'); G=$(printf '%s' "$GAP_JSON" | jq 'length')
  S=$(printf '%s' "$STRUGGLE_JSON" | jq 'length')
  echo "✓ recursive-improvement capture: weaknesses=$W gaps=$G struggles=$S follow_ups=$FU_COUNT regression=$REG_FLAG self_assessment=$SELF_ASSESSMENT"
  [ "$INVESTIGATE" != "null" ] && echo "  → investigate-and-update: $INVESTIGATE"
fi

printf '%s\n' "$RECORD"
exit 0
