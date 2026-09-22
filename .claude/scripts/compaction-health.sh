#!/usr/bin/env bash
# compaction-health.sh — regression alarm for "the session compacts too often / resumes too slowly".
#
# WHY (2026-09-21, cleanscale): a lead session ran for THREE DAYS compacting every 18–22 min
# (normal: ~hourly) and sitting 6–10 min in "Running SessionStart hooks…" after each one —
# about half its wall-clock — and nothing said so. Both causes were ordinary growth crossing
# a cliff: a never-pruned shared task list (969 items ≈ 39K tokens per task_reminder) and a
# janitor that had gone quadratic over a ~1,350-entry state dir. Each left a clear signal in
# the session transcript the whole time. This script reads those signals.
#
# CHECKS (each threshold is an env override; a finding needs evidence inside the window):
#   C1 compactions in any rolling hour      > PWT_CH_MAX_COMPACTIONS_PER_HOUR   (3)
#   C2 a SessionStart:compact hook took     > PWT_CH_MAX_COMPACT_HOOK_S         (30)
#   C3 task_reminder itemCount              > PWT_CH_MAX_TASK_REMINDER_ITEMS    (150)
#   C4 context right after a compaction     > PWT_CH_MAX_POST_COMPACT_CONTEXT   (110000)
#        first API call after the boundary: input + cache_read + cache_creation tokens.
#        compactMetadata.postTokens is only the SUMMARY (~18K); the real floor also carries
#        the system prompt, tools, CLAUDE.md, hook output. Healthy ≈ 77–82K, regressed ≈ 120K.
#   C5 top-level entries in .claude/state   > PWT_CH_MAX_STATE_ENTRIES          (3000)
#
# READ-ONLY over transcripts. Writes exactly two files, both under .claude/state/:
#   compaction-health.json   latest verdict (schema compaction-health/1)
#   compaction-health.txt    human banner — present ONLY while the verdict is `alarm`;
#                            session-start.sh cats it, so surfacing costs no scan.
#
# Usage:
#   compaction-health.sh                  # scan, write verdict, print it
#   compaction-health.sh --quiet          # print only when there are findings
#   compaction-health.sh --transcripts D  # scan D instead of this project's transcript dir
#   compaction-health.sh --census         # WRITES NOTHING: what gets injected into context, by
#                                         # attachment type (count, ≈tokens, largest, per hour).
#                                         # Run before and after enabling a CLI feature — see
#                                         # docs/operations/version-uplift.md "Context-cost gate".
#   PWT_CH_WINDOW_HOURS (6)  PWT_CH_TAIL_MB (64: only the tail of each transcript is read —
#   a lead transcript reaches 1 GB)  PWT_DISABLE_COMPACTION_HEALTH=1 (kill switch)
#
# Scope: sessions whose cwd is THIS checkout. Worktree lanes log under their own project dir
# and are short-lived; the alarm is about long-running lead sessions.
# Exit code: always 0 (best-effort; launched detached from session-start.sh).
# bash 3.2 compatible; the parsing is python3 (already a hard dependency of the status line).

set -u

[ "${PWT_DISABLE_COMPACTION_HEALTH:-}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

QUIET=0
CENSUS=0
TRANSCRIPTS=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --quiet|-q) QUIET=1 ;;
        --census) CENSUS=1 ;;
        --transcripts) shift; TRANSCRIPTS="${1:-}" ;;
        --help|-h) sed -nE 's/^# ?//; 2,/^$/p' "$0" | head -40; exit 0 ;;
        *) ;;  # ignore unknown args (best-effort caller)
    esac
    shift
done

PROJECT_ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}}"
STATE_DIR="${STATE_DIR:-$PROJECT_ROOT/.claude/state}"
[ -d "$STATE_DIR" ] || exit 0

PROJECT_ROOT="$PROJECT_ROOT" STATE_DIR="$STATE_DIR" TRANSCRIPTS="$TRANSCRIPTS" QUIET="$QUIET" CENSUS="$CENSUS" \
python3 - <<'PY' || true
import datetime, glob, json, os, re, sys, tempfile, time

env = os.environ
state_dir, quiet = env["STATE_DIR"], env["QUIET"] == "1"

def num(name, default):
    try:
        v = float(env.get(name, ""))
        return v if v > 0 else default
    except ValueError:
        return default

