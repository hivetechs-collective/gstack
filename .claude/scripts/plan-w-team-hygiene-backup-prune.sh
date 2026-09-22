#!/usr/bin/env bash
# plan-w-team-hygiene-backup-prune.sh — expire old preserve-then-reap backups.
#
# `preserve_then_reap` (plan-w-team-dirty-ignore-lib.sh) writes a backup of a worktree's
# uncommitted delta to `<main checkout>/.claude/state/hygiene-backups/` before a forced
# removal:   <worktree-name>-<YYYYMMDDTHHMMSSZ>.patch | .files/ | .manifest.txt
# Nothing ever expired them. On a busy host 32 backups reached 890 MB in eight days, and a
# stale copy of a consumer script inside one `.files/` tree was picked up by that repo's
# lint and turned its default branch red (cleanscale, 2026-09-21).
#
# A backup exists BECAUSE its content was never committed, so "the lane's PR merged" says
# nothing about whether the backup is still wanted. The only honest retention rule is time
# (plus a size ceiling so a burst cannot fill the disk):
#
#   1. AGE  — a backup older than PWT_HYGIENE_BACKUP_KEEP_DAYS (default 14) expires.
#   2. SIZE — while the directory exceeds PWT_HYGIENE_BACKUP_MAX_MB (default 1024), the
#             OLDEST backups expire first — but never one younger than
#             PWT_HYGIENE_BACKUP_MIN_KEEP_HOURS (default 48). An unmet ceiling is reported.
#   The floor binds BOTH rules and has a HARD minimum of 1 hour (a smaller value is raised to
#   it, and said so): no combination of settings expires the backup a GC run just wrote.
#
# "Older" needs BOTH clocks to agree: the UTC timestamp in the name AND the entry's mtime.
# A freshly restored / touched backup is therefore young.
#
# Dry-run by default (like the worktree GC that calls it); `--execute` to delete.
#
# Usage:
#   plan-w-team-hygiene-backup-prune.sh [--root <main checkout>] [--execute] [--quiet]
#
# Environment:
#   PWT_HYGIENE_BACKUP_KEEP_DAYS        age gate, days (default 14)
#   PWT_HYGIENE_BACKUP_MAX_MB           size ceiling, MB (default 1024; 0 disables the ceiling)
#   PWT_HYGIENE_BACKUP_MIN_KEEP_HOURS   floor neither rule goes below (default 48; hard minimum 1)
#   PWT_DISABLE_HYGIENE_BACKUP_PRUNE=1  no-op
#
# Safety invariants — every uncertainty is a KEEP:
#   • Only DIRECT children of `<root>/.claude/state/hygiene-backups` are considered, and the
#     directory must resolve (realpath) to exactly that path — a symlinked backups dir, state
#     dir or `.claude` is refused outright.
#   • Only names matching `<stem>-<YYYYMMDDTHHMMSSZ>.(patch|files|manifest.txt)` with a
#     parseable timestamp. Anything else is left alone and counted as `unrecognized`.
#   • A symlink entry is never followed and never removed.
#   • Removal never follows symlinks INSIDE a `.files/` tree (they are unlinked, not walked);
#     if this python's rmtree is not symlink-attack resistant, directory backups are KEPT.
#   • An mtime from the future inside a `.files/` tree (copied with `cp -p` from an arbitrary
#     worktree) is ignored as evidence — it must not make one backup immortal. A future NAME or
#     top-level mtime still reads as young → KEEP.
#   • python3 missing, unreadable directory, bad numeric env → nothing is removed.
#   • Always exits 0: a hygiene helper must never fail its caller.
# bash 3.2 compatible.
set -u

[ "${PWT_DISABLE_HYGIENE_BACKUP_PRUNE:-}" = "1" ] && exit 0

ROOT=""
EXECUTE=0
QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)    ROOT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --execute) EXECUTE=1; shift ;;
        --quiet)   QUIET=1; shift ;;
        -h|--help) sed -n '2,51p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         echo "[hygiene-backups] unknown argument: $1" >&2; exit 0 ;;
    esac
done

if [ -z "$ROOT" ]; then
    ROOT="${PWT_PROJECT_ROOT_OVERRIDE:-}"
    if [ -z "$ROOT" ]; then
        COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
        if [ -n "$COMMON_DIR" ]; then
            ROOT="$(cd "$(dirname "$COMMON_DIR")" 2>/dev/null && pwd || echo "")"
        fi
    fi
fi
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 0
command -v python3 >/dev/null 2>&1 || { [ "$QUIET" = "1" ] || echo "[hygiene-backups] python3 unavailable — nothing pruned" >&2; exit 0; }

PWT_HB_ROOT="$ROOT" PWT_HB_EXECUTE="$EXECUTE" PWT_HB_QUIET="$QUIET" python3 - <<'PY' || true
import os, re, shutil, sys, time, calendar

root    = os.environ["PWT_HB_ROOT"]
execute = os.environ.get("PWT_HB_EXECUTE") == "1"
quiet   = os.environ.get("PWT_HB_QUIET") == "1"

def say(msg):
    if not quiet:
        sys.stderr.write("[hygiene-backups] %s\n" % msg)

def num(name, default, lo):
    raw = os.environ.get(name, "")
    if raw == "":
        return default
    try:
        v = float(raw)
    except ValueError:
        return None
    return v if v >= lo else None

keep_days = num("PWT_HYGIENE_BACKUP_KEEP_DAYS", 14.0, 0.0)
max_mb    = num("PWT_HYGIENE_BACKUP_MAX_MB", 1024.0, 0.0)
min_hours = num("PWT_HYGIENE_BACKUP_MIN_KEEP_HOURS", 48.0, 0.0)
if keep_days is None or max_mb is None or min_hours is None:
    say("unusable PWT_HYGIENE_BACKUP_* value — nothing pruned")
    sys.exit(0)
