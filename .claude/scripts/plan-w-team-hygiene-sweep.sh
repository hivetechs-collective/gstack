#!/usr/bin/env bash
# plan-w-team-hygiene-sweep.sh — standing pre-flight + supervisor-wake hygiene (AC7)
#
# Composes the existing disk-hygiene GCs into ONE sweep the /plan-w-team supervisor
# (and the top-of-pipeline pre-flight) runs to keep worktree/companion cruft from
# accumulating until it blocks a spawn (the 2026-05-29 67-worktree → ENOSPC failure
# this prevents). It reuses — never reimplements — the layer scripts:
#   * plan-w-team-worktree-gc.sh   (SAFE-PRUNE-MERGED/-IDLE/-PUSHED + orphan dirs)
#   * plan-w-team-companion-gc.sh  (orphan watchers + leaked build daemons, AC5a)
#   * disk-budget.sh               (df headroom signal for the summary)
#
# It emits a ONE-LINE machine summary of what it reaped so the supervisor can surface
# it in its per-wake transcript summary:
#   hygiene-sweep: df_free_gb=<n> worktrees=<n> wt_reaped=<n> companions_reaped=<n> \
#                  orphan_dirs=<n> mode=<dry-run|execute> action=<recommended>
#
# Usage:
#   plan-w-team-hygiene-sweep.sh              # DRY-RUN (default): report, reap nothing
#   plan-w-team-hygiene-sweep.sh --execute    # actually reclaim (passes --execute down)
#   plan-w-team-hygiene-sweep.sh --orphans-ok # also reap ORPHAN-ASK worktrees/dirs
#   plan-w-team-hygiene-sweep.sh --json       # machine-readable rollup
#
# Env:
#   PWT_HYGIENE_SWEEP_DISABLE=1     no-op (exit 0)
#   PWT_HYGIENE_GC                  override path to plan-w-team-worktree-gc.sh (tests)
#   PWT_HYGIENE_COMPANION_GC        override path to plan-w-team-companion-gc.sh (tests)
#   PWT_HYGIENE_DISK_BUDGET         override path to disk-budget.sh (tests)
#
# Fail-open + dry-run by default: this is janitorial; a layer-script error warns and
# is counted as 0, never aborts the sweep or the caller. Safety invariants live in
# the layer scripts (never touch outside .claude/worktrees/, never delete real work).
#
# Spec: docs/specs/worktree-gc-bg-daemon-hardening.md (AC7)
# Tests: .claude/scripts/plan-w-team-hygiene-sweep.test.sh

set -u

[ "${PWT_HYGIENE_SWEEP_DISABLE:-0}" = "1" ] && { echo '{"skipped":true,"reason":"PWT_HYGIENE_SWEEP_DISABLE=1"}'; exit 0; }

MODE_EXECUTE=0; MODE_ORPHANS_OK=0; MODE_JSON=0
while [ $# -gt 0 ]; do
    case "$1" in
        --execute)    MODE_EXECUTE=1; shift ;;
        --orphans-ok) MODE_ORPHANS_OK=1; shift ;;
        --json)       MODE_JSON=1; shift ;;
        --help|-h)    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
GC="${PWT_HYGIENE_GC:-$SELF_DIR/plan-w-team-worktree-gc.sh}"
COMPANION_GC="${PWT_HYGIENE_COMPANION_GC:-$SELF_DIR/plan-w-team-companion-gc.sh}"
DISK_BUDGET="${PWT_HYGIENE_DISK_BUDGET:-$SELF_DIR/disk-budget.sh}"

# Build the shared flag string (zsh/bash-3.2 safe — no arrays needed downstream).
EXEC_FLAG=""; [ "$MODE_EXECUTE" = "1" ] && EXEC_FLAG="--execute"
ORPHAN_FLAG=""; [ "$MODE_ORPHANS_OK" = "1" ] && ORPHAN_FLAG="--orphans-ok"

