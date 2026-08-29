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

# ── 9/10: Fix A1 — primary-checkout re-sync + remote-branch delete ─────────
# These source the script (it returns before the arg-required main flow) and
# drive __resync_primary_checkout directly against an origin-backed fixture.
new_origin_repo() {
    # Builds: bare origin + primary clone parked on a stale feature branch whose
    # work already landed on origin/main (the "server-side squash" shape).
    # Echoes the primary checkout path.
    local tmp; tmp="$(mktemp -d -t pwt-resync-test.XXXXXX)"
    ROOTS+=("$tmp")
    git init -q --bare "$tmp/origin.git"
    git -C "$tmp/origin.git" symbolic-ref HEAD refs/heads/main   # bare default branch = main
    git clone -q "$tmp/origin.git" "$tmp/primary" 2>/dev/null
    git -C "$tmp/primary" config user.email t@t.t
    git -C "$tmp/primary" config user.name t
    git -C "$tmp/primary" commit -q --allow-empty -m init
    git -C "$tmp/primary" branch -M main
    git -C "$tmp/primary" push -q -u origin main
    git -C "$tmp/primary" remote set-head origin main           # populate refs/remotes/origin/HEAD
    # Feature branch + its remote copy.
    git -C "$tmp/primary" switch -q -c feat-x
    git -C "$tmp/primary" commit -q --allow-empty -m feat
    git -C "$tmp/primary" push -q -u origin feat-x
    # Land feat-x on origin/main (server squash), then rewind primary/main so it
    # is genuinely behind origin/main, and park primary on the stale feat-x label.
    git -C "$tmp/primary" switch -q main
    git -C "$tmp/primary" merge -q feat-x
    git -C "$tmp/primary" push -q origin main
    git -C "$tmp/primary" reset -q --hard HEAD~1   # primary/main now 1 behind origin/main
    git -C "$tmp/primary" switch -q feat-x          # parked on stale label, clean tree
    echo "$tmp/primary"
}

echo "[9] resync: ff primary to default + delete remote feature branch"
PRIMARY=$(new_origin_repo)
RESYNC_OUT=$(
    export MAIN_CHECKOUT="$PRIMARY" BRANCH="feat-x"
    # shellcheck disable=SC1090
    source "$ONMERGE"
    __resync_primary_checkout
    echo "HEAD=$(git -C "$PRIMARY" symbolic-ref --short HEAD 2>/dev/null)"
    echo "BEHIND=$(git -C "$PRIMARY" rev-list --count HEAD..origin/main 2>/dev/null)"
    echo "REMOTE=$(git -C "$PRIMARY" ls-remote --heads origin feat-x 2>/dev/null | wc -l | tr -d ' ')"
    echo "REMOVED=$RESYNC_REMOVED_REMOTE_BRANCH"
    echo "RHEAD=$RESYNC_PRIMARY_HEAD"
)
assert_eq "primary switched to main" "main" "$(printf '%s\n' "$RESYNC_OUT" | sed -n 's/^HEAD=//p')"
assert_eq "primary 0 behind origin/main" "0" "$(printf '%s\n' "$RESYNC_OUT" | sed -n 's/^BEHIND=//p')"
assert_eq "remote feat-x deleted" "0" "$(printf '%s\n' "$RESYNC_OUT" | sed -n 's/^REMOTE=//p')"
assert_eq "RESYNC_REMOVED_REMOTE_BRANCH true" "true" "$(printf '%s\n' "$RESYNC_OUT" | sed -n 's/^REMOVED=//p')"
assert_eq "RESYNC_PRIMARY_HEAD main" "main" "$(printf '%s\n' "$RESYNC_OUT" | sed -n 's/^RHEAD=//p')"

