#!/bin/bash
# plan-w-team-regression-gate.sh — no-regression gate for /plan-w-team.
#
# The ship stage already blocks a RED suite at ship time (§6b exit code) and the
# evaluator withholds SUCCESS on a fresh RED skill suite. Neither remembers the
# PRE-CHANGE state, so two real regressions slip through:
#   1. A repo that already had failing tests on its base: §6b blocks the whole
#      suite, unable to tell "you broke a new test" from "this was already red"
#      (the manual stash→run-on-clean-main→attribute-blame carve-out in
#      04-fix-first-review.md §5-0 exists precisely because nothing automates it).
#   2. A change that DELETES a previously-passing test: the suite still exits 0
#      with fewer tests, so §6b never fires.
#
# This gate captures a baseline of the test state on the BASE tree at execute-start,
# then at ship re-runs and blocks ONLY on positive evidence that a test green at
# baseline is now red or gone. Pre-existing failures do not block; an un-runnable
# or unparseable suite is INDETERMINATE and never blocks (fail-open — a real
# regression needs positive evidence, matching the test-green philosophy).
#
# Subcommands:
#   baseline --slug SLUG [--root DIR] [--cmd "npm test"]
#       Detect + run the suite on the current (base) tree; write
#       .claude/state/plan-w-team-test-baseline-<SLUG>.json. Always exit 0 (capture
#       never blocks); exit 3 if no test framework is detected (records no-suite).
#
#   verify --slug SLUG [--root DIR]
#       Re-run and compare to the baseline artifact.
#       Exit 0  = no regression (or indeterminate / no baseline / no suite → fail-open)
#       Exit 10 = REGRESSION (positive evidence) — the caller hard-blocks + escalates
#       Exit 3  = no suite / no baseline captured → skip
#
# Kill switch: PLAN_W_TEAM_DISABLE_REGRESSION_GATE=1 makes both subcommands no-op
# (baseline exits 3, verify exits 3). Waiver for an intentional test removal:
# .claude/state/plan-w-team-regression-waiver-<SLUG> (verify treats a present
# waiver as authorization → exit 0 with a recorded note).
#
# bash 3.2 compatible.

set -u

SUB="${1:-}"
[ -n "$SUB" ] || { echo "usage: $0 {baseline|verify} --slug SLUG [opts]" >&2; exit 2; }
shift || true

ROOT=""; SLUG=""; CMD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="${2:-}"; shift 2 || exit 2 ;;
        --slug) SLUG="${2:-}"; shift 2 || exit 2 ;;
        --cmd)  CMD="${2:-}";  shift 2 || exit 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "$SLUG" ] || { echo "--slug is required" >&2; exit 2; }
[ -n "$ROOT" ] || ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
[ -d "$ROOT" ] || { echo "root not a directory: $ROOT" >&2; exit 2; }

STATE_DIR="$ROOT/.claude/state"
BASELINE_FILE="$STATE_DIR/plan-w-team-test-baseline-$SLUG.json"
WAIVER_FILE="$STATE_DIR/plan-w-team-regression-waiver-$SLUG"

# ─── Kill switch ─────────────────────────────────────────────────────────────
if [ "${PLAN_W_TEAM_DISABLE_REGRESSION_GATE:-0}" = "1" ]; then
    echo "regression gate disabled (PLAN_W_TEAM_DISABLE_REGRESSION_GATE=1)" >&2
    exit 3
fi

# ─── Detect the test command (mirrors §6b run_tests detection) ───────────────
detect_cmd() {
    [ -n "$CMD" ] && { printf '%s' "$CMD"; return 0; }
    if [ -f "$ROOT/package.json" ] && grep -q '"test"' "$ROOT/package.json" 2>/dev/null; then
        printf 'npm test --silent'; return 0
    fi
    [ -f "$ROOT/Cargo.toml" ]  && { printf 'cargo test';  return 0; }
    [ -f "$ROOT/go.mod" ]      && { printf 'go test ./...'; return 0; }
    if [ -f "$ROOT/pyproject.toml" ] || [ -f "$ROOT/pytest.ini" ] || [ -f "$ROOT/setup.cfg" ] || [ -d "$ROOT/tests" ]; then
        if command -v pytest >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
            printf 'pytest -q'; return 0
        fi
    fi
    return 1
}