HARD_FLOOR_H = 1.0
if min_hours < HARD_FLOOR_H:
    say("PWT_HYGIENE_BACKUP_MIN_KEEP_HOURS=%g raised to the hard minimum of %g h" % (min_hours, HARD_FLOOR_H))
    min_hours = HARD_FLOOR_H
SAFE_RMTREE = bool(getattr(shutil.rmtree, "avoids_symlink_attacks", False))

bdir = os.path.join(root, ".claude", "state", "hygiene-backups")
if not os.path.isdir(bdir):
    sys.exit(0)
# The directory must BE where it claims to be: no symlink anywhere on the way in.
expected = os.path.join(os.path.realpath(root), ".claude", "state", "hygiene-backups")
if os.path.islink(bdir) or os.path.realpath(bdir) != expected:
    say("refusing: %s does not resolve to itself (symlink on the path) — nothing pruned" % bdir)
    sys.exit(0)

NAME = re.compile(r"^(?P<stem>.+)-(?P<ts>\d{8}T\d{6}Z)\.(?:patch|files|manifest\.txt)$")
now = time.time()
FUTURE_SLACK_S = 300.0

def tree_stat(path):
    """(bytes, newest mtime) without following any symlink."""
    st = os.lstat(path)
    total, newest = st.st_size, st.st_mtime
    if os.path.isdir(path) and not os.path.islink(path):
        for dp, dns, fns in os.walk(path, followlinks=False):
            for n in dns + fns:
                try:
                    s = os.lstat(os.path.join(dp, n))
                except OSError:
                    continue
                total += s.st_size
                # in-tree mtimes are preserved from the source worktree (`cp -p`); one from the
                # future is not evidence of anything and would pin this backup forever
                if s.st_mtime <= now + FUTURE_SLACK_S:
                    newest = max(newest, s.st_mtime)
    return total, newest

try:
    names = sorted(os.listdir(bdir))
except OSError:
    say("cannot list %s — nothing pruned" % bdir)
    sys.exit(0)

groups, unrecognized = {}, 0          # key "<stem>-<ts>" → one backup (patch + files + manifest)
for n in names:
    p = os.path.join(bdir, n)
    m = NAME.match(n)
    if not m or os.path.islink(p):
        unrecognized += 1
        continue
    try:
        named = calendar.timegm(time.strptime(m.group("ts"), "%Y%m%dT%H%M%SZ"))
        size, newest = tree_stat(p)
    except (ValueError, OSError):
        unrecognized += 1
        continue
    g = groups.setdefault("%s-%s" % (m.group("stem"), m.group("ts")), {"paths": [], "bytes": 0, "young": 0.0})
    g["paths"].append(p)
    g["bytes"] += size
    # the YOUNGER of the two clocks decides — both must be old for the backup to be old
    g["young"] = max(g["young"], named, newest)

def age_h(g):
    return (now - g["young"]) / 3600.0

total = sum(g["bytes"] for g in groups.values())
expire, reason = [], {}
for k, g in groups.items():
    # the floor binds the age gate too: KEEP_DAYS=0 must not expire the backup this very
    # GC run wrote a moment ago, which would turn preserve-then-reap into plain reap
    if age_h(g) > max(keep_days * 24.0, min_hours):
        expire.append(k); reason[k] = "older than %g d" % keep_days

cap = max_mb * 1024 * 1024
remaining = total - sum(groups[k]["bytes"] for k in expire)
if cap > 0 and remaining > cap:
    for k in sorted((k for k in groups if k not in reason), key=lambda k: groups[k]["young"]):
        if remaining <= cap:
            break
        if age_h(groups[k]) <= min_hours:
            continue
        expire.append(k); reason[k] = "over the %g MB ceiling (oldest first)" % max_mb
        remaining -= groups[k]["bytes"]

removed = freed = 0
for k in sorted(expire, key=lambda k: groups[k]["young"]):
    g = groups[k]
    if not execute:
        say("[dry-run] would remove %s (%.1f MB, %.0f h old — %s)" % (k, g["bytes"] / 1048576.0, age_h(g), reason[k]))
        removed += 1; freed += g["bytes"]
        continue
    ok = True
    for p in g["paths"]:
        try:
            if os.path.islink(p) or os.path.dirname(p) != bdir:
                ok = False; continue                      # re-check at the moment of deletion
            if os.path.isdir(p):
                if not SAFE_RMTREE:
                    ok = False
                    say("this python3's rmtree is not symlink-attack resistant — keeping %s" % p)
                    continue
                shutil.rmtree(p)                          # never follows symlinks inside
            else:
                os.unlink(p)
        except OSError as e:
            ok = False
            say("could not remove %s: %s" % (p, e))
    if ok:
        removed += 1; freed += g["bytes"]

left = total - freed
if removed or unrecognized or (cap > 0 and left > cap):
    say("%s %d backup(s), %.1f MB; %d kept, %.1f MB%s" % (
        "removed" if execute else "would remove", removed, freed / 1048576.0,
        len(groups) - removed, left / 1048576.0,
        ("; %d unrecognized entr%s left alone" % (unrecognized, "y" if unrecognized == 1 else "ies")) if unrecognized else ""))
if cap > 0 and left > cap:
    # reported even with --quiet: this is the condition a human has to look at
    sys.stderr.write("[hygiene-backups] ⚠ still %.0f MB > %g MB ceiling — every remaining backup is younger than %g h\n"
                     % (left / 1048576.0, max_mb, min_hours))
PY
exit 0
