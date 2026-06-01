#!/usr/bin/env bash
# pwt-manifest.sh — canonical, main-checkout-relative run manifest for /plan-w-team.
#
# THE PROBLEM THIS SOLVES
# -----------------------
# A /plan-w-team worker runs inside a worktree under .claude/worktrees/<name>/
# and writes its live goal/fleet/stage state INTO that worktree's .claude/state/.
# A supervisor or human dashboard polling the MAIN checkout's .claude/state/ sees
# only the spawn registry (written to origin), never the live stage — the
# "founder's view is blind to live stage" gap. There is also no single artifact
# that joins {run, stage, strategy, tasks, builder roster} for a human reader.
#
# This helper writes ONE canonical manifest to the MAIN checkout's .claude/state/
# regardless of whether it is called from a worktree or the main checkout (the
# path is resolved via `git --git-common-dir`). The worker updates it at each
# lifecycle stage; readers (`pwt-status.sh`, the supervisor poll, a human) read
# one stable place. Worktree-local lifecycle state is left exactly where it is —
# the manifest references the worktree so a reader can still drill in.
#
# Manifest path:      <MAIN>/.claude/state/plan-w-team-manifest-<slug>.json
# Stage-event stream: <MAIN>/.claude/state/plan-w-team-stage-events-<slug>.jsonl
#
# Schema (plan-w-team-manifest/v1):
#   { schema, slug, run_sid, worktree_path, strategy, current_stage,
#     stage_updated_at, builder_count, tasks:[{id,status,owner_builder_sid,worktree}],
#     started_at, updated_at, terminal_state, terminal_reason }
#
# Subcommands:
#   init  --slug S --run-sid R [--worktree W] [--strategy ST] [--stage STG]
#   set   --slug S [--stage STG] [--strategy ST] [--worktree W] [--builders N]
#                  [--terminal T] [--terminal-reason R] [--run-sid R]
#   task  --slug S --id T --status pending|running|done|failed [--owner SID] [--worktree W]
#   read  --slug S            (emit the manifest JSON; exit 3 if absent)
#   path  --slug S            (print the resolved manifest path)
#   list                      (one line per manifest: slug stage strategy builders terminal)
#
# === FAIL-OPEN CONTRACT ===
# This is observability, NEVER a gate. Every failure path exits 0 (except `read`
# missing → 3, and usage error → 2) so a writer call can never block the
# lifecycle. Kill switch: PLAN_W_TEAM_MANIFEST_DISABLE=1 → no-op exit 0.
#
# Spec: docs/specs/pwt-run-manifest.md
# Tests: .claude/scripts/pwt-manifest.test.sh
# Readers: pwt-status.sh, plan-w-team-fleet-query.sh, supervisor-protocol.md

set -u

if [ "${PLAN_W_TEAM_MANIFEST_DISABLE:-0}" = "1" ]; then
    exit 0
fi

SCHEMA="plan-w-team-manifest/v1"

