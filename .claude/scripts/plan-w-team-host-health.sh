#!/usr/bin/env bash
# plan-w-team-host-health.sh — one host-health sampler, three consumers.
#
# WHY THIS EXISTS
#   The 2026-08-19 incident (docs/specs/pwt-host-load-and-stall-protection.md)
#   had three independent fixes that all need the same question answered: "is
#   this host starving, and who is starving it?"
#     F2  plan-w-team-verify-run.sh   — mandatory diagnosis at the retry cap
#     F3  plan-w-team-await-terminal.sh — proactive supervisor distress watch
#     F5  plan-w-team-test-green.sh   — load annotation beside duration_s
#   Three copies of a load-average parser would be the reuse-first violation
#   this repo gates on, and they would drift. One sampler, one contract.
#
# SCOPE (deliberately narrow — this is NOT a machine monitor)
#   It answers only about the run's own health and about whatever is starving
#   it. Processes belonging to the lane (the repo root or one of its worktrees
#   appears in their command line) are EXCLUDED from the runaway-CPU signal:
#   the run's own builders are supposed to use CPU. They are, however, the only
#   processes counted as orphans — a re-parented lane process is leaked work.
#
# OUTPUT — minified JSON on stdout, ALWAYS exit 0:
#   {"ts","supported","ncpu","load_1m","load_ratio","load_factor_threshold",
#    "load_suspect","top_consumers":[{"pid","pcpu","command"}],
#    "max_nonlane_pcpu","nonlane_cpu_threshold","orphan_count",
#    "orphan_threshold","breach","breach_reasons":[...]}
#
# FAIL-OPEN CONTRACT
#   A sampler that cannot sample NEVER claims distress. Any unreadable input
#   yields supported=false, breach=false, breach_reasons=[]. Callers key on
#   `breach`, so an unsupported host silently disables every consumer's
#   escalation path rather than firing a false one.
#
# USAGE
#   plan-w-team-host-health.sh [--repo-root DIR] [--worktree DIR]... [--json]
#
# ENV — thresholds (all overridable):
#   PWT_HOST_LOAD_FACTOR   1.5  load_1m > factor * ncpu          → load_suspect / "load"
#   PWT_HOST_CPU_PCT       150  any NON-lane process above this  → "cpu"
#   PWT_HOST_ORPHAN_MAX      5  lane orphans at or above this    → "orphans"
#
# ENV — test seams (house *_STUB_* pattern, same as ram-budget.sh):
#   PWT_HOST_HEALTH_STUB_UPTIME  file used in place of `uptime`
#   PWT_HOST_HEALTH_STUB_PS      file used in place of `ps`
#   PWT_HOST_HEALTH_STUB_NCPU    integer used in place of the ncpu probe
#
# bash 3.2 (mac-mini /bin/bash): no `declare -A`, no `${v,,}`, no mapfile.

set -u

LOAD_FACTOR="${PWT_HOST_LOAD_FACTOR:-1.5}"
CPU_PCT="${PWT_HOST_CPU_PCT:-150}"
ORPHAN_MAX="${PWT_HOST_ORPHAN_MAX:-5}"

REPO_ROOT=""
WORKTREES=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --worktree)
      if [ -n "${2:-}" ]; then
        WORKTREES="${WORKTREES}${WORKTREES:+
}${2}"
      fi
      shift; [ $# -gt 0 ] && shift ;;
    --json) shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

# ── Repo root + worktree set (lane classification inputs) ───────────────────
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
fi
# Discover the repo's worktrees so a worktree mounted OUTSIDE the main checkout
# is still classified as lane. Failure here is not fatal — it only widens the
# non-lane set, which can add a breach reason, never remove one.
if [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT" ]; then
  WT_LIST=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null \
            | awk '/^worktree /{ $1=""; sub(/^ /,""); print }' || echo "")
  if [ -n "$WT_LIST" ]; then
    WORKTREES="${WORKTREES}${WORKTREES:+
}${WT_LIST}"
  fi
