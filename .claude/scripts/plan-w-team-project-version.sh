#!/bin/bash
# plan-w-team-project-version.sh — CONSUMER-project version detect / bump / verify.
#
# The /plan-w-team ship stage (§6d) already mechanizes the SKILL's own VERSION
# (via plan-w-team-next-version.sh). For a CONSUMER feature ship — the project the
# user is actually building — the version bump was PROSE-ONLY: "bump the project's
# own version artifact, head the CHANGELOG with it" with nothing detecting, writing,
# or verifying it. This script is the consumer analog: it detects the project's
# canonical version artifact, bumps it by semver, and verifies a ship actually
# advanced it vs the run-start baseline — so "increment the version, tie it to the
# commit" is enforced mechanically instead of relying on the assistant remembering.
#
# Subcommands:
#   detect [--root DIR]
#       Find the project's version artifact. On success prints three lines
#       (path=<repo-relative> / kind=<npm|cargo|python|dart|plain> / current=<ver>)
#       and exits 0. Exits 10 if no artifact is found.
#
#   bump --kind <patch|minor|major> [--root DIR] [--write]
#       Compute the next semver from the detected current. Prints
#       current=<ver> / next=<ver>. With --write, edits the artifact in place
#       (surgical — only the version declaration is touched, formatting preserved).
#       Exits 0 ok, 10 no artifact, 2 bad kind/usage, 5 write failed.
#
#   verify --baseline <ver> [--root DIR]
#       Compare the artifact's CURRENT version to <baseline> (the value captured
#       at run start). Exits: 0 = advanced (bumped), 20 = unchanged (NOT bumped),
#       21 = went backwards, 10 = no artifact.
#
# Detection priority (first hit wins): package.json → Cargo.toml → pyproject.toml
# → pubspec.yaml → VERSION / version.txt. python3 is the parser/writer; a grep
# fallback covers `detect`/`verify` when python3 is absent (bump --write requires
# python3 and surfaces an error otherwise, so a version file is never half-written).
#
# Exit-code registry (distinct so a caller can branch):
#   0   success
#   2   usage / bad --kind
#   5   bump --write failed (artifact unwritable / parser error)
#   10  no version artifact detected
#   20  verify: version UNCHANGED vs baseline (not bumped)
#   21  verify: version went BACKWARDS vs baseline
#
# bash 3.2 compatible (mac-mini /bin/bash). No `declare -A`, no bash-4 isms.

set -u

SUB="${1:-}"
[ -n "$SUB" ] || { echo "usage: $0 {detect|bump|verify} [opts]" >&2; exit 2; }
shift || true

ROOT=""
KIND=""
BASELINE=""
WRITE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)     ROOT="${2:-}"; shift 2 || { echo "--root needs a value" >&2; exit 2; } ;;
        --kind)     KIND="${2:-}"; shift 2 || { echo "--kind needs a value" >&2; exit 2; } ;;
        --baseline) BASELINE="${2:-}"; shift 2 || { echo "--baseline needs a value" >&2; exit 2; } ;;
        --write)    WRITE=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Resolve the project root (worktree-aware): explicit --root, else git toplevel, else cwd.
if [ -z "$ROOT" ]; then
    ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
[ -d "$ROOT" ] || { echo "root not a directory: $ROOT" >&2; exit 2; }

