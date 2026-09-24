#!/usr/bin/env bash
# plan-w-team-grounding-gate.sh  (GRD — Existing-System Grounding gate)
#
# ENFORCING two-phase gate that closes the existing-repo drift failure mode:
# a /plan-w-team run planning against an EXISTING repo without first reading
# its canonical documentation, so wrong assumptions about the current
# architecture get baked into the spec and propagate unchecked.
#
# Phase 1 (Step 1 freeze pre-condition, --phase spec, the default):
#   The spec MUST carry a non-blank "Existing-System Grounding Ledger"
#   section (heading matches "Grounding Ledger" OR "Existing-System
#   Grounding", case-insensitive, any level) whose body:
#     - covers EVERY canonical doc the enumerator finds (each enumerated
#       relative path must APPEAR in the section body — the read-vs-
#       skipped-with-reason disposition wording is the lead's duty, checked
#       semantically at Step 5, NOT parsed here), AND
#     - contains at least one claim TABLE ROW whose status cell is
#       CONFIRMED/ASSUMED (row-anchored — prose mentions of the tokens do
#       not count), OR the canonical greenfield statement (the phrase
#       "no existing documentation" — a bare "greenfield" mention or its
#       negation does not qualify).
#
# Phase 2 (Step 5 review re-check, --phase review):
#   Same checks against the LIVE repo (a doc added mid-run must be covered),
#   PLUS zero ASSUMED rows may remain — by review time every assumption is
#   either CONFIRMED against the repo or was refuted and the spec corrected.
#
# The enumerator (--enumerate) is the deterministic detection FLOOR (audit
# P9c philosophy: detection must not be LLM-only). It lists canonical
# entry-point docs only — README*, CLAUDE.md, AGENTS.md, CONTRIBUTING*,
# ARCHITECTURE*, DESIGN*, GOVERNANCE*, root docs/*.md, docs/architecture/,
# docs/adr/, docs/decisions/ — NOT every doc in the repo. Deep feature-
# relevant docs are reached from these entry points (LLM judgment, verified
# semantically at Step 5 per shared/grounding.md).
#
# Claims query (--claims --spec <spec>):
#   A programmatic accessor over the SAME Grounding Ledger the --check gate
#   reads, for downstream callers that must know whether a change is grounded
#   (Step-7 doc-vs-code conflict resolution, 06-post-ship.md §7a-quater/§7f).
#   It emits one "<STATUS>\t<claim>" line per ledger claim row to stdout
#   (STATUS ∈ CONFIRMED/ASSUMED, claim = the row's first cell), and its EXIT
#   CODE is the grounded verdict:
#     0 — every claim row is CONFIRMED (the ledger is fully grounded)
#     1 — any row is ASSUMED, OR the ledger is absent / blank / has no claim
#         rows (i.e. NOT fully grounded — treat the change as unconfirmed)
#   CALLER CONTRACT: the PLAN_W_TEAM_DISABLE_GROUNDING kill switch below makes
#   EVERY mode exit 0, so a kill-switched exit 0 is NOT a grounding verdict. A
#   caller that gates a grounding-dependent action on --claims MUST test
#   PLAN_W_TEAM_DISABLE_GROUNDING itself FIRST and apply its OWN disabled-policy:
#   when the switch is set the grounding floor is off and grounding cannot be
#   confirmed, so a conservative caller treats "disabled" as NOT grounded rather
#   than reading exit 0 as "confirmed". See 06-post-ship.md §7a-quater for the
#   reference caller (disabled floor → DOC_TRUSTED=0 → do not overwrite the doc).
#
# Kill switch (consistent with the PLAN_W_TEAM_DISABLE_* family):
#   PLAN_W_TEAM_DISABLE_GROUNDING=1 → exit 0 with a notice, never blocks.
#
# Usage:
#   plan-w-team-grounding-gate.sh --enumerate [--root <dir>]
#   plan-w-team-grounding-gate.sh --check --spec docs/specs/<slug>.md \
#       [--phase spec|review] [--root <dir>]
#   plan-w-team-grounding-gate.sh --check --slug <slug>   # → docs/specs/<slug>.md
#   plan-w-team-grounding-gate.sh --claims --spec docs/specs/<slug>.md \
#       [--root <dir>]                                    # or --slug <slug>
#
# Exit codes (mirrors plan-w-team-reuse-audit-gate.sh):
#   0 — gate passes (or kill switch active); for --claims, ledger fully CONFIRMED
#   1 — gate FAILS (section missing/blank, uncovered doc, ASSUMED at review);
#       for --claims, any ASSUMED row or an absent/blank/rowless ledger
#   2 — spec file not found (author the spec first)
#
# Env:
#   PWT_GROUNDING_MAX  — enumeration cap (default 30). Truncation is LOUD
#                        (warning on stderr), never silent.
#
# bash 3.2 compatible (no associative arrays, no mapfile).