MAX_PER_HOUR = num("PWT_CH_MAX_COMPACTIONS_PER_HOUR", 3)
MAX_HOOK_S   = num("PWT_CH_MAX_COMPACT_HOOK_S", 30)
MAX_ITEMS    = num("PWT_CH_MAX_TASK_REMINDER_ITEMS", 150)
MAX_FLOOR    = num("PWT_CH_MAX_POST_COMPACT_CONTEXT", 110000)
MAX_ENTRIES  = num("PWT_CH_MAX_STATE_ENTRIES", 3000)
WINDOW_S     = num("PWT_CH_WINDOW_HOURS", 6) * 3600
TAIL_BYTES   = int(num("PWT_CH_TAIL_MB", 64) * 1024 * 1024)

tdir = env["TRANSCRIPTS"] or os.path.join(
    env.get("CLAUDE_PROJECTS_DIR") or os.path.expanduser("~/.claude/projects"),
    re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(env["PROJECT_ROOT"])))

now = time.time()
cut = now - WINDOW_S

def epoch(ts):
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None

def clock(t):  # local, 12-hour — what a person reads (no %-m: not portable)
    d = datetime.datetime.fromtimestamp(t)
    return "%s %d/%d %d:%02d%s" % (d.strftime("%a"), d.month, d.day, d.hour % 12 or 12, d.minute,
                                    "am" if d.hour < 12 else "pm")

