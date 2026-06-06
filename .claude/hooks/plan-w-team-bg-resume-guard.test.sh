#!/usr/bin/env bash
# plan-w-team-bg-resume-guard.test.sh — AC4 SessionStart resume-staleness guard.
#
# Drives the hook with canned SessionStart JSON on stdin and a stubbed stop command
# (PWT_RESUME_GUARD_STOP_CMD writes the stopped sid to a file) so no real session is
# signalled. Covers: STALE → stop requested + systemMessage; LIVE → no stop; UNKNOWN
# → no stop (fail-open); disabled → no-op; plus an end-to-end path through the real
# pwt-goal.sh --resume-staleness-check against a seeded terminal goal-state.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD="$SCRIPT_DIR/plan-w-team-bg-resume-guard.sh"
PWT_GOAL="$SCRIPT_DIR/../scripts/pwt-goal.sh"
[ -x "$GUARD" ] || { echo "FAIL: guard not executable"; exit 1; }

PASS=0; FAIL=0; ROOTS=()
pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; echo "    $2"; FAIL=$((FAIL+1)); }
assert_eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "expected=[$2] actual=[$3]"; }
cleanup() { for r in "${ROOTS[@]:-}"; do [ -n "${r:-}" ] && rm -rf "$r"; done; }
trap cleanup EXIT

mkroot() { local r; r="$(mktemp -d -t pwt-resume.XXXXXX)"; ROOTS+=("$r"); mkdir -p "$r/.claude/state"; echo "$r"; }

# Build a real stop-stub SCRIPT that records its first arg (the stopped sid) into
# the given file. Returns the script path. (A bare command string can't carry the
# redirection / positional the guard invokes via `$STOP_CMD "$SID"`.)
stop_stub() {
    local stopfile="$1" s
    s="$(mktemp -t pwt-stopstub.XXXXXX)"
    printf '#!/usr/bin/env bash\nprintf "%%s" "$1" > %q\n' "$stopfile" > "$s"
    chmod +x "$s"
    echo "$s"
}

echo "── plan-w-team-bg-resume-guard tests ──"

# [1] STALE verdict (check cmd exits 0) → stop requested + systemMessage emitted
echo "[1] STALE → stop requested + systemMessage"
R=$(mkroot); STOPFILE="$R/stopped.txt"
OUT=$( printf '{"session_id":"abc12345","source":"resume","cwd":"%s"}' "$R" | \
       PWT_RESUME_GUARD_CHECK_CMD="true" \
       PWT_RESUME_GUARD_STOP_CMD="$(stop_stub "$STOPFILE")" \
       bash "$GUARD" 2>/dev/null )
sleep 0.3
assert_eq "stop command invoked with the sid" "abc12345" "$(cat "$STOPFILE" 2>/dev/null)"
printf '%s' "$OUT" | grep -q 'bg-resume-guard' && pass "systemMessage emitted on STALE" || fail "systemMessage emitted on STALE" "missing marker"
printf '%s' "$OUT" | grep -q 'already shipped' && pass "additionalContext explains self-exit" || fail "additionalContext explains self-exit" "missing text"

# [2] LIVE verdict (check cmd exits 1) → NO stop
echo "[2] LIVE → no stop"
R=$(mkroot); STOPFILE="$R/stopped.txt"
printf '{"session_id":"def67890","source":"resume","cwd":"%s"}' "$R" | \
    PWT_RESUME_GUARD_CHECK_CMD="exit 1" \
    PWT_RESUME_GUARD_STOP_CMD="$(stop_stub "$STOPFILE")" \
    bash "$GUARD" >/dev/null 2>&1
sleep 0.3
assert_eq "LIVE → stop NOT invoked" "no" "$([ -f "$STOPFILE" ] && echo yes || echo no)"

# [3] UNKNOWN verdict (check cmd exits 2) → NO stop (fail-open)
echo "[3] UNKNOWN → no stop (fail-open)"
R=$(mkroot); STOPFILE="$R/stopped.txt"
printf '{"session_id":"ghi13579","source":"resume","cwd":"%s"}' "$R" | \
    PWT_RESUME_GUARD_CHECK_CMD="exit 2" \
    PWT_RESUME_GUARD_STOP_CMD="$(stop_stub "$STOPFILE")" \
    bash "$GUARD" >/dev/null 2>&1
