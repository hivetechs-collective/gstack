#!/usr/bin/env bash
# Tests for pwt-manifest.sh — the canonical /plan-w-team run manifest.
#
# Covers: init/set/task upsert, stage-event stream, main-checkout resolution
# from a worktree, gitignore-on-write, read/list/path, kill switch, and the
# fail-open contract (bad input never non-zero on writers).
#
# Usage: bash .claude/scripts/pwt-manifest.test.sh
# Exits 0 on all-pass, 1 on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/pwt-manifest.sh"

PASS=0; FAIL=0; ROOTS=()
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; echo "    $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected=[$2] actual=[$3]"; fi
}
cleanup() { for r in "${ROOTS[@]:-}"; do [ -n "${r:-}" ] && [ -d "$r" ] && rm -rf "$r"; done; }
trap cleanup EXIT

new_repo() {
    local root; root="$(mktemp -d -t pwt-manifest-test.XXXXXX)"
    ROOTS+=("$root")
    git -C "$root" init -q -b main
    git -C "$root" config user.email t@t.t; git -C "$root" config user.name t
    echo seed > "$root/seed.txt"; git -C "$root" add seed.txt; git -C "$root" commit -qm seed
    mkdir -p "$root/.claude/state"
    echo "$root"
}
jget() { python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1]))' "$1"; }
M() { ( cd "$1" && CLAUDE_PROJECT_DIR="$1" bash "$MANIFEST" "${@:2}" ); }

echo "── pwt-manifest tests ──"

# ── 1: init creates a manifest at the main-checkout state dir ───────────────
echo "[1] init writes manifest with schema + slug + run_sid"
R=$(new_repo)
M "$R" init --slug feat-x --run-sid 45c3dbba --strategy lead-implements-directly --stage 1-scope >/dev/null
MF="$R/.claude/state/plan-w-team-manifest-feat-x.json"
assert_eq "manifest file exists" "yes" "$([ -f "$MF" ] && echo yes || echo no)"
assert_eq "schema set"     "plan-w-team-manifest/v1" "$(jget schema < "$MF")"
assert_eq "slug set"       "feat-x"   "$(jget slug < "$MF")"
assert_eq "run_sid set"    "45c3dbba" "$(jget run_sid < "$MF")"
assert_eq "stage set"      "1-scope"  "$(jget current_stage < "$MF")"

# ── 2: set updates stage + worktree; empty flags never clobber ──────────────
echo "[2] set updates stage/worktree, preserves run_sid"
M "$R" set --slug feat-x --stage 3-execute --worktree "$R/.claude/worktrees/feat-x" --builders 3 >/dev/null
assert_eq "stage updated"   "3-execute" "$(jget current_stage < "$MF")"
assert_eq "builders updated" "3"        "$(jget builder_count < "$MF")"
assert_eq "run_sid preserved" "45c3dbba" "$(jget run_sid < "$MF")"

# ── 3: task upsert (add then mutate) ────────────────────────────────────────
echo "[3] task upsert adds and then updates in place"
M "$R" task --slug feat-x --id T1 --status running --owner aaaa1111 >/dev/null
M "$R" task --slug feat-x --id T2 --status pending >/dev/null
N1=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["tasks"]))' "$MF")
assert_eq "two tasks" "2" "$N1"
M "$R" task --slug feat-x --id T1 --status done >/dev/null
N2=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["tasks"]))' "$MF")
assert_eq "still two tasks (upsert, not append)" "2" "$N2"
T1S=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print([t for t in d["tasks"] if t["id"]=="T1"][0]["status"])' "$MF")
assert_eq "T1 status mutated to done" "done" "$T1S"

# ── 4: stage-event stream appends a row per stage change ────────────────────
echo "[4] stage transitions append to the event stream"
EV="$R/.claude/state/plan-w-team-stage-events-feat-x.jsonl"
ROWS=$(grep -c . "$EV" 2>/dev/null || echo 0)
assert_eq "two stage events (1-scope, 3-execute)" "2" "$ROWS"
LAST_STAGE=$(tail -1 "$EV" | jget stage)
assert_eq "last event stage" "3-execute" "$LAST_STAGE"
LAST_SID=$(tail -1 "$EV" | jget run_sid)
assert_eq "event backfills run_sid from manifest" "45c3dbba" "$LAST_SID"

