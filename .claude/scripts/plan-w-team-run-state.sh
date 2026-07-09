#!/bin/bash
# plan-w-team-run-state.sh  (Run-State Router — deterministic run-state detector)
#
# Item 1 of the Run-State Router feature (spec: docs/specs/run-state-router.md).
#
# READ-ONLY, FAIL-OPEN state detector. Given optional topic words and/or an
# explicit slug, it fuzzy-matches candidate /plan-w-team runs in the CONSUMER
# repo and, for each, reads the artifact ladder to emit a run-state verdict:
#
#     no-prior | specd | mid-execution | built-unreviewed |
#     shipped-unretroed | complete | live-now
#
# The router (manifest Step -1) and pwt-goal derivation consume these verdicts
# to route intent × state (continue → resume, readiness question → status mode,
# live run → stand down, etc.) instead of blindly re-running the full 0→8
# pipeline on in-progress or shipped work.
#
# DESIGN (reuse-first — shared/reuse-first.md):
#   - Reader idioms (lock_state, goal_terminal, state-dir resolution) mirror
#     .claude/scripts/pwt-status.sh (read-only, jq-guarded).
#   - The authoritative live-vs-terminal signal REUSES
#     `pwt-goal.sh --resume-staleness-check --json` (pwt-goal.sh:89-210), which
#     itself resolves goal-state across explicit→primary→main→worktree-glob
#     dirs and honors PWT_PROJECT_ROOT_OVERRIDE.
#
# FAIL-OPEN CONTRACT (the router must NEVER block a run): any per-candidate
# read error degrades that candidate to `no-prior` with a stderr warning. The
# script exits 0 always, except usage errors (exit 2).
#
# GC-AWARENESS: Step 8 retro deletes per-run files (baseline/fleet) on
# RETRO_SUCCESS. Absence of per-run files is therefore NOT "never ran" — a spec
# plus a retro/completion artifact (or a goal-state SUCCESS) reads `complete`.
#
# Usage:
#   plan-w-team-run-state.sh [--topic "<words>"] [--slug <slug>]
#                            [--json] [--root <dir>] [-h|--help]
#
# Exit codes:
#   0 — verdict(s) emitted (including the no-candidate case)
#   2 — usage error (unknown flag)
#
# Env:
#   PWT_PROJECT_ROOT_OVERRIDE  — repo root override (tests); precedes CLAUDE_PROJECT_DIR.
#   PWT_RUN_STATE_MAX_CANDIDATES — cap on emitted candidates (default 20, LOUD).
#
# bash 3.2 compatible (no associative arrays, no mapfile).

set -u

PROG="plan-w-team-run-state"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Arg parsing ──────────────────────────────────────────────────────────────
TOPIC=""
WANT_SLUG=""
WANT_JSON=0
ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --topic) TOPIC="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --slug)  WANT_SLUG="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --json)  WANT_JSON=1; shift ;;
    --root)  ROOT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -48; exit 0 ;;
    *) echo "[$PROG] unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ── Resolve repo root + state dir (mirrors pwt-status.sh / pwt-goal.sh) ───────
if [ -z "$ROOT" ]; then
  ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
fi
STATE_DIR="$ROOT/.claude/state"
SPECS_DIR="$ROOT/docs/specs"

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

warn() { echo "[$PROG] ⚠ $*" >&2; }