echo "[10] resync: diverged primary main is NOT force-moved (ff-only declines)"
PRIMARY=$(new_origin_repo)
git -C "$PRIMARY" switch -q main
git -C "$PRIMARY" merge -q --ff-only origin/main             # catch up (0 behind)
git -C "$PRIMARY" commit -q --allow-empty -m local-only-divergent
CLONE2="$(dirname "$PRIMARY")/clone2"
git clone -q "$(dirname "$PRIMARY")/origin.git" "$CLONE2" 2>/dev/null
git -C "$CLONE2" config user.email t@t.t; git -C "$CLONE2" config user.name t
git -C "$CLONE2" commit -q --allow-empty -m other-divergent
git -C "$CLONE2" push -q origin main                          # origin/main now diverges from primary
DIV_OUT=$(
    export MAIN_CHECKOUT="$PRIMARY" BRANCH="feat-x"
    # shellcheck disable=SC1090
    source "$ONMERGE"
    __resync_primary_checkout
    echo "HEAD=$(git -C "$PRIMARY" symbolic-ref --short HEAD 2>/dev/null)"
    echo "HAS_LOCAL=$(git -C "$PRIMARY" log --oneline 2>/dev/null | grep -c local-only-divergent)"
)
assert_eq "diverged: HEAD still main" "main" "$(printf '%s\n' "$DIV_OUT" | sed -n 's/^HEAD=//p')"
assert_eq "diverged: local commit preserved (not force-reset)" "1" "$(printf '%s\n' "$DIV_OUT" | sed -n 's/^HAS_LOCAL=//p')"

# ══ WT-2: dirty-ignore parity with the periodic GC ═════════════════════════
# Before this block, invariant 2 tested RAW porcelain, so ANY dirt — including
# the `.claude/` sync churn that hooks rewrite into every worktree — pinned the
# worktree forever at ship time, while the periodic GC (which filters that churn
# through PWT_DIRTY_IGNORE_DEFAULT) considered the same tree clean. Ship-time
# reclaim therefore leaked exactly the worktrees the GC would have reaped.
#
# The fix shares the GC's WHOLE dirtiness contract, not just the loosening half:
# the ignore filter (reclaim policy churn) AND VETO 2 (a tracked edit is an
# absolute veto in any path) AND preserve-then-reap (untracked authored files are
# backed up before the destructive removal). Porting only the filter would trade a
# leaked worktree for destroyed authored work — the 2026-07-30 loss class.

# helper: repo with a TRACKED file under .claude/ (so a worktree can dirty it)
new_repo_tracked_claude() {
    local root; root="$(new_repo)"
    mkdir -p "$root/.claude/hooks"
    echo 'v1-committed' > "$root/.claude/hooks/tracked-hook.sh"
    git -C "$root" add .claude/hooks/tracked-hook.sh
    git -C "$root" commit -qm "add tracked hook under .claude/"
    echo "$root"
}

# ── 11: untracked ignore-set churn → RECLAIMED (the WT-2 leak) ─────────────
echo "[11] untracked .claude/ sync churn only → reclaimed (not leaked)"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "syncchurn")
mkdir -p "$WT/.claude/state"
echo '{"cache":1}' > "$WT/.claude/state/bg-agents-cache.json"
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 bash "$ONMERGE" "$WT" "worktree-syncchurn" )
assert_eq "ignore-set churn: not skipped" "False" "$(jget skipped <<< "$OUT")"
assert_eq "ignore-set churn: removed"     "True"  "$(jget removed_worktree <<< "$OUT")"
assert_eq "ignore-set churn: dir gone"    "no"    "$([ -d "$WT" ] && echo yes || echo no)"

# ── 12: TRACKED edit is an absolute veto (GC VETO 2) ───────────────────────
echo "[12] uncommitted TRACKED edit under .claude/ → skip, content survives"
R=$(new_repo_tracked_claude)
WT=$(add_merged_worktree "$R" "trackededit")
echo 'v2-hand-edited' > "$WT/.claude/hooks/tracked-hook.sh"
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 bash "$ONMERGE" "$WT" "worktree-trackededit" )
assert_eq "tracked veto: skipped"    "True" "$(jget skipped <<< "$OUT")"
assert_eq "tracked veto: preserved"  "yes"  "$([ -d "$WT" ] && echo yes || echo no)"
assert_eq "tracked veto: edit survived" "yes" \
    "$(grep -q v2-hand-edited "$WT/.claude/hooks/tracked-hook.sh" 2>/dev/null && echo yes || echo no)"
case "$(jget reason <<< "$OUT")" in
    *TRACKED*) pass "tracked veto: reason names TRACKED" ;;
    *) fail "tracked veto: reason names TRACKED" "got: $(jget reason <<< "$OUT")" ;;
esac

