#!/usr/bin/env bash
# Tests for plan-w-team-retro-capture.sh (Deliverable 3 — recursive-improvement capture)
#
# Coverage:
#   T1  basic run, no prior history → valid record, empty arrays (NOT skipped), regression=false
#   T2  --weakness/--gap/--struggle/--follow-up args populate arrays
#   T3  self-assessment <8 → investigate_and_update non-empty + auto follow-up appended
#   T4  regression detection — prior adherence higher than current → regression_flag=true + signal named
#   T5  empty-input case emits valid EMPTY arrays (shadow path: never a skipped block)
#   T6  missing --slug → exit 2
#   T7  bash-3.2 compatibility — no declare -A / ${var^^} / ${var,,} bashisms in the helper
#   T8  follow-ups appended to the durable cross-run followups log as open rows
#
# bash 3.2 compatible (mac-mini /bin/bash). Worktree-safe: every run uses an
# isolated mktemp --state-dir, never the ambient checkout.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/plan-w-team-retro-capture.sh"

PASS=0
FAIL=0
assert() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $name"; PASS=$((PASS + 1))
  else
    echo "  ✗ $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

make_state() { local d; d=$(mktemp -d); echo "$d"; }

# ─── T1 — basic run, no prior history ────────────────────────────────────────
echo "T1: basic run, no prior history"
SD=$(make_state)
OUT=$("$HELPER" --slug t1 --state-dir "$SD" --quiet)
assert "valid JSON emitted" "0" "$(printf '%s' "$OUT" | jq empty >/dev/null 2>&1; echo $?)"
assert "weaknesses is empty array" "0" "$(printf '%s' "$OUT" | jq '.weaknesses | length')"
assert "regression_flag false" "false" "$(printf '%s' "$OUT" | jq -r '.regression_flag')"
assert "self_assessment null" "null" "$(printf '%s' "$OUT" | jq -r '.self_assessment')"
assert "capture file written" "1" "$([ -f "$SD/plan-w-team-retro-capture-t1.json" ] && echo 1 || echo 0)"
rm -rf "$SD"

# ─── T2 — args populate arrays ───────────────────────────────────────────────
echo "T2: args populate arrays"
SD=$(make_state)
OUT=$("$HELPER" --slug t2 --state-dir "$SD" --quiet \
  --weakness "spec missed a shadow path" \
  --gap "no perf benchmark" \
  --struggle "merge conflict on barrel file" \
  --follow-up "add benchmark next run")
assert "weaknesses count" "1" "$(printf '%s' "$OUT" | jq '.weaknesses | length')"
assert "gaps count" "1" "$(printf '%s' "$OUT" | jq '.gaps | length')"
assert "struggles count" "1" "$(printf '%s' "$OUT" | jq '.struggles | length')"
assert "follow_ups count" "1" "$(printf '%s' "$OUT" | jq '.follow_ups | length')"
assert "weakness text preserved" "spec missed a shadow path" "$(printf '%s' "$OUT" | jq -r '.weaknesses[0]')"
rm -rf "$SD"

# ─── T3 — self-assessment <8 triggers investigate-and-update + auto follow-up ─
echo "T3: self-assessment <8 → investigate + auto follow-up"
SD=$(make_state)
OUT=$("$HELPER" --slug t3 --state-dir "$SD" --quiet --self-assessment 6)
assert "investigate_and_update non-null" "0" "$(printf '%s' "$OUT" | jq -e '.investigate_and_update != null' >/dev/null 2>&1; echo $?)"
assert "auto follow-up present" "1" "$(printf '%s' "$OUT" | jq '[.follow_ups[] | select(test("self-assessment"))] | length')"
assert "self_assessment recorded" "6" "$(printf '%s' "$OUT" | jq -r '.self_assessment')"
# self-assessment >=8 must NOT trigger investigate
OUT9=$("$HELPER" --slug t3b --state-dir "$SD" --quiet --self-assessment 9)
assert "no investigate at 9" "null" "$(printf '%s' "$OUT9" | jq -r '.investigate_and_update')"
rm -rf "$SD"

