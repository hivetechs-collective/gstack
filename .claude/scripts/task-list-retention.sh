#!/usr/bin/env bash
# task-list-retention.sh — keep a SHARED Claude Code task list small.
#
# WHY (2026-09-21, cleanscale): the shell wrapper keys the task list on the REPO NAME
# (CLAUDE_CODE_TASK_LIST_ID=<repo>), so every session in a repo shares one list at
# ~/.claude/tasks/<repo>/ and nothing ever prunes it. With Task tools on, Claude Code
# injects a `task_reminder` carrying the WHOLE list. cleanscale's had 969 tasks (844
# completed, 796 of them >30 days old): each reminder cost ~39K tokens, ~2.5 landed per
# compaction cycle, and the lead session compacted every 18–22 min instead of every hour.
#
# WHAT IT DOES — it ARCHIVES (mv), it never deletes. Everything it moves is recoverable
# from ~/.claude/tasks-archive/<list>/<YYYY-MM-DD>/{completed,stale-open,over-cap}/.
#   1. completed tasks untouched for  PWT_TASK_COMPLETED_KEEP_DAYS (default 2)  → completed/
#   2. open tasks untouched for       PWT_TASK_STALE_OPEN_DAYS     (default 30) → stale-open/
#   3. if the list is still over      PWT_TASK_LIST_CAP            (default 150),
#      the OLDEST remaining completed tasks                                     → over-cap/
#      Live open work is never moved to meet the cap; an unmeetable cap is REPORTED.
#
# NEVER moved: `.highwatermark` / `.lock` (Claude Code's own id counter + lock), the task
# with the highest numeric id (so a list without a highwatermark can never reuse an id),
# any task a KEPT open task still names in blocks/blockedBy, any file that is not
# `<digits>.json`, anything unparseable, anything that is not a regular file.
#
# Usage:
#   task-list-retention.sh                 # list = $CLAUDE_CODE_TASK_LIST_ID, else repo basename
#   task-list-retention.sh --list <id>     # explicit list id ([A-Za-z0-9._-]+ only)
#   task-list-retention.sh --dry-run       # report, move nothing
#   task-list-retention.sh --quiet         # no output unless something moved or the cap is unmet
#   CLAUDE_TASKS_DIR / CLAUDE_TASKS_ARCHIVE_DIR override the two roots (tests).
#   PWT_DISABLE_TASK_LIST_RETENTION=1      # kill switch
#
# Exit code: always 0 (best-effort hygiene; launched detached from session-start.sh).
# bash 3.2 compatible; the JSON work is python3 (already a hard dependency of the status line).

set -u

[ "${PWT_DISABLE_TASK_LIST_RETENTION:-}" = "1" ] && exit 0

LIST_ID="${CLAUDE_CODE_TASK_LIST_ID:-}"
DRY_RUN=0
QUIET=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --list) shift; LIST_ID="${1:-}" ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --quiet|-q) QUIET=1 ;;
        --help|-h) sed -nE 's/^# ?//; 2,/^$/p' "$0" | head -34; exit 0 ;;
        *) ;;  # ignore unknown args (best-effort caller)
    esac
    shift
done

if [ -z "$LIST_ID" ]; then
    TOP="$(command git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$TOP" ] && LIST_ID="$(basename "$TOP")"
fi
# The list id becomes a path component under two roots: refuse anything that could climb.
case "$LIST_ID" in
    ""|.|..|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
# Per-session lists (session-<sid>) are private to one session and die with it.
case "$LIST_ID" in session-*) exit 0 ;; esac

