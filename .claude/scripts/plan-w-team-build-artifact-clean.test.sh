#!/usr/bin/env bash
# plan-w-team-build-artifact-clean.test.sh — E7 build-artifact hygiene.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/plan-w-team-build-artifact-clean.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: cleaner not executable"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TR=$(mktemp -d); trap 'rm -rf "$TR"' EXIT
WTS="$TR/.claude/worktrees"
mk_wt() { # $1 name → makes a worktree with artifacts + source + a node_modules symlink
    local n="$1"; local wt="$WTS/$n"   # separate locals — bash 3.2 same-stmt expansion trap
    mkdir -p "$wt/ios/Pods" "$wt/ios/DerivedData" "$wt/android/.gradle" "$wt/src"
    echo x > "$wt/ios/Pods/a"; echo x > "$wt/ios/DerivedData/a"; echo x > "$wt/android/.gradle/a"
    echo "source" > "$wt/src/app.ts"
    mkdir -p "$TR/real_nm"; echo dep > "$TR/real_nm/pkg"
    ln -s "$TR/real_nm" "$wt/node_modules"   # symlinked deps (E5) — must be preserved
    echo "$wt"
}
run() { PWT_PROJECT_ROOT_OVERRIDE="$TR" bash "$SCRIPT" "$@" 2>"$TR/err"; }

echo "── build-artifact-clean tests ──"

WT=$(mk_wt agent-a)

# [1] dry-run reports reclaimable but deletes nothing
OUT=$(run "$WT" --json)
{ echo "$OUT" | grep -q '"mode": "dry-run"' && [ -d "$WT/ios/Pods" ]; } \
  && ok "dry-run reports but does not delete" || bad "dry-run deleted or wrong mode"

# [2] execute removes the known artifact dirs
run "$WT" --execute >/dev/null
{ [ ! -d "$WT/ios/Pods" ] && [ ! -d "$WT/ios/DerivedData" ] && [ ! -d "$WT/android/.gradle" ]; } \
  && ok "execute removes ios/Pods, DerivedData, android/.gradle" || bad "artifacts not removed"

# [3] source is preserved
[ -f "$WT/src/app.ts" ] && ok "source files preserved" || bad "source deleted (BUG)"

# [4] node_modules symlink (shared deps, E5) is NOT touched
{ [ -L "$WT/node_modules" ] && [ -f "$WT/node_modules/pkg" ]; } \
  && ok "node_modules symlink + target preserved" || bad "node_modules disturbed (BUG)"

# [5] refuse a path OUTSIDE .claude/worktrees
mkdir -p "$TR/not-a-worktree/ios/Pods"
run "$TR/not-a-worktree" --execute >/dev/null
{ grep -qi "REFUSE" "$TR/err" && [ -d "$TR/not-a-worktree/ios/Pods" ]; } \
  && ok "refuses + preserves a path outside .claude/worktrees" || bad "did not refuse outside path"

# [6] --all sweeps every worktree
mk_wt agent-b >/dev/null; mk_wt agent-c >/dev/null
run --all --execute >/dev/null
{ [ ! -d "$WTS/agent-b/ios/Pods" ] && [ ! -d "$WTS/agent-c/android/.gradle" ]; } \
  && ok "--all sweeps every worktree" || bad "--all missed a worktree"

# [7] idempotent — re-run on already-clean worktree exits 0, reports ~0
run --all --execute >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "idempotent re-run exits 0" || bad "non-zero on clean re-run ($rc)"

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
