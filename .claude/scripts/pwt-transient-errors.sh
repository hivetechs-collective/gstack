#!/usr/bin/env bash
# Shared transient-connection-error pattern set. Single source of truth for
# plan-w-team-goal-evaluator.sh (API_HALT classification) and the supervisor
# protocol's API_HALT bounded-restart logic. Mirrors the centralization model of
# secret-scan.sh's PATTERNS catalog (one source, many callers).
# Spec: docs/specs/pwt-worker-recovery-and-workflow-guard.md (AC4).
#
# Usage (source, then call):
#   . "$(dirname "$0")/pwt-transient-errors.sh"
#   if pwt_is_transient_error "$LAST_TURN_TEXT"; then ...; fi
# or get the ERE alternation directly for grep -iE:
#   RE=$(pwt_transient_error_ere)
#
# bash 3.2 safe: plain indexed array + functions; NO associative arrays, NO mapfile.

# Each entry is a fixed substring OR ERE fragment, matched case-insensitively.
# The first four are the spec-named patterns; the last two are the same
# node/undici transient class (additive hardening).
PWT_TRANSIENT_ERROR_PATTERNS=(
  'API Error'
  'socket connection (was )?closed'
  'connection closed unexpectedly'
  'ECONNRESET'
  'ETIMEDOUT'
  'socket hang up'
)

# Emit a single ERE alternation of all patterns (for grep -iE).
pwt_transient_error_ere() {
  local out='' p
  for p in "${PWT_TRANSIENT_ERROR_PATTERNS[@]}"; do
    if [ -z "$out" ]; then out="$p"; else out="$out|$p"; fi
  done
  printf '%s' "$out"
}

# Return 0 if $1 matches any transient pattern (case-insensitive), else 1.
pwt_is_transient_error() {
  local text="$1" re
  re=$(pwt_transient_error_ere)
  printf '%s' "$text" | grep -iE "$re" >/dev/null 2>&1
}

# Mark as sourced (lets callers guard against double-sourcing if they wish).
PWT_TRANSIENT_ERRORS_SOURCED=1
