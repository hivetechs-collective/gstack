#!/usr/bin/env bash
# Regression test for the --worker-only "stops short of ship" root cause
# (docs/specs/worker-only-stops-short-rootcause.md).
#
# THE BUG (run 10ac5920, 2026-06-07): pwt-goal.sh --worker-only seeded the
# anti-skip goal-state into $PROJECT_ROOT/.claude/state, where PROJECT_ROOT was
# resolved via `git rev-parse --show-toplevel`. When the launcher was invoked
# from inside a STALE SIBLING worktree, --show-toplevel returned the caller's
# worktree (pwt-evaluate-...), NOT the worker's freshly-created worktree
# (pwt-apply-...). The seed landed in the wrong directory, the worker's
# goal-evaluator never found it, the anti-skip anchor was inert, and the worker
# stopped freely after commit+push — never reaching Step 6 ship or Step 8 retro.
#
# THE FIX: pwt-goal.sh derives the worker's runtime worktree the SAME way
# `claude --bg --worktree <name>` does — via git-common-dir → MAIN_REPO —
# and seeds the goal-state into the worker's own worktree state dir AND the
# canonical main-repo state dir. await-terminal.sh disambiguates same-slug
# worktree goal-states by worker SID.
#
# This test is HERMETIC: it builds a throwaway git repo with a real sibling
# worktree, fakes `claude` (which materializes the worker worktree like the real
# binary), and invokes pwt-goal.sh --worker-only FROM INSIDE the stale sibling
# WITHOUT PWT_PROJECT_ROOT_OVERRIDE — so the real git-common-dir resolution path
# is exercised (the override would mask the bug, which is exactly why the
# existing pwt-goal-worker-only.test.sh never caught it).
#
# bash 3.2 compatible (mac-mini /bin/bash): no `declare -A`, no `mapfile`.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PWT_GOAL="$SCRIPT_DIR/pwt-goal.sh"
AWAIT="$SCRIPT_DIR/plan-w-team-await-terminal.sh"
[ -x "$PWT_GOAL" ] || { echo "FAIL: pwt-goal.sh not executable"; exit 1; }
[ -x "$AWAIT" ]    || { echo "FAIL: plan-w-team-await-terminal.sh not executable"; exit 1; }

PASS=0
FAIL=0
FAIL_NOTES=()
note_fail() { FAIL=$((FAIL+1)); FAIL_NOTES+=("$1"); printf "  \033[31m✗\033[0m %s\n" "$1"; }
note_pass() { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }

SANDBOX=$(mktemp -d -t pwt-seed-path-test.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

# ── Build a real main git repo ──────────────────────────────────────────────
MAIN="$SANDBOX/main"
mkdir -p "$MAIN"
(
  cd "$MAIN" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name  test
  git config commit.gpgsign false
  mkdir -p .claude/state
  echo "seed" > README.md
  git add -A && git commit -qm "init"
) || { echo "FAIL: could not init sandbox repo"; exit 1; }

# ── Create a REAL stale sibling worktree (the buggy caller location) ─────────
# This is the worktree the origin chat was sitting in when the bug fired; its
# basename intentionally differs from the worker's (evaluate vs apply).
STALE="$MAIN/.claude/worktrees/pwt-evaluate-stale-sibling"
(
  cd "$MAIN" || exit 1
  git worktree add -q -b stale-sibling "$STALE" >/dev/null 2>&1
) || { echo "FAIL: could not create stale sibling worktree"; exit 1; }
mkdir -p "$STALE/.claude/state"

# ── Fake `claude`: mimic real `claude --bg --worktree <name>` ───────────────
# It (a) parses --worktree <name>, (b) materializes the worker worktree under
# the MAIN repo's .claude/worktrees/ (resolved via git-common-dir, exactly as
# the real binary registers worktrees against the common git dir), and
# (c) prints one `backgrounded · <sid>` line. This makes the worker worktree
# EXIST at seed time, which is the production timeline (claude --bg returns
# after worktree setup).
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/claude" <<'FAKE'
#!/usr/bin/env bash
WT=""
prev=""
for a in "$@"; do
  [ "$prev" = "--worktree" ] && { WT="$a"; break; }
  prev="$a"
done
if [ -n "$WT" ]; then
  CDIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  if [ -n "$CDIR" ]; then
    case "$CDIR" in
      /*) MROOT=$(dirname "$CDIR") ;;
      *)  MROOT=$(cd "$(dirname "$CDIR")" 2>/dev/null && pwd || echo "") ;;
    esac
    [ -n "$MROOT" ] && mkdir -p "$MROOT/.claude/worktrees/$WT/.claude/state" 2>/dev/null || true
  fi
fi
echo "backgrounded · cafef00d"
exit 0
FAKE
chmod +x "$SANDBOX/bin/claude"

# Common env to keep the test focused on seed-path semantics (disable capacity
# gates + the cross-repo registry; avoid the PWT-DS2 cascade in nested shells).
common_env() {
  export PATH="$SANDBOX/bin:$PATH"
  export PWT_RAM_CLAIMS_REGISTRY="$SANDBOX/pwt-ram-claims.jsonl"
  export PLAN_W_TEAM_DISABLE_RAM_GATE=1
  export PLAN_W_TEAM_DISABLE_DISK_GATE=1
  export PLAN_W_TEAM_DISABLE_WORKTREE_CAP=1
  export PLAN_W_TEAM_DISABLE_FAIR_SHARE=1
  unset PLAN_W_TEAM_DISABLE_PROMPT_ROUTE 2>/dev/null || true
  unset PWT_PROJECT_ROOT_OVERRIDE 2>/dev/null || true   # <- exercise real git-common-dir path
  unset CLAUDE_PROJECT_DIR 2>/dev/null || true
  unset CLAUDE_JOB_DIR 2>/dev/null || true
}

REQUEST="fix the worker only stops short of ship root cause"

echo "Testing pwt-goal.sh --worker-only seed-path derivation (root-cause regression)"
echo

# ════════════════════════════════════════════════════════════════════════════
# Case 1 — invoked from inside the STALE sibling worktree (the bug condition)
# ════════════════════════════════════════════════════════════════════════════
( common_env; cd "$STALE" || exit 1; bash "$PWT_GOAL" --worker-only "$REQUEST" >/dev/null 2>&1 )

# Discover the worker worktree the fake claude created (the pwt-fix-... one,
# NOT the pwt-evaluate-stale-sibling caller).
WORKER_GOAL=""
for f in "$MAIN"/.claude/worktrees/*/.claude/state/plan-w-team-goal-*.json; do
  case "$f" in *pwt-evaluate-stale-sibling*) continue ;; esac   # skip the caller
  [ -f "$f" ] && { WORKER_GOAL="$f"; break; }