# ── Candidate slug enumeration ───────────────────────────────────────────────
# Union of: spec filenames, goal-state .slug fields, scope-lock slugs, and
# directive files. De-duplicated. (Titles are mined for fuzzy scoring only.)
enumerate_slugs() {
  {
    # Spec filenames (docs/specs/<slug>.md)
    if [ -d "$SPECS_DIR" ]; then
      for f in "$SPECS_DIR"/*.md; do
        [ -f "$f" ] || continue
        b="$(basename "$f" .md)"; printf '%s\n' "$b"
      done
    fi
    if [ -d "$STATE_DIR" ]; then
      # goal-state slugs (from filename — robust even if .slug field drifts)
      for f in "$STATE_DIR"/plan-w-team-goal-*.json; do
        [ -f "$f" ] || continue
        b="$(basename "$f" .json)"; printf '%s\n' "${b#plan-w-team-goal-}"
      done
      # scope-lock slugs
      for f in "$STATE_DIR"/plan-w-team-scope-lock-*.json; do
        [ -f "$f" ] || continue
        b="$(basename "$f" .json)"; printf '%s\n' "${b#plan-w-team-scope-lock-}"
      done
    fi
  } | LC_ALL=C sort -u | grep -v '^$'
}

# ── Fuzzy score: matched topic tokens / topic tokens, integer percent ────────
# Token overlap between the (lowercased, non-alnum-split) topic words and the
# candidate slug + its spec title. Deterministic, no external deps.
tokenize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '\n' | grep -v '^$'; }

score_candidate() { # $1=slug → integer 0..100 (100 when no topic given or exact slug)
  local slug="$1" title="" hay tok total=0 hit=0
  [ -z "$TOPIC" ] && { printf '100'; return 0; }
  # Spec title (first markdown H1) enriches the haystack.
  if [ -f "$SPECS_DIR/$slug.md" ]; then
    title="$(grep -m1 '^# ' "$SPECS_DIR/$slug.md" 2>/dev/null | sed 's/^# *//')"
  fi
  hay="$(printf '%s %s' "$slug" "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ')"
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    total=$((total + 1))
    case " $hay " in *" $tok "*) hit=$((hit + 1)) ;; esac
  done <<EOF
$(tokenize "$TOPIC")
EOF
  [ "$total" -eq 0 ] && { printf '0'; return 0; }
  printf '%s' $(( hit * 100 / total ))
}

# ── Per-slug artifact readers ────────────────────────────────────────────────
art() { [ -e "$STATE_DIR/plan-w-team-$1" ] && printf 'true' || printf 'false'; }