fi
LANE_PATHS="${REPO_ROOT}${REPO_ROOT:+
}${WORKTREES}"
# Hand the lane set to awk through the ENVIRONMENT, never through `-v`.
# `awk -v name=value` rejects a newline inside the value: with no worktrees the
# string ends in one, awk exits non-zero, the `|| echo ""` swallows it, and the
# whole process table silently normalizes to EMPTY — max_nonlane_pcpu 0 and
# orphan_count 0 on a host that is actually on fire. Fail-open is correct for a
# missing input; it is NOT correct for an input we have and cannot pass.
LANE_PATHS=$(printf '%s' "$LANE_PATHS" | sed -e 's/[[:space:]]*$//')
export PWT_HH_LANE_PATHS="$LANE_PATHS"

# ── ncpu ────────────────────────────────────────────────────────────────────
NCPU=""
if [ -n "${PWT_HOST_HEALTH_STUB_NCPU:-}" ]; then
  NCPU="$PWT_HOST_HEALTH_STUB_NCPU"
else
  NCPU=$(sysctl -n hw.ncpu 2>/dev/null || echo "")
  [ -n "$NCPU" ] || NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo "")
  [ -n "$NCPU" ] || NCPU=$(nproc 2>/dev/null || echo "")
fi
case "$NCPU" in
  ''|*[!0-9]*) NCPU=1 ;;
esac
[ "$NCPU" -lt 1 ] 2>/dev/null && NCPU=1

# ── 1-minute load average ───────────────────────────────────────────────────
# macOS: "load averages: 2.15 2.30 2.45"   Linux: "load average: 0.52, 0.58, 0.59"
# A STUB path that does not resolve is an explicit "cannot sample" — it must
# NOT silently fall through to the real `uptime`, or a test asserting the
# fail-open path would measure the host instead of the fixture.
SUPPORTED="true"
UPTIME_RAW=""
if [ -n "${PWT_HOST_HEALTH_STUB_UPTIME:-}" ]; then
  if [ -r "$PWT_HOST_HEALTH_STUB_UPTIME" ]; then
    UPTIME_RAW=$(cat "$PWT_HOST_HEALTH_STUB_UPTIME" 2>/dev/null || echo "")
  else
    UPTIME_RAW=""
  fi
elif command -v uptime >/dev/null 2>&1; then
  UPTIME_RAW=$(uptime 2>/dev/null || echo "")
elif [ -r /proc/loadavg ]; then
  UPTIME_RAW="load average: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
fi

LOAD_1M=""
if [ -n "$UPTIME_RAW" ]; then
  LOAD_1M=$(printf '%s\n' "$UPTIME_RAW" \
    | sed -n 's/.*[Ll]oad average[s]*:[[:space:]]*//p' \
    | head -1 \
    | tr ',' ' ' \
    | awk '{print $1}')
fi
case "$LOAD_1M" in
  ''|*[!0-9.]*) LOAD_1M=""; SUPPORTED="false" ;;
esac

# ── Process table ───────────────────────────────────────────────────────────
# `-o args=` is the portable spelling (BSD `command=` / Linux `cmd=` differ).
PS_RAW=""
if [ -n "${PWT_HOST_HEALTH_STUB_PS:-}" ]; then
  [ -r "$PWT_HOST_HEALTH_STUB_PS" ] && PS_RAW=$(cat "$PWT_HOST_HEALTH_STUB_PS" 2>/dev/null || echo "")
elif command -v ps >/dev/null 2>&1; then
  PS_RAW=$(ps -A -o pid=,ppid=,pcpu=,args= 2>/dev/null || echo "")
fi

