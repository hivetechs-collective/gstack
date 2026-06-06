#!/usr/bin/env bash
# Tests for plan-w-team-worktree-gc.sh
#
# Builds throwaway fixture repos with real git worktrees under .claude/worktrees/
# and asserts the classifier produces the right CLASS / action for each case.
# gh is stubbed via PWT_WORKTREE_GC_DEFAULT_BRANCH + a fake gh on PATH so the
# squash-merge scenario can be exercised deterministically without network.
#
# Usage: bash .claude/scripts/plan-w-team-worktree-gc.test.sh
# Exits 0 on all-pass, 1 on any failure.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GC="$SCRIPT_DIR/plan-w-team-worktree-gc.sh"

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

# Create a fresh fixture "main checkout" git repo with a default branch `main`.
new_repo() {
    local root
    root="$(mktemp -d -t pwt-gc-test.XXXXXX)"
    ROOTS+=("$root")
    git -C "$root" init -q -b main
    git -C "$root" config user.email t@t.t
    git -C "$root" config user.name t
    echo "seed" > "$root/seed.txt"
    # Track .claude/state/ as a non-empty dir so worktrees inherit it and runtime
    # churn surfaces with its full path ("?? .claude/state/<file>" or
    # " M .claude/state/<file>") rather than a single collapsed "?? .claude/"
    # entry. Mirrors real repos and is required by the ignore-path dirty tests.
    mkdir -p "$root/.claude/state"
    echo "keep" > "$root/.claude/state/.gitkeep"
    git -C "$root" add seed.txt .claude/state/.gitkeep
    git -C "$root" commit -qm "seed"
    mkdir -p "$root/.claude/worktrees"
    echo "$root"
}

# Add a worktree on a new branch. $3 (optional) = "merge" to merge it back to main.
add_worktree() {
    local root="$1" name="$2" merge="${3:-}"
    local wt="$root/.claude/worktrees/$name"
    local branch="worktree-$name"
    git -C "$root" worktree add -q -b "$branch" "$wt" >/dev/null 2>&1
    echo "change-$name" > "$wt/file-$name.txt"
    git -C "$wt" add "file-$name.txt"
    git -C "$wt" commit -qm "work on $name"
    if [ "$merge" = "merge" ]; then
        git -C "$root" merge -q --no-ff "$branch" -m "merge $branch" >/dev/null 2>&1
    fi
    echo "$wt"
}

# Run the GC in a fixture, returning the JSON. We force gh OFF by default
# (PWT_WORKTREE_GC stubs) so local merge check is exercised; individual tests
# can override. Lock checks are disabled (fixtures aren't locked) and live-cwd
# is injected explicitly.
run_gc() {
    local root="$1"; shift
    ( cd "$root" && \
      PWT_WORKTREE_GC_DEFAULT_BRANCH=main \
      PWT_WORKTREE_GC_TEST_MODE=1 \
      PWT_WORKTREE_GC_IGNORE_LOCKS=1 \
      PATH="$root/_nogh:$PATH" \
      bash "$GC" "$@" 2>/dev/null )
}

# Disable gh by shadowing it with a non-executable stub dir entry. Simpler:
# point HOME/PATH so `gh` resolves to a stub that fails auth.
make_nogh() {
    local root="$1"
    mkdir -p "$root/_nogh"
    cat > "$root/_nogh/gh" <<'EOF'
#!/bin/bash
# stub gh that reports "not authenticated" → forces local merge fallback
if [ "$1" = "auth" ]; then exit 1; fi
exit 1
EOF
    chmod +x "$root/_nogh/gh"
}

# A gh stub that reports a given branch as squash-merged (in `pr list --state
# merged`) but where local `git branch --merged` would NOT see it (we never
# merge locally). Exercises the gh-source-of-truth path.
make_gh_merged() {
    local root="$1" merged_branch="$2"
    mkdir -p "$root/_gh"
    cat > "$root/_gh/gh" <<EOF
#!/bin/bash
case "\$*" in
  "auth status") exit 0 ;;
  *"repo view"*) echo "fixture/repo"; exit 0 ;;
  *"pr list"*"--state merged"*) echo "$merged_branch"; exit 0 ;;
  *"pr list"*"--state open"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$root/_gh/gh"
}