done

# AC1: seed landed in the worker's runtime worktree (under MAIN, not the caller).
if [ -n "$WORKER_GOAL" ]; then
  note_pass "AC1: goal-state seeded into worker runtime worktree ($(basename "$(dirname "$(dirname "$(dirname "$WORKER_GOAL")")")"))"
else
  note_fail "AC1: no goal-state in any worker worktree under MAIN/.claude/worktrees/"
fi

# AC1 (negative): the seed must NOT be in the stale caller worktree (the bug).
if [ -z "$(ls "$STALE"/.claude/state/plan-w-team-goal-*.json 2>/dev/null)" ]; then
  note_pass "AC1: stale caller worktree has NO goal-state (bug condition cleared)"
else
  note_fail "AC1: goal-state leaked into the STALE caller worktree (the original bug)"
fi

# AC2: a copy also lives in the canonical main-repo state dir, same worker_sid.
MAIN_GOAL=$(ls "$MAIN"/.claude/state/plan-w-team-goal-*.json 2>/dev/null | head -1)
if [ -n "$MAIN_GOAL" ] && [ -f "$MAIN_GOAL" ]; then
  M_SID=$(grep -o '"worker_sid"[^,}]*' "$MAIN_GOAL" | head -1)
  if printf '%s' "$M_SID" | grep -q 'cafef00d'; then
    note_pass "AC2: main-repo state has goal-state with worker_sid=cafef00d"
  else
    note_fail "AC2: main-repo goal-state present but worker_sid mismatch ($M_SID)"
  fi
else
  note_fail "AC2: no goal-state in canonical main-repo .claude/state/"
fi