# ─── T4 — regression detection vs prior history ──────────────────────────────
echo "T4: regression detection"
SD=$(make_state)
HIST="$SD/hist.jsonl"
# Prior run recorded bypass_rate=5; current retro-state has bypass_rate.score=3 (a drop).
printf '%s\n' '{"slug":"prev","best_practice_adherence":{"bypass_rate":5,"doc_hygiene":5,"untracked_hygiene":5}}' > "$HIST"
RS="$SD/plan-w-team-retro-cur.json"
printf '%s\n' '{"quality_signals":{"bypass_rate":{"score":3},"doc_hygiene":5},"untracked_hygiene":{"score":5}}' > "$RS"
OUT=$("$HELPER" --slug t4 --state-dir "$SD" --retro-state "$RS" --history "$HIST" --quiet)
assert "regression_flag true" "true" "$(printf '%s' "$OUT" | jq -r '.regression_flag')"
assert "regressed signal named" "bypass_rate" "$(printf '%s' "$OUT" | jq -r '.regressed_signals[0].signal')"
assert "regression auto follow-up" "1" "$(printf '%s' "$OUT" | jq '[.follow_ups[] | select(test("regression"))] | length')"
# No-regression case: equal scores → false
printf '%s\n' '{"slug":"prev2","best_practice_adherence":{"bypass_rate":3}}' > "$SD/hist2.jsonl"
OUT2=$("$HELPER" --slug t4b --state-dir "$SD" --retro-state "$RS" --history "$SD/hist2.jsonl" --quiet)
assert "no regression when equal" "false" "$(printf '%s' "$OUT2" | jq -r '.regression_flag')"
rm -rf "$SD"

# ─── T5 — empty-input shadow path: valid empty arrays, not a skipped block ────
echo "T5: empty input → valid empty arrays (not skipped)"
SD=$(make_state)
OUT=$("$HELPER" --slug t5 --state-dir "$SD" --quiet)
assert "weaknesses == []" "[]" "$(printf '%s' "$OUT" | jq -c '.weaknesses')"
assert "gaps == []" "[]" "$(printf '%s' "$OUT" | jq -c '.gaps')"
assert "struggles == []" "[]" "$(printf '%s' "$OUT" | jq -c '.struggles')"
assert "follow_ups == []" "[]" "$(printf '%s' "$OUT" | jq -c '.follow_ups')"
assert "record still emitted (has slug)" "t5" "$(printf '%s' "$OUT" | jq -r '.slug')"
rm -rf "$SD"

# ─── T6 — missing --slug → exit 2 ────────────────────────────────────────────
echo "T6: missing --slug → exit 2"
"$HELPER" --state-dir "$(make_state)" --quiet >/dev/null 2>&1
assert "exit code 2" "2" "$?"

# ─── T7 — bash 3.2 compatibility (no bash-4 isms) ────────────────────────────
echo "T7: bash 3.2 compatibility"
assert "no declare -A" "0" "$(grep -c 'declare -A' "$HELPER")"
assert "no \${var^^} uppercase" "0" "$(grep -cE '\$\{[A-Za-z_][A-Za-z0-9_]*\^\^' "$HELPER")"
assert "no \${var,,} lowercase" "0" "$(grep -cE '\$\{[A-Za-z_][A-Za-z0-9_]*,,' "$HELPER")"
# Parses clean under bash -n.
bash -n "$HELPER" >/dev/null 2>&1
assert "bash -n parses clean" "0" "$?"

# ─── T8 — follow-ups appended to durable cross-run log ───────────────────────
echo "T8: follow-ups appended to cross-run log"
SD=$(make_state)
FUL="$SD/followups.jsonl"
"$HELPER" --slug t8 --state-dir "$SD" --followups-log "$FUL" --quiet \
  --follow-up "wire X into Y" >/dev/null
assert "followups log created" "1" "$([ -f "$FUL" ] && echo 1 || echo 0)"
assert "one open follow-up row" "1" "$(jq -s '[.[] | select(.status=="open")] | length' "$FUL" 2>/dev/null)"
assert "follow-up text preserved" "wire X into Y" "$(jq -rs '.[0].text' "$FUL" 2>/dev/null)"
rm -rf "$SD"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "plan-w-team-retro-capture.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