# ─── python3 core (detect + bump + write) ────────────────────────────────────
# Emits machine-readable KEY=VALUE lines and exits with this script's codes.
run_py() {  # $1 = mode (detect|bump) ; env: PV_ROOT, PV_KIND, PV_WRITE
    PV_ROOT="$ROOT" PV_MODE="$1" PV_KIND="$KIND" PV_WRITE="$WRITE" python3 - <<'PY'
import os, re, sys

root  = os.environ.get("PV_ROOT", ".")
mode  = os.environ.get("PV_MODE", "detect")
kind_arg = os.environ.get("PV_KIND", "")
do_write = os.environ.get("PV_WRITE", "0") == "1"

# (kind, filename, is_regex_filename)
CANDIDATES = [
    ("npm",    "package.json",   False),
    ("cargo",  "Cargo.toml",     False),
    ("python", "pyproject.toml", False),
    ("dart",   "pubspec.yaml",   False),
    ("plain",  "VERSION",        False),
    ("plain",  "version.txt",    False),
]

SEMVER = re.compile(r'^\s*v?(\d+)\.(\d+)\.(\d+)([-+][0-9A-Za-z.\-]+)?\s*$')

def read(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return None

def find_npm(text):
    # Top-level "version": "x.y.z". Match the first plausible one.
    m = re.search(r'"version"\s*:\s*"([^"]+)"', text)
    return m.group(1) if m else None

def _section_version(text, section_names):
    # TOML: find `version = "x"` inside the FIRST matching [section].
    lines = text.splitlines()
    in_target = False
    for ln in lines:
        s = ln.strip()
        if s.startswith("[") and s.endswith("]"):
            sec = s[1:-1].strip()
            in_target = sec in section_names
            continue
        if in_target:
            m = re.match(r'version\s*=\s*"([^"]+)"', s)
            if m:
                return m.group(1)
    return None

def find_cargo(text):
    return _section_version(text, {"package"})

def find_python(text):
    # PEP 621 [project] or poetry [tool.poetry]
    return _section_version(text, {"project", "tool.poetry"})

def find_dart(text):
    m = re.search(r'(?m)^version:\s*([^\s#]+)', text)
    return m.group(1) if m else None

def find_plain(text):
    t = text.strip()
    return t if t else None

FINDERS = {
    "npm": find_npm, "cargo": find_cargo, "python": find_python,
    "dart": find_dart, "plain": find_plain,
}

def detect():
    for kind, fname, _ in CANDIDATES:
        path = os.path.join(root, fname)
        if not os.path.isfile(path):
            continue
        text = read(path)
        if text is None:
            continue
        cur = FINDERS[kind](text)
        if cur:
            rel = os.path.relpath(path, root)
            return kind, rel, cur, path, text
    return None

def bump_semver(ver, kind):
    m = SEMVER.match(ver)
    if not m:
        return None
    major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if kind == "major":
        major, minor, patch = major + 1, 0, 0
    elif kind == "minor":
        minor, patch = minor + 1, 0
    elif kind == "patch":
        patch = patch + 1
    else:
        return None
    return "%d.%d.%d" % (major, minor, patch)

def write_back(kind, path, text, cur, nxt):
    # Surgical replacement of ONLY the version declaration that currently holds
    # `cur`, so a coincidental match of the same string elsewhere is untouched.
    esc = re.escape(cur)
    if kind == "npm":
        new = re.sub(r'("version"\s*:\s*")' + esc + r'(")', r'\g<1>' + nxt + r'\g<2>', text, count=1)
    elif kind in ("cargo", "python"):
        new = re.sub(r'(version\s*=\s*")' + esc + r'(")', r'\g<1>' + nxt + r'\g<2>', text, count=1)
    elif kind == "dart":
        new = re.sub(r'(?m)(^version:\s*)' + esc, r'\g<1>' + nxt, text, count=1)
    elif kind == "plain":
        new = text.replace(cur, nxt, 1) if cur in text else (nxt + "\n")
    else:
        return False
    if new == text and kind != "plain":
        return False
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
        return True
    except Exception:
        return False

d = detect()
if d is None:
    sys.exit(10)
kind, rel, cur, path, text = d

if mode == "detect":
    print("path=%s" % rel)
    print("kind=%s" % kind)
    print("current=%s" % cur)
    sys.exit(0)

if mode == "bump":
    nxt = bump_semver(cur, kind_arg)
    if nxt is None:
        sys.stderr.write("cannot bump non-semver version %r (kind=%s)\n" % (cur, kind_arg))
        sys.exit(2)
    print("path=%s" % rel)
    print("kind=%s" % kind)
    print("current=%s" % cur)
    print("next=%s" % nxt)
    if do_write:
        if not write_back(kind, path, text, cur, nxt):
            sys.stderr.write("write-back failed for %s\n" % rel)
            sys.exit(5)
    sys.exit(0)

sys.exit(2)
PY
}

# ─── grep fallback for detect (python3 absent) ───────────────────────────────
detect_fallback() {
    local f cur
    if [ -f "$ROOT/package.json" ]; then
        cur=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$ROOT/package.json" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
        [ -n "$cur" ] && { echo "path=package.json"; echo "kind=npm"; echo "current=$cur"; return 0; }
    fi
    for f in Cargo.toml pyproject.toml; do
        if [ -f "$ROOT/$f" ]; then
            cur=$(grep -oE '^version[[:space:]]*=[[:space:]]*"[^"]+"' "$ROOT/$f" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
            [ -n "$cur" ] && { echo "path=$f"; echo "kind=toml"; echo "current=$cur"; return 0; }
        fi
    done
    for f in VERSION version.txt; do
        if [ -f "$ROOT/$f" ]; then
            cur=$(head -1 "$ROOT/$f" 2>/dev/null | tr -d '[:space:]')
            [ -n "$cur" ] && { echo "path=$f"; echo "kind=plain"; echo "current=$cur"; return 0; }
        fi
    done
    return 10
}

# Numeric-triple semver compare. Echoes: gt | eq | lt | bad. Ignores build/prerelease
# for ordering; a same-triple-but-different-string pair is treated as "gt" (bumped).
semver_cmp() {  # $1=current $2=baseline
    local a b
    a=$(printf '%s' "$1" | sed -E 's/^v//')
    b=$(printf '%s' "$2" | sed -E 's/^v//')
    local at="${a%%[-+]*}" bt="${b%%[-+]*}"
    case "$at" in *.*.*) : ;; *) echo bad; return ;; esac
    case "$bt" in *.*.*) : ;; *) echo bad; return ;; esac
    local a1 a2 a3 b1 b2 b3
    a1="${at%%.*}"; a3="${at##*.}"; a2="${at#*.}"; a2="${a2%%.*}"
    b1="${bt%%.*}"; b3="${bt##*.}"; b2="${bt#*.}"; b2="${b2%%.*}"
    # Guard against non-numeric segments.
    case "$a1$a2$a3$b1$b2$b3" in *[!0-9]*) echo bad; return ;; esac
    if   [ "$a1" -gt "$b1" ]; then echo gt; return; elif [ "$a1" -lt "$b1" ]; then echo lt; return; fi
    if   [ "$a2" -gt "$b2" ]; then echo gt; return; elif [ "$a2" -lt "$b2" ]; then echo lt; return; fi
    if   [ "$a3" -gt "$b3" ]; then echo gt; return; elif [ "$a3" -lt "$b3" ]; then echo lt; return; fi
    # Triples equal — differ only by prerelease/build?
    if [ "$a" != "$b" ]; then echo gt; else echo eq; fi
}