# ─── Parse test output → JSON (green / failing[] / pass_count / total / fidelity)
# python3 does the framework-aware parsing; a plain exit-code record is the
# fallback when python3 is absent.
parse_run() {  # $1 = exit code, $2 = path to combined test output ; echoes JSON
    local rc="$1" outfile="$2"
    if command -v python3 >/dev/null 2>&1; then
        PV_RC="$rc" PV_OUTFILE="$outfile" python3 - <<'PY'
import os, re, sys
try:
    with open(os.environ.get("PV_OUTFILE", ""), "r", encoding="utf-8", errors="replace") as _f:
        out = _f.read()
except Exception:
    out = ""
rc  = int(os.environ.get("PV_RC", "1"))

failing = set()
pass_count = None
total = None
framework = None

# jest / vitest
m = re.search(r'Tests?:\s+(?:(\d+) failed[,\s]+)?(?:(\d+) passed[,\s]+)?(\d+) total', out)
if m:
    framework = "jest"
    f = int(m.group(1) or 0); p = int(m.group(2) or 0); t = int(m.group(3))
    pass_count, total = p, t
for mm in re.finditer(r'(?m)^\s*(?:✕|×|✗)\s+(.+?)\s*$', out):
    failing.add(mm.group(1).strip())

# pytest
mp = re.search(r'(\d+) failed', out)
mpp = re.search(r'(\d+) passed', out)
if mp or (mpp and 'pytest' in out.lower()) or re.search(r'(?m)^FAILED ', out):
    framework = framework or "pytest"
    if mpp:
        pass_count = int(mpp.group(1))
    fc = int(mp.group(1)) if mp else 0
    if pass_count is not None:
        total = pass_count + fc
    for mm in re.finditer(r'(?m)^FAILED\s+(\S+)', out):
        failing.add(mm.group(1))

# cargo
mc = re.search(r'test result:\s+\w+\.\s+(\d+) passed;\s+(\d+) failed', out)
if mc:
    framework = "cargo"
    p = int(mc.group(1)); f = int(mc.group(2))
    pass_count = (pass_count or 0) + p
    total = (total or 0) + p + f
    for mm in re.finditer(r'(?m)^test (\S+) \.\.\. FAILED', out):
        failing.add(mm.group(1))

# go
gofails = re.findall(r'(?m)^\s*--- FAIL:\s+(\S+)', out)
if gofails:
    framework = framework or "go"
    for n in gofails:
        failing.add(n)

green = (rc == 0) and (len(failing) == 0)
fidelity = "names" if framework else "exit-only"

def jarr(xs):
    return "[" + ",".join('"%s"' % x.replace('\\','\\\\').replace('"','\\"') for x in sorted(xs)) + "]"

def jnum(x):
    return "null" if x is None else str(x)

print('{"green":%s,"exit":%d,"fidelity":"%s","framework":%s,"failing":%s,"pass_count":%s,"total":%s}' % (
    "true" if green else "false", rc, fidelity,
    ('"%s"' % framework) if framework else "null",
    jarr(failing), jnum(pass_count), jnum(total)))
PY
    else
        # exit-code-only fallback
        local green="false"; [ "$rc" = "0" ] && green="true"
        printf '{"green":%s,"exit":%s,"fidelity":"exit-only","framework":null,"failing":[],"pass_count":null,"total":null}' "$green" "$rc"
    fi
}

run_suite() {  # echoes JSON verdict for the current tree; rc 3 if no framework
    local cmd rc tmp
    cmd=$(detect_cmd) || return 3
    tmp=$(mktemp -t pwt-reg.XXXXXX) || return 3
    ( cd "$ROOT" && eval "$cmd" ) >"$tmp" 2>&1
    rc=$?
    parse_run "$rc" "$tmp"
    rm -f "$tmp"
    return 0
}

