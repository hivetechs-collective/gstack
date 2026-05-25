#!/usr/bin/env bash
# Tests for plan-w-team-worktree-on-merge.sh
#
# Exercises the per-merge cleanup wrapper against real fixture git worktrees:
# the clean-merge happy path (worktree + branch + fleet row swept) and every
# safe-skip path (uncommitted, in-use, outside-worktrees, idempotent no-op).
#
# Usage: bash .claude/scripts/plan-w-team-worktree-on-merge.test.sh
# Exits 0 on all-pass, 1 on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ONMERGE="$SCRIPT_DIR/plan-w-team-worktree-on-merge.sh"

PASS=0
FAIL=0
ROOTS=()

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; echo "    $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then pass "$name"
    else fail "$name" "expected=[$expected] actual=[$actual]"; fi
}

cleanup() {
    for r in "${ROOTS[@]:-}"; do
        [ -n "${r:-}" ] && [ -d "$r" ] && rm -rf "$r"
    done
}
trap cleanup EXIT

new_repo() {
    local root; root="$(mktemp -d -t pwt-onmerge-test.XXXXXX)"
    ROOTS+=("$root")
    git -C "$root" init -q -b main
    git -C "$root" config user.email t@t.t
    git -C "$root" config user.name t
    echo seed > "$root/seed.txt"; git -C "$root" add seed.txt; git -C "$root" commit -qm seed
    mkdir -p "$root/.claude/worktrees" "$root/.claude/state"
    echo "$root"
}

add_merged_worktree() {
    local root="$1" name="$2"
    local wt="$root/.claude/worktrees/$name" branch="worktree-$name"
    git -C "$root" worktree add -q -b "$branch" "$wt" >/dev/null 2>&1
    echo c > "$wt/f.txt"; git -C "$wt" add f.txt; git -C "$wt" commit -qm "w $name"
    git -C "$root" merge -q --no-ff "$branch" -m "merge $branch" >/dev/null 2>&1
    echo "$wt"
}

jget() { python3 -c 'import json,sys;print(json.load(sys.stdin).get(sys.argv[1]))' "$1"; }

echo "── plan-w-team-worktree-on-merge tests ──"

# ── 1: clean-merge happy path ──────────────────────────────────────────────
echo "[1] clean-merge: worktree + branch + fleet row removed"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "ship-feat")
printf '{"session_id":"s","worktree_path":"%s","branch":"worktree-ship-feat"}\n' "$WT" \
    > "$R/.claude/state/plan-w-team-spawned-children-ship.jsonl"
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 bash "$ONMERGE" "$WT" "worktree-ship-feat" "ship" )
assert_eq "removed_worktree true"  "True"  "$(jget removed_worktree <<< "$OUT")"
assert_eq "removed_branch true"    "True"  "$(jget removed_branch <<< "$OUT")"
assert_eq "not skipped"            "False" "$(jget skipped <<< "$OUT")"
assert_eq "worktree dir gone"      "no"    "$([ -d "$WT" ] && echo yes || echo no)"
BR=$(git -C "$R" show-ref --verify --quiet refs/heads/worktree-ship-feat && echo yes || echo no)
assert_eq "branch deleted"         "no"    "$BR"
ROWS=$(grep -c . "$R/.claude/state/plan-w-team-spawned-children-ship.jsonl" 2>/dev/null); ROWS="${ROWS:-0}"
assert_eq "fleet row unregistered" "0"     "$ROWS"

# ── 2: uncommitted → safe-skip ─────────────────────────────────────────────
echo "[2] uncommitted changes → safe-skip, preserve"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "dirty-feat")
echo dirty > "$WT/extra.txt"
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 bash "$ONMERGE" "$WT" "worktree-dirty-feat" )
assert_eq "skipped true"      "True" "$(jget skipped <<< "$OUT")"
assert_eq "worktree preserved" "yes" "$([ -d "$WT" ] && echo yes || echo no)"

# ── 3: in-use → safe-skip ──────────────────────────────────────────────────
echo "[3] in-use (live cwd injected) → safe-skip"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "inuse-feat")
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_LIVE_CWDS="$WT" bash "$ONMERGE" "$WT" "worktree-inuse-feat" )
assert_eq "skipped true"       "True" "$(jget skipped <<< "$OUT")"
assert_eq "worktree preserved" "yes"  "$([ -d "$WT" ] && echo yes || echo no)"

# ── 4: outside .claude/worktrees/ → refuse ─────────────────────────────────
echo "[4] path outside .claude/worktrees/ → refuse"
R=$(new_repo)
OUTSIDE="$R/external"
git -C "$R" worktree add -q -b ext "$OUTSIDE" >/dev/null 2>&1
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 bash "$ONMERGE" "$OUTSIDE" "ext" )
assert_eq "skipped true (refused)" "True" "$(jget skipped <<< "$OUT")"
assert_eq "external worktree preserved" "yes" "$([ -d "$OUTSIDE" ] && echo yes || echo no)"

# ── 5: idempotent — already-gone worktree ──────────────────────────────────
echo "[5] idempotency: already-removed worktree is a clean no-op"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "idem-feat")
# Remove once
( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 bash "$ONMERGE" "$WT" "worktree-idem-feat" ) >/dev/null
# Run again — branch+dir already gone
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 bash "$ONMERGE" "$WT" "worktree-idem-feat" )
RC=$?
assert_eq "re-run exit 0" "0" "$RC"
assert_eq "re-run skipped true (no-op)" "True" "$(jget skipped <<< "$OUT")"

# ── 6: disable kill-switch ─────────────────────────────────────────────────
echo "[6] PWT_WORKTREE_ON_MERGE_DISABLE=1 → no-op"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "disable-feat")
OUT=$( cd "$R" && PWT_WORKTREE_ON_MERGE_DISABLE=1 bash "$ONMERGE" "$WT" "worktree-disable-feat" )
assert_eq "skipped true" "True" "$(jget skipped <<< "$OUT")"
assert_eq "worktree preserved" "yes" "$([ -d "$WT" ] && echo yes || echo no)"

# ── 7: missing args → usage error exit 2 ───────────────────────────────────
echo "[7] missing args → exit 2"
R=$(new_repo)
( cd "$R" && bash "$ONMERGE" ) >/dev/null 2>&1
assert_eq "missing-args exit 2" "2" "$?"

# ── 8: bash 3.2 compatibility (macOS /bin/bash; mac-mini deployment) ────────
# Runtime guard against bash-4 constructs (declare -A etc.) that `bash -n` misses.
echo "[8] runs clean under bash 3.2 (/bin/bash on macOS)"
if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
    R=$(new_repo); WT=$(add_merged_worktree "$R" "b32-feat"); ERRF="$R/b32.err"
    OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 /bin/bash "$ONMERGE" "$WT" "worktree-b32-feat" 2>"$ERRF" ); RC=$?
    ERR=$(cat "$ERRF" 2>/dev/null)
    case "$ERR" in
        *"invalid option"*|*"declare:"*|*"unbound variable"*|*"bad substitution"*) E32=1 ;;
        *) E32=0 ;;
    esac
    assert_eq "bash 3.2: no bash-4 error signature" "0" "$E32"
    assert_eq "bash 3.2: merged worktree removed" "True" "$(jget removed_worktree <<< "$OUT")"
else
    echo "  ⊘ skipped (no bash 3.2 at /bin/bash — not the regression-risk host)"
fi

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
