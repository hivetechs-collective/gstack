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
    git -C "$root" add seed.txt
    git -C "$root" commit -qm "seed"
    mkdir -p "$root/.claude/worktrees" "$root/.claude/state"
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

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