class_of() {
    # $1 json, $2 worktree name → CLASS
    python3 -c '
import json,sys
d=json.load(sys.stdin)
for w in d["worktrees"]:
    if w["name"]==sys.argv[1]:
        print(w["class"]); break
' "$2" <<< "$1"
}
action_of() {
    python3 -c '
import json,sys
d=json.load(sys.stdin)
for w in d["worktrees"]:
    if w["name"]==sys.argv[1]:
        print(w["action"]); break
' "$2" <<< "$1"
}
field_of() {
    python3 -c '
import json,sys
d=json.load(sys.stdin)
for w in d["worktrees"]:
    if w["name"]==sys.argv[1]:
        print(json.dumps(w.get(sys.argv[2]))); break
' "$2" "$3" <<< "$1"
}

echo "── plan-w-team-worktree-gc tests ──"

# ── Test 1: SAFE-PRUNE-MERGED via local merge ──────────────────────────────
echo "[1] SAFE-PRUNE-MERGED (local merge)"
R=$(new_repo); make_nogh "$R"
add_worktree "$R" "merged-feat" merge >/dev/null
JSON=$(run_gc "$R" --json)
assert_eq "merged worktree → SAFE-PRUNE-MERGED" "SAFE-PRUNE-MERGED" "$(class_of "$JSON" merged-feat)"
assert_eq "dry-run action is dry-remove" "dry-remove" "$(action_of "$JSON" merged-feat)"
assert_eq "merge_source reported local" "\"local\"" "$(field_of "$JSON" merged-feat merge_source)"

# ── Test 2: SAFE-PRUNE-MERGED via gh (squash-merge, NOT in local history) ───
echo "[2] SAFE-PRUNE-MERGED (gh squash-merge, invisible to local)"
R=$(new_repo)
add_worktree "$R" "squash-feat" >/dev/null   # NOT merged locally
make_gh_merged "$R" "worktree-squash-feat"
JSON=$( cd "$R" && PWT_WORKTREE_GC_DEFAULT_BRANCH=main PWT_WORKTREE_GC_TEST_MODE=1 \
        PWT_WORKTREE_GC_IGNORE_LOCKS=1 PATH="$R/_gh:$PATH" bash "$GC" --json 2>/dev/null )
assert_eq "squash-merged via gh → SAFE-PRUNE-MERGED" "SAFE-PRUNE-MERGED" "$(class_of "$JSON" squash-feat)"
assert_eq "merge_source reported gh" "\"gh\"" "$(field_of "$JSON" squash-feat merge_source)"
assert_eq "merged_by includes gh" "\"gh\"" "$(field_of "$JSON" squash-feat merged_by)"

# ── Test 3: SAFE-PRUNE-IDLE (old commit, no PR, unmerged) ───────────────────
echo "[3] SAFE-PRUNE-IDLE (commit older than idle threshold)"
R=$(new_repo); make_nogh "$R"
WT=$(add_worktree "$R" "idle-feat")
# Backdate the commit ~30 days
OLD=$(( $(date +%s) - 30*86400 ))
OLD_ISO=$(python3 -c "import time;print(time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime($OLD)))")
( cd "$WT" && GIT_COMMITTER_DATE="$OLD_ISO" git commit -q --amend --no-edit --date "$OLD_ISO" >/dev/null 2>&1 )
JSON=$(run_gc "$R" --json)
assert_eq "idle worktree → SAFE-PRUNE-IDLE" "SAFE-PRUNE-IDLE" "$(class_of "$JSON" idle-feat)"

# idle threshold override: with PWT_WORKTREE_IDLE_DAYS=99 it should NOT be idle
JSON=$( cd "$R" && PWT_WORKTREE_GC_DEFAULT_BRANCH=main PWT_WORKTREE_GC_TEST_MODE=1 \
        PWT_WORKTREE_GC_IGNORE_LOCKS=1 PWT_WORKTREE_IDLE_DAYS=99 PATH="$R/_nogh:$PATH" \
        bash "$GC" --json 2>/dev/null )
assert_eq "idle threshold 99d → ORPHAN-ASK not IDLE" "ORPHAN-ASK" "$(class_of "$JSON" idle-feat)"

# ── Test 4: UNSAFE-KEEP — uncommitted changes ──────────────────────────────
echo "[4] UNSAFE-KEEP (uncommitted changes)"
R=$(new_repo); make_nogh "$R"
WT=$(add_worktree "$R" "dirty-feat" merge)   # merged BUT dirty
echo "uncommitted" > "$WT/dirty.txt"          # untracked / dirty
JSON=$(run_gc "$R" --json)
assert_eq "dirty merged worktree → UNSAFE-KEEP" "UNSAFE-KEEP" "$(class_of "$JSON" dirty-feat)"
assert_eq "dirty worktree action keep" "keep" "$(action_of "$JSON" dirty-feat)"
assert_eq "uncommitted flag true" "true" "$(field_of "$JSON" dirty-feat uncommitted)"