# ── 5: written from a WORKTREE → manifest still lands in MAIN checkout ───────
echo "[5] worktree write resolves to the MAIN checkout state dir"
R2=$(new_repo)
WT="$R2/.claude/worktrees/wt1"
git -C "$R2" worktree add -q -b wt1 "$WT" >/dev/null 2>&1
# Call from inside the worktree, WITHOUT a state-dir override → git-common-dir resolves main.
( cd "$WT" && bash "$MANIFEST" set --slug wt-run --stage 5-ship --run-sid bbbb2222 >/dev/null )
MAIN_MF="$R2/.claude/state/plan-w-team-manifest-wt-run.json"
WT_MF="$WT/.claude/state/plan-w-team-manifest-wt-run.json"
assert_eq "manifest in MAIN checkout"     "yes" "$([ -f "$MAIN_MF" ] && echo yes || echo no)"
assert_eq "NOT written into the worktree" "no"  "$([ -f "$WT_MF" ] && echo yes || echo no)"

# ── 6: gitignore-on-write ───────────────────────────────────────────────────
echo "[6] manifest patterns appended to .gitignore"
assert_eq "gitignore has manifest pattern" "yes" \
    "$(grep -q 'plan-w-team-manifest-' "$R/.gitignore" && echo yes || echo no)"
assert_eq "gitignore has stage-events pattern" "yes" \
    "$(grep -q 'plan-w-team-stage-events-' "$R/.gitignore" && echo yes || echo no)"

# ── 7: read / list / path ───────────────────────────────────────────────────
echo "[7] read, list, path subcommands"
RJSON=$(M "$R" read --slug feat-x)
assert_eq "read emits valid JSON slug" "feat-x" "$(echo "$RJSON" | jget slug)"
M "$R" read --slug does-not-exist >/dev/null 2>&1
assert_eq "read missing → exit 3" "3" "$?"
LIST=$(M "$R" list)
assert_eq "list mentions slug" "yes" "$(echo "$LIST" | grep -q feat-x && echo yes || echo no)"
PATHOUT=$(M "$R" path --slug feat-x)
assert_eq "path resolves manifest file" "yes" "$(echo "$PATHOUT" | grep -q 'plan-w-team-manifest-feat-x.json' && echo yes || echo no)"

# ── 8: kill switch + fail-open ──────────────────────────────────────────────
echo "[8] kill switch + fail-open on bad input"
R3=$(new_repo)
( cd "$R3" && CLAUDE_PROJECT_DIR="$R3" PLAN_W_TEAM_MANIFEST_DISABLE=1 bash "$MANIFEST" init --slug killed --run-sid x >/dev/null )
assert_eq "kill switch → no manifest" "no" \
    "$([ -f "$R3/.claude/state/plan-w-team-manifest-killed.json" ] && echo yes || echo no)"
M "$R3" set >/dev/null 2>&1   # missing --slug
assert_eq "writer missing --slug → exit 0 (fail-open)" "0" "$?"

# ── 9: bash 3.2 compatibility (macOS /bin/bash; mac-mini deployment) ─────────
echo "[9] runs clean under bash 3.2"
if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
    R4=$(new_repo); ERRF="$R4/b32.err"
    ( cd "$R4" && CLAUDE_PROJECT_DIR="$R4" /bin/bash "$MANIFEST" init --slug b32 --run-sid z --stage 1-scope 2>"$ERRF" >/dev/null )
    ERR=$(cat "$ERRF" 2>/dev/null)
    case "$ERR" in
        *"declare:"*|*"unbound variable"*|*"bad substitution"*|*"invalid option"*) E32=1 ;;
        *) E32=0 ;;
    esac
    assert_eq "bash 3.2: no bash-4 error signature" "0" "$E32"
    assert_eq "bash 3.2: manifest written" "yes" \
        "$([ -f "$R4/.claude/state/plan-w-team-manifest-b32.json" ] && echo yes || echo no)"
else
    echo "  ⊘ skipped (no bash 3.2 at /bin/bash)"
fi

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
