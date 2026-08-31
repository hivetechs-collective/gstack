#!/usr/bin/env bash
# lib.sh — shared bash helpers for /plan-w-team multi-account management.
#
# The P0 zero-overhead gate lives here: pwt_acct_is_dormant decides the
# dormant/single-account majority in PURE BASH (+ jq, a hard repo dep) so the
# common case NEVER spawns a Python subprocess. Only a genuinely multi-account
# machine (>=2 active accounts AND multi_account_enabled) falls through to the
# Python selector/lane_cred path.
#
# bash 3.2 compatible (mac-mini portability): no `declare -A`, no `${x^^}`.
# SECURITY: no function here ever reads or echoes a token value — jq reads only
# the enabled flag and the active-account COUNT, never a token.

# Canonical registry path. Honors $XDG_CONFIG_HOME; ~/.config fallback.
pwt_acct_registry_path() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/claude-pwt/accounts.json"
}

# Sibling usage cache path.
pwt_acct_cache_path() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/claude-pwt/usage-cache.json"
}

# The python3 to dispatch with; empty output if none on PATH.
pwt_acct_python() {
  command -v python3 2>/dev/null || true
}

# Refuse-on-loose-perms check. Returns non-zero (NOT ok) if $1 is group- or
# world-accessible; returns 0 (ok) for a 0600-tight file, a missing file
# (nothing to protect), or when perms can't be read (caller decides).
# Portable across macOS (stat -f) and Linux (stat -c).
pwt_acct_perms_ok() {
  local f="$1" mode
  [ -n "$f" ] || return 0
  [ -e "$f" ] || return 0
  mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null)" || return 0
  [ -n "$mode" ] || return 0
  # Any group/world bit set (octal 077) => too loose.
  if (( 8#${mode} & 8#77 )); then
    return 1
  fi
  return 0
}

# THE dormancy short-circuit (P0). Returns 0 (dormant — do nothing new) unless
# the registry is present, readable, multi_account_enabled == true, AND has >= 2
# active accounts, in which case it returns 1 (NOT dormant → activate the
# multi-account path). Fail-safe to dormant (today's behavior) on ANY doubt:
# missing/empty registry, missing jq, or an unreadable/malformed file.
pwt_acct_is_dormant() {
  local reg jq_bin enabled active
  reg="$(pwt_acct_registry_path)"

  # Absent or empty => dormant (return 0). This is the hot path for ~all repos.
  [ -s "$reg" ] || return 0

  # jq is a hard repo dependency; if it is somehow missing, fail safe to dormant
  # rather than spawning python just to decide dormancy.
  jq_bin="$(command -v jq 2>/dev/null)" || return 0
  [ -n "$jq_bin" ] || return 0

  enabled="$("$jq_bin" -r '.multi_account_enabled // false' "$reg" 2>/dev/null)" || return 0
  [ "$enabled" = "true" ] || return 0

  active="$("$jq_bin" -r '[.accounts[]? | select(.active == true)] | length' "$reg" 2>/dev/null)" || return 0
  case "$active" in
    ''|*[!0-9]*) return 0 ;;  # unparseable => dormant
  esac
  if [ "$active" -ge 2 ]; then
    return 1   # NOT dormant: multi-account path activates
  fi
  return 0     # 0 or 1 active accounts => dormant
}