TASKS_ROOT="${CLAUDE_TASKS_DIR:-$HOME/.claude/tasks}"
ARCHIVE_ROOT="${CLAUDE_TASKS_ARCHIVE_DIR:-$HOME/.claude/tasks-archive}"
LIST_DIR="$TASKS_ROOT/$LIST_ID"
[ -d "$LIST_DIR" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

LIST_DIR="$LIST_DIR" ARCHIVE_DIR="$ARCHIVE_ROOT/$LIST_ID" DRY_RUN="$DRY_RUN" QUIET="$QUIET" \
KEEP_DAYS="${PWT_TASK_COMPLETED_KEEP_DAYS:-2}" STALE_DAYS="${PWT_TASK_STALE_OPEN_DAYS:-30}" \
CAP="${PWT_TASK_LIST_CAP:-150}" python3 - <<'PY' || true
import json, os, re, sys, time, datetime

list_dir, archive_dir = os.environ["LIST_DIR"], os.environ["ARCHIVE_DIR"]
dry, quiet = os.environ["DRY_RUN"] == "1", os.environ["QUIET"] == "1"

def num(name, default):
    try:
        v = float(os.environ.get(name, ""))
        return v if v >= 0 else default
    except ValueError:
        return default

keep_s, stale_s, cap = num("KEEP_DAYS", 2) * 86400, num("STALE_DAYS", 30) * 86400, int(num("CAP", 150))
now = time.time()
OPEN = {"pending", "in_progress"}

tasks = {}                                   # id -> dict(path, status, mtime, refs)
for name in os.listdir(list_dir):
    if not re.fullmatch(r"[0-9]+\.json", name):
        continue                             # .highwatermark, .lock, anything foreign: untouched
    path = os.path.join(list_dir, name)
    if os.path.islink(path) or not os.path.isfile(path):
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        st = os.stat(path)
    except (OSError, ValueError):
        continue                             # unreadable / unparseable: keep
    if not isinstance(d, dict) or not isinstance(d.get("status"), str):
        continue
    refs = set()
    for key in ("blocks", "blockedBy"):
        v = d.get(key)
        if isinstance(v, list):
            refs.update(str(x) for x in v)
    tasks[name[:-5]] = dict(path=path, status=d["status"], mtime=st.st_mtime, refs=refs)

if not tasks:
    sys.exit(0)

max_id = max(tasks, key=int)
moves = {}                                   # id -> bucket

for tid, t in tasks.items():
    age = now - t["mtime"]
    if t["status"] == "completed" and age >= keep_s:
        moves[tid] = "completed"
    elif t["status"] in OPEN and age >= stale_s:
        moves[tid] = "stale-open"

def protect():
    """Drop from `moves` the id-anchor and anything a KEPT open task still references.
    Iterates: un-moving one task can make it a keeper whose own references matter."""
    changed = True
    while changed:
        changed = False
        moves.pop(max_id, None)
        pinned = set()
        for tid, t in tasks.items():
            if tid not in moves and t["status"] in OPEN:
                pinned |= t["refs"]
        for tid in list(moves):
            if tid in pinned:
                del moves[tid]; changed = True

protect()

remaining = [tid for tid in tasks if tid not in moves]
if len(remaining) > cap:
    spare = sorted((tid for tid in remaining if tasks[tid]["status"] == "completed"),
                   key=lambda tid: tasks[tid]["mtime"])
    for tid in spare[: len(remaining) - cap]:
        moves[tid] = "over-cap"
    protect()
    remaining = [tid for tid in tasks if tid not in moves]

day = datetime.date.today().isoformat()
moved = {}
for tid, bucket in sorted(moves.items(), key=lambda kv: int(kv[0])):
    dest_dir = os.path.join(archive_dir, day, bucket)
    dest = os.path.join(dest_dir, tid + ".json")
    if dry:
        moved[bucket] = moved.get(bucket, 0) + 1
        continue
    try:
        os.makedirs(dest_dir, exist_ok=True)
        if os.path.exists(dest):             # same id archived earlier today: never overwrite
            dest = os.path.join(dest_dir, "%s.%d.json" % (tid, int(now)))
        os.rename(tasks[tid]["path"], dest)  # same filesystem ($HOME/.claude): atomic
        moved[bucket] = moved.get(bucket, 0) + 1
    except OSError:
        remaining.append(tid)                # could not move: it is still in the list

total = sum(moved.values())
unmet = len(remaining) > cap
if (total or unmet) or not quiet:
    verb = "would archive" if dry else "archived"
    detail = ", ".join("%d %s" % (n, b) for b, n in sorted(moved.items())) or "nothing"
    print("🗂  task list %s: %s %s → %d left (cap %d)%s" % (
        os.path.basename(list_dir), verb, detail, len(remaining), cap,
        "" if dry or not total else " · archive: " + os.path.join(archive_dir, day)))
    if unmet:
        print("   ⚠ still over the cap: %d live open task(s) are never auto-archived — close or "
              "delete the ones that are done" % sum(1 for t in remaining if tasks[t]["status"] in OPEN))
PY

exit 0
