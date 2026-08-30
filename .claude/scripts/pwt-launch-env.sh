#!/usr/bin/env bash
# pwt-launch-env.sh — the ONE shared launch-env builder (BRIEF §5, C5 reuse-first).
#
# Before this, pwt-goal.sh built its bg-spawn `LAUNCH_ENV` string inline (pwt-goal.sh:1899-1970),
# and pwt-steer.sh's resume passed only PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1 — so a RESUMED worker
# silently lost the stop-hook-cap raise, the workflow disable, the lean statusline, etc. This is
# the single definition all three spawn/resume paths share (pwt-goal.sh, pwt-steer.sh,
# pwt-resume.sh) so a resumed run regains the exact launch environment of a fresh one.
#
# Sourced (bash 3.2). TWO functions, deliberately split:
#   __pwt_scrub_leak_env   — unsets the two "deictic leak" vars (pwt-goal.sh:1908/1916). MUST be
#                            called DIRECTLY (never in a `$(…)` subshell) or the unset is lost.
#   __pwt_build_launch_env — PURE: echoes the LAUNCH_ENV string. Safe to capture via `$(…)`.
# Callers do:  __pwt_scrub_leak_env; LAUNCH_ENV=$(__pwt_build_launch_env "$AUTO_PUSH")
#
# PARITY (P0): the string __pwt_build_launch_env returns for a given (auto_push,
# PWT_STOP_HOOK_BLOCK_CAP, PLAN_W_TEAM_SPEC_FANOUT) is byte-identical to what pwt-goal.sh built
# inline before the extraction — asserted by tests/skill/cases/governor-parity.bats.
#
# NOT included (deliberately, matching pwt-goal.sh): the model pins PWT_PRIMARY_MODEL /
# PWT_FALLBACK_MODEL are passed as separate `--model`/`--fallback-model` FLAGS, never inside
# LAUNCH_ENV. Callers set/pass those themselves.

# Captured at SOURCE time so __pwt_nice_prefix can self-source the governor lib (same dir)
# when a caller has not already sourced it. A plain var assignment — never touches
# __pwt_build_launch_env, so the launch-env parity golden is unaffected.
__PWT_LAUNCH_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

__pwt_scrub_leak_env() {
  # PWT-CTX worker env hygiene (pwt-goal.sh:1901-1916): the deictic escape hatch + the Fable-consult
  # force are for THIS invocation only. `env $LAUNCH_ENV claude` inherits our environment, so an
  # operator who exported them would silently pass them to the worker and every nested pwt-goal —
  # the recorded PLAN_W_TEAM_DISABLE_*/FORCE_* leak class. Unset after the guards (earlier in the
  # caller) have consumed them. Call DIRECTLY so the unset lands in the caller's shell.
  unset PLAN_W_TEAM_ALLOW_CONTEXT_BLIND
  unset PLAN_W_TEAM_FORCE_FABLE_CONSULT
}