# ─── resolve the MAIN checkout (never a worktree) ─────────────────────────────
# git-common-dir from a worktree points at <main>/.git; its dirname is the main
# checkout. From the main checkout it is ".git" → dirname is the main checkout.
# Fall back to CLAUDE_PROJECT_DIR, then script-relative ../.. .
__resolve_main_checkout() {
    local cdir mc
    cdir="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
    if [ -n "$cdir" ]; then
        case "$cdir" in
            /*) mc="$(dirname "$cdir")" ;;
            *)  mc="$(dirname "$(realpath "$cdir" 2>/dev/null || echo "$PWD/$cdir")")" ;;
        esac
    fi
    if [ -z "${mc:-}" ] || [ ! -d "$mc/.claude" ]; then
        mc="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
    fi
    printf '%s' "$mc"
}

# PWT_MANIFEST_STATE_DIR lets a caller that already resolved the correct origin
# state dir (e.g. pwt-goal.sh's supervisor-goal mirror, where the origin repo may
# differ from $PWD) force the target. Otherwise resolve the main checkout from CWD.
if [ -n "${PWT_MANIFEST_STATE_DIR:-}" ]; then
    STATE_DIR="$PWT_MANIFEST_STATE_DIR"
    MAIN_CHECKOUT="$(cd "$STATE_DIR/../.." 2>/dev/null && pwd || echo "$STATE_DIR")"
else
    MAIN_CHECKOUT="$(__resolve_main_checkout)"
    STATE_DIR="$MAIN_CHECKOUT/.claude/state"
fi

# Ensure the manifest + stage-event patterns are gitignored in the MAIN checkout
# (gitignore-on-write — these are per-run machine state, never committed). Mirrors
# how the rest of the plan-w-team state files are kept out of git.
__ensure_gitignored() {
    local gi="$MAIN_CHECKOUT/.gitignore"
    [ -d "$MAIN_CHECKOUT" ] || return 0
    grep -qF '.claude/state/plan-w-team-manifest-' "$gi" 2>/dev/null && return 0
    {
        printf '\n# /plan-w-team canonical run manifest + stage-event stream (per-run, local only)\n'
        printf '%s\n' '.claude/state/plan-w-team-manifest-*.json'
        printf '%s\n' '.claude/state/plan-w-team-stage-events-*.jsonl'
    } >> "$gi" 2>/dev/null || true
}

ts_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ─── arg parsing ──────────────────────────────────────────────────────────────
SUB="${1:-}"
[ -n "$SUB" ] && shift || true

SLUG=""; RUN_SID=""; WORKTREE=""; STRATEGY=""; STAGE=""; BUILDERS=""
TERMINAL=""; TERMINAL_REASON=""; TASK_ID=""; TASK_STATUS=""; TASK_OWNER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --slug)            SLUG="${2:-}"; shift 2 ;;
        --run-sid)         RUN_SID="${2:-}"; shift 2 ;;
        --worktree)        WORKTREE="${2:-}"; shift 2 ;;
        --strategy)        STRATEGY="${2:-}"; shift 2 ;;
        --stage)           STAGE="${2:-}"; shift 2 ;;
        --builders)        BUILDERS="${2:-}"; shift 2 ;;
        --terminal)        TERMINAL="${2:-}"; shift 2 ;;
        --terminal-reason) TERMINAL_REASON="${2:-}"; shift 2 ;;
        --id)              TASK_ID="${2:-}"; shift 2 ;;
        --status)          TASK_STATUS="${2:-}"; shift 2 ;;
        --owner)           TASK_OWNER="${2:-}"; shift 2 ;;
        -h|--help)         SUB="help"; shift ;;
        *)                 shift ;;
    esac
done

usage() {
    sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
}

# All JSON read-modify-write goes through python3 for safe escaping + atomicity.
if ! command -v python3 >/dev/null 2>&1; then
    # No python3 → fail-open for writers, but `read`/`list` cannot work.
    case "$SUB" in
        read|list) echo "pwt-manifest: python3 required for $SUB" >&2; exit 0 ;;
        *) exit 0 ;;
    esac
fi

manifest_path() { printf '%s/plan-w-team-manifest-%s.json' "$STATE_DIR" "$1"; }
events_path()   { printf '%s/plan-w-team-stage-events-%s.jsonl' "$STATE_DIR" "$1"; }

# python helper: load-or-init manifest, apply a JSON patch + optional task op,
# write atomically (temp + os.replace). Args: <path> <schema> <now> <patch_json> <task_json>
__apply() {
    local mpath="$1" patch="$2" taskj="$3" now; now="$(ts_now)"
    MANIFEST_PATH="$mpath" SCHEMA="$SCHEMA" NOW="$now" PATCH="$patch" TASKOP="$taskj" python3 - <<'PY'
import json, os, sys, tempfile
path   = os.environ["MANIFEST_PATH"]
schema = os.environ["SCHEMA"]
now    = os.environ["NOW"]
patch  = json.loads(os.environ.get("PATCH") or "{}")
taskop = json.loads(os.environ.get("TASKOP") or "null")

doc = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            doc = json.load(f) or {}
    except Exception:
        doc = {}

doc.setdefault("schema", schema)
doc.setdefault("tasks", [])
doc.setdefault("started_at", now)
doc.setdefault("terminal_state", None)

# Apply scalar patch (skip empty strings so we never clobber with blanks).
for k, v in patch.items():
    if v == "" or v is None:
        continue
    if k == "current_stage":
        doc["current_stage"] = v
        doc["stage_updated_at"] = now
    else:
        doc[k] = v

# Apply task upsert.
if isinstance(taskop, dict) and taskop.get("id"):
    tasks = doc.get("tasks") or []
    found = False
    for t in tasks:
        if t.get("id") == taskop["id"]:
            for kk in ("status", "owner_builder_sid", "worktree"):
                if taskop.get(kk) not in (None, ""):
                    t[kk] = taskop[kk]
            found = True
            break
    if not found:
        tasks.append({
            "id": taskop["id"],
            "status": taskop.get("status") or "pending",
            "owner_builder_sid": taskop.get("owner_builder_sid"),
            "worktree": taskop.get("worktree"),
        })
    doc["tasks"] = tasks

doc["updated_at"] = now

d = os.path.dirname(path)
try:
    os.makedirs(d, exist_ok=True)
except Exception:
    pass
fd, tmp = tempfile.mkstemp(dir=d, prefix=".pwt-manifest.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
    sys.exit(0)
PY
}

# Build a scalar-patch JSON from the parsed flags (only set keys are included).
__build_patch() {
    SLUG="$SLUG" RUN_SID="$RUN_SID" WORKTREE="$WORKTREE" STRATEGY="$STRATEGY" \
    STAGE="$STAGE" BUILDERS="$BUILDERS" TERMINAL="$TERMINAL" TREASON="$TERMINAL_REASON" \
    python3 - <<'PY'
import json, os
p = {}
def put(k, env, cast=None):
    v = os.environ.get(env, "")
    if v == "": return
    if cast == "int":
        try: v = int(v)
        except Exception: return
    p[k] = v
put("slug", "SLUG")
put("run_sid", "RUN_SID")
put("worktree_path", "WORKTREE")
put("strategy", "STRATEGY")
put("current_stage", "STAGE")
put("builder_count", "BUILDERS", "int")
put("terminal_state", "TERMINAL")
put("terminal_reason", "TREASON")
print(json.dumps(p))
PY
}

__append_stage_event() {
    local epath="$1"
    [ -d "$(dirname "$epath")" ] || mkdir -p "$(dirname "$epath")" 2>/dev/null || return 0
    # Backfill run_sid from the manifest when not supplied on this call, so the
    # event stream is always complete regardless of which flag set the stage.
    SLUG="$SLUG" STAGE="$STAGE" RUN_SID="$RUN_SID" TS="$(ts_now)" \
    MPATH="$(manifest_path "$SLUG")" python3 - "$epath" <<'PY' 2>/dev/null || true
import json, os, sys
rsid = os.environ.get("RUN_SID","")
if not rsid:
    try:
        rsid = (json.load(open(os.environ["MPATH"])) or {}).get("run_sid","") or ""
    except Exception:
        rsid = ""
row = {"ts": os.environ["TS"], "slug": os.environ.get("SLUG",""),
       "stage": os.environ.get("STAGE",""), "run_sid": rsid}
with open(sys.argv[1], "a") as f:
    f.write(json.dumps(row) + "\n")
PY
}

case "$SUB" in
    help|"")
        usage; [ "$SUB" = "help" ] && exit 0 || exit 2 ;;

    init|set)
        [ -z "$SLUG" ] && { echo "pwt-manifest $SUB: --slug required" >&2; exit 0; }
        __ensure_gitignored
        PATCH="$(__build_patch)"
        __apply "$(manifest_path "$SLUG")" "$PATCH" "null"
        # A stage change emits a transition event (structured stream — no ANSI grep).
        [ -n "$STAGE" ] && __append_stage_event "$(events_path "$SLUG")"
        exit 0 ;;

    task)
        [ -z "$SLUG" ] && { echo "pwt-manifest task: --slug required" >&2; exit 0; }
        [ -z "$TASK_ID" ] && { echo "pwt-manifest task: --id required" >&2; exit 0; }
        __ensure_gitignored
        TASKJSON=$(TASK_ID="$TASK_ID" TASK_STATUS="$TASK_STATUS" TASK_OWNER="$TASK_OWNER" \
            WORKTREE="$WORKTREE" python3 - <<'PY'
import json, os
print(json.dumps({
    "id": os.environ.get("TASK_ID",""),
    "status": os.environ.get("TASK_STATUS",""),
    "owner_builder_sid": os.environ.get("TASK_OWNER",""),
    "worktree": os.environ.get("WORKTREE",""),
}))
PY
)
        __apply "$(manifest_path "$SLUG")" "{}" "$TASKJSON"
        exit 0 ;;

    path)
        [ -z "$SLUG" ] && { echo "pwt-manifest path: --slug required" >&2; exit 2; }
        manifest_path "$SLUG"; echo; exit 0 ;;

    read)
        [ -z "$SLUG" ] && { echo "pwt-manifest read: --slug required" >&2; exit 2; }
        mp="$(manifest_path "$SLUG")"
        [ -f "$mp" ] || { echo "pwt-manifest: no manifest for slug '$SLUG'" >&2; exit 3; }
        cat "$mp"; exit 0 ;;

    list)
        shopt -s nullglob 2>/dev/null || true
        any=0
        for mp in "$STATE_DIR"/plan-w-team-manifest-*.json; do
            any=1
            python3 - "$mp" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print("%-34s %-14s %-22s builders=%-3s %s" % (
    d.get("slug","?"), d.get("current_stage","?"), d.get("strategy","?"),
    d.get("builder_count",0), d.get("terminal_state") or "pending"))
PY
        done
        [ "$any" = "0" ] && echo "No /plan-w-team manifests"
        exit 0 ;;

    *)
        echo "pwt-manifest: unknown subcommand '$SUB'" >&2; usage; exit 2 ;;
esac