# ── Test 5: UNSAFE-KEEP — in-use (live cwd injected) ───────────────────────
echo "[5] UNSAFE-KEEP (in-use via injected live cwd)"
R=$(new_repo); make_nogh "$R"
WT=$(add_worktree "$R" "inuse-feat" merge)   # merged but a live session has it
JSON=$( cd "$R" && PWT_WORKTREE_GC_DEFAULT_BRANCH=main PWT_WORKTREE_GC_IGNORE_LOCKS=1 \
        PWT_WORKTREE_GC_TEST_LIVE_CWDS="$WT" PATH="$R/_nogh:$PATH" bash "$GC" --json 2>/dev/null )
assert_eq "in-use merged worktree → UNSAFE-KEEP" "UNSAFE-KEEP" "$(class_of "$JSON" inuse-feat)"
assert_eq "in_use flag true" "true" "$(field_of "$JSON" inuse-feat in_use)"

# ── Test 6: UNSAFE-KEEP — registered in active PWT run (unmerged in-flight) ─
# An UNMERGED worktree with a fleet registry row is a genuinely in-flight run.
# (A merged branch + stale row is intentionally NOT kept — see Test 6b.)
echo "[6] UNSAFE-KEEP (registered in active /plan-w-team run, unmerged)"
R=$(new_repo); make_nogh "$R"
WT=$(add_worktree "$R" "active-feat")   # NOT merged → in-flight
printf '{"session_id":"abc","worktree_path":"%s","branch":"worktree-active-feat"}\n' "$WT" \
    > "$R/.claude/state/plan-w-team-spawned-children-active.jsonl"
JSON=$(run_gc "$R" --json)
assert_eq "registered-active unmerged worktree → UNSAFE-KEEP" "UNSAFE-KEEP" "$(class_of "$JSON" active-feat)"
assert_eq "active_run flag true" "true" "$(field_of "$JSON" active-feat active_run)"

# ── Test 6b: MERGED overrides a stale fleet row (post-merge garbage) ───────
echo "[6b] MERGED branch with stale fleet row → SAFE-PRUNE-MERGED (not kept)"
R=$(new_repo); make_nogh "$R"
WT=$(add_worktree "$R" "staleactive-feat" merge)   # merged + stale row
printf '{"session_id":"abc","worktree_path":"%s","branch":"worktree-staleactive-feat"}\n' "$WT" \
    > "$R/.claude/state/plan-w-team-spawned-children-stale.jsonl"
JSON=$(run_gc "$R" --json)
assert_eq "merged+stale-row → SAFE-PRUNE-MERGED" "SAFE-PRUNE-MERGED" "$(class_of "$JSON" staleactive-feat)"

# ── Test 7: ORPHAN-ASK and --orphans-ok gating ────────────────────────────
echo "[7] ORPHAN-ASK (unmerged, not idle) requires --orphans-ok"
R=$(new_repo); make_nogh "$R"
add_worktree "$R" "orphan-feat" >/dev/null   # unmerged, recent
JSON=$(run_gc "$R" --json)
assert_eq "unmerged recent → ORPHAN-ASK" "ORPHAN-ASK" "$(class_of "$JSON" orphan-feat)"
assert_eq "ORPHAN-ASK without flag → keep-orphan" "keep-orphan" "$(action_of "$JSON" orphan-feat)"
# With --orphans-ok (dry-run): action becomes dry-remove
JSON=$(run_gc "$R" --orphans-ok --json)
assert_eq "ORPHAN-ASK with --orphans-ok (dry) → dry-remove" "dry-remove" "$(action_of "$JSON" orphan-feat)"