set -u

PROG="plan-w-team-grounding-gate"

# ── Kill switch ──────────────────────────────────────────────────────────────
if [ "${PLAN_W_TEAM_DISABLE_GROUNDING:-}" = "1" ]; then
  echo "[$PROG] PLAN_W_TEAM_DISABLE_GROUNDING=1 — grounding gate disabled (exit 0)"
  # Record the bypass in the run's kill-switch ledger (row 27). The ledger scans
  # our argv for --spec/--slug/--root; output discarded, failure ignored.
  "$(dirname "$0")/plan-w-team-killswitch-ledger.sh" record \
    --switch PLAN_W_TEAM_DISABLE_GROUNDING --site grounding-gate -- ${1+"$@"} >/dev/null 2>&1 || true
  exit 0
fi

# ── Arg parsing ──────────────────────────────────────────────────────────────
MODE=""
SPEC=""
SLUG=""
ROOT=""
PHASE="spec"
while [ $# -gt 0 ]; do
  case "$1" in
    --enumerate) MODE="enumerate"; shift ;;
    --check) MODE="check"; shift ;;
    --claims) MODE="claims"; shift ;;
    # "shift 2" with the flag as the LAST arg shifts nothing (set -u does not
    # catch a failed shift), leaving $# and $1 unchanged → infinite 100%-CPU
    # loop. Shift the flag, then shift the value only if one is present.
    --spec) SPEC="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --slug) SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --root) ROOT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --phase) PHASE="${2:-spec}"; shift; [ $# -gt 0 ] && shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -50; exit 0 ;;
    *) [ -z "$SPEC" ] && { [ "$MODE" = "check" ] || [ "$MODE" = "claims" ]; } && SPEC="$1"; shift ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "[$PROG] ✗ pass --enumerate or --check" >&2
  exit 2
fi

if [ "$PHASE" != "spec" ] && [ "$PHASE" != "review" ]; then
  echo "[$PROG] ✗ --phase must be 'spec' or 'review' (got: $PHASE)" >&2
  exit 2
fi

