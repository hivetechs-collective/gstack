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
# Model resolution (Model Tiering v9; pure, echo only, identical governed and ungoverned):
#   pwt_primary_model <id> [<if-unset>] → the lane primary: a Fable / claude-opus-5 / bare-opus id
#                                  is refused (one stderr warning) and echoes <if-unset> when given,
#                                  else claude-opus-5-5; any other id echoes trimmed, case kept
#   pwt_fallback_model <primary> [<explicit>] → the --fallback-model list for that primary
#                                  (Opus 5.5 → claude-opus-4-8,claude-sonnet-5; any other → itself);
#                                  never a refused id
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

# ── C2 budget + model accessors (phase 3) ────────────────────────────────────────
# All GOVERNED-ONLY + FAIL-OPEN, mirroring pwt_governor_get. bash 3.2 (case-based, no
# declare -A). Every one is inert ungoverned: pwt_governor_get returns empty with no
# manifest, so a caller reading these on an ungoverned host sees the pre-contract value.

# Echo a validated NON-NEGATIVE INTEGER from .budget.<subkey>, else empty. A key that is
# PRESENT but non-integer/negative (e.g. "8.5", "8GB") is treated as ABSENT and warns ONCE
# — a governor whose cap silently did not take is the 2026-08-19 host-starvation class, so
# it must be diagnosable rather than fail toward NO protection.
pwt_governor_budget_int() {   # $1 = subkey (max_builders|ram_floor_gb|disk_min_gb|nice)
  local raw; raw=$(pwt_governor_get ".budget.${1}")   # empty ungoverned OR key absent
  [ -n "$raw" ] || { echo ""; return 0; }
  case "$raw" in
    *[!0-9]*) __pwt_gov_warn_once "budget.${1}='${raw}' is not a non-negative integer — ignoring (cap did not take)"; echo ""; return 0 ;;
  esac
  echo "$raw"
}

# Clamp a requested builder count to budget.max_builders. Echoes min(requested, cap).
# When requested>cap it ALSO emits a NAMED refusal to stderr — the mechanical manifest
# refusal of the excess. Ungoverned / absent cap / invalid / non-numeric requested ⇒
# echoes requested UNCHANGED (parity).
pwt_governor_clamp_builders() {   # $1 = requested
  local req="${1:-}"
  case "$req" in ""|*[!0-9]*) echo "$req"; return 0 ;; esac
  local cap; cap=$(pwt_governor_budget_int max_builders)
  [ -n "$cap" ] && [ "$cap" -gt 0 ] || { echo "$req"; return 0; }
  if [ "$req" -gt "$cap" ]; then
    printf '⚠ pwt-governor: builder count clamped %s→%s by budget.max_builders\n' "$req" "$cap" >&2
    echo "$cap"
  else
    echo "$req"
  fi
}

# Downward-only model guard. Per-tier EXACT-STRING ALLOW-LIST membership — NOT rank≤ceiling.
# A capability-rank gate is blind to the reliability ban that keeps Fable out of the lead /
# fan-out tiers: claude-fable-5-1 is a *downgrade* by capability yet models.intelligent:
# claude-fable-5-1 is exactly the 2026-07 lockout. So the accessor emits ONLY a member of the
# tier's allow-list or the tier's HARDCODED DEFAULT LITERAL — never claude-opus-5 (forbidden, v5),
# the bare `opus`/`opus-*` alias (CLI-resolved, so it drifts by CLI version: claude-opus-5 on
# 2.1.25x, claude-opus-5-5 on 2.1.280), `inherit`, an unknown, or a tier-raise.
# Ungoverned ⇒ empty (the caller keeps its own default).
#
# ⚠ THE ALLOW-LIST IS BOUND TO tests/skill/cases/model-tiering-v5.bats (the FUNCTIONAL sweep,
#   v5-8). A model GENERATION rollover MUST update BOTH — the sweep fails loudly if this table
#   and the doctrine drift apart (Model Tiering v5, skill 2.14.3: Opus 5 FORBIDDEN). Model
#   Tiering v6 (2.20.0) was NOT such a rollover: it moved subagent tiers to follow-the-lane at
#   agent frontmatter + spawn sites and left this governor policy table byte-for-byte unchanged.
#   Model Tiering v8 (2.50.0, operator order 2026-09-22) IS one: intelligent claude-opus-4-8 →
#   claude-opus-5-5. claude-opus-4-8 is deliberately NOT kept for backward compat — a governed
#   config still naming it is refused (loud warning) and lands on the 5.5 default, which IS the
#   rollover. Only the exact id claude-opus-5 is banned; never widen that to a claude-opus-5* glob.
pwt_governor_model() {   # $1 = tier (design|intelligent|mechanical)
  local tier="${1:-}" default=""
  case "$tier" in
    design)      default="claude-opus-5-5" ;;   # Model Tiering v9 (2.50.0): design = Opus 5.5
    intelligent) default="claude-opus-5-5" ;;
    mechanical)  default="claude-sonnet-5" ;;
    *) echo ""; return 0 ;;
  esac
  pwt_governed || { echo ""; return 0; }
  local ov; ov=$(pwt_governor_get ".models.${tier}")
  ov=$(printf '%s' "$ov" | tr -d '[:space:]')   # trim before the exact-string match
  [ -n "$ov" ] || { echo "$default"; return 0; }
  local ok=0
  case "$tier" in
    # Model Tiering v9 (2.50.0, operator ruling 2026-09-22): Fable 5.1 is retired — no
    # Fable anywhere. A governed config still naming a Fable id (claude-fable-5-1, or the
    # bare claude-fable-5 accepted since 2.36.0) is now REFUSED and lands on the
    # claude-opus-5-5 design default with one warning, the way v8 treated claude-opus-4-8.
    design)      case "$ov" in claude-opus-5-5|claude-sonnet-5|claude-haiku-4-5) ok=1 ;; esac ;;
    intelligent) case "$ov" in claude-opus-5-5|claude-sonnet-5|claude-haiku-4-5) ok=1 ;; esac ;;
    mechanical)  case "$ov" in claude-sonnet-5|claude-haiku-4-5) ok=1 ;; esac ;;
  esac
  if [ "$ok" = "1" ]; then
    echo "$ov"
  else
    printf '⚠ pwt-governor: models.%s=%s refused (forbidden/tier-raise/unknown) — using %s\n' "$tier" "$ov" "$default" >&2
    echo "$default"
  fi
}

