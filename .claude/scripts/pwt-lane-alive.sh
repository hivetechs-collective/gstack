#!/usr/bin/env bash
# pwt-lane-alive.sh — the ONE liveness truth (BRIEF §4). Consolidates the ~10 disagreeing
# liveness definitions (families A–D) into a single process-corroborated predicate.
#
#   pwt-lane-alive.sh <slug> [--json] [--worker-sid <uuid>] [--repo-root <dir>]
#   (sourced) pwt_lane_alive <slug> ...
#
# EXIT:  0 alive  ·  1 not-alive (confirmed dead)  ·  2 cannot-determine  ·  3 usage
#
# Each CONSUMER documents its fail-closed branch for exit 2 (BRIEF §4.2):
#   GC/sweep → KEEP the worktree · lane guard → KEEP binding · DS1 → REFUSE to spawn a
#   duplicate · await-terminal → keep waiting (never DIED on uncertainty) · pwt-status → unknown.
#
# ALIVE ⇔ positive PROCESS evidence, corroborated (BRIEF §4.2): a pid (from the worker sid's
# registry row and/or the workflow-lock pid) that `kill -0` finds alive AND one corroboration
# (the sid's transcript held open by that pid via `lsof`, or transcript freshness, or a
# pty/claim-socket child). THE REGISTRY ALONE NEVER SUFFICES. Registry-absent but process
# present ⇒ alive. An empty/unqueryable registry is "no registry evidence", never "dead".
#
# NOT-ALIVE (exit 1, release-authorizing — AC8) requires the CONJUNCTION of negative evidence:
# the recorded pid is ESRCH (truly gone, not EPERM-alive-unownable) AND `pgrep -f <uuid>` finds
# no process. A live worker whose recorded pid is stale returns 2 (HOLD), never 1. A SECOND
# exit-1 path (SPAWN-LIVE2, 2.32.0) covers a DEAD RUN behind a still-`blocked` process: the
# worker transcript's tail shows the CLI's unrecoverable-goal-clear AND the transcript is frozen
# (see __pla_abandoned). It only UPGRADES 0/2 → 1, never masks a live/progressing worker.
#
# bg-spare ownership (BRIEF §4.3, the O2 correction): do NOT exclude a `bg-spare`-argv process by
# argv — a claimed spare keeps that argv and can BE the live lead. Count it only when it owns a
# claim socket / pty-host child / live children; an unclaimed spare and the `claude daemon` never.
#
# blocked reconciliation (BRIEF §4.2): this predicate answers PROCESS liveness only. A `blocked`
# worker waiting at its Stop hook is a live process. Whether the RUN still progresses is the
# consumers' exclusion semantics (await-terminal / evaluator) — not this predicate's concern.
#
# Governed extension (BRIEF §4.5): when governed and manifest `liveness_cmd` is set, consult it
# (argv `<cmd> <slug>`, never sourced) and record BOTH answers to a governed-only file
# `.claude/state/plan-w-team-liveness-<slug>.jsonl`; on disagreement PREFER process evidence.
# Ungoverned: that file is NEVER created (parity).
#
# TEST SEAMS (house *_STUB_* pattern): PWT_LANE_ALIVE_STUB_AGENTS (registry JSON file),
# PWT_LANE_ALIVE_STUB_PROC (TSV: pid<TAB>state<TAB>corroborated<TAB>class), PWT_LANE_ALIVE_STUB_PGREP
# (TSV: uuid<TAB>count). class ∈ {lead, spare-owned, spare-unclaimed, daemon}. state ∈ {alive,eperm,dead}.

set -u

__pla_self_dir() { cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd; }

