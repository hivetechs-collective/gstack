#!/usr/bin/env bash
# supervisor-progress-check.sh — generic STEP-0 self-check for the /plan-w-team supervisor.
#
# Objective, un-gameable progress verification + anti-drift anchor. Runs as the
# FIRST thing in every supervisor polling tick, BEFORE the standard worker
# observation. Snapshots user-verifiable metrics, diffs them against the prior
# tick's snapshot, and emits a verdict:
#
#   PROGRESSING   — at least one objective metric moved since last tick
#   IN-FLIGHT     — no metric moved, but an agent worktree was touched < 30 min
#                   ago (work is cooking, not yet landed) — not a stall
#   BACKLOG-CLEAR — all known acceptance criteria pass (near done) — not a stall
#   STALLED       — no progress, nothing in-flight, backlog remains (streak++)
#   STALL-ALERT   — STALL_THRESHOLD consecutive stalled ticks → exit 2. The
#                   supervisor MUST spawn the next backlog item or escalate a
#                   hard-gate to the user. Monitoring without action is a
#                   FAILURE, never a valid tick (see shared/supervisor-protocol.md
#                   §Step 0 + feedback rule "monitoring-only tick = failure while
#                   backlog > 0").
#
# WHY THIS EXISTS: the supervisor's self-reported `goal_progress` sentence is
# gameable — a supervisor can keep saying "progressing" while zero work lands
# (false RAM ceilings, "memory pressure", perceived limits → indefinite idle).
# This check makes progress MECHANICAL: real numbers must move, or it's a stall.
#
# PORTABILITY: no repo-specific paths. Metrics derive from the run's own git +
# spec/transcript, not a fixed product tracker. Degrades gracefully when an AC
# source isn't found (judges on commits/PRs only; never hard-alerts on an
# unknown backlog). bash 3.2 compatible (macOS /bin/bash) — no associative
# arrays; JSON is read with python, never grep-on-JSON (grep silently returns 0
# and defeats stall detection).
#
# Usage:
#   supervisor-progress-check.sh [--slug SLUG] [--state PATH] [--threshold N]
#                                [--transcript PATH] [--spec PATH]
#
# SLUG SCOPING (2026-06-07 hermeticity fix): pass --slug to write a PER-RUN
# snapshot at .claude/state/supervisor-progress-<slug>.json carrying a `slug`
# field. The goal-evaluator anti-park reader (__antipark_state) reads ONLY the
# current run's slug-keyed file, so a stale/foreign run's snapshot can never
# contaminate another run's Stop decision. Without --slug (legacy callers) the
# global .claude/state/supervisor-progress.json is written with slug="" — the
# slug-keyed reader ignores it (fail-open), so the gate is simply inert. An
# explicit --state always wins over the slug-derived default.
# Env: PWT_AUTONOMY_PROFILE (strict|relaxed; unset=strict=today's exact behavior),
#      STALL_THRESHOLD (overrides profile; strict 2 / relaxed 4),
#      PWT_INFLIGHT_MMIN (overrides profile; strict 30 / relaxed 60),
#      CLAUDE_TRANSCRIPT_PATH (transcript default)
# Reads/writes: .claude/state/supervisor-progress.json
# Exit: 0 normal; 2 on STALL-ALERT (caller MUST act, not idle).

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || true

STATE=".claude/state/supervisor-progress.json"
# ── autonomy profile (C6 pilot) ───────────────────────────────────────────────
# PWT_AUTONOMY_PROFILE in {strict,relaxed}; unset/unknown => strict == byte-for-byte
# today's behavior. The profile supplies FALLBACKS only — an explicitly-set
# STALL_THRESHOLD / PWT_INFLIGHT_MMIN (and the --threshold flag below) always win
# (explicit > profile > strict-default). bash 3.2 safe: plain scalars + case.
_profile="${PWT_AUTONOMY_PROFILE:-strict}"
case "$_profile" in
    relaxed) _def_threshold=4; _def_inflight_mmin=60 ;;
    *)       _def_threshold=2; _def_inflight_mmin=30 ;;  # strict / unset / unknown
esac
THRESHOLD="${STALL_THRESHOLD:-$_def_threshold}"
INFLIGHT_MMIN="${PWT_INFLIGHT_MMIN:-$_def_inflight_mmin}"
TRANSCRIPT="${CLAUDE_TRANSCRIPT_PATH:-}"
SPEC=""
SLUG=""
STATE_EXPLICIT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --slug)       SLUG="${2:-}"; shift 2 ;;
        --state)      STATE="${2:-$STATE}"; STATE_EXPLICIT=1; shift 2 ;;
        --threshold)  THRESHOLD="${2:-$THRESHOLD}"; shift 2 ;;
        --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
        --spec)       SPEC="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
# Slug-scope the snapshot path unless an explicit --state was given. The reader
# (goal-evaluator __antipark_state) resolves the SAME slug-keyed filename, so the
# writer/reader stay in lockstep. Empty slug → legacy global default.
if [ -n "$SLUG" ] && [ "$STATE_EXPLICIT" -eq 0 ]; then
    STATE=".claude/state/supervisor-progress-${SLUG}.json"
fi
mkdir -p "$(dirname "$STATE")" 2>/dev/null || true