# Model Tiering v9 hardening (cleanscale review 2.50.0-1): ONE refusal set for every model id a
# lane is launched on — the primary AND each --fallback-model rung. The refusal is matched on a
# NORMALIZED form (whitespace and non-ASCII bytes stripped, lower-cased), because the CLI does
# the same before it resolves a name. Verified in the CLI 2.1.281 binary: the --fallback-model
# list is split on ',' and each entry JS-trim()med (which also strips U+FEFF/U+00A0) with empty
# entries dropped, and the model resolver trims and lower-cases a name before matching the
# aliases (fable, opus, sonnet, haiku, ...). So 'claude-opus-4-8, claude-fable-5-1', 'FABLE' or a
# BOM-prefixed id would otherwise slip past an exact-string match and still reach Fable.
# Refused:
#   - Fable in any form — claude-fable*, the bare alias fable, fable[...]   (retired, v9)
#   - EXACTLY claude-opus-5, and its context-suffixed claude-opus-5[...]     (forbidden, v5)
#   - the bare alias opus / opus[...] — it resolves by CLI version (claude-opus-5 before 2.1.280),
#     so a lane must name an explicit id
# Never widen the Opus 5 arm into a claude-opus-5* glob: claude-opus-5-5 is the Brain tier.
# The normalized form is for MATCHING only. An id that passes is emitted as the caller wrote it
# with only the surrounding whitespace trimmed (__pwt_model_trim): the CLI hands a non-alias id
# on in its original case, so a case-sensitive gateway/proxy model name must survive intact.
__pwt_model_norm() {   # $1 = model id → echoes it with whitespace + non-ASCII bytes removed, lower-cased
  printf '%s' "${1:-}" | LC_ALL=C tr -d '\200-\377[:space:]' | LC_ALL=C tr '[:upper:]' '[:lower:]'
}
__pwt_model_trim() {   # $1 = model id → echoes it with ONLY leading/trailing whitespace removed
  local v="${1:-}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s\n' "$v"
}
__pwt_model_refused() {   # $1 = NORMALIZED model id → exit 0 when Model Tiering v9 refuses it
  case "${1:-}" in
    claude-fable*|fable|fable\[*|claude-opus-5|claude-opus-5\[*|opus|opus\[*) return 0 ;;
  esac
  return 1
}

# Model Tiering v9 hardening (2.50.0-1): the lane PRIMARY gets the same refusal as a fallback
# rung. A requested primary (an env PWT_PRIMARY_MODEL, a consumer model table exporting it, or
# a lead's transcript model) naming Fable, claude-opus-5 or the bare opus alias is refused with
# ONE warning; anything else is echoed trimmed, in its original case. An empty or refused
# primary echoes $2 when a second argument is given, else claude-opus-5-5. The spawn/resume
# sites pass "" so a refused env pin counts as UNSET and their normal resolution runs (the
# governed intelligent tier when a governor manifest applies, else claude-opus-5-5); they call
# it BEFORE the governed override and pwt_fallback_model. Pure (echo only).
pwt_primary_model() {   # $1 = requested primary (may be empty); $2 = echo when empty/refused (optional)
  local d="claude-opus-5-5" p n
  [ $# -ge 2 ] && d="${2}"
  p=$(__pwt_model_trim "${1:-}"); n=$(__pwt_model_norm "$p")
  [ -n "$n" ] || { printf '%s\n' "$d"; return 0; }
  if __pwt_model_refused "$n"; then
    printf '⚠ pwt-governor: primary model %s refused (Fable is retired, claude-opus-5 is forbidden, bare opus is CLI-version-dependent — Model Tiering v9); %s\n' \
      "$p" "$([ -n "$d" ] && printf 'using %s' "$d" || printf 'treating it as unset')" >&2
    printf '%s\n' "$d"
    return 0
  fi
  printf '%s\n' "$p"
}

# Model Tiering v9 (2.50.0, operator ruling 2026-09-22): the bg --fallback-model for a lane.
# No Fable anywhere, fallbacks included. When Opus 5.5 is overloaded or unavailable the lane
# steps down the fleet chain Opus 4.8 → Sonnet 5 (cleanscale #6254); any other primary (a
# consumer's Sonnet/Haiku lane) falls back to itself. `--fallback-model` takes a
# comma-separated list (CLI 2.1.280) and outranks settings.json `fallbackModel`.
# An explicit fallback is checked entry by entry on the normalized form (see __pwt_model_norm):
# empty entries ('a,,b', a trailing comma), an entry naming the primary's own model, and
# duplicates are dropped; if ANY entry is refused (__pwt_model_refused) the whole explicit list
# is refused (one warning) and the default chain is used, as it is when nothing valid remains.
# Kept entries — and a non-Opus-5.5 primary falling back to itself — are emitted trimmed, in
# their original case. A refused or empty PRIMARY seeds the Opus 5.5 chain, so this never
# echoes — or warns "using" — a forbidden model. Pure (echo only); governed and ungoverned alike.
pwt_fallback_model() {   # $1 = resolved primary, $2 = explicit fallback (may be empty)
  local p pn f="${2:-}" base def m e rest out="" seen="," bad=""
  p=$(__pwt_model_trim "${1:-}"); pn=$(__pwt_model_norm "$p")
  if [ -z "$pn" ] || __pwt_model_refused "$pn"; then p="claude-opus-5-5"; pn="$p"; fi
  base="${pn%%\[*}"
  case "$base" in
    claude-opus-5-5) def="claude-opus-4-8,claude-sonnet-5" ;;
    *)               def="$p" ;;
  esac
  if [ -z "$f" ]; then echo "$def"; return 0; fi
  # Split on commas with parameter expansion, not an unquoted $f: word splitting would also
  # pathname-expand a bracketed id such as claude-opus-5-5[1m] against the cwd.
  rest="$f,"
  while [ -n "$rest" ]; do
    m="${rest%%,*}"; rest="${rest#*,}"
    e=$(__pwt_model_norm "$m")
    [ -n "$e" ] || continue
    if __pwt_model_refused "$e"; then bad=$(__pwt_model_trim "$m"); continue; fi
    [ "${e%%\[*}" = "$base" ] && continue
    case "$seen" in *",$e,"*) continue ;; esac
    seen="$seen$e,"
    out="${out:+$out,}$(__pwt_model_trim "$m")"
  done
  if [ -n "$bad" ]; then
    printf '⚠ pwt-governor: fallback %s refused (%s is retired, forbidden, or a CLI-version-dependent alias — Model Tiering v9); using %s\n' "$f" "$bad" "$def" >&2
    echo "$def"
    return 0
  fi
  [ -n "$out" ] || out="$def"
  echo "$out"
}