case "$SUB" in
    detect)
        if command -v python3 >/dev/null 2>&1; then
            OUT=$(run_py detect); RC=$?
            [ "$RC" = "0" ] && { printf '%s\n' "$OUT"; exit 0; }
            [ "$RC" = "10" ] && { echo "no version artifact under $ROOT" >&2; exit 10; }
            exit "$RC"
        else
            detect_fallback && exit 0
            echo "no version artifact under $ROOT (grep fallback)" >&2
            exit 10
        fi
        ;;
    bump)
        case "$KIND" in patch|minor|major) : ;; *) echo "bump needs --kind patch|minor|major" >&2; exit 2 ;; esac
        command -v python3 >/dev/null 2>&1 || { echo "bump requires python3" >&2; exit 5; }
        OUT=$(run_py bump); RC=$?
        printf '%s\n' "$OUT"
        exit "$RC"
        ;;
    verify)
        [ -n "$BASELINE" ] || { echo "verify needs --baseline <ver>" >&2; exit 2; }
        if command -v python3 >/dev/null 2>&1; then
            OUT=$(run_py detect); RC=$?
        else
            OUT=$(detect_fallback); RC=$?
        fi
        [ "$RC" = "10" ] && { echo "no version artifact under $ROOT" >&2; exit 10; }
        [ "$RC" = "0" ] || exit "$RC"
        CUR=$(printf '%s\n' "$OUT" | grep '^current=' | head -1 | cut -d= -f2-)
        [ -n "$CUR" ] || { echo "could not read current version" >&2; exit 10; }
        CMP=$(semver_cmp "$CUR" "$BASELINE")
        echo "current=$CUR"
        echo "baseline=$BASELINE"
        case "$CMP" in
            gt)  echo "result=advanced";   exit 0 ;;
            eq)  echo "result=unchanged";  exit 20 ;;
            lt)  echo "result=backwards";  exit 21 ;;
            *)   echo "result=uncomparable (non-semver) — treating as unchanged" >&2; exit 20 ;;
        esac
        ;;
    *)
        echo "usage: $0 {detect|bump|verify} [opts]" >&2; exit 2 ;;
esac