# ── 13: empty override restores strict any-dirty=keep ──────────────────────
echo "[13] PWT_WORKTREE_GC_DIRTY_IGNORE= (empty) → strict, churn skips again"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "strictset")
mkdir -p "$WT/.claude/state"; echo '{}' > "$WT/.claude/state/bg-agents-cache.json"
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 PWT_WORKTREE_GC_DIRTY_IGNORE= \
       bash "$ONMERGE" "$WT" "worktree-strictset" )
assert_eq "empty ignore set: skipped"   "True" "$(jget skipped <<< "$OUT")"
assert_eq "empty ignore set: preserved" "yes"  "$([ -d "$WT" ] && echo yes || echo no)"

# ── 14: override REPLACES the set (not additive) ───────────────────────────
echo "[14] custom ignore set replaces default → .claude/ churn becomes real dirt"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "replaceset")
mkdir -p "$WT/.claude/state"; echo '{}' > "$WT/.claude/state/bg-agents-cache.json"
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 PWT_WORKTREE_GC_DIRTY_IGNORE="node_modules" \
       bash "$ONMERGE" "$WT" "worktree-replaceset" )
assert_eq "replaced set: skipped"   "True" "$(jget skipped <<< "$OUT")"
assert_eq "replaced set: preserved" "yes"  "$([ -d "$WT" ] && echo yes || echo no)"

# ── 15: python3 unavailable → strict fallback, never "clean" ───────────────
# The filter and the JSON serializer are BOTH python3, so a broken interpreter
# makes the filter report "no real dirt". Reading that as clean would authorize
# the removal — the GC's VETO 0 class, one script over. Must degrade to skip.
echo "[15] python3 unavailable → strict fallback skip (worktree survives)"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "nopy")
mkdir -p "$WT/.claude/state"; echo '{}' > "$WT/.claude/state/bg-agents-cache.json"
PYSTUB="$R/_nopy"; mkdir -p "$PYSTUB"
printf '#!/bin/sh\nexit 127\n' > "$PYSTUB/python3"; chmod +x "$PYSTUB/python3"
OUT=$( cd "$R" && PATH="$PYSTUB:$PATH" PWT_WORKTREE_GC_TEST_MODE=1 \
       bash "$ONMERGE" "$WT" "worktree-nopy" 2>/dev/null )
assert_eq "no python3: worktree survives" "yes" "$([ -d "$WT" ] && echo yes || echo no)"
case "$OUT" in
    *python3*) pass "no python3: reason names the cause" ;;
    *) fail "no python3: reason names the cause" "got: $OUT" ;;
esac

# ── 16: shared lib unreadable → strict fallback, never "clean" ─────────────
echo "[16] dirty-ignore lib unavailable → strict fallback skip"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "nolib")
mkdir -p "$WT/.claude/state"; echo '{}' > "$WT/.claude/state/bg-agents-cache.json"
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 \
       PWT_DIRTY_IGNORE_LIB="$R/definitely-not-here.sh" \
       bash "$ONMERGE" "$WT" "worktree-nolib" 2>/dev/null )
assert_eq "no lib: skipped"   "True" "$(jget skipped <<< "$OUT")"
assert_eq "no lib: preserved" "yes"  "$([ -d "$WT" ] && echo yes || echo no)"

# ── 17: untracked AUTHORED file is backed up before the reap ───────────────
# `.claude/` is in the CLASSIFY ignore set (so this is reapable) but NOT in the
# narrower PRESERVE set, so the authored file must reach a backup first. Without
# this, closing the leak would silently start destroying authored work.
echo "[17] untracked authored file under .claude/ → reclaimed AND backed up"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "authored")
mkdir -p "$WT/.claude/hooks"
echo 'authored-by-a-builder' > "$WT/.claude/hooks/authored-new.sh"
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 bash "$ONMERGE" "$WT" "worktree-authored" )
assert_eq "authored: removed" "True" "$(jget removed_worktree <<< "$OUT")"
BK=$(grep -rl "authored-new.sh" "$R/.claude/state/hygiene-backups" 2>/dev/null | head -1)
assert_eq "authored: backup names the file" "yes" "$([ -n "$BK" ] && echo yes || echo no)"
# The name alone is not a backup — assert the CONTENT survived the reap.
CONTENT=$(grep -rl "authored-by-a-builder" "$R/.claude/state/hygiene-backups" 2>/dev/null | head -1)
assert_eq "authored: backup preserves CONTENT" "yes" "$([ -n "$CONTENT" ] && echo yes || echo no)"