# Auto-detect the run's AC source (newest spec/AC-snapshot) when not supplied.
if [ -z "$SPEC" ]; then
    SPEC=$(ls -t .claude/state/plan-w-team-ac-snapshot-*.md 2>/dev/null | head -1 || true)
fi

# ── objective metrics (all user-verifiable) ───────────────────────────────────
main_commits=$(git rev-list --count HEAD 2>/dev/null || echo 0)
open_prs=0
if command -v gh >/dev/null 2>&1; then
    # NB: no `|| echo 0` — under `set -o pipefail` a failing `gh` makes the
    # pipeline exit non-zero even though `wc` already printed 0, so `|| echo 0`
    # would append a SECOND 0 → "0\n0" → broken JSON + integer-compare error.
    open_prs=$(gh pr list --state open --limit 100 2>/dev/null | wc -l | tr -d ' ')
    [ -z "$open_prs" ] && open_prs=0
fi
# AC-PASS count = the run's own finish-line signal (emitted by Step 5/6).
acs_passed=0
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    acs_passed=$(grep -ohE 'AC[0-9]+:[[:space:]]*PASS' "$TRANSCRIPT" 2>/dev/null | grep -oE 'AC[0-9]+' | sort -u | wc -l | tr -d ' ')
fi
# Total ACs = the locked backlog target (anti-drift anchor).
acs_total=0
if [ -n "$SPEC" ] && [ -f "$SPEC" ]; then
    acs_total=$(grep -ohE 'AC[0-9]+' "$SPEC" 2>/dev/null | sort -u | wc -l | tr -d ' ')
fi
backlog=$(( acs_total > acs_passed ? acs_total - acs_passed : 0 ))
backlog_known=0; [ "$acs_total" -gt 0 ] && backlog_known=1
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── previous snapshot (python parser — never grep-on-JSON) ─────────────────────
_rk() {
    python3 -c "import json,sys
try: print(json.load(open('$STATE')).get('$1', 0))
except Exception: print(0)" 2>/dev/null || echo 0
}
had_prev=0; prev_commits=0; prev_acs=0; prev_prs=0; stall_streak=0
if [ -f "$STATE" ]; then
    had_prev=1
    prev_commits=$(_rk mainCommits); prev_acs=$(_rk acsPassed)
    prev_prs=$(_rk openPRs); stall_streak=$(_rk stallStreak)
fi

# ── progress determination ────────────────────────────────────────────────────
progressed=0
[ "$main_commits" -gt "$prev_commits" ] && progressed=1
[ "$acs_passed"  -gt "$prev_acs" ]      && progressed=1
[ "$open_prs"    -ne "$prev_prs" ]      && progressed=1
[ "$had_prev"    -eq 0 ]                && progressed=1   # first run = baseline

# In-flight guard: an agent worktree touched in the last 30 min = work cooking
# (not yet reflected in metrics). Don't mistake that for supervisor idleness.
inflight=$(find .claude/worktrees -maxdepth 1 -type d -name 'agent-*' -mmin "-${INFLIGHT_MMIN}" 2>/dev/null | wc -l | tr -d ' ')

if [ "$progressed" -eq 1 ]; then
    verdict="PROGRESSING"; stall_streak=0
elif [ "${inflight:-0}" -gt 0 ]; then
    verdict="IN-FLIGHT"; stall_streak=0
elif [ "$backlog_known" -eq 1 ] && [ "$backlog" -eq 0 ]; then
    verdict="BACKLOG-CLEAR"; stall_streak=0
elif [ "$backlog_known" -eq 0 ]; then
    # No AC source → cannot assert a backlog exists. Report STALLED-UNKNOWN but
    # never escalate (avoid false alerts on runs without an AC snapshot).
    stall_streak=$((stall_streak + 1)); verdict="STALLED-UNKNOWN"
else
    stall_streak=$((stall_streak + 1))
    if [ "$stall_streak" -ge "$THRESHOLD" ]; then verdict="STALL-ALERT"; else verdict="STALLED"; fi
fi

cat > "$STATE" <<EOF
{
  "ts": "$now",
  "slug": "$SLUG",
  "mainCommits": $main_commits,
  "acsPassed": $acs_passed,
  "acsTotal": $acs_total,
  "backlog": $backlog,
  "backlogKnown": $backlog_known,
  "openPRs": $open_prs,
  "inflight": $inflight,
  "stallStreak": $stall_streak,
  "verdict": "$verdict"
}
EOF

echo "VERDICT: $verdict (stallStreak=$stall_streak)"
echo "  commits=$main_commits (was $prev_commits)  ACs=$acs_passed/$acs_total passing  openPRs=$open_prs (was $prev_prs)  inflight=$inflight"
if [ "$backlog_known" -eq 1 ]; then
    echo "  [anti-drift] backlog=$backlog unmet ACs — pull the next item ONLY from the spec's failing ACs (${SPEC:-?}); never improvise off-target."
else
    echo "  [anti-drift] no AC source found — judging on commits/PRs only; pass --spec to anchor the backlog."
fi
if [ "$verdict" = "STALL-ALERT" ]; then
    echo "🔴 STALL-ALERT: no objective progress for ${stall_streak} ticks and backlog=${backlog}>0."
    echo "ACTION REQUIRED: spawn the next backlog item NOW or escalate a hard-gate to the user."
    echo "Monitoring without action is a FAILURE — do NOT idle, do NOT wait on a perceived ceiling."
    exit 2
fi
exit 0