goal_terminal_of() { # $1=slug → terminal_state string, "" if null/absent/corrupt
  local gf="$STATE_DIR/plan-w-team-goal-$1.json" v=""
  [ -f "$gf" ] || { printf ''; return 0; }
  if [ "$HAVE_JQ" -eq 1 ]; then
    v="$(jq -r '.terminal_state // empty' "$gf" 2>/dev/null)"
  else
    v="$(grep -o '"terminal_state"[[:space:]]*:[[:space:]]*"[^"]*"' "$gf" 2>/dev/null | sed 's/.*:[[:space:]]*"//;s/"$//')"
  fi
  printf '%s' "$v"
}

lock_alive_of() { # $1=slug → true if workflow lock dir present AND owner PID alive
  local d="$STATE_DIR/plan-w-team-workflow-$1.lock" pid
  [ -d "$d" ] || { printf 'false'; return 0; }
  pid="$(cat "$d/pid" 2>/dev/null || echo "")"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then printf 'true'; else printf 'false'; fi
}

# NOTE on reuse (shared/reuse-first.md): the "goal-state terminal_state
# null = open/not-finished" reading below (goal_terminal_of) mirrors the
# authoritative terminal detection in pwt-goal.sh --resume-staleness-check
# (pwt-goal.sh:166-179). We deliberately do NOT shell out to that subprocess
# for the verdict: its branch-merge leg reports STALE for a fresh worktree
# branch with 0 unique commits (a false SHIPPED signal — memory:
# gc-reaps-live-worker-worktree), and its non-terminal LIVE verdict fires for
# ANY unfinished run, so it cannot discriminate live-now (running now) from
# mid-execution (open but resumable). Process liveness (live lock PID OR fresh
# hook-spawn flag) is that discriminator. The state artifacts
# (ship-verdict/retro/completion) are the authoritative shipped/complete signal.

# Fresh hook-spawn flag → a route-hook-spawned worker is running RIGHT NOW.
# The route hook writes plan-w-team-hook-spawn-<parent_sid>.flag containing the
# worker SID at spawn (state-artifacts.md). "Fresh" = mtime within the live
# window (default 30 min). We match the flag to THIS slug via the goal-state's
# worker_sid (a flag with no matching worker_sid is some other run's).
fresh_spawn_flag_of() { # $1=slug → true|false
  local slug="$1" gf="$STATE_DIR/plan-w-team-goal-$slug.json" wsid="" f mt now win
  [ -d "$STATE_DIR" ] || { printf 'false'; return 0; }
  win="${PWT_RUN_STATE_LIVE_WINDOW_MIN:-30}"
  now="$(date +%s)"
  if [ -f "$gf" ]; then
    if [ "$HAVE_JQ" -eq 1 ]; then wsid="$(jq -r '.worker_sid // empty' "$gf" 2>/dev/null)"; fi
  fi
  for f in "$STATE_DIR"/plan-w-team-hook-spawn-*.flag; do
    [ -f "$f" ] || continue
    mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
    [ $(( (now - mt) / 60 )) -gt "$win" ] && continue          # not fresh
    # Match to this slug when we know the worker_sid; else any fresh flag counts.
    if [ -n "$wsid" ]; then
      grep -q "$wsid" "$f" 2>/dev/null && { printf 'true'; return 0; }
    else
      grep -q "$slug" "$f" 2>/dev/null && { printf 'true'; return 0; }
    fi
  done
  printf 'false'
}

spec_age_days_of() { # $1=slug → integer days since spec mtime, or -1
  local f="$SPECS_DIR/$1.md" mt now
  [ -f "$f" ] || { printf '%s' -1; return 0; }
  mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")"
  [ -z "$mt" ] && { printf '%s' -1; return 0; }
  now="$(date +%s)"
  printf '%s' $(( (now - mt) / 86400 ))
}

head_moved_since_spec_of() { # $1=slug → true|false (best-effort, fail-open false)
  local f="$SPECS_DIR/$1.md" spec_ct head_ct
  [ -f "$f" ] || { printf 'false'; return 0; }
  spec_ct="$(git -C "$ROOT" log -1 --format=%ct -- "docs/specs/$1.md" 2>/dev/null || echo "")"
  head_ct="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo "")"
  [ -z "$spec_ct" ] || [ -z "$head_ct" ] && { printf 'false'; return 0; }
  [ "$head_ct" -gt "$spec_ct" ] && printf 'true' || printf 'false'
}

# ── Verdict decision (ordered) ───────────────────────────────────────────────
decide_verdict() { # $1=slug → verdict token
  local slug="$1"
  local spec scope_lock ac_snap baseline manifest review ship postship retro completion
  spec="$([ -f "$SPECS_DIR/$slug.md" ] && printf true || printf false)"
  scope_lock="$(art "scope-lock-$slug.json")"
  ac_snap="$(art "ac-snapshot-$slug.md")"
  baseline="$(art "untracked-baseline-$slug.txt")"
  manifest="$(art "manifest-$slug.json")"
  review="$(art "review-findings-$slug.md")"
  ship="$(art "ship-verdict-$slug.json")"
  postship="$(art "postship-$slug.json")"
  retro="$(art "retro-$slug.json")"
  completion="$(art "completion-$slug.json")"
  local term lock_alive
  term="$(goal_terminal_of "$slug")"
  lock_alive="$(lock_alive_of "$slug")"

  # 1. live-now (STAND DOWN — a worker is running right now): the run is
  #    non-terminal AND a liveness signal fires — a live workflow-lock PID, a
  #    fresh hook-spawn flag, or pwt-goal staleness LIVE (unmerged, non-terminal).
  #    Process liveness is the discriminator vs. mid-execution (both are
  #    non-terminal; only live-now is ACTIVELY running). The workflow-lock PID
  #    is often stale under the ephemeral-shell harness, so the fresh spawn flag
  #    is the reliable just-started signal.
  if [ -f "$STATE_DIR/plan-w-team-goal-$slug.json" ] && [ -z "$term" ]; then
    if [ "$lock_alive" = "true" ] || [ "$(fresh_spawn_flag_of "$slug")" = "true" ]; then
      printf 'live-now'; return 0
    fi
  elif [ "$lock_alive" = "true" ]; then
    # A live lock with no goal-state at all still means a session is running.
    printf 'live-now'; return 0
  fi

  # 2. complete: retro/completion present, OR goal-state SUCCESS (GC-aware:
  #    per-run files may be gone; spec+terminal evidence still reads complete).
  if [ "$retro" = "true" ] || [ "$completion" = "true" ] || [ "$term" = "SUCCESS" ]; then
    printf 'complete'; return 0
  fi

  # 3. shipped-unretroed: a ship verdict exists but retro has not run.
  if [ "$ship" = "true" ]; then printf 'shipped-unretroed'; return 0; fi

  # 4. built-unreviewed: build/execution artifacts exist, no ship verdict yet.
  if [ "$manifest" = "true" ] || [ "$review" = "true" ]; then
    printf 'built-unreviewed'; return 0
  fi

  # 5. mid-execution: execution underway (scope-lock/ac-snapshot/baseline), or a
  #    non-terminal goal-state that is NOT live (a halted/idle run to resume).
  if [ "$scope_lock" = "true" ] || [ "$ac_snap" = "true" ] || [ "$baseline" = "true" ]; then
    printf 'mid-execution'; return 0
  fi
  if [ -f "$STATE_DIR/plan-w-team-goal-$slug.json" ] && [ -z "$term" ]; then
    printf 'mid-execution'; return 0
  fi

  # 6. specd: only the spec exists.
  if [ "$spec" = "true" ]; then printf 'specd'; return 0; fi

  # 7. no-prior.
  printf 'no-prior'
}

# ── Emit one candidate object (JSON) ─────────────────────────────────────────
emit_candidate_json() { # $1=slug $2=score
  local slug="$1" score="$2" verdict
  verdict="$(decide_verdict "$slug" 2>/dev/null || echo 'no-prior')"
  local spec_age head_moved
  spec_age="$(spec_age_days_of "$slug")"
  head_moved="$(head_moved_since_spec_of "$slug")"
  if [ "$HAVE_JQ" -eq 1 ]; then
    jq -n \
      --arg slug "$slug" --arg verdict "$verdict" --argjson score "$score" \
      --argjson spec_age "$spec_age" --argjson head_moved "$head_moved" \
      --arg spec "$([ -f "$SPECS_DIR/$slug.md" ] && echo true || echo false)" \
      --arg scope_lock "$(art "scope-lock-$slug.json")" \
      --arg ac_snapshot "$(art "ac-snapshot-$slug.md")" \
      --arg baseline "$(art "untracked-baseline-$slug.txt")" \
      --arg manifest "$(art "manifest-$slug.json")" \
      --arg review_findings "$(art "review-findings-$slug.md")" \
      --arg ship_verdict "$(art "ship-verdict-$slug.json")" \
      --arg postship "$(art "postship-$slug.json")" \
      --arg retro "$(art "retro-$slug.json")" \
      --arg completion "$(art "completion-$slug.json")" \
      --arg goal_terminal "$(goal_terminal_of "$slug")" \
      --arg workflow_lock "$(lock_alive_of "$slug")" \
      '{slug:$slug, verdict:$verdict, score:$score,
        artifacts:{spec:($spec=="true"), scope_lock:($scope_lock=="true"),
          ac_snapshot:($ac_snapshot=="true"), baseline:($baseline=="true"),
          manifest:($manifest=="true"), review_findings:($review_findings=="true"),
          ship_verdict:($ship_verdict=="true"), postship:($postship=="true"),
          retro:($retro=="true"), completion:($completion=="true"),
          goal_terminal:$goal_terminal, workflow_lock:($workflow_lock=="true")},
        freshness:{spec_age_days:$spec_age, head_moved_since_spec:$head_moved}}'
  else
    printf '{"slug":"%s","verdict":"%s","score":%s,"freshness":{"spec_age_days":%s,"head_moved_since_spec":%s}}' \
      "$slug" "$verdict" "$score" "$spec_age" "$head_moved"
  fi
}