sleep 0.3
assert_eq "UNKNOWN → stop NOT invoked" "no" "$([ -f "$STOPFILE" ] && echo yes || echo no)"

# [4] disabled kill-switch → no-op (no stop even when check would say STALE)
echo "[4] PLAN_W_TEAM_BG_RESUME_GUARD_DISABLE=1 → no-op"
R=$(mkroot); STOPFILE="$R/stopped.txt"
printf '{"session_id":"jkl24680","source":"resume","cwd":"%s"}' "$R" | \
    PLAN_W_TEAM_BG_RESUME_GUARD_DISABLE=1 PWT_RESUME_GUARD_CHECK_CMD="true" \
    PWT_RESUME_GUARD_STOP_CMD="$(stop_stub "$STOPFILE")" \
    bash "$GUARD" >/dev/null 2>&1
sleep 0.3
assert_eq "disabled → stop NOT invoked" "no" "$([ -f "$STOPFILE" ] && echo yes || echo no)"

# [5] no session_id in input → no-op
echo "[5] missing session_id → no-op"
R=$(mkroot); STOPFILE="$R/stopped.txt"
printf '{"source":"resume","cwd":"%s"}' "$R" | \
    PWT_RESUME_GUARD_CHECK_CMD="true" PWT_RESUME_GUARD_STOP_CMD="$(stop_stub "$STOPFILE")" \
    bash "$GUARD" >/dev/null 2>&1
assert_eq "no sid → stop NOT invoked" "no" "$([ -f "$STOPFILE" ] && echo yes || echo no)"

# [6] END-TO-END: real pwt-goal --resume-staleness-check against a seeded terminal
#     goal-state whose worker_sid matches → guard self-exits.
if [ -x "$PWT_GOAL" ]; then
  echo "[6] e2e: terminal goal-state for sid → guard requests stop"
  R=$(mkroot); STOPFILE="$R/stopped.txt"
  printf '{"slug":"e2e-demo","worker_sid":"e2e99999","terminal_state":"SUCCESS","terminal_reason":"shipped"}\n' \
      > "$R/.claude/state/plan-w-team-goal-e2e-demo.json"
  # Point the guard at the real checker by NOT overriding CHECK_CMD; pass cwd=$R so
  # the checker resolves $R/.claude/state. Neutralize worker cascade env.
  printf '{"session_id":"e2e99999","source":"resume","cwd":"%s"}' "$R" | \
      env -u PLAN_W_TEAM_DISABLE_PROMPT_ROUTE \
      PWT_PROJECT_ROOT_OVERRIDE="$R" CLAUDE_PROJECT_DIR="$R" \
      PWT_RESUME_GUARD_STOP_CMD="$(stop_stub "$STOPFILE")" \
      bash "$GUARD" >/dev/null 2>&1
  sleep 0.3
  assert_eq "e2e terminal goal-state → stop invoked with sid" "e2e99999" "$(cat "$STOPFILE" 2>/dev/null)"

  echo "[7] e2e: NON-terminal goal-state for sid → no stop"
  R=$(mkroot); STOPFILE="$R/stopped.txt"
  printf '{"slug":"e2e-live","worker_sid":"e2e88888","terminal_state":null}\n' \
      > "$R/.claude/state/plan-w-team-goal-e2e-live.json"
  printf '{"session_id":"e2e88888","source":"resume","cwd":"%s"}' "$R" | \
      env -u PLAN_W_TEAM_DISABLE_PROMPT_ROUTE \
      PWT_PROJECT_ROOT_OVERRIDE="$R" CLAUDE_PROJECT_DIR="$R" \
      PWT_RESUME_GUARD_STOP_CMD="$(stop_stub "$STOPFILE")" \
      bash "$GUARD" >/dev/null 2>&1
  sleep 0.3
  assert_eq "e2e non-terminal → stop NOT invoked" "no" "$([ -f "$STOPFILE" ] && echo yes || echo no)"
else
  echo "  ⊘ e2e skipped (pwt-goal.sh not found)"
fi

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