# ── Test 8: safety — worktree outside .claude/worktrees/ is never enumerated ─
echo "[8] worktrees outside .claude/worktrees/ are never touched"
R=$(new_repo); make_nogh "$R"
OUTSIDE="$R/external-wt"
git -C "$R" worktree add -q -b external-branch "$OUTSIDE" >/dev/null 2>&1
add_worktree "$R" "inside-feat" merge >/dev/null
JSON=$(run_gc "$R" --json)
OUT_PRESENT=$(python3 -c '
import json,sys
d=json.load(sys.stdin)
print("yes" if any(w["name"]=="external-wt" for w in d["worktrees"]) else "no")
' <<< "$JSON")
assert_eq "external worktree not enumerated" "no" "$OUT_PRESENT"
assert_eq "external worktree dir still exists" "yes" "$([ -d "$OUTSIDE" ] && echo yes || echo no)"

# ── Test 9: --execute removes SAFE-PRUNE-MERGED worktree + branch ──────────
echo "[9] --execute removes merged worktree + branch + fleet row"
R=$(new_repo); make_nogh "$R"
WT=$(add_worktree "$R" "exec-feat" merge)
printf '{"session_id":"x","worktree_path":"%s","branch":"worktree-exec-feat"}\n' "$WT" \
    > "$R/.claude/state/plan-w-team-spawned-children-exec.jsonl"
JSON=$(run_gc "$R" --execute --json)
assert_eq "merged worktree action remove" "remove" "$(action_of "$JSON" exec-feat)"
assert_eq "removed_worktree true" "true" "$(field_of "$JSON" exec-feat removed_worktree)"
assert_eq "worktree dir gone" "no" "$([ -d "$WT" ] && echo yes || echo no)"
BRANCH_GONE=$(git -C "$R" show-ref --verify --quiet refs/heads/worktree-exec-feat && echo no || echo yes)
assert_eq "branch deleted" "yes" "$BRANCH_GONE"
FLEET_ROWS=$(grep -c . "$R/.claude/state/plan-w-team-spawned-children-exec.jsonl" 2>/dev/null)
FLEET_ROWS="${FLEET_ROWS:-0}"
assert_eq "fleet JSONL row unregistered" "0" "$FLEET_ROWS"

# ── Test 10: negative — --execute does NOT remove uncommitted worktree ─────
echo "[10] --execute preserves uncommitted worktree"
R=$(new_repo); make_nogh "$R"
WT=$(add_worktree "$R" "keepdirty-feat" merge)
echo "dirty" > "$WT/d.txt"
run_gc "$R" --execute --json >/dev/null
assert_eq "uncommitted worktree preserved" "yes" "$([ -d "$WT" ] && echo yes || echo no)"

# ── Test 11: negative — ORPHAN not removed without --orphans-ok even on --execute ─
echo "[11] --execute alone does NOT remove ORPHAN-ASK"
R=$(new_repo); make_nogh "$R"
WT=$(add_worktree "$R" "keeporphan-feat")
run_gc "$R" --execute --json >/dev/null
assert_eq "orphan preserved without --orphans-ok" "yes" "$([ -d "$WT" ] && echo yes || echo no)"
# With both flags it IS removed:
WT2=$(add_worktree "$R" "killorphan-feat")
run_gc "$R" --execute --orphans-ok --json >/dev/null
assert_eq "orphan removed with --execute --orphans-ok" "no" "$([ -d "$WT2" ] && echo yes || echo no)"

# ── Test 12: idempotency — re-run on clean repo is a no-op exit 0 ──────────
echo "[12] idempotency"
R=$(new_repo); make_nogh "$R"
add_worktree "$R" "idem-feat" merge >/dev/null
run_gc "$R" --execute --json >/dev/null
JSON=$(run_gc "$R" --execute --json); RC=$?
assert_eq "re-run exit 0" "0" "$RC"
REMOVED2=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["totals"]["removed"])' <<< "$JSON")
assert_eq "re-run removes nothing" "0" "$REMOVED2"

# ── Test 13: scope selectors ───────────────────────────────────────────────
echo "[13] scope selectors (subagents-of-current-run, branch)"
R=$(new_repo); make_nogh "$R"
add_worktree "$R" "agent-deadbeef" merge >/dev/null
add_worktree "$R" "regular-feat" merge >/dev/null
JSON=$(run_gc "$R" --scope subagents-of-current-run --json)
N_SCOPED=$(python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d["worktrees"]))' <<< "$JSON")
assert_eq "subagents scope counts only agent-* (scanned)" "1" "$N_SCOPED"
ONLY_AGENT=$(python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["worktrees"][0]["name"] if d["worktrees"] else "none")' <<< "$JSON")
assert_eq "scoped worktree is the agent one" "agent-deadbeef" "$ONLY_AGENT"
# branch scope
JSON=$(run_gc "$R" --scope branch --branch worktree-regular-feat --json)
N_BR=$(python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d["worktrees"]))' <<< "$JSON")
assert_eq "branch scope counts only the matching branch" "1" "$N_BR"

# ── Test 14: JSON schema well-formedness ───────────────────────────────────
echo "[14] JSON output schema"
R=$(new_repo); make_nogh "$R"
add_worktree "$R" "schema-feat" merge >/dev/null
JSON=$(run_gc "$R" --json)
SCHEMA_OK=$(python3 -c '
import json,sys
d=json.load(sys.stdin)
need=["schema","main_checkout","default_branch","merge_source","gh_available","mode","scope","totals","worktrees"]
print("ok" if all(k in d for k in need) and d["schema"]=="plan-w-team-worktree-gc/v1" else "bad")
' <<< "$JSON")
assert_eq "JSON has all top-level keys + schema id" "ok" "$SCHEMA_OK"

# ── Test 15: disable kill-switch ───────────────────────────────────────────
echo "[15] PWT_WORKTREE_GC_DISABLE=1 → no-op"
R=$(new_repo)
OUT=$( cd "$R" && PWT_WORKTREE_GC_DISABLE=1 bash "$GC" --json 2>/dev/null )
SKIPPED=$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("skipped"))' <<< "$OUT")
assert_eq "disable returns skipped:true" "True" "$SKIPPED"

