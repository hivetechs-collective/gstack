#!/usr/bin/env bash
# access-control-content-scan.sh
#
# Deterministic content-signal detection FLOOR for OWASP #1 (Broken Access
# Control). Greps the ADDED hunks of a diff for the CS-1..CS-4 token shapes
# defined in shared/owasp-top10-mapping.md and emits suspects to a state file.
#
# WHY THIS EXISTS (audit P9c, docs/operations/pwt-principles-enforcement-audit-2026-06-02.md):
# The §6c-ter ship gate (05-ship.md) is deterministic — it exit-1s when
# `access_control_high_unresolved > 0`. But that count is authored by an LLM in
# Step 5 §5b; if the model fails to notice an access-control signal in the diff,
# it writes 0 and the gate passes a live account-takeover / cross-tenant IDOR
# through (exactly the 2026-06-01 seed-platform-admin + jobs.ts escapes). A
# deterministic gate is only as trustworthy as the detection feeding it. This
# script is the independent detection backstop so detection is not solely LLM
# judgment.
#
# These patterns are a FLOOR, not a precise classifier: they fail toward MORE
# scrutiny (deny-by-default). A flagged line is a suspect for a human/reviewer to
# adjudicate, not a proven vuln. Missing a real signal is the costly error;
# over-flagging is cheap.
#
# Usage:
#   access-control-content-scan.sh [--slug <slug>] [--base <ref>] \
#       [--diff-file <path>] [--state-dir <dir>] [--quiet]
#
# Exit codes:
#   0  scanned cleanly — no suspects in the added hunks
#   3  suspect(s) found — review required (deny-by-default); written to the
#      suspects file and echoed (unless --quiet)
#   2  could not produce a diff (e.g. unreadable --diff-file) — FAIL TOWARD
#      review-required; the caller must treat this as "cannot prove clean"
set -uo pipefail

SLUG=""
BASE=""
DIFF_FILE=""
STATE_DIR_OVERRIDE=""
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --base) BASE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --diff-file) DIFF_FILE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --state-dir) STATE_DIR_OVERRIDE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --quiet) QUIET=1; shift ;;
    *) shift ;;
  esac
done

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATE_DIR="${STATE_DIR_OVERRIDE:-$PROJECT_ROOT/.claude/state}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
SUSPECTS_FILE="$STATE_DIR/plan-w-team-content-signal-suspects-${SLUG:-unscoped}.txt"
: > "$SUSPECTS_FILE"

# ── Obtain the unified diff (zero context so only changed lines are scanned) ──
get_diff() {
  if [ -n "$DIFF_FILE" ]; then
    [ -r "$DIFF_FILE" ] || return 2
    cat "$DIFF_FILE"
    return 0
  fi
  local base="$BASE"
  if [ -z "$base" ]; then
    base="$(git merge-base origin/HEAD HEAD 2>/dev/null \
         || git merge-base origin/main HEAD 2>/dev/null || echo "")"
  fi
  if [ -n "$base" ]; then
    git diff --unified=0 "$base"...HEAD 2>/dev/null && return 0
  fi
  # Last resort: working tree vs HEAD (covers an un-committed in-progress diff).
  git diff --unified=0 HEAD 2>/dev/null
}

DIFF="$(get_diff)" || {
  [ "$QUIET" = "1" ] || echo "ADVISORY: access-control-content-scan could not produce a diff — treating as REVIEW-REQUIRED (cannot prove clean)." >&2
  printf '# scan-error: could not produce a diff for slug=%s — review required\n' "${SLUG:-unscoped}" >> "$SUSPECTS_FILE"
  exit 2
}

# ── CS-1..CS-4 token shapes (from shared/owasp-top10-mapping.md) ──────────────
# CS-1 privilege-bearing field WRITE. `role` is intentionally omitted (too noisy
# vs ARIA/type usage); the high-signal sensitive fields are kept.
CS1='(platformRole|tenantId|orgId|isQaUser|ownerId|isAdmin|permissions|passwordHash|balance|[A-Za-z_]+Cents)[[:space:]]*[:=]'
# CS-2 request-body spread into an ORM update/insert.
CS2='\.\.\.[[:space:]]*(req\.body|body|input|payload)|Object\.assign\(|\.set\(\{[[:space:]]*\.\.\.|\.values\(\{[[:space:]]*\.\.\.'
# CS-3 service / bypass / QA / admin-token-gated handler.
CS3='QA_SIM_TOKEN|_BYPASS_|[xX]-[A-Za-z-]*bypass|service[_-]?token'
# CS-4 where/query-by-id (BOLA) — flagged only when the SAME line lacks a
# tenant/owner predicate (the missing-predicate is the actual signal).
# `where[(:]` covers both the call form `where(eq(t.id` AND Drizzle's relational
# object-property form `where: eq(t.id` / `where: (eq(t.id` (round-2 audit §3.5
# soft edge — the regex previously missed the `where:` form).
CS4='where[(:][[:space:]]*[(]?eq\([A-Za-z0-9_]+\.id|findById|WHERE[[:space:]]+[A-Za-z0-9_.]*id[[:space:]]*='
TENANT='tenant|org|owner|userId|user_id|accountId|account_id'

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SUSPECTS_FILE"; }

cur_file=""
while IFS= read -r line; do
  case "$line" in
    '+++ '*)
      cur_file="${line#+++ }"
      cur_file="${cur_file#b/}"
      ;;
    '+'*)
      # Skip the file-header '+++' (already handled) and empty additions.
      content="${line#+}"
      [ -z "$content" ] && continue
      if printf '%s' "$content" | grep -qE "$CS1"; then record "CS-1" "$cur_file" "$(printf '%s' "$content" | sed 's/^[[:space:]]*//' | cut -c1-160)"; fi
      if printf '%s' "$content" | grep -qE "$CS2"; then record "CS-2" "$cur_file" "$(printf '%s' "$content" | sed 's/^[[:space:]]*//' | cut -c1-160)"; fi
      if printf '%s' "$content" | grep -qE "$CS3"; then record "CS-3" "$cur_file" "$(printf '%s' "$content" | sed 's/^[[:space:]]*//' | cut -c1-160)"; fi
      if printf '%s' "$content" | grep -qE "$CS4" && ! printf '%s' "$content" | grep -qiE "$TENANT"; then record "CS-4" "$cur_file" "$(printf '%s' "$content" | sed 's/^[[:space:]]*//' | cut -c1-160)"; fi
      ;;
  esac
done <<EOF
$DIFF
EOF

if [ -s "$SUSPECTS_FILE" ]; then
  if [ "$QUIET" != "1" ]; then
    echo "⚠ access-control content signals detected ($(wc -l < "$SUSPECTS_FILE" | tr -d ' ') suspect line(s)) — REVIEW REQUIRED (deny-by-default):" >&2
    sed 's/^/    /' "$SUSPECTS_FILE" >&2
    echo "  suspects file: $SUSPECTS_FILE" >&2
  fi
  exit 3
fi

[ "$QUIET" = "1" ] || echo "access-control-content-scan: clean (no CS-1..CS-4 signals in added hunks)" >&2
exit 0