json_field() {  # $1 json  $2 key ; naive scalar/array extractor
    printf '%s' "$1" | sed -E "s/.*\"$2\":(\"[^\"]*\"|\\[[^]]*\\]|[^,}]*).*/\\1/" | sed -E 's/^"//; s/"$//'
}

case "$SUB" in
    baseline)
        mkdir -p "$STATE_DIR" 2>/dev/null || true
        VERDICT=$(run_suite); RC=$?
        if [ "$RC" = "3" ]; then
            printf '{"slug":"%s","no_suite":true,"captured_at":"%s"}\n' \
                "$SLUG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BASELINE_FILE"
            echo "regression baseline: no test framework detected under $ROOT → no-suite" >&2
            exit 3
        fi
        CMD_USED=$(detect_cmd 2>/dev/null || echo "")
        printf '{"slug":"%s","captured_at":"%s","command":"%s","baseline":%s}\n' \
            "$SLUG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CMD_USED" "$VERDICT" > "$BASELINE_FILE"
        echo "regression baseline captured → $BASELINE_FILE" >&2
        printf '%s\n' "$VERDICT"
        exit 0
        ;;
    verify)
        if [ ! -f "$BASELINE_FILE" ]; then
            echo "regression verify: no baseline for slug '$SLUG' — skipping (fail-open)" >&2
            exit 3
        fi
        BASE_JSON=$(cat "$BASELINE_FILE" 2>/dev/null)
        case "$BASE_JSON" in
            *'"no_suite":true'*) echo "regression verify: baseline was no-suite — skipping" >&2; exit 3 ;;
        esac
        if [ -f "$WAIVER_FILE" ]; then
            echo "regression verify: waiver present ($WAIVER_FILE) — authorized, not blocking" >&2
            exit 0
        fi
        NOW=$(run_suite); RC=$?
        [ "$RC" = "3" ] && { echo "regression verify: suite no longer runnable — skipping (fail-open)" >&2; exit 3; }

        # Compare with python3 for reliable set/number math; degrade to green-flag
        # comparison without it.
        if command -v python3 >/dev/null 2>&1; then
            PV_BASE="$BASE_JSON" PV_NOW="$NOW" python3 - <<'PY'
import os, json, sys
try:
    base = json.loads(os.environ["PV_BASE"]).get("baseline", {})
    now  = json.loads(os.environ["PV_NOW"])
except Exception:
    print("regression verify: unparseable verdicts — skipping (fail-open)", file=sys.stderr)
    sys.exit(3)

reasons = []
bfail = set(base.get("failing") or [])
nfail = set(now.get("failing") or [])
new_failures = sorted(nfail - bfail)

# 1. Green baseline, red now → something that passed now fails.
if base.get("green") and not now.get("green"):
    reasons.append("suite was GREEN at baseline, now RED")

# 2. New failing test names (works even if baseline was already red).
if new_failures:
    reasons.append("new failing test(s): " + ", ".join(new_failures[:10]))

# 3. Passing-count drop (a previously-passing test now fails OR was deleted).
bp, np_ = base.get("pass_count"), now.get("pass_count")
if isinstance(bp, int) and isinstance(np_, int) and np_ < bp:
    reasons.append("passing count dropped %d → %d (regressed or removed test)" % (bp, np_))

if reasons:
    print("REGRESSION detected vs run-start baseline:", file=sys.stderr)
    for r in reasons:
        print("  - " + r, file=sys.stderr)
    sys.exit(10)
print("no regression vs baseline (pre-existing failures, if any, are unchanged)", file=sys.stderr)
sys.exit(0)
PY
            exit $?
        else
            BG=$(json_field "$BASE_JSON" green); NG=$(json_field "$NOW" green)
            if [ "$BG" = "true" ] && [ "$NG" != "true" ]; then
                echo "REGRESSION: suite was green at baseline, now red (exit-only fidelity)" >&2
                exit 10
            fi
            echo "no regression detectable at exit-only fidelity (fail-open)" >&2
            exit 0
        fi
        ;;
    *)
        echo "usage: $0 {baseline|verify} --slug SLUG [opts]" >&2; exit 2 ;;
esac