# ── Resolve repo root ────────────────────────────────────────────────────────
if [ -z "$ROOT" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
if [ ! -d "$ROOT" ]; then
  echo "[$PROG] ✗ root dir not found: $ROOT" >&2
  exit 2
fi

# ── Enumerator: canonical grounding docs, relative paths, sorted, capped ────
# Deterministic order + LOUD cap (no silent truncation).
GROUNDING_MAX="${PWT_GROUNDING_MAX:-30}"

enumerate_docs() {
  # Root-level canonical entry points (case variants via glob).
  # Emitted as paths relative to $ROOT, one per line.
  (
    cd "$ROOT" || exit 0
    for f in README* readme* CLAUDE.md AGENTS.md CONTRIBUTING* ARCHITECTURE* \
             DESIGN* GOVERNANCE*; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done
    # Top-level docs/*.md only (subdirs below are opt-in by category).
    for f in docs/*.md; do
      [ -f "$f" ] && printf '%s\n' "$f"
    done
    # Architecture-decision categories (bounded, high-signal).
    for d in docs/architecture docs/adr docs/decisions; do
      if [ -d "$d" ]; then
        for f in "$d"/*.md; do
          [ -f "$f" ] && printf '%s\n' "$f"
        done
      fi
    done
  ) | LC_ALL=C sort -u   # C collation: deterministic across machines/locales
}

ALL_DOCS=$(enumerate_docs)
if [ -n "$ALL_DOCS" ]; then
  TOTAL_DOCS=$(printf '%s\n' "$ALL_DOCS" | grep -c .)
else
  TOTAL_DOCS=0
fi

if [ "$TOTAL_DOCS" -gt "$GROUNDING_MAX" ]; then
  DOCS=$(printf '%s\n' "$ALL_DOCS" | head -n "$GROUNDING_MAX")
  DROPPED=$((TOTAL_DOCS - GROUNDING_MAX))
  echo "[$PROG] ⚠ enumeration capped at $GROUNDING_MAX of $TOTAL_DOCS docs ($DROPPED dropped — raise PWT_GROUNDING_MAX to widen)" >&2
else
  DOCS="$ALL_DOCS"
fi

if [ "$MODE" = "enumerate" ]; then
  [ -n "$DOCS" ] && printf '%s\n' "$DOCS"
  exit 0
fi

# ── --check / --claims mode (both read a spec's Grounding Ledger) ────────────
if [ -z "$SPEC" ] && [ -n "$SLUG" ]; then
  SPEC="docs/specs/${SLUG}.md"
fi
if [ -z "$SPEC" ]; then
  echo "[$PROG] ✗ no --spec or --slug given" >&2
  exit 2
fi

# Resolve: as-given, else relative to $ROOT.
if [ ! -f "$SPEC" ] && [ -f "$ROOT/$SPEC" ]; then
  SPEC="$ROOT/$SPEC"
fi
if [ ! -f "$SPEC" ]; then
  echo "[$PROG] ✗ spec file not found: $SPEC" >&2
  echo "[$PROG]   author the spec (Step 1) before the grounding gate runs." >&2
  exit 2
fi

# ── Extract the Grounding Ledger section body ────────────────────────────────
# Same extraction pattern as the reuse-audit gate: from the first heading
# matching the section names to (but excluding) the next heading.
BODY=$(awk '
  BEGIN { insec = 0 }
  /^#{1,6}[[:space:]]/ {
    low = tolower($0)
    if (insec == 1) { insec = 0 }
    if (low ~ /grounding ledger/ || low ~ /existing-system grounding/) {
      insec = 1
      next
    }
    if (insec == 0) next
  }
  insec == 1 { print }
' "$SPEC")

if ! grep -qiE '^#{1,6}[[:space:]].*(grounding ledger|existing-system grounding)' "$SPEC"; then
  echo "[$PROG] ✗ spec has no 'Existing-System Grounding Ledger' section: $SPEC" >&2
  echo "[$PROG]   add the mandatory section (see 01-specification.md / shared/grounding.md)." >&2
  exit 1
fi

BODY_STRIPPED=$(printf '%s' "$BODY" | tr -d '[:space:]')
if [ -z "$BODY_STRIPPED" ]; then
  echo "[$PROG] ✗ Grounding Ledger section present but BLANK: $SPEC" >&2
  echo "[$PROG]   list CONFIRMED/ASSUMED claim rows + sources consulted, or state greenfield." >&2
  exit 1
fi

# ── --claims: programmatic ledger accessor (grounded-verdict via exit code) ──
# Reaches here only when the section is PRESENT and non-blank (absent/blank
# already exited 1 above — both map to "not grounded" per AC1). Emits one
# "<STATUS>\t<claim>" line per claim row to stdout, then exits 0 iff there is
# at least one claim row AND every claim row is CONFIRMED; exits 1 on any
# ASSUMED row or when the ledger has no claim rows at all.
if [ "$MODE" = "claims" ]; then
  # Reuse CLAIM_ROW_RE (defined below for --check) verbatim: a markdown TABLE
  # ROW whose last cell is the status token. Prose mentions do not count.
  CLAIMS_ROW_RE='^\|.*\|[[:space:]]*(CONFIRMED|ASSUMED)[[:space:]]*\|?[[:space:]]*$'
  CLAIM_LINES=$(printf '%s\n' "$BODY" | grep -E "$CLAIMS_ROW_RE" || true)
  if [ -z "$CLAIM_LINES" ]; then
    echo "[$PROG] ✗ --claims: Grounding Ledger has no CONFIRMED/ASSUMED claim rows: $SPEC" >&2
    exit 1
  fi
  # Emit "<STATUS>\t<claim>" per row. claim = first cell ($2 under -F'|', since
  # the leading pipe makes $1 empty); STATUS = the rightmost cell that is
  # EXACTLY CONFIRMED/ASSUMED (scan from the right so a trailing-pipe empty
  # field and a claim cell that merely contains the word both behave).
  printf '%s\n' "$CLAIM_LINES" | awk -F'|' '
    {
      claim = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", claim)
      status = ""
      for (i = NF; i >= 1; i--) {
        cell = $i
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
        if (cell == "CONFIRMED" || cell == "ASSUMED") { status = cell; break }
      }
      print status "\t" claim
    }
  '
  # Verdict: any ASSUMED row → not grounded → exit 1.
  ASSUMED_ROWS=$(printf '%s\n' "$CLAIM_LINES" | grep -cE '^\|.*\|[[:space:]]*ASSUMED[[:space:]]*\|?[[:space:]]*$' || true)
  if [ "${ASSUMED_ROWS:-0}" -gt 0 ]; then
    echo "[$PROG] --claims: $ASSUMED_ROWS ASSUMED row(s) — ledger NOT fully grounded (exit 1)" >&2
    exit 1
  fi
  echo "[$PROG] --claims: all claim rows CONFIRMED — ledger fully grounded (exit 0)" >&2
  exit 0
fi

# ── Greenfield short-circuit ─────────────────────────────────────────────────
# A repo with no enumerable docs may legitimately declare greenfield. When
# docs DO exist, a greenfield claim does not exempt coverage — the docs must
# still be listed (consulted or skipped-with-reason).
IS_GREENFIELD=0
# Anchored to the canonical phrase — a negation like "this is NOT a greenfield
# repo" must not waive the claim-row requirement (verify-workflow finding).
if printf '%s' "$BODY" | grep -qiE 'no existing documentation'; then
  IS_GREENFIELD=1
fi

# ── Coverage: every enumerated doc must appear in the section ────────────────
MISSING=""
if [ -n "$DOCS" ]; then
  while IFS= read -r doc; do
    [ -z "$doc" ] && continue
    # The spec under check is itself allowed to be absent from its own ledger.
    case "$SPEC" in *"$doc") continue ;; esac
    # Boundary-anchored match: a bare grep -qF would let a LONGER path cover a
    # shorter one (ledger says "docs/README.md", root README.md counts as
    # covered — verify-workflow finding). Require the char before the path to
    # NOT be a path character, and the char after to not extend the filename.
    doc_re=$(printf '%s' "$doc" | sed 's/[][\.^$*+?(){}|]/\\&/g')
    if ! printf '%s\n' "$BODY" | grep -qE "(^|[^A-Za-z0-9/._-])${doc_re}([^A-Za-z0-9_-]|\$)"; then
      MISSING="${MISSING}${doc}
"
    fi
  done <<EOF_DOCS
$DOCS
EOF_DOCS
fi

if [ -n "$MISSING" ]; then
  echo "[$PROG] ✗ Grounding Ledger does not cover these canonical docs (consult or add 'skipped: <reason>'):" >&2
  printf '%s' "$MISSING" | sed 's/^/[grounding]     - /' >&2
  exit 1
fi

# ── Claim rows OR greenfield statement ───────────────────────────────────────
# Row-anchored: only a markdown TABLE ROW whose last cell is the status token
# counts as a claim row. Guidance prose containing the words CONFIRMED/ASSUMED
# (e.g. the 01-specification.md template's own row-rules sentence, legitimately
# kept in a spec) must neither satisfy HAS_CLAIMS nor block --phase review
# (verify-workflow blocker finding).
CLAIM_ROW_RE='^\|.*\|[[:space:]]*(CONFIRMED|ASSUMED)[[:space:]]*\|?[[:space:]]*$'
HAS_CLAIMS=0
if printf '%s\n' "$BODY" | grep -qE "$CLAIM_ROW_RE"; then
  HAS_CLAIMS=1
fi

if [ "$HAS_CLAIMS" -eq 0 ] && [ "$IS_GREENFIELD" -eq 0 ]; then
  echo "[$PROG] ✗ Grounding Ledger has neither a CONFIRMED/ASSUMED claim row" >&2
  echo "[$PROG]   nor an explicit greenfield statement: $SPEC" >&2
  exit 1
fi

# ── Review phase: no ASSUMED rows may survive to Step 5 ──────────────────────
if [ "$PHASE" = "review" ]; then
  ASSUMED_COUNT=$(printf '%s\n' "$BODY" | grep -cE '^\|.*\|[[:space:]]*ASSUMED[[:space:]]*\|?[[:space:]]*$' || true)
  if [ "${ASSUMED_COUNT:-0}" -gt 0 ]; then
    echo "[$PROG] ✗ review phase: $ASSUMED_COUNT ASSUMED row(s) remain in the Grounding Ledger" >&2
    echo "[$PROG]   every assumption must be CONFIRMED against the repo (or refuted and" >&2
    echo "[$PROG]   the spec corrected + re-frozen) before Step 5 approves. See" >&2
    echo "[$PROG]   04-fix-first-review.md §5a-ter / shared/grounding.md." >&2
    exit 1
  fi
fi

if [ "$IS_GREENFIELD" -eq 1 ] && [ "$HAS_CLAIMS" -eq 0 ]; then
  echo "[$PROG] ✓ Grounding Ledger: explicit greenfield statement, coverage clean — gate passes ($PHASE)"
else
  echo "[$PROG] ✓ Grounding Ledger present, coverage clean — gate passes ($PHASE)"
fi
exit 0