# ── Test 16: bash 3.2 compatibility (macOS /bin/bash; mac-mini deployment) ──
# Guards the regression class that broke the Layer 2 engine (`declare -A`):
# `bash -n` can't catch a runtime bash-4 builtin failure, so run the classifier
# under /bin/bash 3.2 and assert no bash-4 error signature + valid JSON.
echo "[16] runs clean under bash 3.2 (/bin/bash on macOS)"
if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
    R=$(new_repo); make_nogh "$R"; add_worktree "$R" b32 merge >/dev/null
    ERRF="$R/b32.err"
    OUT=$( cd "$R" && PWT_WORKTREE_GC_DEFAULT_BRANCH=main PWT_WORKTREE_GC_TEST_MODE=1 \
           PWT_WORKTREE_GC_IGNORE_LOCKS=1 PATH="$R/_nogh:$PATH" \
           /bin/bash "$GC" --json 2>"$ERRF" ); RC=$?
    ERR=$(cat "$ERRF" 2>/dev/null)
    case "$ERR" in
        *"invalid option"*|*"declare:"*|*"unbound variable"*|*"bad substitution"*) E32=1 ;;
        *) E32=0 ;;
    esac
    VALID=$(printf '%s' "$OUT" | python3 -c 'import json,sys; json.loads(sys.stdin.read()); print("ok")' 2>/dev/null || echo bad)
    assert_eq "bash 3.2: no bash-4 error signature" "0" "$E32"
    assert_eq "bash 3.2: exits 0" "0" "$RC"
    assert_eq "bash 3.2: emits valid classifier JSON" "ok" "$VALID"
else
    echo "  ⊘ skipped (no bash 3.2 at /bin/bash — not the regression-risk host)"
fi

# ── Test 17: ignore-path dirty — churn confined to .claude/state/ is "clean" ─
# Runtime hooks rewrite .claude/state/* into every worktree. A merged worktree
# dirty ONLY in those paths must still be reclaimable (Change C, 2026-05).
echo "[17] dirty only in .claude/state/ → treated clean → SAFE-PRUNE-MERGED"
R=$(new_repo); make_nogh "$R"
WT=$(add_worktree "$R" "statedirty-feat" merge)
mkdir -p "$WT/.claude/state"
echo '{"cache":1}' > "$WT/.claude/state/bg-agents-cache.json"   # transient churn
JSON=$(run_gc "$R" --json)
assert_eq "state-only-dirty merged → SAFE-PRUNE-MERGED" "SAFE-PRUNE-MERGED" "$(class_of "$JSON" statedirty-feat)"
assert_eq "state-only-dirty uncommitted flag false" "false" "$(field_of "$JSON" statedirty-feat uncommitted)"

# ── Test 18: ignore-path dirty — a REAL edit alongside state churn still blocks ─
echo "[18] real edit + state churn → UNSAFE-KEEP (real work protected)"
R=$(new_repo); make_nogh "$R"
WT=$(add_worktree "$R" "realdirty-feat" merge)
mkdir -p "$WT/.claude/state"
echo '{"cache":1}' > "$WT/.claude/state/bg-agents-cache.json"   # ignored
echo "genuine work" > "$WT/important.txt"                        # NOT ignored
JSON=$(run_gc "$R" --json)
assert_eq "real-edit merged → UNSAFE-KEEP" "UNSAFE-KEEP" "$(class_of "$JSON" realdirty-feat)"
assert_eq "real-edit uncommitted flag true" "true" "$(field_of "$JSON" realdirty-feat uncommitted)"