# ── repo root (main checkout), for approver-dir scoping ──────────────────────────
__pwt_gov_repo_root() {   # echoes the MAIN checkout root, or empty
  local sd; sd=$(__pwt_gov_state_dirs 2>/dev/null | head -n1)
  [ -n "$sd" ] || { echo ""; return 1; }
  echo "${sd%/.claude/state}"
}

# ── governed-command execution primitive (phase 2, C1) ───────────────────────────
# Runs a governor-supplied command string under the SAME execution contract phase 1
# uses for liveness_cmd (pwt-lane-alive.sh §4.5), factored so the C1 event sink shares it:
#   - argv exec, NEVER sourced (env -i scrubs the environment; only PATH is preserved)
#   - a timeout is REQUIRED (gtimeout/timeout); no timeout binary ⇒ refuse, never run unbounded
#   - the git-TRACKED-manifest refusal (a committed manifest must never arm command execution)
#   - stdin is passed THROUGH to the command (a caller tees a JSON line); the command's
#     stdout/stderr are discarded — only its exit code is observed
# Exit: the command's exit code (0..) when it ran; 3 no-timeout-binary; 4 tracked-manifest
#       refusal; 5 empty command. FAIL-OPEN is the CALLER's responsibility (never blocks).
# $1 = command string (word-split like liveness_cmd); $2.. = extra argv appended.
pwt_governor_run_cmd() {
  local cmd="$1"; shift || true
  # Belt-and-suspenders: this primitive executes a governor-supplied command, so it must
  # never run outside governed mode. The only caller (pwt_governor_emit_event) already
  # gates on pwt_governed; this guard protects any future caller. Exit 6 = not governed.
  pwt_governed || return 6
  [ -n "$cmd" ] || return 5
  local mpath; mpath=$(pwt_governor_manifest_path)
  if [ -n "$mpath" ] && command -v git >/dev/null 2>&1 \
       && git -C "$(dirname "$mpath")" ls-files --error-unmatch "$mpath" >/dev/null 2>&1; then
    return 4   # tracked-manifest refusal (shared with liveness_cmd's AC9 backstop)
  fi
  local tb=""
  if [ "${PWT_GOV_FORCE_NO_TIMEOUT:-0}" != "1" ]; then   # test seam: simulate a host with no timeout binary
    command -v gtimeout >/dev/null 2>&1 && tb=gtimeout
    [ -z "$tb" ] && command -v timeout >/dev/null 2>&1 && tb=timeout
  fi
  [ -n "$tb" ] || return 3   # no timeout binary → refuse (never run unbounded)
  env -i PATH="$PATH" "$tb" "${PWT_GOVERNOR_CMD_TIMEOUT_S:-10}" $cmd "$@" >/dev/null 2>&1
  return $?
}

