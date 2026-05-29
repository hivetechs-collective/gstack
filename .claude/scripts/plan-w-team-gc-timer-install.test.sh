#!/usr/bin/env bash
# plan-w-team-gc-timer-install.test.sh — E3 auto-install of the worktree-GC timer.
# Runs entirely in a temp LaunchAgents dir with PWT_GC_TIMER_NO_LOAD=1 so it never
# touches the real ~/Library/LaunchAgents and never invokes launchctl.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/plan-w-team-gc-timer-install.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: installer not executable"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# HERMETIC: never let ANY invocation trigger the real disk-pressure sweep, which
# would run the production plan-w-team-worktree-gc.sh --execute against the live
# repo (side-effecting; flaky inside the concurrent full suite). The installer
# logic is exercised; the production GC is not.
export PWT_GC_TIMER_PRESSURE=0
export PWT_GC_TIMER_NO_LOAD=1

TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
# Common test env: temp agents dir, never load, never pressure-sweep, fixed label.
run() { PWT_GC_TIMER_AGENTS_DIR="$TD" PWT_GC_TIMER_NO_LOAD=1 PWT_GC_TIMER_PRESSURE=0 \
        PWT_GC_TIMER_LABEL=io.test.pwt-gc bash "$SCRIPT" "$@" 2>"$TD/err"; }
PLIST="$TD/io.test.pwt-gc.plist"

echo "── gc-timer install tests ──"

# [1] fresh install renders a plist
run >/dev/null
[ -f "$PLIST" ] && ok "fresh install renders the plist" || bad "no plist rendered ($(cat "$TD/err"))"

# [2] daily schedule — Weekday key dropped (template is weekly)
if [ -f "$PLIST" ]; then
  grep -q "Weekday" "$PLIST" && bad "Weekday still present (should be daily)" || ok "daily schedule (Weekday dropped)"
else bad "no plist for schedule check"; fi

# [3] placeholders substituted (no __REPO_PATH__ / __LABEL__ left)
if [ -f "$PLIST" ]; then
  grep -qE '__(REPO_PATH|LABEL)__' "$PLIST" && bad "placeholder left unsubstituted" || ok "placeholders substituted"
else bad "no plist for placeholder check"; fi

# [4] label honored
grep -q "io.test.pwt-gc" "$PLIST" 2>/dev/null && ok "custom label rendered" || bad "label not rendered"

# [5] idempotent — second run reports 'already current', content unchanged
SUM1=$(cksum "$PLIST" 2>/dev/null)
run >/dev/null
grep -q "already current" "$TD/err" && ok "second run is idempotent (already current)" || bad "not idempotent"
SUM2=$(cksum "$PLIST" 2>/dev/null)
[ "$SUM1" = "$SUM2" ] && ok "plist content unchanged on re-run" || bad "plist changed on re-run"

# [6] --status reports installed
run --status >"$TD/status"
grep -qi "installed" "$TD/status" && ok "--status reports installed" || bad "--status wrong: $(cat "$TD/status")"

# [7] --uninstall removes the plist
run --uninstall >/dev/null
[ ! -f "$PLIST" ] && ok "--uninstall removes the plist" || bad "plist not removed"

# [8] PWT_GC_TIMER_DISABLE=1 → no install, exit 0
PWT_GC_TIMER_DISABLE=1 PWT_GC_TIMER_AGENTS_DIR="$TD" PWT_GC_TIMER_NO_LOAD=1 PWT_GC_TIMER_LABEL=io.test.pwt-gc bash "$SCRIPT" >/dev/null 2>&1
rc=$?
{ [ "$rc" -eq 0 ] && [ ! -f "$PLIST" ]; } && ok "PWT_GC_TIMER_DISABLE=1 → no install, exit 0" || bad "disable knob honored? rc=$rc"

# [9] missing template → fail-open (exit 0, no crash)
( cd "$TD" && PWT_GC_TIMER_AGENTS_DIR="$TD/x" PWT_GC_TIMER_NO_LOAD=1 PWT_GC_TIMER_LABEL=io.test.pwt-gc \
    PWT_PROJECT_ROOT_OVERRIDE="$TD" bash "$SCRIPT" >/dev/null 2>&1 ); rc=$?
# (template lives next to the installer, so it IS found; this asserts the run
#  still exits 0 cleanly even from an unrelated cwd — fail-open contract.)
[ "$rc" -eq 0 ] && ok "runs fail-open (exit 0) from arbitrary cwd" || bad "non-zero exit ($rc)"

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