# ── Build candidate list ─────────────────────────────────────────────────────
CANDIDATES=""
if [ -n "$WANT_SLUG" ]; then
  CANDIDATES="$WANT_SLUG"          # explicit slug short-circuits enumeration
else
  CANDIDATES="$(enumerate_slugs)"
fi

MAX="${PWT_RUN_STATE_MAX_CANDIDATES:-20}"

# Score, rank (desc), cap.
RANKED=""
if [ -n "$CANDIDATES" ]; then
  SCORED=""
  while IFS= read -r slug; do
    [ -z "$slug" ] && continue
    if [ -n "$WANT_SLUG" ]; then sc=100; else sc="$(score_candidate "$slug")"; fi
    # Drop zero-score fuzzy matches when a topic was given (noise reduction),
    # but always keep an explicit slug.
    if [ -n "$TOPIC" ] && [ -z "$WANT_SLUG" ] && [ "$sc" -eq 0 ]; then continue; fi
    SCORED="${SCORED}${sc} ${slug}
"
  done <<EOF
$CANDIDATES
EOF
  RANKED="$(printf '%s' "$SCORED" | grep -v '^$' | LC_ALL=C sort -t' ' -k1,1nr -k2,2)"
  TOTAL="$(printf '%s' "$RANKED" | grep -c . )"
  if [ "${TOTAL:-0}" -gt "$MAX" ]; then
    warn "candidate list capped at $MAX of $TOTAL (raise PWT_RUN_STATE_MAX_CANDIDATES)"
    RANKED="$(printf '%s\n' "$RANKED" | head -n "$MAX")"
  fi
