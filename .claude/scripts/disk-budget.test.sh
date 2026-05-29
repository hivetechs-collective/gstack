#!/usr/bin/env bash
# disk-budget.test.sh — PWT-DISK1 pre-spawn disk gate (E2).
# Asserts: BLOCK below floor; SPAWN_OK above; heavy-build uses the higher floor;
# fail-open on unreadable df; does NOT block on APFS % alone when free GB is healthy.
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/disk-budget.sh"
[ -x "$SCRIPT" ] || { echo "FAIL: disk-budget.sh not executable"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdf() { # free_kb used_pct → path  (1K-block df with given Avail + Capacity)
    # NOTE: separate `local` lines — bash 3.2 does NOT expand a same-statement
    # earlier local var ($fk) within the same `local` declaration.
    local fk="$1" pct="$2"
    local f="$TMP/df_${fk}_${pct}.txt"
    printf 'Filesystem 1K-blocks Used Avail Capacity Mounted\n/dev/x 100000000 1 %s %s%% /\n' "$fk" "$pct" > "$f"
    echo "$f"
}
action_of() { printf '%s' "$1" | grep -oE '"recommended_action": *"?[^",}]*"?' | head -1 | sed -E 's/.*: *"?//; s/"?$//'; }

echo "── disk-budget tests ──"

# [1] BLOCK below the default 15 GB floor (8 GB free)
OUT=$(DISK_BUDGET_STUB_DF=$(mkdf 8388608 92) "$SCRIPT")
[ "$(action_of "$OUT")" = "BLOCK" ] && ok "8 GB free → BLOCK (below 15 floor)" || bad "expected BLOCK, got $(action_of "$OUT")"

# [2] SPAWN_OK well above the floor (40 GB free)
OUT=$(DISK_BUDGET_STUB_DF=$(mkdf 41943040 60) "$SCRIPT")
[ "$(action_of "$OUT")" = "SPAWN_OK" ] && ok "40 GB free → SPAWN_OK" || bad "expected SPAWN_OK, got $(action_of "$OUT")"

# [3] heavy-build raises the floor: 20 GB free → SPAWN_OK normal, BLOCK for a build directive
DF20=$(mkdf 20971520 79)
[ "$(action_of "$(DISK_BUDGET_STUB_DF=$DF20 "$SCRIPT")")" = "SPAWN_OK" ] \
  && ok "20 GB free, normal → SPAWN_OK (floor 15)" || bad "normal 20GB expected SPAWN_OK"
[ "$(action_of "$(DISK_BUDGET_STUB_DF=$DF20 "$SCRIPT" 'ship iOS app with pod install + xcodebuild')")" = "BLOCK" ] \
  && ok "20 GB free, heavy-build → BLOCK (floor 25)" || bad "heavy-build 20GB expected BLOCK"

# [4] fail-open on unreadable df → recommended_action null, exit 0
OUT=$(DISK_BUDGET_STUB_DF="$TMP/nope-$$" "$SCRIPT" 2>/dev/null); RC=$?
{ [ "$RC" -eq 0 ] && [ "$(action_of "$OUT")" = "null" ]; } && ok "unreadable df → fail-open null, exit 0" || bad "fail-open wrong (rc=$RC act=$(action_of "$OUT"))"

# [5] APFS trap: 94% used but 30 GB free → SPAWN_OK (must NOT block on % alone)
OUT=$(DISK_BUDGET_STUB_DF=$(mkdf 31457280 94) "$SCRIPT")
{ [ "$(action_of "$OUT")" = "SPAWN_OK" ] && printf '%s' "$OUT" | grep -q '"used_pct": 94'; } \
  && ok "94% used + 30 GB free → SPAWN_OK (gates on free GB, not %)" || bad "APFS-% trap: got $(action_of "$OUT")"

# [6] heavy-build flag is reported true for build directives
printf '%s' "$(DISK_BUDGET_STUB_DF=$(mkdf 41943040 50) "$SCRIPT" 'run gradlew assembleRelease')" | grep -q '"heavy_build": true' \
  && ok "build directive → heavy_build:true" || bad "heavy_build not flagged"

# ── pwt-goal.sh integration: the gate is wired into the real spawn path ───────
PWTGOAL="$(cd "$(dirname "$0")" && pwd)/pwt-goal.sh"
if [ -x "$PWTGOAL" ]; then
  GROOT="$TMP/proj"; mkdir -p "$GROOT/.claude/worktrees"
  GENV="PLAN_W_TEAM_DISABLE_RAM_GATE=1 PLAN_W_TEAM_DISABLE_FAIR_SHARE=1 PWT_RAM_CLAIMS_REGISTRY=$TMP/claims.jsonl PWT_PROJECT_ROOT_OVERRIDE=$GROOT CLAUDE_PROJECT_DIR=$GROOT"

  # [7] free_gb < floor → spawn refused, exit 5
  env $GENV DISK_BUDGET_STUB_DF="$(mkdf 8388608 92)" bash "$PWTGOAL" --worker-only "integration low disk" >/dev/null 2>&1
  [ "$?" -eq 5 ] && ok "pwt-goal refuses spawn when free_gb < floor (exit 5)" || bad "low-disk spawn not refused"

  # [8] worktree count >= cap → spawn refused, exit 5 (disk gate disabled to isolate the cap)
  i=1; while [ "$i" -le 10 ]; do mkdir -p "$GROOT/.claude/worktrees/agent-$i"; i=$((i+1)); done
  env $GENV PLAN_W_TEAM_DISABLE_DISK_GATE=1 bash "$PWTGOAL" --worker-only "integration cap" >/dev/null 2>&1
  [ "$?" -eq 5 ] && ok "pwt-goal refuses spawn above PWT_MAX_WORKTREES (exit 5)" || bad "over-cap spawn not refused"
else
  echo "  ⊘ pwt-goal.sh integration skipped (not found)"
fi

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