# Slug parity: worker worktree basename == the --worktree name passed to claude.
WT_ARG=$(grep -o -- '--worktree [^ ]*' "$MAIN/.claude/worktrees/"*/.claude/state/* 2>/dev/null | head -1)  # noop guard
if [ -n "$WORKER_GOAL" ]; then
  WT_BASENAME=$(basename "$(dirname "$(dirname "$(dirname "$WORKER_GOAL")")")")
  case "$WT_BASENAME" in
    pwt-fix-the-worker-only*) note_pass "slug parity: worker worktree basename matches request slug ($WT_BASENAME)" ;;
    *) note_fail "slug parity: unexpected worker worktree basename ($WT_BASENAME)" ;;
  esac
fi

# ════════════════════════════════════════════════════════════════════════════
# Case 2 — :0:60 truncation parity (long request)
# ════════════════════════════════════════════════════════════════════════════
# Reset worktrees + state from case 1.
git -C "$MAIN" worktree prune >/dev/null 2>&1 || true
rm -rf "$MAIN"/.claude/worktrees/pwt-fix-* 2>/dev/null || true
rm -f  "$MAIN"/.claude/state/plan-w-team-goal-*.json 2>/dev/null || true
LONG="implement an exhaustively long feature description that definitely exceeds sixty characters of slug to force truncation parity checks"
( common_env; cd "$STALE" || exit 1; bash "$PWT_GOAL" --worker-only "$LONG" >/dev/null 2>&1 )
TRUNC_WT=""
for d in "$MAIN"/.claude/worktrees/pwt-*; do
  case "$d" in *pwt-evaluate-stale-sibling*) continue ;; esac
  [ -d "$d" ] && { TRUNC_WT="$d"; break; }
done
if [ -n "$TRUNC_WT" ]; then
  BN=$(basename "$TRUNC_WT")
  if [ "${#BN}" -le 60 ] && [ -f "$TRUNC_WT/.claude/state/plan-w-team-goal-"*.json ] 2>/dev/null; then
    note_pass "truncation parity: worker worktree basename is ${#BN}<=60 chars and carries the seed"
  else
    # second check without the glob-in-test for portability
    SEEDED=$(ls "$TRUNC_WT"/.claude/state/plan-w-team-goal-*.json 2>/dev/null | head -1)
    if [ "${#BN}" -le 60 ] && [ -n "$SEEDED" ]; then
      note_pass "truncation parity: worker worktree basename is ${#BN}<=60 chars and carries the seed"
    else
      note_fail "truncation parity: basename=${#BN} chars seeded=${SEEDED:-none}"
    fi
  fi
else
  note_fail "truncation parity: no truncated worker worktree created"
fi

# ════════════════════════════════════════════════════════════════════════════
# Case 3 — PWT_DISABLE_WORKER_WORKTREE=1 → seed ONLY into main repo
# ════════════════════════════════════════════════════════════════════════════
git -C "$MAIN" worktree prune >/dev/null 2>&1 || true
rm -rf "$MAIN"/.claude/worktrees/pwt-fix-* "$MAIN"/.claude/worktrees/pwt-implement-* 2>/dev/null || true
rm -f  "$MAIN"/.claude/state/plan-w-team-goal-*.json 2>/dev/null || true
( common_env; export PWT_DISABLE_WORKER_WORKTREE=1; cd "$STALE" || exit 1; bash "$PWT_GOAL" --worker-only "$REQUEST" >/dev/null 2>&1 )
MAIN_ONLY=$(ls "$MAIN"/.claude/state/plan-w-team-goal-*.json 2>/dev/null | head -1)
WT_LEAK=""
for f in "$MAIN"/.claude/worktrees/*/.claude/state/plan-w-team-goal-*.json; do
  case "$f" in *pwt-evaluate-stale-sibling*) continue ;; esac
  [ -f "$f" ] && { WT_LEAK="$f"; break; }
done
if [ -n "$MAIN_ONLY" ] && [ -z "$WT_LEAK" ]; then
  note_pass "AC3: PWT_DISABLE_WORKER_WORKTREE=1 seeds only the main-repo state (no worktree path)"
else
  note_fail "AC3: expected main-only seed; main=${MAIN_ONLY:-none} worktree_leak=${WT_LEAK:-none}"
fi

# ════════════════════════════════════════════════════════════════════════════
# Case 4 — await-terminal SID disambiguation among same-slug worktrees
# ════════════════════════════════════════════════════════════════════════════
# Two worktrees carry a goal-state with the SAME slug but DIFFERENT worker_sid.
# __resolve_goal_file must return the one whose worker_sid == --worker-sid.
DSLUG="disambig-slug"
mkdir -p "$MAIN/.claude/worktrees/wt-a/.claude/state" "$MAIN/.claude/worktrees/wt-b/.claude/state"
printf '{"slug":"%s","worker_sid":"aaaa1111","terminal_state":null}\n' "$DSLUG" \
  > "$MAIN/.claude/worktrees/wt-a/.claude/state/plan-w-team-goal-${DSLUG}.json"
printf '{"slug":"%s","worker_sid":"bbbb2222","terminal_state":null}\n' "$DSLUG" \
  > "$MAIN/.claude/worktrees/wt-b/.claude/state/plan-w-team-goal-${DSLUG}.json"
# Ensure main repo has NO same-slug file so the worktree glob is consulted.
rm -f "$MAIN"/.claude/state/plan-w-team-goal-${DSLUG}.json 2>/dev/null || true

RESOLVED=$( cd "$MAIN" && bash "$AWAIT" --slug "$DSLUG" --worker-sid "bbbb2222" --print-goal-file 2>/dev/null )
if printf '%s' "$RESOLVED" | grep -q "wt-b/.claude/state/plan-w-team-goal-${DSLUG}.json"; then
  note_pass "AC4: await-terminal resolves the worktree whose worker_sid matches --worker-sid (wt-b)"
else
  note_fail "AC4: SID disambiguation failed — resolved '$RESOLVED' (expected wt-b)"
fi

# AC4 fallback: with no --worker-sid, resolution must still succeed (first match).
RESOLVED2=$( cd "$MAIN" && bash "$AWAIT" --slug "$DSLUG" --print-goal-file 2>/dev/null )
if printf '%s' "$RESOLVED2" | grep -q "plan-w-team-goal-${DSLUG}.json"; then
  note_pass "AC4: no --worker-sid → first-match fallback still resolves (no regression)"
else
  note_fail "AC4: first-match fallback returned nothing ('$RESOLVED2')"
fi

echo
echo "─────────────────────────────────────────"
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:"
  for n in "${FAIL_NOTES[@]}"; do echo "  - $n"; done
  exit 1
fi
exit 0