# Helper: run GC WITHOUT ignoring locks (exercises stale-lock logic). Still uses
# TEST_MODE=1 so the live-session scan is empty — lock liveness comes only from
# commit recency. gh stub (passed via PATH) supplies merged-ness.
run_gc_locks() {
    local root="$1" ghdir="$2"; shift 2
    ( cd "$root" && PWT_WORKTREE_GC_DEFAULT_BRANCH=main PWT_WORKTREE_GC_TEST_MODE=1 \
      PATH="$root/$ghdir:$PATH" bash "$GC" "$@" 2>/dev/null )
}
backdate_tip() {  # $1 worktree — push tip commit ~30 days into the past
    local wt="$1" old old_iso
    old=$(( $(date +%s) - 30*86400 ))
    old_iso=$(python3 -c "import time;print(time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime($old)))")
    ( cd "$wt" && GIT_COMMITTER_DATE="$old_iso" git commit -q --amend --no-edit --date "$old_iso" >/dev/null 2>&1 )
}
backdate_tip_hours() {  # $1 worktree, $2 hours — push tip commit N hours into the past
    local wt="$1" hrs="$2" old old_iso
    old=$(( $(date +%s) - hrs*3600 ))
    old_iso=$(python3 -c "import time;print(time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime($old)))")
    ( cd "$wt" && GIT_COMMITTER_DATE="$old_iso" git commit -q --amend --no-edit --date "$old_iso" >/dev/null 2>&1 )
}

# ── Test 19: stale lock — locked + merged + OLD commit → lock ignored, pruned ─
# This is the disk-bloat root cause: a lock left behind by a dead subagent must
# NOT pin a merged worktree forever (Change B, 2026-05).
echo "[19] stale lock (locked + merged + old commit) → SAFE-PRUNE-MERGED"
R=$(new_repo)
WT=$(add_worktree "$R" "stalelock-feat")          # not merged locally
backdate_tip "$WT"                                 # commit > LOCK_STALE_HOURS old
make_gh_merged "$R" "worktree-stalelock-feat"      # gh says merged
git -C "$R" worktree lock "$WT" >/dev/null 2>&1
JSON=$(run_gc_locks "$R" _gh --json)
assert_eq "stale-locked merged → SAFE-PRUNE-MERGED" "SAFE-PRUNE-MERGED" "$(class_of "$JSON" stalelock-feat)"
assert_eq "stale-locked locked flag true" "true" "$(field_of "$JSON" stalelock-feat locked)"
assert_eq "stale-locked stale_lock flag true" "true" "$(field_of "$JSON" stalelock-feat stale_lock)"

# ── Test 19b: E1 default 24h→6h — locked + merged + ~10h-old commit → PRUNED ──
# Under the OLD 24h default this 10h-old lock was "recent" and KEPT; under the new
# 6h default (PWT_STALE_LOCK_HOURS) it is stale and the merged worktree is reaped.
echo "[19b] stale lock (locked + merged + 10h-old commit) → SAFE-PRUNE-MERGED (6h default)"
R=$(new_repo)
WT=$(add_worktree "$R" "tenhrlock-feat")
backdate_tip_hours "$WT" 10
make_gh_merged "$R" "worktree-tenhrlock-feat"
git -C "$R" worktree lock "$WT" >/dev/null 2>&1
JSON=$(run_gc_locks "$R" _gh --json)
assert_eq "10h-old locked merged → SAFE-PRUNE-MERGED (new 6h default)" "SAFE-PRUNE-MERGED" "$(class_of "$JSON" tenhrlock-feat)"
# And the legacy 24h knob still wins when set explicitly (kept as lock-recent).
JSON=$( cd "$R" && PWT_WORKTREE_GC_DEFAULT_BRANCH=main PWT_WORKTREE_GC_TEST_MODE=1 \
        PWT_STALE_LOCK_HOURS=24 PATH="$R/_gh:$PATH" bash "$GC" --json 2>/dev/null )
assert_eq "PWT_STALE_LOCK_HOURS=24 → 10h lock kept (lock-recent)" "UNSAFE-KEEP" "$(class_of "$JSON" tenhrlock-feat)"

# ── Test 20: fresh lock — locked + RECENT commit → honored as in-use (kept) ──
# A lock backed by recent activity may be a live agent the scan missed; keep it.
echo "[20] fresh lock (locked + recent commit) → UNSAFE-KEEP (lock-recent)"
R=$(new_repo)
WT=$(add_worktree "$R" "freshlock-feat")           # recent commit (now)
make_gh_merged "$R" "worktree-freshlock-feat"
git -C "$R" worktree lock "$WT" >/dev/null 2>&1
JSON=$(run_gc_locks "$R" _gh --json)
assert_eq "fresh-locked → UNSAFE-KEEP" "UNSAFE-KEEP" "$(class_of "$JSON" freshlock-feat)"
assert_eq "fresh-locked in_use_source lock-recent" "\"lock-recent\"" "$(field_of "$JSON" freshlock-feat in_use_source)"