# ── governed event sink (phase 2, C1) ────────────────────────────────────────────
# Tees ONE JSON line — {ts, slug, detail} — to the manifest's event_sink command via
# pwt_governor_run_cmd. GOVERNED-ONLY: a no-op (exit 0, no line, no file) when ungoverned,
# when .event_sink is empty, or when PWT_DISABLE_EVENT_SINK=1. FAIL-OPEN: any refusal / skip /
# non-zero sink NEVER blocks the pipeline — the emitter always returns 0.
# $1 = slug; $2 = compact detail JSON object (the caller composes it; must carry ".event").
pwt_governor_emit_event() {
  [ "${PWT_DISABLE_EVENT_SINK:-0}" = "1" ] && return 0
  local slug="${1:-}" detail="${2:-}"
  [ -n "$detail" ] || detail='{}'
  pwt_governed || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local sink; sink=$(pwt_governor_get '.event_sink')
  [ -n "$sink" ] || return 0
  # Never emit a malformed line: degrade an unparseable detail to {}.
  printf '%s' "$detail" | jq -e . >/dev/null 2>&1 || detail='{}'
  local ts line
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  line=$(jq -cn --arg ts "$ts" --arg slug "$slug" --argjson detail "$detail" \
      '{ts:$ts, slug:$slug, detail:$detail}' 2>/dev/null) || return 0
  printf '%s\n' "$line" | pwt_governor_run_cmd "$sink" >/dev/null 2>&1 || true
  return 0
}

# ── C4 approver dir resolution + validation (phase 2) ────────────────────────────
# Echoes the validated approver directory (absolute), or empty when NOT APPLICABLE
# (ungoverned / no file-mode approver) or REFUSED (git-tracked or escaping the repo).
# An empty result means the caller falls back to the human prompt — NEVER auto-approves.
# Exit: 0 = usable dir echoed; 1 = not applicable; 4 = refused (tracked or escaping).
pwt_governor_approver_dir() {
  pwt_governed || { echo ""; return 1; }
  local mode; mode=$(pwt_governor_get '.approver.mode')
  [ "$mode" = "file" ] || { echo ""; return 1; }
  local dir; dir=$(pwt_governor_get '.approver.dir')
  [ -n "$dir" ] || dir=".claude/state/pwt-pause"
  local root; root=$(__pwt_gov_repo_root)
  [ -n "$root" ] || { echo ""; return 4; }
  # Escaping refusal: any `..` component, or an absolute dir not under the repo root.
  case "/$dir/" in *"/../"*) echo ""; return 4 ;; esac
  local abs
  case "$dir" in
    /*) abs="$dir"; case "$abs/" in "$root/"*) : ;; *) echo ""; return 4 ;; esac ;;
    *)  abs="$root/$dir" ;;
  esac
  # Tracked refusal: a git-tracked approver dir is branch-author-controllable.
  if command -v git >/dev/null 2>&1 \
       && git -C "$root" ls-files --error-unmatch "$dir" >/dev/null 2>&1; then
    echo ""; return 4
  fi
  echo "$abs"; return 0
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
