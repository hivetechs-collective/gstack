#!/usr/bin/env bash
# pwt-governor-lib.sh — Governor Contract phase 1: governed-mode detection (BRIEF §2).
#
# Sourced library (bash 3.2, jq only). The ONE switch every governed behaviour hangs on.
#
# CONTRACT (P0 — parity):
#   - OFF BY DEFAULT. With neither PWT_GOVERNOR set nor a valid pwt-governor.json manifest,
#     NOTHING new happens: no file is created, no stderr line is emitted, callers behave
#     byte-for-byte as before. This is asserted by tests/skill/cases/governor-parity.bats.
#   - A manifest that EXISTS but does not parse / has the wrong schema is treated as ABSENT
#     (fail-open on absence) PLUS exactly ONE stderr warning per process. A broken manifest
#     must never silently enable governed paths, and never wedge a run.
#   - Every manifest key is optional; a missing key means "as today".
#
# Detection:
#   governed  ⇔  env PWT_GOVERNOR is non-empty (except 0/false/no)   [env may be a name or a path]
#          OR  a manifest .claude/state/pwt-governor.json that parses and carries
#              "schema":"pwt-governor/1". The MAIN checkout's .claude/state/ (resolved by the
#              git-common-dir idiom, same as plan-w-team-lane-guard.sh) WINS over the worktree's.
#
# Public API (sourced):
#   pwt_governed                 → exit 0 governed / 1 ungoverned  (fail-open to ungoverned)
#   pwt_governor_name            → echoes the governor name (env value if a bare name, else .name)
#   pwt_governor_get <jq-path>   → echoes a manifest field (empty when ungoverned or key absent)
#   pwt_governor_manifest_path   → echoes the resolved manifest path, or empty
#
# CLI (executed, not sourced): `pwt-governor-lib.sh --json` for tests.
#
# See docs/operations/governor-contract.md and shared/state-artifacts.md (pwt-governor.json is
# an EXTERNAL-INPUT artifact with no pipeline writer — like plan-w-team-lane-release-<slug>.json).

# ── state-dir resolution: MAIN checkout first (wins), then the worktree ──────────
__pwt_gov_state_dirs() {   # echoes one dir per line; MAIN first
  local cdir main wt
  if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then
    echo "${PWT_PROJECT_ROOT_OVERRIDE%/}/.claude/state"
    return 0
  fi
  cdir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  case "$cdir" in
    "") main="" ;;
    /*) main=$(dirname "$cdir") ;;
    *)  main=$(cd "$(dirname "$cdir")" 2>/dev/null && pwd || echo "") ;;
  esac
  [ -n "$main" ] && echo "${main%/}/.claude/state"
  wt=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$wt" ] && [ "${wt%/}/.claude/state" != "${main:+${main%/}/.claude/state}" ]; then
    echo "${wt%/}/.claude/state"
  fi
}

pwt_governor_manifest_path() {   # first existing manifest (MAIN wins), or empty
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ -f "$d/pwt-governor.json" ]; then echo "$d/pwt-governor.json"; return 0; fi
  done < <(__pwt_gov_state_dirs)
  return 0
}

__pwt_gov_warn_once() {   # exactly ONE stderr warning per process (env marker, NOT a file — parity)
  [ -n "${__PWT_GOVERNOR_WARNED:-}" ] && return 0
  export __PWT_GOVERNOR_WARNED=1
  printf '⚠ pwt-governor: %s\n' "$1" >&2
}

pwt_governed() {   # exit 0 governed / 1 ungoverned; fail-open to ungoverned
  case "${PWT_GOVERNOR:-}" in
    ""|0|false|FALSE|no|NO|off|OFF) : ;;   # not governed by env
    *) return 0 ;;                          # governed by env (name or path)
  esac
  local mp schema
  mp=$(pwt_governor_manifest_path)
  [ -n "$mp" ] || return 1                  # no env, no manifest → ungoverned, silent
  schema=$(jq -r '.schema // "__missing__"' "$mp" 2>/dev/null || echo "__parsefail__")
  case "$schema" in
    "__parsefail__")
      __pwt_gov_warn_once "manifest $mp does not parse — treating as absent (ungoverned)"
      return 1 ;;
    "pwt-governor/1") return 0 ;;
    *)
      __pwt_gov_warn_once "manifest $mp has schema '$schema' (want pwt-governor/1) — treating as absent (ungoverned)"
      return 1 ;;
  esac
}

# Which manifest supplies KEYS. A PWT_GOVERNOR that is an absolute path to a readable manifest
# takes precedence (operator-supplied, typically OUT of the repo — the sanctioned way to arm
# liveness_cmd, since an in-tree manifest is branch-author-writable; see governor-contract.md).
__pwt_gov_keys_manifest() {
  case "${PWT_GOVERNOR:-}" in
    /*) [ -f "$PWT_GOVERNOR" ] && { echo "$PWT_GOVERNOR"; return 0; } ;;
  esac
  pwt_governor_manifest_path
}

pwt_governor_name() {
  case "${PWT_GOVERNOR:-}" in
    ""|0|false|FALSE|no|NO|off|OFF) : ;;
    /*) : ;;                                # a path, not a name
    *) echo "$PWT_GOVERNOR"; return 0 ;;
  esac
  local mp; mp=$(__pwt_gov_keys_manifest)
  [ -n "$mp" ] || { echo ""; return 0; }
  jq -r '.name // ""' "$mp" 2>/dev/null || echo ""
}

pwt_governor_get() {   # $1 = jq path (e.g. .liveness_cmd); empty when ungoverned or absent
  pwt_governed || { echo ""; return 0; }
  local mp; mp=$(__pwt_gov_keys_manifest)
  [ -n "$mp" ] || { echo ""; return 0; }
  jq -r "(${1}) // \"\"" "$mp" 2>/dev/null || echo ""
}

# ── CLI (executed, not sourced) ─────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  case "${1:-}" in
    --json)
      if pwt_governed; then __g=true; else __g=false; fi
      jq -n \
        --argjson governed "$__g" \
        --arg name "$(pwt_governor_name)" \
        --arg manifest "$(pwt_governor_manifest_path)" \
        '{governed:$governed, name:$name, manifest_path:$manifest}'
      ;;
    --governed) pwt_governed; exit $? ;;
    *) echo "usage: pwt-governor-lib.sh --json|--governed" >&2; exit 2 ;;
  esac
fi