# ── Test 21: TRUST_LOCKS=1 restores legacy any-lock=in-use ──────────────────
echo "[21] PWT_WORKTREE_GC_TRUST_LOCKS=1 → old locked worktree kept"
R=$(new_repo)
WT=$(add_worktree "$R" "trustlock-feat")
backdate_tip "$WT"                                 # old → would be STALE by default
make_gh_merged "$R" "worktree-trustlock-feat"
git -C "$R" worktree lock "$WT" >/dev/null 2>&1
JSON=$( cd "$R" && PWT_WORKTREE_GC_DEFAULT_BRANCH=main PWT_WORKTREE_GC_TEST_MODE=1 \
        PWT_WORKTREE_GC_TRUST_LOCKS=1 PATH="$R/_gh:$PATH" bash "$GC" --json 2>/dev/null )
assert_eq "trusted lock → UNSAFE-KEEP" "UNSAFE-KEEP" "$(class_of "$JSON" trustlock-feat)"

# ── helper: give a repo a real `origin` remote (bare) and push a branch ──────
# Used by the SAFE-PRUNE-PUSHED (AC1) tests so `git branch -r --contains` sees the
# worktree's HEAD on origin/*.
add_origin() {
    local root="$1"
    local bare="$root/_origin.git"
    [ -d "$bare" ] || git init -q --bare "$bare"
    git -C "$root" remote add origin "$bare" 2>/dev/null || git -C "$root" remote set-url origin "$bare"
}
push_branch() {  # $1 root, $2 branch
    git -C "$1" push -q origin "$2" 2>/dev/null
    git -C "$1" fetch -q origin 2>/dev/null   # populate refs/remotes/origin/*
}

# ── Test 22 (AC1): pushed-not-merged worktree → SAFE-PRUNE-PUSHED ───────────
echo "[22] AC1: pushed (origin-reachable) + unmerged + only-policy-churn → SAFE-PRUNE-PUSHED"
R=$(new_repo); make_nogh "$R"; add_origin "$R"
WT=$(add_worktree "$R" "pushed-feat")        # committed, NOT merged to main
push_branch "$R" "worktree-pushed-feat"      # HEAD now on origin/*
# add ONLY policy churn (.claude/*) — must still be reapable
mkdir -p "$WT/.claude/commands/plan-w-team"
echo "tooling" > "$WT/.claude/commands/plan-w-team/x.md"
JSON=$(run_gc "$R" --json)
assert_eq "pushed unmerged → SAFE-PRUNE-PUSHED" "SAFE-PRUNE-PUSHED" "$(class_of "$JSON" pushed-feat)"
assert_eq "pushed origin_reachable flag true" "true" "$(field_of "$JSON" pushed-feat origin_reachable)"
assert_eq "pushed dry-run action dry-remove" "dry-remove" "$(action_of "$JSON" pushed-feat)"
assert_eq "pushed uncommitted flag false (only .claude churn)" "false" "$(field_of "$JSON" pushed-feat uncommitted)"
# --execute reaps it like any SAFE-PRUNE (NOT orphan-gated)
run_gc "$R" --execute --json >/dev/null
assert_eq "pushed worktree removed under --execute (no --orphans-ok)" "no" "$([ -d "$WT" ] && echo yes || echo no)"

# ── Test 23 (AC1 negative): pushed BUT real uncommitted work → UNSAFE-KEEP ──
echo "[23] AC1 negative: pushed + REAL non-policy delta → UNSAFE-KEEP (not pruned)"
R=$(new_repo); make_nogh "$R"; add_origin "$R"
WT=$(add_worktree "$R" "pushedreal-feat")
push_branch "$R" "worktree-pushedreal-feat"
echo "real work" > "$WT/src.txt"             # NON-ignored real delta
JSON=$(run_gc "$R" --json)
assert_eq "pushed + real delta → UNSAFE-KEEP" "UNSAFE-KEEP" "$(class_of "$JSON" pushedreal-feat)"
assert_eq "pushed + real delta uncommitted true" "true" "$(field_of "$JSON" pushedreal-feat uncommitted)"