# ─── worktree GC (reuse; --json for parseable rollup) ──────────────────────
WT_JSON=""
if [ -x "$GC" ]; then
    WT_JSON="$("$GC" $EXEC_FLAG $ORPHAN_FLAG --json 2>/dev/null || echo "")"
fi
WT_SCANNED=0; WT_REAPED=0; ORPHAN_DIRS=0
if [ -n "$WT_JSON" ]; then
    eval "$(printf '%s' "$WT_JSON" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
t=d.get("totals",{}) if isinstance(d,dict) else {}
wts=d.get("worktrees",[]) if isinstance(d,dict) else []
orphan=sum(1 for w in wts if w.get("orphan_dir"))
print("WT_SCANNED=%d" % int(t.get("scanned",0)))
print("WT_REAPED=%d" % int(t.get("removed",0)))
print("ORPHAN_DIRS=%d" % orphan)
' 2>/dev/null)"
fi

# ─── companion GC (reuse; orphan watchers + leaked build daemons) ──────────
COMP_JSON=""
if [ -x "$COMPANION_GC" ]; then
    COMP_JSON="$("$COMPANION_GC" $EXEC_FLAG --json 2>/dev/null || echo "")"
fi
COMP_REAPED=0
if [ -n "$COMP_JSON" ]; then
    COMP_REAPED=$(printf '%s' "$COMP_JSON" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print(int(d.get("totals",{}).get("killed",0)) if isinstance(d,dict) else 0)
' 2>/dev/null || echo 0)
fi

# ─── disk headroom signal (advisory, for the summary) ──────────────────────
DF_FREE="null"; DISK_ACTION="unknown"
if [ -x "$DISK_BUDGET" ]; then
    DB_JSON="$("$DISK_BUDGET" 2>/dev/null || echo "")"
    if [ -n "$DB_JSON" ]; then
        DF_FREE=$(printf '%s' "$DB_JSON" | grep -oE '"free_gb": *[^,}]*' | head -1 | sed -E 's/.*: *//' | tr -d ' ')
        DISK_ACTION=$(printf '%s' "$DB_JSON" | grep -oE '"recommended_action": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
        [ -z "$DF_FREE" ] && DF_FREE="null"
        [ -z "$DISK_ACTION" ] && DISK_ACTION="unknown"
    fi
fi

MODE_LABEL="dry-run"; [ "$MODE_EXECUTE" = "1" ] && MODE_LABEL="execute"

if [ "$MODE_JSON" = "1" ]; then
    DF_FREE="$DF_FREE" DISK_ACTION="$DISK_ACTION" WT_SCANNED="$WT_SCANNED" WT_REAPED="$WT_REAPED" \
    COMP_REAPED="$COMP_REAPED" ORPHAN_DIRS="$ORPHAN_DIRS" MODE_LABEL="$MODE_LABEL" \
    python3 -c '
import json,os
def num(v):
    try: return float(v) if "." in v else int(v)
    except Exception: return None
print(json.dumps({
  "schema":"plan-w-team-hygiene-sweep/v1",
  "mode": os.environ["MODE_LABEL"],
  "df_free_gb": num(os.environ["DF_FREE"]),
  "disk_action": os.environ["DISK_ACTION"],
  "worktrees_scanned": int(os.environ["WT_SCANNED"]),
  "worktrees_reaped": int(os.environ["WT_REAPED"]),
  "companions_reaped": int(os.environ["COMP_REAPED"]),
  "orphan_dirs": int(os.environ["ORPHAN_DIRS"]),
}, indent=2))
'
else
    # The ONE-LINE summary the supervisor surfaces per wake (and pre-flight logs).
    printf 'hygiene-sweep: df_free_gb=%s worktrees=%s wt_reaped=%s companions_reaped=%s orphan_dirs=%s mode=%s action=%s\n' \
        "$DF_FREE" "$WT_SCANNED" "$WT_REAPED" "$COMP_REAPED" "$ORPHAN_DIRS" "$MODE_LABEL" "$DISK_ACTION"
fi
exit 0