# ── 18b: a FAILED backup aborts the removal ────────────────────────────────
# The other half of the preserve contract. Reclaim is only safe because the
# backup ran; if the backup could fail and the removal proceed anyway, the
# preserve step would be decorative on exactly the runs that need it. Forced by
# making the backup root unwritable.
echo "[18b] preserve-then-reap backup failure → removal aborted, worktree kept"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "bkfail")
mkdir -p "$WT/.claude/hooks"
echo 'authored-work' > "$WT/.claude/hooks/authored.sh"
chmod 500 "$R/.claude/state"          # mkdir of hygiene-backups/ will fail
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 bash "$ONMERGE" "$WT" "worktree-bkfail" 2>/dev/null )
chmod 700 "$R/.claude/state"          # restore so cleanup can remove the fixture
assert_eq "backup failure: skipped"          "True" "$(jget skipped <<< "$OUT")"
assert_eq "backup failure: worktree kept"    "yes"  "$([ -d "$WT" ] && echo yes || echo no)"
assert_eq "backup failure: authored work intact" "yes" \
    "$(grep -q authored-work "$WT/.claude/hooks/authored.sh" 2>/dev/null && echo yes || echo no)"
case "$(jget reason <<< "$OUT")" in
    *preserve*) pass "backup failure: reason names the backup" ;;
    *) fail "backup failure: reason names the backup" "got: $(jget reason <<< "$OUT")" ;;
esac

# ── 18: genuine source dirt still blocks (no over-loosening) ───────────────
echo "[18] untracked file OUTSIDE the ignore set → still skipped"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "realdirt")
echo 'real work' > "$WT/src-note.txt"
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_MODE=1 bash "$ONMERGE" "$WT" "worktree-realdirt" )
assert_eq "real dirt: skipped"   "True" "$(jget skipped <<< "$OUT")"
assert_eq "real dirt: preserved" "yes"  "$([ -d "$WT" ] && echo yes || echo no)"

# ══ invariant 3: fail-closed liveness parity with the periodic GC (2.11.0) ══
# Invariant 2 is deliberately loose since 2.8.0, so invariant 3 is what stands
# between a live session and `rm -rf`. These cases assert that "no matching path"
# only authorizes removal when the probe ACTUALLY RAN.

# ── 19: probe failed (test seam) → fail closed, worktree kept ──────────────
echo "[19] liveness probe failed → fail-closed skip (clean, merged worktree)"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "livefail")
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_QUERY_FAILED=1 bash "$ONMERGE" "$WT" "worktree-livefail" )
assert_eq "probe failed: skipped"   "True" "$(jget skipped <<< "$OUT")"
assert_eq "probe failed: preserved" "yes"  "$([ -d "$WT" ] && echo yes || echo no)"
case "$(jget reason <<< "$OUT")" in
    *"fail-closed"*) pass "probe failed: reason names fail-closed" ;;
    *) fail "probe failed: reason names fail-closed" "got: $(jget reason <<< "$OUT")" ;;
esac

# ── 19b: canonical helper MISSING → fail closed ────────────────────────────
# The pre-2.11.0 shape: no helper, LIVE_CWDS empty, in-use check skipped whole.
echo "[19b] canonical liveness helper missing → fail-closed skip"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "nohelper")
OUT=$( cd "$R" && PWT_LIVE_SESSION_CWDS_SCRIPT="$R/definitely-not-here.sh" \
       bash "$ONMERGE" "$WT" "worktree-nohelper" )
assert_eq "no helper: skipped"   "True" "$(jget skipped <<< "$OUT")"
assert_eq "no helper: preserved" "yes"  "$([ -d "$WT" ] && echo yes || echo no)"

# ── 19c: helper emits the __QUERY_FAILED__ token → fail closed ─────────────
echo "[19c] liveness helper returns __QUERY_FAILED__ → fail-closed skip"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "qfail")
STUB="$R/_qfail.sh"
printf '#!/bin/sh\nprintf "__QUERY_FAILED__\\n"\n' > "$STUB"; chmod +x "$STUB"
OUT=$( cd "$R" && PWT_LIVE_SESSION_CWDS_SCRIPT="$STUB" bash "$ONMERGE" "$WT" "worktree-qfail" )
assert_eq "query-failed token: skipped"   "True" "$(jget skipped <<< "$OUT")"
assert_eq "query-failed token: preserved" "yes"  "$([ -d "$WT" ] && echo yes || echo no)"

