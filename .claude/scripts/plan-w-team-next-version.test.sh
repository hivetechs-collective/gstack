#!/bin/bash
# Tests for plan-w-team-next-version.sh — ship-time VERSION rebump against
# CURRENT main (PWT-VERSION-COLLISION, 2026-06-07).
# Usage: bash .claude/scripts/plan-w-team-next-version.test.sh
#
# The defect: two concurrent runs spawned off the same base both bumped VERSION
# to the same value (both grabbed 1.35.0) because each bumped from its SPAWN-time
# snapshot, blind to a sibling that landed a higher version first. The fix derives
# the next version from main's CURRENT VERSION at ship time.
#
# Each case builds a hermetic throwaway git repo so the test never touches the
# real repo or network. bash 3.2 compatible.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/plan-w-team-next-version.sh"

PASS=0
FAIL=0
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS + 1))
    else echo "  ✗ $name"; echo "    expected: $expected"; echo "    actual:   $actual"; FAIL=$((FAIL + 1)); fi
}

# Build a hermetic repo: main has VERSION=$1; checkout a branch off the BASE
# commit (VERSION=$2) to emulate a run that spawned before main advanced.
# Echoes the sandbox dir. Caller must rm -rf it.
make_sandbox() {
    local main_version="$1" spawn_version="$2"
    local d; d=$(mktemp -d)
    (
        cd "$d" || exit 1
        git init -q
        git config user.email t@t.local
        git config user.name  tester
        git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
        printf '%s\n' "$spawn_version" > VERSION
        git add VERSION
        git commit -qm "base $spawn_version"
        git branch -M main
        BASE=$(git rev-parse HEAD)
        # Run A advances main past the spawn snapshot.
        printf '%s\n' "$main_version" > VERSION
        git commit -qam "runA ships $main_version"
        # Run B is on a branch off BASE — its working-tree VERSION is the stale
        # spawn snapshot ($spawn_version).
        git checkout -q -b runB "$BASE"
    ) >/dev/null 2>&1
    printf '%s' "$d"
}

echo "════════════════════════════════════════"
echo "  plan-w-team-next-version rebump tests"
echo "════════════════════════════════════════"

# ── AC5 headline: spawn 1.36.0, main advanced to 1.37.0, minor bump → 1.38.0 ──
echo "AC5: spawn-snapshot 1.36.0 + main now 1.37.0 + minor → 1.38.0 (no collision)"
SB=$(make_sandbox "1.37.0" "1.36.0")
NEXT=$( cd "$SB" && "$HELPER" --bump minor --ref main --version-file VERSION )
assert_eq "rebumps from current main (1.37.0→1.38.0), not stale snapshot (1.36.0→1.37.0)" "1.38.0" "$NEXT"
rm -rf "$SB"

# ── Control: the BUG behavior — bumping from the stale working-tree → collision ─
echo "Control: bumping from the stale working-tree (1.36.0) WOULD collide at 1.37.0"
SB=$(make_sandbox "1.37.0" "1.36.0")
# Force --ref to the spawn branch's own tree (HEAD=runB=base=1.36.0): reproduces
# the pre-fix collision so the contrast with AC5 is explicit.
NEXT_BUG=$( cd "$SB" && "$HELPER" --bump minor --ref HEAD --version-file VERSION )
assert_eq "spawn-snapshot rebump collides at 1.37.0 (the defect we fixed)" "1.37.0" "$NEXT_BUG"
rm -rf "$SB"

# ── Auto-resolution: no --ref → resolves local main (origin/main absent) ───────
echo "Auto: no --ref resolves main automatically (origin/main absent in sandbox)"
SB=$(make_sandbox "1.40.0" "1.36.0")
NEXT=$( cd "$SB" && "$HELPER" --bump patch --version-file VERSION )
assert_eq "auto-resolves main=1.40.0 → patch 1.40.1" "1.40.1" "$NEXT"
rm -rf "$SB"

# ── Bump kinds ────────────────────────────────────────────────────────────────
echo "Bump kinds from main=2.4.9"
SB=$(make_sandbox "2.4.9" "2.4.0")
assert_eq "major → 3.0.0" "3.0.0" "$( cd "$SB" && "$HELPER" --bump major --ref main --version-file VERSION )"
assert_eq "minor → 2.5.0" "2.5.0" "$( cd "$SB" && "$HELPER" --bump minor --ref main --version-file VERSION )"
assert_eq "patch → 2.4.10" "2.4.10" "$( cd "$SB" && "$HELPER" --bump patch --ref main --version-file VERSION )"
rm -rf "$SB"

# ── --write actually overwrites the working-tree VERSION ──────────────────────
echo "--write overwrites the working-tree VERSION file"
SB=$(make_sandbox "1.37.0" "1.36.0")
( cd "$SB" && "$HELPER" --bump minor --ref main --version-file VERSION --write >/dev/null )
WRITTEN=$( cd "$SB" && tr -d '[:space:]' < VERSION )
assert_eq "VERSION file written with rebumped value" "1.38.0" "$WRITTEN"
rm -rf "$SB"

# ── Invalid bump kind is rejected ─────────────────────────────────────────────
echo "Invalid --bump is rejected (exit 1)"
SB=$(make_sandbox "1.37.0" "1.36.0")
( cd "$SB" && "$HELPER" --bump sideways --ref main --version-file VERSION >/dev/null 2>&1 )
assert_eq "exit 1 on bad bump kind" "1" "$?"
rm -rf "$SB"

# ── bash 3.2 cleanliness (no bash-4 error signatures) ─────────────────────────
echo "bash 3.2: runs clean under /bin/bash"
SB=$(make_sandbox "1.37.0" "1.36.0")
ERR=$( cd "$SB" && /bin/bash "$HELPER" --bump minor --ref main --version-file VERSION 2>&1 >/dev/null )
case "$ERR" in
    *"declare: -A"*|*"bad substitution"*) echo "  ✗ bash-4 error signature: $ERR"; FAIL=$((FAIL + 1)) ;;
    *) echo "  ✓ no bash-4 error signature"; PASS=$((PASS + 1)) ;;
esac
rm -rf "$SB"

echo "════════════════════════════════════════"
echo "  Pass: $PASS  Fail: $FAIL"
echo "════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
