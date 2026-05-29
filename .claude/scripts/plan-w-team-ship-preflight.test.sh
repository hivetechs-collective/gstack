#!/usr/bin/env bash
# plan-w-team-ship-preflight.test.sh — REQ-1 pre-push self-heal (deps + sim).
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/plan-w-team-ship-preflight.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: preflight not executable"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
field() { printf '%s' "$1" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$2'))" 2>/dev/null; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# fakes
cat > "$T/pnpm" <<'EOF'
#!/bin/bash
[ "$1" = "install" ] && { mkdir -p node_modules/.bin; exit 0; }
exit 0
EOF
cat > "$T/pnpm_fail" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$T/xcrun_booted" <<'EOF'
#!/bin/bash
[ "$2" = "list" ] && { echo "    iPhone 15 (X) (Booted)"; exit 0; }
exit 0
EOF
cat > "$T/xcrun_idle" <<'EOF'
#!/bin/bash
[ "$2" = "list" ] && { echo "-- iOS 17.0 --"; exit 0; }
exit 0
EOF
cat > "$T/deps_share_ok" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$T"/pnpm "$T"/pnpm_fail "$T"/xcrun_booted "$T"/xcrun_idle "$T"/deps_share_ok

echo "── ship-preflight tests ──"

# [1] JS repo, node_modules missing → seeds via pnpm fallback
WT="$T/js"; mkdir -p "$WT"; echo lock > "$WT/pnpm-lock.yaml"
OUT=$(PWT_SHIP_SIM_SHUTDOWN=0 PWT_SHIP_PREFLIGHT_PNPM="$T/pnpm" "$SCRIPT" --worktree "$WT" --json)
[ "$(field "$OUT" deps_action)" = "pnpm-install-frozen" ] && ok "missing node_modules → pnpm-install-frozen" || bad "deps seed wrong: $OUT"

# [2] node_modules present → no-op
mkdir -p "$WT/node_modules/foo"
OUT=$(PWT_SHIP_SIM_SHUTDOWN=0 PWT_SHIP_PREFLIGHT_PNPM="$T/pnpm" "$SCRIPT" --worktree "$WT" --json)
[ "$(field "$OUT" deps_action)" = "present" ] && ok "present node_modules → no-op" || bad "should be present: $OUT"

# [3] deps-share path wins when a real main worktree + share succeeds
REPO="$T/repo"; git init -q "$REPO"; (cd "$REPO" && git config user.email t@t.t && git config user.name t && echo x>f && git add f && git commit -qm i)
echo lock > "$REPO/pnpm-lock.yaml"
WTW="$T/repo-wt"; git -C "$REPO" worktree add -q "$WTW" -b feat >/dev/null 2>&1
echo lock > "$WTW/pnpm-lock.yaml"; rm -rf "$WTW/node_modules"
OUT=$(PWT_SHIP_SIM_SHUTDOWN=0 PWT_DEPS_SHARE_CMD="$T/deps_share_ok" "$SCRIPT" --worktree "$WTW" --json)
[ "$(field "$OUT" deps_action)" = "shared-from-main" ] && ok "worktree+deps-share → shared-from-main" || bad "deps-share path wrong: $OUT"

# [4] deps seed fails cleanly when no share + no pnpm (fail-open, surfaced)
WTF="$T/jsfail"; mkdir -p "$WTF"; echo lock > "$WTF/pnpm-lock.yaml"
OUT=$(PWT_SHIP_SIM_SHUTDOWN=0 PWT_SHIP_PREFLIGHT_PNPM="$T/pnpm_fail" "$SCRIPT" --worktree "$WTF" --json); rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$(field "$OUT" deps_action)" | grep -q failed; } && ok "unseedable deps → failed(...) but exit 0 (fail-open)" || bad "fail-open wrong (rc=$rc $OUT)"

# [5] iOS repo + booted sim → shutdown
WI="$T/ios"; mkdir -p "$WI/ios"
OUT=$(PWT_SHIP_DEPS_DISABLE=1 PWT_SHIP_PREFLIGHT_XCRUN="$T/xcrun_booted" "$SCRIPT" --worktree "$WI" --json)
printf '%s' "$(field "$OUT" sim_action)" | grep -q "shutdown" && ok "iOS + booted sim → shutdown" || bad "sim shutdown wrong: $OUT"

# [6] iOS repo + NO booted sim → none-booted
OUT=$(PWT_SHIP_DEPS_DISABLE=1 PWT_SHIP_PREFLIGHT_XCRUN="$T/xcrun_idle" "$SCRIPT" --worktree "$WI" --json)
[ "$(field "$OUT" sim_action)" = "none-booted" ] && ok "iOS + no booted sim → none-booted" || bad "should be none-booted: $OUT"

# [7] PWT_SHIP_SIM_SHUTDOWN=0 → sim skipped even on iOS+booted
OUT=$(PWT_SHIP_DEPS_DISABLE=1 PWT_SHIP_SIM_SHUTDOWN=0 PWT_SHIP_PREFLIGHT_XCRUN="$T/xcrun_booted" "$SCRIPT" --worktree "$WI" --json)
[ "$(field "$OUT" sim_action)" = "skip" ] && ok "PWT_SHIP_SIM_SHUTDOWN=0 → sim skipped" || bad "sim kill-switch ignored: $OUT"

# [8] non-iOS, non-JS → both skip
WP="$T/plain"; mkdir -p "$WP"
OUT=$("$SCRIPT" --worktree "$WP" --json)
{ [ "$(field "$OUT" deps_action)" = "skip" ] && [ "$(field "$OUT" sim_action)" = "skip" ]; } && ok "plain repo → both skip" || bad "plain wrong: $OUT"

# [9] disable knob → disabled, exit 0
OUT=$(PWT_SHIP_PREFLIGHT_DISABLE=1 "$SCRIPT" --worktree "$WT" --json); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(field "$OUT" deps_action)" = "disabled" ]; } && ok "PWT_SHIP_PREFLIGHT_DISABLE=1 → disabled" || bad "disable knob failed"

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