# ── 19d: CONTROL — probe SUCCEEDS with unrelated cwds → removal proceeds ───
# Without this, tests 19/19b/19c would also pass if the fix simply refused to
# remove anything ever. This is the arm that proves the veto is conditional.
echo "[19d] control: probe succeeds, no match → worktree removed"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "livok")
STUB="$R/_livok.sh"
printf '#!/bin/sh\nprintf "/somewhere/else\\n"\n' > "$STUB"; chmod +x "$STUB"
OUT=$( cd "$R" && PWT_LIVE_SESSION_CWDS_SCRIPT="$STUB" bash "$ONMERGE" "$WT" "worktree-livok" )
assert_eq "probe ok: not skipped"     "False" "$(jget skipped <<< "$OUT")"
assert_eq "probe ok: removed"         "True"  "$(jget removed_worktree <<< "$OUT")"
assert_eq "probe ok: dir gone"        "no"    "$([ -d "$WT" ] && echo yes || echo no)"

# ── 19e: probe succeeds AND matches this worktree → in-use veto (unchanged) ─
echo "[19e] probe succeeds and matches → in-use skip, reason names in-use"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "livehit")
STUB="$R/_livehit.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$WT" > "$STUB"; chmod +x "$STUB"
OUT=$( cd "$R" && PWT_LIVE_SESSION_CWDS_SCRIPT="$STUB" bash "$ONMERGE" "$WT" "worktree-livehit" )
assert_eq "probe hit: skipped"   "True" "$(jget skipped <<< "$OUT")"
assert_eq "probe hit: preserved" "yes"  "$([ -d "$WT" ] && echo yes || echo no)"
case "$(jget reason <<< "$OUT")" in
    *in-use*) pass "probe hit: reason names in-use (not fail-closed)" ;;
    *) fail "probe hit: reason names in-use (not fail-closed)" "got: $(jget reason <<< "$OUT")" ;;
esac

# ── 19f: AC13 — the secondary source cannot CLEAR the fail-closed flag ──────
# claude-agents-extended.sh is additive-only: it may add protected paths, but a
# successful secondary must never launder a FAILED canonical probe into "clean".
echo "[19f] canonical probe failed + secondary returns data → still fail-closed"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "additive")
EXT="$R/_ext.sh"
printf '#!/bin/sh\nprintf "[{\\"cwd\\":\\"/unrelated/path\\"}]\\n"\n' > "$EXT"; chmod +x "$EXT"
OUT=$( cd "$R" && PWT_LIVE_SESSION_CWDS_SCRIPT="$R/definitely-not-here.sh" \
       PWT_WORKTREE_GC_AGENTS_EXTENDED="$EXT" \
       bash "$ONMERGE" "$WT" "worktree-additive" )
assert_eq "additive-only: skipped"   "True" "$(jget skipped <<< "$OUT")"
assert_eq "additive-only: preserved" "yes"  "$([ -d "$WT" ] && echo yes || echo no)"

# ── 19i: the secondary source is load-bearing for COVERAGE, not just tidy ───
# Measured against real `claude agents --json` (2026-08-19): the canonical probe
# filters on kind+status, so a background row carrying only `state` (e.g. a
# BLOCKED worker stuck at its Stop hook) is dropped — while
# claude-agents-extended.sh returns every row unfiltered. The union is what
# makes coverage complete, so a successful-but-blind primary must not be able to
# authorize a reap that the secondary would veto.
echo "[19i] primary succeeds but omits the path; secondary supplies it → in-use skip"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "union")
STUB="$R/_union_primary.sh"
printf '#!/bin/sh\nprintf "/somewhere/else\\n"\n' > "$STUB"; chmod +x "$STUB"
EXT="$R/_union_ext.sh"
printf '#!/bin/sh\nprintf "[{\\"cwd\\":\\"%s\\"}]\\n"\n' "$WT" > "$EXT"; chmod +x "$EXT"
OUT=$( cd "$R" && PWT_LIVE_SESSION_CWDS_SCRIPT="$STUB" \
       PWT_WORKTREE_GC_AGENTS_EXTENDED="$EXT" \
       bash "$ONMERGE" "$WT" "worktree-union" )