# ── Test 24 (AC2): broadened dirty-exclusion (.claude + node_modules + dist) ─
echo "[24] AC2: dirty only across .claude/ + node_modules/ + dist/ → treated clean"
R=$(new_repo); make_nogh "$R"
# Build the worktree manually so apps/web is TRACKED before the merge (real-repo
# layout): then an untracked dist/ surfaces as "apps/web/dist/" rather than git
# collapsing the whole untracked "apps/" to one porcelain line.
WT="$R/.claude/worktrees/broaddirty-feat"
git -C "$R" worktree add -q -b worktree-broaddirty-feat "$WT" >/dev/null 2>&1
mkdir -p "$WT/apps/web"
echo "tracked" > "$WT/apps/web/app.ts"
echo "change" > "$WT/file-broaddirty-feat.txt"
git -C "$WT" add apps/web/app.ts file-broaddirty-feat.txt >/dev/null 2>&1
git -C "$WT" commit -qm "work + track apps/web" >/dev/null 2>&1
git -C "$R" merge -q --no-ff worktree-broaddirty-feat -m "merge broaddirty" >/dev/null 2>&1
mkdir -p "$WT/.claude/hooks" "$WT/node_modules/pkg" "$WT/apps/web/dist"
echo x > "$WT/.claude/hooks/h.sh"
echo y > "$WT/node_modules/pkg/index.js"
echo z > "$WT/apps/web/dist/bundle.js"
JSON=$(run_gc "$R" --json)
assert_eq "broadened-ignore merged → SAFE-PRUNE-MERGED" "SAFE-PRUNE-MERGED" "$(class_of "$JSON" broaddirty-feat)"
assert_eq "broadened-ignore uncommitted false" "false" "$(field_of "$JSON" broaddirty-feat uncommitted)"
# a single real edit alongside the ignored churn still blocks
echo "real" > "$WT/README-change.txt"
JSON=$(run_gc "$R" --json)
assert_eq "real edit beside broadened churn → UNSAFE-KEEP" "UNSAFE-KEEP" "$(class_of "$JSON" broaddirty-feat)"

# ── Test 25 (AC5b): git-unregistered orphan dir → ORPHAN-ASK ────────────────
echo "[25] AC5b: git-unregistered dir under .claude/worktrees/ → ORPHAN-ASK"
R=$(new_repo); make_nogh "$R"
ORPHAN="$R/.claude/worktrees/orphan-leftover"
mkdir -p "$ORPHAN/node_modules"
echo "dep" > "$ORPHAN/node_modules/x.js"      # only ignored content → no patch needed
# NOTE: no TEST_MODE here so the registered-worktree check actually runs.
JSON=$( cd "$R" && PWT_WORKTREE_GC_DEFAULT_BRANCH=main PWT_WORKTREE_GC_IGNORE_LOCKS=1 \
        PATH="$R/_nogh:$PATH" bash "$GC" --json 2>/dev/null )
assert_eq "unregistered dir → ORPHAN-ASK" "ORPHAN-ASK" "$(class_of "$JSON" orphan-leftover)"
assert_eq "unregistered dir orphan_dir flag true" "true" "$(field_of "$JSON" orphan-leftover orphan_dir)"
assert_eq "unregistered dir without --orphans-ok → keep-orphan" "keep-orphan" "$(action_of "$JSON" orphan-leftover)"

# ── Test 26 (AC6): preserve-then-reap dumps a backup before forced removal ───
echo "[26] AC6: orphan dir with REAL files → backup written before reap"
R=$(new_repo); make_nogh "$R"
ORPHAN="$R/.claude/worktrees/orphan-realwork"
mkdir -p "$ORPHAN/src" "$ORPHAN/node_modules"
echo "unique work" > "$ORPHAN/src/keep.ts"    # REAL non-ignored file
echo "dep" > "$ORPHAN/node_modules/y.js"      # ignored
( cd "$R" && PWT_WORKTREE_GC_DEFAULT_BRANCH=main PWT_WORKTREE_GC_IGNORE_LOCKS=1 \
  PATH="$R/_nogh:$PATH" bash "$GC" --execute --orphans-ok --json >/dev/null 2>&1 )
assert_eq "orphan-realwork dir removed under --orphans-ok" "no" "$([ -d "$ORPHAN" ] && echo yes || echo no)"
BACKUP_HIT=$(ls -d "$R"/.claude/state/hygiene-backups/orphan-realwork-*.files 2>/dev/null | head -1)
assert_eq "preserve-then-reap wrote a backup .files dir" "yes" "$([ -n "$BACKUP_HIT" ] && [ -f "$BACKUP_HIT/src/keep.ts" ] && echo yes || echo no)"
MANIFEST_HIT=$(ls "$R"/.claude/state/hygiene-backups/orphan-realwork-*.manifest.txt 2>/dev/null | head -1)
assert_eq "preserve-then-reap wrote a manifest" "yes" "$([ -n "$MANIFEST_HIT" ] && echo yes || echo no)"
# node_modules (ignored) must NOT be copied
assert_eq "ignored node_modules NOT preserved" "no" "$([ -n "$BACKUP_HIT" ] && [ -e "$BACKUP_HIT/node_modules/y.js" ] && echo yes || echo no)"

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