__pwt_build_launch_env() {   # $1 = AUTO_PUSH (0/1, default 0) → echoes LAUNCH_ENV (pure)
  local auto_push="${1:-0}"
  local env_str="PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1"

  [ "$auto_push" = "1" ] && env_str="$env_str PLAN_W_TEAM_AUTO_APPROVE_PUSH=1"

  # PWT-WF1 (pwt-goal.sh:1920-1929): bg sessions run headless where /workflows can auto-run;
  # disable it so an incidental "workflow" token can't spawn a nested fan-out past the RAM gate.
  env_str="$env_str CLAUDE_CODE_DISABLE_WORKFLOWS=1"

  # PWT-P3 no-caps guarantee (pwt-goal.sh:1931-1942): the goal-evaluator blocks the Stop hook far
  # more than the default cap of 8; raise it so a bg worker isn't force-stopped mid-pipeline.
  env_str="$env_str CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=${PWT_STOP_HOOK_BLOCK_CAP:-200}"

  # Spec-fanout override forwarding (pwt-goal.sh:1944-1951): forward ONLY when the operator set it,
  # so =0 (hard off) and =1 (force on) reach bg workers; unset → worker resolves AUTO from the stage.
  [ -n "${PLAN_W_TEAM_SPEC_FANOUT:-}" ] && env_str="$env_str PLAN_W_TEAM_SPEC_FANOUT=${PLAN_W_TEAM_SPEC_FANOUT}"

  # Context-cap forwarding (Model Tiering v6 item 2, 2026-08-30 burn audit): when the operator or
  # lane sets CLAUDE_CODE_AUTO_COMPACT_WINDOW (documented knob; plain token count), carry it so the
  # spawn, steer AND resume paths all compact at the SAME window. Without it, Opus 4.8 / Fable 5
  # lanes compacted only at the 1M limit (185–640K contexts, 0 compactions; 53% of spend was
  # cache-read of that history). Forward-only (like PLAN_W_TEAM_SPEC_FANOUT above): unset ⇒ the
  # launch-env string is byte-identical, so the parity golden holds.
  [ -n "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" ] && env_str="$env_str CLAUDE_CODE_AUTO_COMPACT_WINDOW=${CLAUDE_CODE_AUTO_COMPACT_WINDOW}"

  # PWT-SUP-YIELD (pwt-goal.sh:1953-1959): force SUPERVISOR_SESSION=0 so a worker can NEVER inherit
  # a supervisor marker (the evaluator lets a supervisor YIELD; a worker must block-to-terminal).
  env_str="$env_str PLAN_W_TEAM_SUPERVISOR_SESSION=0"

  # F1 lean statusline (pwt-goal.sh:1961-1970): every bg session is an unwatched per-turn statusline
  # render machine; lean mode removes the transcript-parsing spawn feedback loop.
  env_str="$env_str PWT_LEAN_STATUSLINE=1"

  printf '%s' "$env_str"
}

# __pwt_nice_prefix — the ONE definition of the C2 governed-nice command prefix (phase 3).
# Echoes `nice -n <N>` when GOVERNED and .budget.nice is an integer in 1..19, else NOTHING.
# PURE (echoes only) so callers can capture it via $(…) and prepend it before `claude`.
# GOVERNED-ONLY + FAIL-OPEN: ungoverned / no nice key / invalid / kill-switched ⇒ empty
# prefix ⇒ the spawn argv is byte-identical to pre-phase-3 (parity). It is DELIBERATELY
# NOT part of __pwt_build_launch_env: nice is a command prefix, not an env var, and folding
# it into the LAUNCH_ENV string would (a) perturb launch-env-autopush.golden and (b) miss the
# LAUNCH_ENV-less safety-net spawn branch entirely. Kill switch: PWT_DISABLE_GOVERNED_NICE=1.
#
# NOTE (Fable #2): a `--bg` launch may be serviced by the daemon's bg-spare pre-fork pool, so
# this prefix can end up nicing only the short-lived dispatch client. Callers therefore ALSO
# best-effort `renice <N> -p <worker-pid>` after the spawn (see __pwt_governed_nice_value).
__pwt_nice_prefix() {
  local n; n=$(__pwt_governed_nice_value) || return 0
  [ -n "$n" ] || return 0
  printf 'nice -n %s' "$n"
}

# __pwt_governed_nice_value — echoes the validated governed nice value (1..19) or nothing.
# Shared by __pwt_nice_prefix (the spawn prefix) and the caller's post-spawn renice fallback.
__pwt_governed_nice_value() {
  [ "${PWT_DISABLE_GOVERNED_NICE:-0}" = "1" ] && return 0
  if ! command -v pwt_governor_budget_int >/dev/null 2>&1; then
    [ -n "${__PWT_LAUNCH_ENV_DIR:-}" ] && [ -r "${__PWT_LAUNCH_ENV_DIR}/pwt-governor-lib.sh" ] \
      && . "${__PWT_LAUNCH_ENV_DIR}/pwt-governor-lib.sh" 2>/dev/null
    command -v pwt_governor_budget_int >/dev/null 2>&1 || return 0
  fi
  local n; n=$(pwt_governor_budget_int nice)
  [ -n "$n" ] || return 0
  case "$n" in *[!0-9]*) return 0 ;; esac
  [ "$n" -ge 1 ] && [ "$n" -le 19 ] || return 0
  printf '%s' "$n"
}