assert_eq "union coverage: skipped"   "True" "$(jget skipped <<< "$OUT")"
assert_eq "union coverage: preserved" "yes"  "$([ -d "$WT" ] && echo yes || echo no)"
case "$(jget reason <<< "$OUT")" in
    *in-use*) pass "union coverage: reason names in-use" ;;
    *) fail "union coverage: reason names in-use" "got: $(jget reason <<< "$OUT")" ;;
esac

# ── 19g: the SHIPPED force path is NOT exempt from the fail-closed arm ──────
# This is the case that makes the gap load-bearing rather than theoretical: on
# the .pwt-shipped path invariant 2 is relaxed BY DESIGN, so invariant 3 is the
# only remaining protection. The marker proves the WORK landed; it says nothing
# about whether a SESSION still owns the worktree.
echo "[19g] shipped-force + probe failed → still kept (marker ≠ session gone)"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "shipfail")
SHA=$(git -C "$WT" rev-parse HEAD)
printf '{"sha":"%s","tag":""}\n' "$SHA" > "$WT/.pwt-shipped"
mkdir -p "$WT/.claude/state"; echo '{}' > "$WT/.claude/state/bg-agents-cache.json"
echo 'post-ship generated' > "$WT/generated-artifact.txt"   # dirt invariant 2 would veto
OUT=$( cd "$R" && PWT_WORKTREE_GC_TEST_QUERY_FAILED=1 bash "$ONMERGE" "$WT" "worktree-shipfail" )
assert_eq "shipped+probe-failed: skipped"   "True" "$(jget skipped <<< "$OUT")"
assert_eq "shipped+probe-failed: preserved" "yes"  "$([ -d "$WT" ] && echo yes || echo no)"
case "$(jget reason <<< "$OUT")" in
    *"fail-closed"*) pass "shipped+probe-failed: kept by invariant 3, not invariant 2" ;;
    *) fail "shipped+probe-failed: kept by invariant 3, not invariant 2" "got: $(jget reason <<< "$OUT")" ;;
esac

# ── 19h: CONTROL — same shipped worktree, probe OK → force-remove still works ─
# Proves 19g is the liveness flag doing the work, not the shipped path breaking.
echo "[19h] control: shipped-force + probe succeeds → force-removed despite dirt"
R=$(new_repo)
WT=$(add_merged_worktree "$R" "shipok")
SHA=$(git -C "$WT" rev-parse HEAD)
printf '{"sha":"%s","tag":""}\n' "$SHA" > "$WT/.pwt-shipped"
echo 'post-ship generated' > "$WT/generated-artifact.txt"
STUB="$R/_shipok.sh"
printf '#!/bin/sh\nprintf "/somewhere/else\\n"\n' > "$STUB"; chmod +x "$STUB"
OUT=$( cd "$R" && PWT_LIVE_SESSION_CWDS_SCRIPT="$STUB" bash "$ONMERGE" "$WT" "worktree-shipok" )
assert_eq "shipped+probe-ok: removed" "True" "$(jget removed_worktree <<< "$OUT")"
assert_eq "shipped+probe-ok: dir gone" "no"  "$([ -d "$WT" ] && echo yes || echo no)"

# ── 20: AC14 — one path dialect across every porcelain call site ────────────
# Mechanical, not by inspection: a future edit that adds an unqualified
# `git … status --porcelain` to any of the three cleanup scripts fails here.
echo "[20] every 'status --porcelain' call site passes -c core.quotePath=false"
UNQUALIFIED=0
for f in plan-w-team-worktree-gc.sh plan-w-team-worktree-on-merge.sh plan-w-team-dirty-ignore-lib.sh; do
    # Executable call sites only: lines that actually invoke git (skip comments).
    while IFS= read -r line; do
        case "$line" in
            \#*) continue ;;
        esac
        case "$line" in
            *"core.quotePath=false"*) : ;;
            *) UNQUALIFIED=$((UNQUALIFIED + 1)); echo "    unqualified in $f: $line" ;;
        esac
    done <<< "$(grep -E '^[^#]*git .*status --porcelain' "$SCRIPT_DIR/$f" 2>/dev/null || true)"
done
assert_eq "no unqualified porcelain call sites" "0" "$UNQUALIFIED"

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