if env.get("CENSUS") == "1":
    # What is injected into the conversation, by attachment type. `rendered` is the text the
    # model actually receives; an attachment without it costs nothing. ≈tokens = chars / 4.
    rows, span = {}, [now, 0]
    for path in sorted(glob.glob(os.path.join(tdir, "*.jsonl"))):
        try:
            st = os.stat(path)
            if st.st_mtime < cut:
                continue
            with open(path, "rb") as fh:
                if st.st_size > TAIL_BYTES:
                    fh.seek(st.st_size - TAIL_BYTES)
                    fh.readline()
                for raw in fh:
                    if b'"type":"attachment"' not in raw:
                        continue
                    try:
                        d = json.loads(raw)
                    except ValueError:
                        continue
                    att = d.get("attachment") if isinstance(d, dict) else None
                    t = epoch(d.get("timestamp")) if isinstance(d, dict) else None
                    if not isinstance(att, dict) or d.get("isSidechain") or t is None or t < cut:
                        continue
                    key = str(att.get("type"))
                    if att.get("hookName"):
                        key += " [%s]" % att["hookName"]
                    rendered = d.get("rendered") if isinstance(d.get("rendered"), list) else []
                    chars = sum(len(r.get("content") or "") for r in rendered if isinstance(r, dict))
                    r = rows.setdefault(key, [0, 0, 0])
                    r[0] += 1; r[1] += chars; r[2] = max(r[2], chars)
                    span[0], span[1] = min(span[0], t), max(span[1], t)
        except OSError:
            continue
    hours = max((span[1] - span[0]) / 3600.0, 1 / 60.0) if rows else 0
    print("context injection census — %s — last %g h (%.1f h of activity)" % (tdir, WINDOW_S / 3600, hours))
    print("%10s %7s %11s %12s  %s" % ("≈tokens", "count", "≈tok/hour", "largest ≈tok", "attachment type"))
    for key, (n, chars, big) in sorted(rows.items(), key=lambda kv: -kv[1][1]):
        print("%10d %7d %11d %12d  %s" % (chars // 4, n, chars / 4 / hours, big // 4, key))
    if not rows:
        print("   (no attachments in the window)")
    sys.exit(0)

M_COMPACT = b'"subtype":"compact_boundary"'
M_HOOK    = b'"hookName":"SessionStart:compact"'
M_TASK    = b'"type":"task_reminder"'
M_USAGE   = b'"usage"'

findings = []
def find(code, sid, value, limit, at, message):
    findings.append(dict(code=code, session=sid, value=value, threshold=limit,
                         at=clock(at) if at else None, message=message))

scanned = 0
for path in sorted(glob.glob(os.path.join(tdir, "*.jsonl"))):
    try:
        st = os.stat(path)
    except OSError:
        continue
    if st.st_mtime < cut:
        continue
    scanned += 1
    sid = os.path.basename(path)[:8]
    compactions, worst_hook, worst_items, worst_floor = [], (0, None), (0, None), (0, None)
    awaiting_floor = None
    try:
        with open(path, "rb") as fh:
            if st.st_size > TAIL_BYTES:
                fh.seek(st.st_size - TAIL_BYTES)
                fh.readline()                      # drop the partial line
            for raw in fh:
                is_c, is_h, is_t = M_COMPACT in raw, M_HOOK in raw, M_TASK in raw
                is_u = awaiting_floor is not None and M_USAGE in raw
                if not (is_c or is_h or is_t or is_u):
                    continue
                try:
                    d = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(d, dict) or d.get("isSidechain"):
                    continue
                t = epoch(d.get("timestamp"))
                if t is None or t < cut:
                    continue
                att = d.get("attachment") if isinstance(d.get("attachment"), dict) else {}
                if d.get("type") == "system" and d.get("subtype") == "compact_boundary":
                    compactions.append(t)
                    awaiting_floor = t
                elif att.get("type") == "hook_success" and att.get("hookName") == "SessionStart:compact":
                    ms = att.get("durationMs")
                    if isinstance(ms, (int, float)) and ms / 1000.0 > worst_hook[0]:
                        worst_hook = (ms / 1000.0, t, str(att.get("command", ""))[-60:])
                elif att.get("type") == "task_reminder":
                    n = att.get("itemCount")
                    if isinstance(n, int) and n > worst_items[0]:
                        worst_items = (n, t)
                elif is_u and d.get("type") == "assistant":
                    u = (d.get("message") or {}).get("usage") or {}
                    total = sum(u.get(k) or 0 for k in
                                ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                    if total > 0:
                        if total > worst_floor[0]:
                            worst_floor = (total, awaiting_floor)
                        awaiting_floor = None
    except OSError:
        continue

    # C1: densest rolling hour
    compactions.sort()
    best, best_at, j = 0, None, 0
    for i, t in enumerate(compactions):
        while t - compactions[j] > 3600:
            j += 1
        if i - j + 1 > best:
            best, best_at = i - j + 1, t
    if best > MAX_PER_HOUR:
        find("C1", sid, best, MAX_PER_HOUR, best_at,
             "%d compactions inside one hour (limit %d) — something is filling the context too fast" % (best, MAX_PER_HOUR))
    if worst_hook[0] > MAX_HOOK_S:
        find("C2", sid, round(worst_hook[0]), MAX_HOOK_S, worst_hook[1],
             "a SessionStart hook took %d s after a compaction (limit %d s): …%s" % (worst_hook[0], MAX_HOOK_S, worst_hook[2]))
    if worst_items[0] > MAX_ITEMS:
        find("C3", sid, worst_items[0], MAX_ITEMS, worst_items[1],
             "task_reminder carried %d tasks (limit %d) — run .claude/scripts/task-list-retention.sh" % (worst_items[0], MAX_ITEMS))
    if worst_floor[0] > MAX_FLOOR:
        find("C4", sid, worst_floor[0], MAX_FLOOR, worst_floor[1],
             "context was %dK right after a compaction (limit %dK) — the fixed per-turn load has grown" % (worst_floor[0] // 1000, MAX_FLOOR // 1000))

try:
    entries = sum(1 for _ in os.scandir(state_dir))
except OSError:
    entries = 0
if entries > MAX_ENTRIES:
    find("C5", None, entries, MAX_ENTRIES, None,
         ".claude/state holds %d entries (limit %d) — check what stopped being reaped" % (entries, MAX_ENTRIES))

status = "alarm" if findings else "ok"
verdict = dict(schema="compaction-health/1", status=status,
               checked_at=datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
               window_hours=WINDOW_S / 3600, transcripts_dir=tdir, transcripts_scanned=scanned,
               state_entries=entries, findings=findings)

lines = []
if findings:
    lines.append("⚠  COMPACTION HEALTH — %d finding(s) in the last %g h (checked %s)" % (len(findings), WINDOW_S / 3600, clock(now)))
    for f in findings:
        where = " · session %s" % f["session"] if f["session"] else ""
        when = " · %s" % f["at"] if f["at"] else ""
        lines.append("   %s %s%s%s" % (f["code"], f["message"], where, when))
    lines.append("   details: .claude/state/compaction-health.json · docs/operations/compaction-health.md")

def atomic(path, text):
    fd, tmp = tempfile.mkstemp(prefix=".compaction-health.", dir=state_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except OSError:
        try: os.unlink(tmp)
        except OSError: pass

atomic(os.path.join(state_dir, "compaction-health.json"), json.dumps(verdict, indent=2) + "\n")
banner = os.path.join(state_dir, "compaction-health.txt")
if findings:
    atomic(banner, "\n".join(lines) + "\n")
else:
    try: os.unlink(banner)
    except OSError: pass

if findings:
    print("\n".join(lines))
elif not quiet:
    print("✓ compaction health ok — %d transcript(s) in the last %g h, %d state entries" % (scanned, WINDOW_S / 3600, entries))
PY

exit 0
