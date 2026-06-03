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

# ── installable preservation (build-artifact-preservation feature, 1.28.0) ──
# FINAL artifacts (*.app/*.ipa/*.apk/*.aab) must be PRESERVED (relocated to the
# kept-artifacts home), while the GB-scale intermediates in the same dir are still
# reclaimed. Mirrors the cleanscale incident: a .app deleted with its ios/build dir.
KEPT="$TR/.playwright-mcp/kept-build-artifacts"   # default home, rooted at REPO_ROOT (=$TR)

# [8]+[9] a .app inside ios/build is RELOCATED to the kept home (not deleted),
#         while a 2 MB intermediate in the same dir IS reclaimed in the same run.
WT2=$(mk_wt agent-d)
mkdir -p "$WT2/ios/build/Debug-iphonesimulator/MyApp.app/Contents"
echo "binary" > "$WT2/ios/build/Debug-iphonesimulator/MyApp.app/Contents/MyApp"
mkdir -p "$WT2/ios/build/Intermediates"
dd if=/dev/zero of="$WT2/ios/build/Intermediates/big.o" bs=1024 count=2048 2>/dev/null
OUT2=$(run "$WT2" --execute --json)
[ -f "$KEPT/agent-d/ios/build/Debug-iphonesimulator/MyApp.app/Contents/MyApp" ] \
  && ok "[AC1] .app inside ios/build relocated to kept home (not deleted)" \
  || bad "[AC1] .app NOT preserved — installable was deleted with its build dir (BUG)"
{ echo "$OUT2" | grep -qE '"reclaimable_mb": [1-9]' && [ ! -d "$WT2/ios/build" ]; } \
  && ok "[AC2] intermediates reclaimed (>=1 MB) in the same run; build dir removed" \
  || bad "[AC2] intermediate reclaim regressed (savings lost)"

# [10] .ipa/.apk/.aab inside android/build + ios/build are likewise preserved
WT3=$(mk_wt agent-e)
mkdir -p "$WT3/android/build/outputs" "$WT3/android/build/intermediates" "$WT3/ios/build"
echo apk > "$WT3/android/build/outputs/app.apk"
echo aab > "$WT3/android/build/outputs/app.aab"
echo ipa > "$WT3/ios/build/App.ipa"
echo o   > "$WT3/android/build/intermediates/o"
run "$WT3" --execute >/dev/null
{ [ -f "$KEPT/agent-e/android/build/outputs/app.apk" ] \
  && [ -f "$KEPT/agent-e/android/build/outputs/app.aab" ] \
  && [ -f "$KEPT/agent-e/ios/build/App.ipa" ] \
  && [ ! -d "$WT3/android/build" ] && [ ! -d "$WT3/ios/build" ]; } \
  && ok "[AC3-clean] .ipa/.apk/.aab preserved; intermediate build dirs removed" \
  || bad "[AC3-clean] android/ios installables not preserved"

# [11] kept-artifacts home is NEVER touched by a subsequent --all sweep
run --all --execute >/dev/null
{ [ -f "$KEPT/agent-d/ios/build/Debug-iphonesimulator/MyApp.app/Contents/MyApp" ] \
  && [ -f "$KEPT/agent-e/android/build/outputs/app.apk" ]; } \
  && ok "[AC5-clean] kept-artifacts home survives an --all sweep (never cleaned)" \
  || bad "[AC5-clean] kept home was clobbered by sweep (BUG)"

# [12] PWT_KEPT_ARTIFACTS_HOME absolute override is honored as-is
WT4=$(mk_wt agent-f)
mkdir -p "$WT4/ios/build"; echo ipa > "$WT4/ios/build/keep.ipa"
ALT="$TR/alt-kept"
PWT_KEPT_ARTIFACTS_HOME="$ALT" PWT_PROJECT_ROOT_OVERRIDE="$TR" bash "$SCRIPT" "$WT4" --execute 2>"$TR/err"
[ -f "$ALT/kept-build-artifacts/agent-f/ios/build/keep.ipa" ] \
  && ok "PWT_KEPT_ARTIFACTS_HOME (absolute) override honored" \
  || bad "PWT_KEPT_ARTIFACTS_HOME override ignored"

# [13] the clean script refuses to clean the kept home itself (in-tree guard)
mkdir -p "$WTS/.kepthome/ios/build"; echo ipa > "$WTS/.kepthome/ios/build/x.ipa"
PWT_KEPT_ARTIFACTS_HOME="$WTS/.kepthome" PWT_PROJECT_ROOT_OVERRIDE="$TR" \
  bash "$SCRIPT" "$WTS/.kepthome" --execute 2>"$TR/err"
[ -f "$WTS/.kepthome/ios/build/x.ipa" ] \
  && ok "refuses to clean the kept-artifacts home itself" \
  || bad "cleaned inside the kept home (BUG: home not protected)"

# [14] dry-run still moves/deletes NOTHING even with installables present
WT5=$(mk_wt agent-g)
mkdir -p "$WT5/ios/build"; echo app > "$WT5/ios/build/Z.app"
run "$WT5" >/dev/null   # dry-run (no --execute)
{ [ -f "$WT5/ios/build/Z.app" ] && [ ! -e "$KEPT/agent-g/ios/build/Z.app" ]; } \
  && ok "dry-run preserves in place — no move, no delete" \
  || bad "dry-run moved or deleted an artifact (BUG)"

# [15] FAIL CLOSED: if find cannot fully enumerate a build dir (unreadable subdir),
# the dir is KEPT, never silently deleted (a hidden installable could be inside).
# (root bypasses unix perms, so the find error can't be simulated there — skip.)
if [ "$(id -u)" != "0" ]; then
  WT6=$(mk_wt agent-h)
  mkdir -p "$WT6/ios/build/locked"; echo x > "$WT6/ios/build/locked/secret"
  chmod 000 "$WT6/ios/build/locked"
  run "$WT6" --execute >/dev/null 2>&1
  [ -d "$WT6/ios/build" ] \
    && ok "find-error fails CLOSED — build dir kept, not silently deleted" \
    || bad "find-error deleted the dir (fail-OPEN regression — could lose an installable)"
  chmod 755 "$WT6/ios/build/locked" 2>/dev/null   # restore so the EXIT trap can clean up
else
  ok "find-error fail-closed (skipped — running as root, perms not enforceable)"
fi

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