# ── frozen-abandonment detector (SPAWN-LIVE2, 2.32.0) ───────────────────────────
# A run the CLI abandoned at spawn (spurious "Not logged in" → /goal self-clears "after an
# unrecoverable error") leaves a LIVE `blocked` process — so process evidence reads ALIVE and
# the lane wedges. This detector recognises the DEAD RUN behind the live process: the CLI's
# unrecoverable-clear system message in the transcript tail AND a FROZEN transcript. The freeze
# gate is the false-positive guard — a healthy worker writes constantly, and the clear message
# is TERMINAL (the CLI stops after emitting it), so "clear-in-tail + long silence" is a dead run
# and NEVER a live, progressing one. Seam: PWT_SPAWN_PROBE_PROJECTS_DIR (shared with pwt-goal.sh).
__pla_ts_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
__pla_worker_transcript() {   # $1=wsid(8) $2=worktree(reserved) → newest transcript naming wsid, or ""
  local sid="$1" base="${PWT_SPAWN_PROBE_PROJECTS_DIR:-$HOME/.claude/projects}"
  [ -n "$sid" ] && [ -d "$base" ] || { echo ""; return 0; }
  ls -t "$base"/*/"$sid"*.jsonl 2>/dev/null | head -1
}
__pla_abandoned() {   # $1=transcript → 0 if abandoned (unrecoverable-clear in tail) AND frozen
  local tr="$1" freeze="${PWT_LANE_ALIVE_ABANDON_FREEZE_S:-120}" now mt age
  [ -n "$tr" ] && [ -f "$tr" ] || return 1
  tail -n 6 "$tr" 2>/dev/null | grep -q 'Goal cleared after an unrecoverable error' || return 1
  now=$(date +%s 2>/dev/null || echo 0); mt=$(__pla_ts_mtime "$tr")
  age=$((now - mt))
  [ "$age" -ge "$freeze" ] 2>/dev/null
}

# ── state-dir resolution (git-common-dir; MAIN wins) ────────────────────────────
__pla_main_root() {
  if [ -n "${PWT_PROJECT_ROOT_OVERRIDE:-}" ]; then echo "${PWT_PROJECT_ROOT_OVERRIDE%/}"; return 0; fi
  local cdir; cdir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  case "$cdir" in
    "") git rev-parse --show-toplevel 2>/dev/null || echo "" ;;
    /*) dirname "$cdir" ;;
    *)  ( cd "$(dirname "$cdir")" 2>/dev/null && pwd ) || echo "" ;;
  esac
}

__pla_goal_file() {   # $1=slug → path to goal-state (worktree then MAIN), or empty
  local slug="$1" root wt
  wt=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  [ -n "$wt" ] && [ -f "$wt/.claude/state/plan-w-team-goal-${slug}.json" ] && { echo "$wt/.claude/state/plan-w-team-goal-${slug}.json"; return 0; }
  root=$(__pla_main_root)
  [ -n "$root" ] && [ -f "$root/.claude/state/plan-w-team-goal-${slug}.json" ] && { echo "$root/.claude/state/plan-w-team-goal-${slug}.json"; return 0; }
  echo ""
}

# ── registry read (stub or claude-agents-extended.sh, the retry wrapper) ────────
__pla_agents_json() {
  if [ -n "${PWT_LANE_ALIVE_STUB_AGENTS:-}" ]; then
    local sout=""
    [ -r "$PWT_LANE_ALIVE_STUB_AGENTS" ] && sout=$(cat "$PWT_LANE_ALIVE_STUB_AGENTS" 2>/dev/null)
    # An empty/invalid stub simulates an unqueryable registry (validate like the real path).
    if printf '%s' "$sout" | jq -e 'type=="array"' >/dev/null 2>&1; then printf '%s' "$sout"; else echo "__PLA_REGISTRY_FAIL__"; fi
    return 0
  fi
  local ext; ext="$(__pla_self_dir)/claude-agents-extended.sh"
  local out
  if [ -x "$ext" ]; then
    out=$(CLAUDE_AGENTS_RETRY="${CLAUDE_AGENTS_RETRY:-3}" "$ext" --json --bg-only 2>/dev/null)
  else
    out=$(claude agents --json 2>/dev/null)
  fi
  # Distinguish "queried, empty/invalid" from "valid array". An unqueryable registry is a sentinel.
  if printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1; then printf '%s' "$out"; else echo "__PLA_REGISTRY_FAIL__"; fi
}

# ── process-evidence layer (syscalls, or PWT_LANE_ALIVE_STUB_PROC) ──────────────
__pla_proc_field() {   # $1=pid $2=col(2=state,3=corroborated,4=class) → stub value or empty
  [ -n "${PWT_LANE_ALIVE_STUB_PROC:-}" ] || { echo ""; return 0; }
  awk -F'\t' -v p="$1" -v c="$2" '$1==p{print $c; exit}' "$PWT_LANE_ALIVE_STUB_PROC" 2>/dev/null
}

__pla_proc_state() {   # $1=pid → alive | eperm | dead  (ownership-aware)
  case "$1" in ''|*[!0-9]*) echo "dead"; return 0 ;; esac
  local s; s=$(__pla_proc_field "$1" 2)
  [ -n "$s" ] && { echo "$s"; return 0; }
  if kill -0 "$1" 2>/dev/null; then echo "alive"; return 0; fi
  if ps -p "$1" >/dev/null 2>&1; then echo "eperm"; return 0; fi   # exists but not ours → alive
  echo "dead"
}

__pla_corroborated() {   # $1=pid $2=uuid → 0 corroborated
  local c; c=$(__pla_proc_field "$1" 3)
  [ -n "$c" ] && { [ "$c" = "1" ] && return 0 || return 1; }
  # Real corroboration: the sid's transcript held open by this pid, OR a fresh transcript,
  # OR a pty/claim-socket child. lsof on the pid's open files naming the sid is the strongest.
  if command -v lsof >/dev/null 2>&1 && [ -n "$2" ]; then
    lsof -p "$1" 2>/dev/null | grep -q "$2" && return 0
  fi
  # Fallback corroboration: the process has live children (a lead drives subprocesses).
  pgrep -P "$1" >/dev/null 2>&1 && return 0
  return 1
}

__pla_class() {   # $1=pid $2=argv → lead | spare-owned | spare-unclaimed | daemon
  local cl; cl=$(__pla_proc_field "$1" 4)
  [ -n "$cl" ] && { echo "$cl"; return 0; }
  case "$2" in
    *"claude daemon"*|*"claude-daemon"*) echo "daemon"; return 0 ;;
  esac
  case "$2" in
    *bg-spare*|*"bg_spare"*)
      # claimed ⇔ owns a claim socket / pty-host child / live children (BRIEF §4.3)
      if pgrep -P "$1" >/dev/null 2>&1; then echo "spare-owned"; else echo "spare-unclaimed"; fi
      return 0 ;;
  esac
  echo "lead"
}

__pla_pgrep_uuid() {   # $1=uuid → count of live processes whose argv names the uuid, or "UNKNOWN"
  # Contract: a NUMERIC result is trustworthy negative/positive evidence; the literal
  # "UNKNOWN" means the probe could not run (pgrep absent or errored). Callers MUST treat
  # UNKNOWN as cannot-determine (verdict 2) and NEVER as "no process" — otherwise a host
  # without pgrep would silently flip cannot-determine → confirmed-dead (exit 1), the one
  # release-authorizing verdict (AC8 conjunction: exit 1 needs a pgrep that RAN and found
  # nothing, not a pgrep that never ran). Test seam: PWT_LANE_ALIVE_PGREP_UNAVAIL=1.
  if [ -n "${PWT_LANE_ALIVE_STUB_PGREP:-}" ]; then
    awk -F'\t' -v u="$1" '$1==u{print $2+0; f=1} END{if(!f)print 0}' "$PWT_LANE_ALIVE_STUB_PGREP" 2>/dev/null
    return 0
  fi
  if [ "${PWT_LANE_ALIVE_PGREP_UNAVAIL:-0}" = "1" ] || ! command -v pgrep >/dev/null 2>&1; then
    echo "UNKNOWN"; return 0
  fi
  local out rc
  out=$(pgrep -f "$1" 2>/dev/null); rc=$?
  # pgrep exit: 0 = one or more matches, 1 = no match, >=2 = error (bad option, internal).
  if [ "$rc" -ge 2 ] 2>/dev/null; then echo "UNKNOWN"; return 0; fi
  [ -z "$out" ] && { echo 0; return 0; }
  printf '%s\n' "$out" | wc -l | tr -d ' '
}

# A registry/candidate row is a LIVE LANE PROCESS when its class is countable AND its process
# is alive AND corroborated. (spare-unclaimed and daemon are never countable.)
__pla_row_live() {   # $1=pid $2=uuid $3=argv → 0 if a live lane process
  local cls st
  cls=$(__pla_class "$1" "$3")
  case "$cls" in daemon|spare-unclaimed) return 1 ;; esac
  st=$(__pla_proc_state "$1")
  case "$st" in dead) return 1 ;; esac          # dead → not a live lane process
  [ "$st" = "alive" ] || return 1                # only 'alive' is countable; eperm is not corroboration-checkable → not counted live
  __pla_corroborated "$1" "$2" || return 1
  return 0
}

# ── governed liveness_cmd consult (BRIEF §4.5) ──────────────────────────────────
__pla_governed_consult() {   # $1=slug $2=process_verdict(0/1/2) → echoes final verdict; records file
  local slug="$1" pv="$2"
  local lib; lib="$(__pla_self_dir)/pwt-governor-lib.sh"
  [ -r "$lib" ] || { echo "$pv"; return 0; }
  # shellcheck disable=SC1090
  . "$lib"
  pwt_governed || { echo "$pv"; return 0; }         # UNGOVERNED: never create the file (parity)
  local cmd; cmd=$(pwt_governor_get '.liveness_cmd')
  [ -n "$cmd" ] || { echo "$pv"; return 0; }

  local root; root=$(__pla_main_root); local sd="${root}/.claude/state"
  mkdir -p "$sd" 2>/dev/null
  local jf="$sd/plan-w-team-liveness-${slug}.jsonl"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # AC9 — liveness_cmd must NEVER be armed by a git-TRACKED manifest: a single committed
  # manifest would arm command execution in every consumer's lane guard. The .gitignore
  # keeps the manifest untrackable by default; this is the RUNTIME backstop (record + refuse).
  local mpath; mpath=$(pwt_governor_manifest_path)
  if [ -n "$mpath" ] && command -v git >/dev/null 2>&1 \
       && git -C "$(dirname "$mpath")" ls-files --error-unmatch "$mpath" >/dev/null 2>&1; then
    jq -cn --arg ts "$ts" --arg slug "$slug" --argjson process "$pv" \
       '{ts:$ts, slug:$slug, kind:"liveness-refused", reason:"git-tracked-manifest", process:$process, verdict:$process}' \
       >> "$jf" 2>/dev/null || true
    echo "$pv"; return 0
  fi

  # AC9 — liveness_cmd runs ONLY under a timeout. It executes synchronously inside the
  # lane-guard PreToolUse hook, so an UNBOUNDED command would stall every Bash call. With no
  # timeout binary present (macOS without coreutils), SKIP it — process evidence already wins
  # in phase 1, so skipping loses nothing and never runs an unbounded child.
  local gv timeout_bin=""
  if [ "${PWT_LIVENESS_FORCE_NO_TIMEOUT:-0}" != "1" ]; then   # test seam: simulate a host with no timeout binary
    command -v gtimeout >/dev/null 2>&1 && timeout_bin=gtimeout
    [ -z "$timeout_bin" ] && command -v timeout >/dev/null 2>&1 && timeout_bin=timeout
  fi
  if [ -z "$timeout_bin" ]; then
    jq -cn --arg ts "$ts" --arg slug "$slug" --argjson process "$pv" \
       '{ts:$ts, slug:$slug, kind:"liveness-skipped", reason:"no-timeout-binary", process:$process, verdict:$process}' \
       >> "$jf" 2>/dev/null || true
    echo "$pv"; return 0
  fi
  # argv exec, never sourced; exit-code only (stdout is never parsed into "alive").
  env -i PATH="$PATH" "$timeout_bin" "${PWT_LIVENESS_CMD_TIMEOUT_S:-10}" $cmd "$slug" >/dev/null 2>&1
  case "$?" in 0) gv=0 ;; 1) gv=1 ;; *) gv=2 ;; esac
  # Record BOTH answers. On disagreement PREFER process evidence; append a disagreement row.
  jq -cn --arg ts "$ts" --arg slug "$slug" --argjson process "$pv" --argjson registry "$gv" \
     --arg governor "$(pwt_governor_name)" --argjson verdict "$pv" \
     '{ts:$ts, slug:$slug, process:$process, registry:$registry, governor:$governor, verdict:$verdict}' \
     >> "$jf" 2>/dev/null || true
  if [ "$gv" != "$pv" ]; then
    jq -cn --arg ts "$ts" --arg slug "$slug" --argjson process "$pv" --argjson governor_verdict "$gv" \
       '{ts:$ts, slug:$slug, kind:"liveness-disagreement", process:$process, governor_verdict:$governor_verdict, resolution:"prefer-process"}' \
       >> "$jf" 2>/dev/null || true
    # C1 (phase 2): tee a liveness-disagreement event to the governor's event_sink.
    # The lib is already sourced above; emit is governed-only + fail-open (parity: this
    # whole function already returned before here when ungoverned).
    if command -v pwt_governor_emit_event >/dev/null 2>&1; then
      pwt_governor_emit_event "$slug" \
        "$(jq -cn --argjson process "$pv" --argjson governor "$gv" \
             '{event:"liveness-disagreement", process:$process, governor:$governor}' 2>/dev/null)" \
        2>/dev/null || true
    fi
  fi
  echo "$pv"   # process evidence wins in phase 1
}

# ── main predicate ──────────────────────────────────────────────────────────────
pwt_lane_alive() {
  local slug="" json=0 wsid_override="" repo_override=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --worker-sid) wsid_override="$2"; shift ;;
      --repo-root) repo_override="$2"; shift ;;
      --*) : ;;
      *) [ -z "$slug" ] && slug="$1" ;;
    esac
    shift
  done
  [ -n "$slug" ] || { echo "usage: pwt_lane_alive <slug> [--json]" >&2; return 3; }

  local gf wsid="" wt=""
  gf=$(__pla_goal_file "$slug")
  if [ -n "$gf" ]; then
    wsid=$(jq -r '.worker_sid // ""' "$gf" 2>/dev/null || echo "")
  fi
  [ -n "$wsid_override" ] && wsid="$wsid_override"
  # lane worktree (from manifest) for cwd scoping of the registry rows
  local root; root=$(__pla_main_root)
  local mf="${root}/.claude/state/plan-w-team-manifest-${slug}.json"
  [ -f "$mf" ] && wt=$(jq -r '.worktree_path // ""' "$mf" 2>/dev/null || echo "")

  local agents; agents=$(__pla_agents_json)
  local reg_fail=0
  [ "$agents" = "__PLA_REGISTRY_FAIL__" ] && reg_fail=1

  # rows attributed to the lane: background rows whose cwd is the lane worktree (or all bg rows
  # when no worktree is recorded). Each row: pid \t sessionId \t state \t argv
  local rows=""
  if [ "$reg_fail" = "0" ]; then
    rows=$(printf '%s' "$agents" | jq -r --arg wt "$wt" '
      .[] | select((.kind // "background")=="background")
          | select($wt=="" or ((.cwd // "")==$wt) or ((.cwd // "")|startswith($wt+"/")))
          | [ (.pid // "" | tostring), (.sessionId // ""), (.state // ""), (.name // .command // "") ]
          | @tsv' 2>/dev/null || echo "")
  fi

  local live_by_registry=0 live_by_process=0
  local w_pid="" w_argv="" w_state=""
  local IFSbak="$IFS"; IFS=$'\n'
  local line
  for line in $rows; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r r_pid r_sid r_state r_argv <<EOF_ROW
$line
EOF_ROW
    live_by_registry=$((live_by_registry+1))
    if __pla_row_live "$r_pid" "$r_sid" "$r_argv"; then
      live_by_process=$((live_by_process+1))
    fi
    # is this the worker's row?
    if [ -n "$wsid" ] && [ "${r_sid:0:8}" = "${wsid:0:8}" ]; then
      w_pid="$r_pid"; w_argv="$r_argv"; w_state="$r_state"
    fi
  done
  IFS="$IFSbak"

  # ── verdict for the worker ────────────────────────────────────────────────────
  local verdict source
  # `pg` is the pgrep-by-uuid probe: a count string, or "UNKNOWN" when pgrep could not run.
  # UNKNOWN is cannot-determine — it may NEVER authorize a release (verdict 1) NOR assert a
  # process is present (verdict 0). Only a NUMERIC "0" is trustworthy "no process" (AC8).
  local pg
  if [ -n "$w_pid" ]; then
    local st; st=$(__pla_proc_state "$w_pid")
    if [ "$st" = "alive" ] && __pla_corroborated "$w_pid" "$wsid"; then
      verdict=0; source="registry-row+process-corroborated"
    elif [ "$st" = "dead" ]; then
      pg=$(__pla_pgrep_uuid "$wsid")
      if [ "$pg" = "UNKNOWN" ]; then verdict=2; source="pid-ESRCH+pgrep-unavailable"
      elif [ "$pg" = "0" ]; then verdict=1; source="pid-ESRCH+no-pgrep"
      else verdict=2; source="pid-dead-but-uuid-process-present"; fi
    else
      verdict=2; source="pid-eperm-or-uncorroborated"
    fi
  else
    # No registry row for the worker.
    if [ "$reg_fail" = "1" ]; then
      # Empty/unqueryable registry is NOT death — consult process evidence directly.
      pg=$(__pla_pgrep_uuid "$wsid")
      if [ -n "$wsid" ] && [ "$pg" != "0" ] && [ "$pg" != "UNKNOWN" ]; then verdict=0; source="registry-absent+process-present"
      else verdict=2; source="registry-unqueryable"; fi
    else
      # Registry is valid but the worker is absent from it.
      pg=$(__pla_pgrep_uuid "$wsid")
      if [ -n "$wsid" ] && [ "$pg" != "0" ] && [ "$pg" != "UNKNOWN" ]; then verdict=0; source="registry-lag+process-present"
      elif [ -n "$wsid" ] && [ "$pg" = "0" ]; then verdict=1; source="absent-from-registry+no-pgrep"
      elif [ -n "$wsid" ]; then verdict=2; source="absent-from-registry+pgrep-unavailable"
      else verdict=2; source="no-worker-sid"; fi
    fi
  fi

  # Frozen-abandonment upgrade (SPAWN-LIVE2): a run the CLI abandoned at spawn leaves a
  # LIVE `blocked` process, so process evidence reads ALIVE (verdict 0) and the lane wedges.
  # If the worker transcript's tail shows the unrecoverable-clear message AND is frozen, the
  # RUN is dead — upgrade to confirmed-dead (1) so the lane guard's confirmed-dead release
  # reclaims it. Only ever UPGRADES toward 1 (the freeze gate blocks masking a live,
  # progressing worker). Kill switch: PWT_LANE_ALIVE_ABANDON_DETECT=0.
  if [ "${PWT_LANE_ALIVE_ABANDON_DETECT:-1}" != "0" ] && [ "$verdict" != "1" ] && [ -n "$wsid" ]; then
    local __pla_tr; __pla_tr=$(__pla_worker_transcript "$wsid" "$wt")
    if [ -n "$__pla_tr" ] && __pla_abandoned "$__pla_tr"; then
      verdict=1; source="transcript-abandoned+frozen"
    fi
  fi

  # governed consult may record disagreement; process evidence wins in phase 1
  local governed=false
  local lib; lib="$(__pla_self_dir)/pwt-governor-lib.sh"
  if [ -r "$lib" ]; then ( . "$lib"; pwt_governed ) && governed=true; fi
  verdict=$(__pla_governed_consult "$slug" "$verdict")

  if [ "$json" = "1" ]; then
    local vlabel; case "$verdict" in 0) vlabel=alive ;; 1) vlabel=not-alive ;; *) vlabel=cannot-determine ;; esac
    jq -cn --arg slug "$slug" --arg wsid "$wsid" --argjson lp "$live_by_process" --argjson lr "$live_by_registry" \
       --arg verdict "$vlabel" --arg source "$source" --argjson governed "$governed" \
       '{slug:$slug, worker_sid:$wsid, live_by_process:$lp, live_by_registry:$lr, verdict:$verdict, source:$source, governed:$governed}'
  fi
  return "$verdict"
}

# ── CLI ─────────────────────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  pwt_lane_alive "$@"
  exit $?
fi