# Normalize to TSV: pid \t ppid \t pcpu \t isLane \t command
# A row whose first field is not numeric is a header or noise — dropped, so a
# stub fixture may carry a human-readable header without special-casing.
PS_TSV=""
if [ -n "$PS_RAW" ]; then
  PS_TSV=$(printf '%s\n' "$PS_RAW" | awk '
    BEGIN { n = split(ENVIRON["PWT_HH_LANE_PATHS"], L, "\n") }
    {
      pid = $1; ppid = $2; pcpu = $3
      if (pid !~ /^[0-9]+$/) next
      if (ppid !~ /^[0-9]+$/) next
      if (pcpu !~ /^[0-9]+(\.[0-9]+)?$/) next
      cmd = ""
      for (i = 4; i <= NF; i++) cmd = cmd (i > 4 ? " " : "") $i
      isLane = 0
      for (j = 1; j <= n; j++) {
        if (L[j] != "" && index(cmd, L[j]) > 0) { isLane = 1; break }
      }
      gsub(/\t/, " ", cmd)
      printf "%s\t%s\t%s\t%s\t%s\n", pid, ppid, pcpu, isLane, cmd
    }' 2>/dev/null || echo "")
fi

MAX_NONLANE=$(printf '%s\n' "$PS_TSV" | awk -F'\t' '
  $4 == 0 { if ($3 + 0 > m + 0) m = $3 + 0 }
  END { printf "%.1f", m + 0 }' 2>/dev/null || echo "0.0")
[ -n "$MAX_NONLANE" ] || MAX_NONLANE="0.0"

ORPHANS=$(printf '%s\n' "$PS_TSV" | awk -F'\t' '
  $4 == 1 && $2 + 0 == 1 { c++ }
  END { print c + 0 }' 2>/dev/null || echo 0)
case "$ORPHANS" in ''|*[!0-9]*) ORPHANS=0 ;; esac

# ── Verdicts (awk does the float math — bash 3.2 has none) ──────────────────
LOAD_RATIO="null"
LOAD_SUSPECT="false"
BREACH_LOAD=0
if [ -n "$LOAD_1M" ]; then
  LOAD_RATIO=$(awk -v l="$LOAD_1M" -v n="$NCPU" 'BEGIN { printf "%.2f", (n > 0 ? l / n : 0) }')
  if awk -v l="$LOAD_1M" -v n="$NCPU" -v f="$LOAD_FACTOR" 'BEGIN { exit !(l > f * n) }'; then
    LOAD_SUSPECT="true"; BREACH_LOAD=1
  fi
fi

BREACH_CPU=0
if awk -v m="$MAX_NONLANE" -v t="$CPU_PCT" 'BEGIN { exit !(m > t) }'; then
  BREACH_CPU=1
fi

BREACH_ORPH=0
[ "$ORPHANS" -ge "$ORPHAN_MAX" ] 2>/dev/null && BREACH_ORPH=1

# Fail-open master switch: an unsupported sample never claims a breach, and
# never reports a reason that a consumer would escalate on.
REASONS=""
if [ "$SUPPORTED" = "true" ]; then
  [ "$BREACH_LOAD" = "1" ] && REASONS="${REASONS}${REASONS:+ }load"
  [ "$BREACH_CPU"  = "1" ] && REASONS="${REASONS}${REASONS:+ }cpu"
  [ "$BREACH_ORPH" = "1" ] && REASONS="${REASONS}${REASONS:+ }orphans"
else
  LOAD_SUSPECT="false"
fi
BREACH="false"
[ -n "$REASONS" ] && BREACH="true"

# ── Emit ────────────────────────────────────────────────────────────────────
# Command strings come from `ps` — untrusted text that must never be printf'd
# into JSON. With jq they go through --arg; without jq, top_consumers is
# emitted EMPTY rather than risk a malformed document (the numeric signals,
# which are what every consumer gates on, are unaffected).
if command -v jq >/dev/null 2>&1; then
  TOP_JSON=$(printf '%s\n' "$PS_TSV" \
    | sort -t"$(printf '\t')" -k3 -gr 2>/dev/null \
    | head -3 \
    | awk -F'\t' 'NF >= 5 { printf "%s\t%s\t%s\n", $1, $3, substr($5, 1, 120) }' \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t"))
                   | map({pid: (.[0] | tonumber), pcpu: (.[1] | tonumber), command: .[2]})' \
      2>/dev/null || echo "[]")
  [ -n "$TOP_JSON" ] || TOP_JSON="[]"
  # `printf '%s' ""` feeds jq ZERO input lines, so `jq -R` emits NOTHING and still
  # exits 0 — the `|| echo "[]"` never fires and REASONS_JSON ends up EMPTY. An
  # empty --argjson is invalid JSON, which fails the whole emit below and silently
  # drops the render into the jq-ABSENT fallback, where top_consumers is hardcoded
  # `[]`. Net effect on a healthy host: the sampler reported no consumers at all,
  # so the ⚠ HOST-DISTRESS block could never name the process that was starving the
  # run — the one field the block exists for. Caught only by running it for real;
  # the stubbed tests all took the breach path, which has non-empty REASONS.
  REASONS_JSON="[]"
  if [ -n "$REASONS" ]; then
    REASONS_JSON=$(printf '%s' "$REASONS" | jq -R -c 'split(" ") | map(select(length > 0))' 2>/dev/null || echo "[]")
    [ -n "$REASONS_JSON" ] || REASONS_JSON="[]"
  fi

  jq -cn \
    --arg ts "$TS" \
    --argjson supported "$SUPPORTED" \
    --argjson ncpu "$NCPU" \
    --argjson load_1m "${LOAD_1M:-null}" \
    --argjson load_ratio "$LOAD_RATIO" \
    --argjson load_factor_threshold "$LOAD_FACTOR" \
    --argjson load_suspect "$LOAD_SUSPECT" \
    --argjson top_consumers "$TOP_JSON" \
    --argjson max_nonlane_pcpu "$MAX_NONLANE" \
    --argjson nonlane_cpu_threshold "$CPU_PCT" \
    --argjson orphan_count "$ORPHANS" \
    --argjson orphan_threshold "$ORPHAN_MAX" \
    --argjson breach "$BREACH" \
    --argjson breach_reasons "$REASONS_JSON" \
    '{ts:$ts, supported:$supported, ncpu:$ncpu, load_1m:$load_1m, load_ratio:$load_ratio,
      load_factor_threshold:$load_factor_threshold, load_suspect:$load_suspect,
      top_consumers:$top_consumers, max_nonlane_pcpu:$max_nonlane_pcpu,
      nonlane_cpu_threshold:$nonlane_cpu_threshold, orphan_count:$orphan_count,
      orphan_threshold:$orphan_threshold, breach:$breach, breach_reasons:$breach_reasons}' \
    2>/dev/null && exit 0
fi

# jq-absent fallback: every interpolated value below is program-controlled
# (numbers this script computed, or a literal it chose). No ps text is emitted.
REASONS_ARR=""
for r in $REASONS; do
  REASONS_ARR="${REASONS_ARR}${REASONS_ARR:+,}\"$r\""
done
printf '{"ts":"%s","supported":%s,"ncpu":%s,"load_1m":%s,"load_ratio":%s,"load_factor_threshold":%s,"load_suspect":%s,"top_consumers":[],"max_nonlane_pcpu":%s,"nonlane_cpu_threshold":%s,"orphan_count":%s,"orphan_threshold":%s,"breach":%s,"breach_reasons":[%s]}\n' \
  "$TS" "$SUPPORTED" "$NCPU" "${LOAD_1M:-null}" "$LOAD_RATIO" "$LOAD_FACTOR" \
  "$LOAD_SUSPECT" "$MAX_NONLANE" "$CPU_PCT" "$ORPHANS" "$ORPHAN_MAX" \
  "$BREACH" "$REASONS_ARR"
exit 0