fi

# ── Output ───────────────────────────────────────────────────────────────────
if [ "$WANT_JSON" = "1" ]; then
  if [ -z "$RANKED" ]; then echo '[]'; exit 0; fi
  OUT="[]"
  if [ "$HAVE_JQ" -eq 1 ]; then
    while IFS=' ' read -r sc slug; do
      [ -z "$slug" ] && continue
      OBJ="$(emit_candidate_json "$slug" "$sc" 2>/dev/null || echo '{}')"
      OUT="$(printf '%s' "$OUT" | jq --argjson o "$OBJ" '. + [$o]' 2>/dev/null || printf '%s' "$OUT")"
    done <<EOF
$RANKED
EOF
    printf '%s\n' "$OUT"
  else
    # jq-less fallback: concatenate object lines.
    printf '['
    first=1
    while IFS=' ' read -r sc slug; do
      [ -z "$slug" ] && continue
      [ "$first" -eq 0 ] && printf ','
      emit_candidate_json "$slug" "$sc"
      first=0
    done <<EOF
$RANKED
EOF
    printf ']\n'
  fi
  exit 0
fi

# Human table
if [ -z "$RANKED" ]; then
  echo "No prior /plan-w-team run-state candidates found."
  exit 0
fi
printf '%-45s  %-18s  %-6s  %s\n' "SLUG" "VERDICT" "SCORE" "SPEC_AGE_DAYS"
printf '%-45s  %-18s  %-6s  %s\n' "----" "-------" "-----" "-------------"
while IFS=' ' read -r sc slug; do
  [ -z "$slug" ] && continue
  v="$(decide_verdict "$slug" 2>/dev/null || echo 'no-prior')"
  age="$(spec_age_days_of "$slug")"
  printf '%-45s  %-18s  %-6s  %s\n' "$slug" "$v" "$sc" "$age"
done <<EOF
$RANKED
EOF
exit 0
