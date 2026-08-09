#!/usr/bin/env bash
# plan-w-team-reuse-audit-gate.test.sh — H1 gate regression tests (bash 3.2)
#
# Exit 0 = all pass; 1 = a failure. Run directly: bash <this file>.
# Discovered by tests/skill/run.sh's shell-integration phase.

set -u

# Resolve the gate script relative to THIS test file (worktree-safe — do not
# rely on ambient CWD; see feedback_test_worktree_cwd_fragility).
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/plan-w-team-reuse-audit-gate.sh"

# Scrub the kill switch so default-behavior cases see a pristine env
# (worker sessions may export PLAN_W_TEAM_DISABLE_*; see project_pwt_worker_disable_env_leak).
unset PLAN_W_TEAM_DISABLE_REUSE_AUDIT

PASS=0
FAIL=0
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

check() {
  # check <description> <expected_exit> <actual_exit>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "  ok   $1 (exit $3)"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $1 (expected $2, got $3)"
  fi
}

[ -f "$GATE" ] || { echo "✗ gate script not found: $GATE" >&2; exit 1; }

# ── Case 1: audit section with verdicts → pass (0) ───────────────────────────
cat > "$TMPD/with-verdicts.md" <<'EOF'
# Feature: x
## Existing-Code Survey / Reuse Audit
| candidate | verdict |
| --------- | ------- |
| foo()     | REUSE   |
| bar()     | BUILD-NEW |
## Requirements
- nothing here
EOF
bash "$GATE" --spec "$TMPD/with-verdicts.md" >/dev/null 2>&1
check "audit with verdicts passes" 0 $?

# ── Case 2: heading present but blank body → fail (1) ─────────────────────────
cat > "$TMPD/blank.md" <<'EOF'
# Feature: x
## Reuse Audit

## Requirements
- something
EOF
bash "$GATE" --spec "$TMPD/blank.md" >/dev/null 2>&1
check "blank audit section fails" 1 $?

# ── Case 3: no audit section at all → fail (1) ────────────────────────────────
cat > "$TMPD/none.md" <<'EOF'
# Feature: x
## Overview
nothing about reuse here
## Requirements
- something
EOF
bash "$GATE" --spec "$TMPD/none.md" >/dev/null 2>&1
check "missing audit section fails" 1 $?

# ── Case 4: explicit "nothing overlaps" statement → pass (0) ──────────────────
cat > "$TMPD/empty-ok.md" <<'EOF'
# Feature: x
## Existing-Code Survey / Reuse Audit
Surveyed the codebase; nothing overlaps this feature.
## Requirements
- something
EOF
bash "$GATE" --spec "$TMPD/empty-ok.md" >/dev/null 2>&1
check "explicit nothing-overlaps statement passes" 0 $?

# ── Case 5: kill switch on a no-audit spec → pass (0) ─────────────────────────
PLAN_W_TEAM_DISABLE_REUSE_AUDIT=1 bash "$GATE" --spec "$TMPD/none.md" >/dev/null 2>&1
check "kill switch bypasses gate" 0 $?

# ── Case 6: missing spec file → exit 2 ───────────────────────────────────────
bash "$GATE" --spec "$TMPD/does-not-exist.md" >/dev/null 2>&1
check "missing spec file exits 2" 2 $?

# ── Case 7: --slug derivation (file absent) → exit 2 ─────────────────────────
bash "$GATE" --slug "definitely-not-a-real-slug-xyz" >/dev/null 2>&1
check "slug-derived missing spec exits 2" 2 $?

# ═════════════════════════════════════════════════════════════════════════════
# PHASE PLUMBING + review/ship verdict re-verification
# ═════════════════════════════════════════════════════════════════════════════

# ── Case 8: --phase spec explicit == default ────────────────────────────────
bash "$GATE" --spec "$TMPD/with-verdicts.md" --phase spec >/dev/null 2>&1
check "--phase spec explicit matches default (verdicts)" 0 $?
bash "$GATE" --spec "$TMPD/blank.md" --phase spec >/dev/null 2>&1
check "--phase spec explicit matches default (blank)" 1 $?

# ── Case 9: invalid phase → exit 2, never a silent fallback ─────────────────
bash "$GATE" --spec "$TMPD/with-verdicts.md" --phase bogus >/dev/null 2>&1
check "invalid --phase exits 2" 2 $?

# ── Case 10: value-less trailing --phase must TERMINATE, not spin ───────────
# The argparse-shift2-lint hang class: `shift 2` on a value-less trailing flag
# shifts nothing and loops forever. A timeout of 124 means the hang is back.
# Portable watchdog — macOS ships no timeout(1), and skipping this case would
# retire the only guard against the hang class it exists to catch.
bash "$GATE" --spec "$TMPD/with-verdicts.md" --phase >/dev/null 2>&1 &
WPID=$!
WAITED=0
while kill -0 "$WPID" 2>/dev/null && [ "$WAITED" -lt 50 ]; do
  sleep 0.1
  WAITED=$((WAITED + 1))
done
if kill -0 "$WPID" 2>/dev/null; then
  kill -9 "$WPID" 2>/dev/null
  wait "$WPID" 2>/dev/null
  FAIL=$((FAIL + 1))
  echo "  FAIL value-less trailing --phase HUNG (>5s) — the shift-2 spin is back"
else
  wait "$WPID" 2>/dev/null
  check "value-less trailing --phase terminates with 2" 2 $?
fi

# ── Case 11: unknown option → exit 2 ────────────────────────────────────────
bash "$GATE" --spec "$TMPD/with-verdicts.md" --bogus-flag >/dev/null 2>&1
check "unknown option exits 2" 2 $?

# ── Case 12: --slug traversal is refused before any path is built ───────────
bash "$GATE" --slug "../../etc" >/dev/null 2>&1
check "traversal --slug exits 2" 2 $?
bash "$GATE" --slug "Bad_Slug" >/dev/null 2>&1
check "non-charset --slug exits 2" 2 $?

# ── Case 13: kill switch covers review/ship too ─────────────────────────────
PLAN_W_TEAM_DISABLE_REUSE_AUDIT=1 bash "$GATE" --spec "$TMPD/none.md" --phase review >/dev/null 2>&1
check "kill switch covers --phase review" 0 $?
PLAN_W_TEAM_DISABLE_REUSE_AUDIT=1 bash "$GATE" --spec "$TMPD/none.md" --phase ship >/dev/null 2>&1
check "kill switch covers --phase ship" 0 $?

# ── Case 14: SECTION EXTRACTOR — nested sub-heading must NOT truncate ───────
# Closes open followups ledger row 11 (deep-audit-2026-06-08). Under --phase
# spec the old extractor false-FAILED here; under review/ship it would have
# false-PASSED silently, dropping every row below the sub-heading.
cat > "$TMPD/subheading.md" <<'EOF'
# Feature: x
## Existing-Code Survey / Reuse Audit

Preamble prose with no verdict token.

### Candidates

| candidate | location | verdict |
| --------- | -------- | ------- |
| foo()     | `a/b.ts` | REUSE   |

## Requirements
- something
EOF
bash "$GATE" --spec "$TMPD/subheading.md" >/dev/null 2>&1
check "verdicts under a ### sub-heading are NOT truncated away" 0 $?

# ── Case 15: heading-shaped line inside a fenced block must not truncate ────
cat > "$TMPD/fenced.md" <<'EOF'
# Feature: x
## Reuse Audit

```bash
# not a heading
### also not a heading
```

| candidate | location | verdict |
| --------- | -------- | ------- |
| foo()     | `a/b.ts` | REUSE   |

## Requirements
- something
EOF
bash "$GATE" --spec "$TMPD/fenced.md" >/dev/null 2>&1
check "heading-shaped line inside a code fence does not truncate" 0 $?

# ── Case 16: legacy grace — no section is fatal at spec, benign at ship ─────
bash "$GATE" --spec "$TMPD/none.md" --phase review >/dev/null 2>&1
check "no audit section: review grants legacy grace (0)" 0 $?
bash "$GATE" --spec "$TMPD/none.md" --phase ship >/dev/null 2>&1
check "no audit section: ship grants legacy grace (0)" 0 $?
bash "$GATE" --spec "$TMPD/none.md" --phase spec >/dev/null 2>&1
check "no audit section: spec still refuses the freeze (1)" 1 $?

# ── Case 17: missing spec at ship keeps the 2-vs-1 distinction ──────────────
bash "$GATE" --spec "$TMPD/does-not-exist.md" --phase ship >/dev/null 2>&1
check "missing spec at --phase ship exits 2 (not 1)" 2 $?

# ═════════════════════════════════════════════════════════════════════════════
# Sandbox git repo — the seam that makes detection deterministic.
# Without --root/--diff-base these cases would read the AMBIENT checkout and
# pass or fail on whatever this run's own branch happens to contain.
# ═════════════════════════════════════════════════════════════════════════════
SBX="$TMPD/sbx"
mkdir -p "$SBX/lib" "$SBX/docs/specs"
( cd "$SBX" \
  && git init -q . \
  && git config user.email t@t && git config user.name t \
  && printf 'x\n' > lib/money.ts \
  && printf 'x\n' > lib/unrelated.ts \
  && git add -A && git commit -qm base ) >/dev/null 2>&1
BASE=$( cd "$SBX" && git rev-parse HEAD )

mk_spec() { # mk_spec <file> <verdict-cell> <location-cell>
  cat > "$1" <<EOF
# Feature: t
## Existing-Code Survey / Reuse Audit

| candidate | location | verdict |
| --------- | -------- | ------- |
| thing     | $3       | $2      |

## Requirements
- x
EOF
}

add_commit() { # add_commit <relpath> <content>
  ( cd "$SBX" && printf '%s\n' "$2" > "$1" && git add -A && git commit -qm add ) >/dev/null 2>&1
}

# ── Case 18: SEEDED VIOLATION — spec froze REUSE, diff added its own ────────
mk_spec "$SBX/docs/specs/t.md" "REUSE" '`lib/money.ts`'
add_commit "lib/newmoney.ts" "export function money() { return 1 }"
bash "$GATE" --root "$SBX" --spec "$SBX/docs/specs/t.md" --phase review --diff-base "$BASE" >/dev/null 2>&1
check "seeded violation: REUSE target re-implemented -> 11" 11 $?

# ── Case 19: EXTEND behaves like REUSE (draft tested only REUSE) ────────────
mk_spec "$SBX/docs/specs/t.md" "EXTEND" '`lib/money.ts`'
bash "$GATE" --root "$SBX" --spec "$SBX/docs/specs/t.md" --phase review --diff-base "$BASE" >/dev/null 2>&1
check "seeded violation under EXTEND -> 11" 11 $?

# ── Case 20: BUILD-NEW is exempt by construction ────────────────────────────
mk_spec "$SBX/docs/specs/t.md" "BUILD-NEW" '`lib/money.ts`'
bash "$GATE" --root "$SBX" --spec "$SBX/docs/specs/t.md" --phase review --diff-base "$BASE" >/dev/null 2>&1
check "BUILD-NEW row is exempt -> 0" 0 $?

# ── Case 21: 'REUSE (pattern)' is exempt — reuse-of-shape leaves no trace ───
mk_spec "$SBX/docs/specs/t.md" "REUSE (pattern)" '`lib/money.ts`'
bash "$GATE" --root "$SBX" --spec "$SBX/docs/specs/t.md" --phase review --diff-base "$BASE" >/dev/null 2>&1
check "REUSE (pattern) row is exempt -> 0" 0 $?

# ── Case 22: honored verdict — unrelated definition added -> clean ──────────
mk_spec "$SBX/docs/specs/t.md" "REUSE" '`lib/unrelated.ts`'
bash "$GATE" --root "$SBX" --spec "$SBX/docs/specs/t.md" --phase review --diff-base "$BASE" >/dev/null 2>&1
check "honored verdict (no colliding definition) -> 0" 0 $?

# ── Case 23: hostile Location cells never resolve and never execute ─────────
for hostile in '`/etc/passwd`' '`../../etc/passwd`' '`.*`' '`$(touch /tmp/pwt-pwned)`'; do
  mk_spec "$SBX/docs/specs/t.md" "REUSE" "$hostile"
  bash "$GATE" --root "$SBX" --spec "$SBX/docs/specs/t.md" --phase review --diff-base "$BASE" >/dev/null 2>&1
  check "hostile Location cell $hostile -> 0 (skipped, not resolved)" 0 $?
done
if [ -e /tmp/pwt-pwned ]; then
  FAIL=$((FAIL + 1)); echo "  FAIL command-substitution cell EXECUTED (/tmp/pwt-pwned exists)"
  rm -f /tmp/pwt-pwned
else
  PASS=$((PASS + 1)); echo "  ok   command-substitution cell was never executed"
fi

# ── Case 23b: the run's OWN spec cannot make the detector fire ─────────────
# A /plan-w-team spec is committed on its own branch and its audit table cites
# every target verbatim. Without the docs/specs exclusion the detector is either
# permanently inert or pure noise, depending on match direction. This asserts
# the exclusion holds: a colliding "definition" that exists ONLY inside a spec
# file must not produce a finding.
# Fresh base so the ONLY colliding definition in range lives in docs/specs —
# otherwise the assertion could not distinguish "excluded" from "would have been
# a finding anyway".
mk_spec "$SBX/docs/specs/t.md" "REUSE" '`lib/money.ts`'
( cd "$SBX" && git add -A && git commit -qm "pre-decoy" ) >/dev/null 2>&1
DECOYBASE=$( cd "$SBX" && git rev-parse HEAD )
( cd "$SBX" \
  && printf 'function money() { return 1 }\n' > docs/specs/decoy.md \
  && git add -A && git commit -qm "spec-only decoy" ) >/dev/null 2>&1
bash "$GATE" --root "$SBX" --spec "$SBX/docs/specs/t.md" --phase review --diff-base "$DECOYBASE" >/dev/null 2>&1
check "colliding definition ONLY inside docs/specs is excluded -> 0" 0 $?
# Positive control: the identical definition under lib/ MUST fire, proving the
# fixture is capable of producing a finding and the case is not vacuous.
( cd "$SBX" \
  && printf 'function money() { return 1 }\n' > lib/decoy2.ts \
  && git add -A && git commit -qm "code decoy" ) >/dev/null 2>&1
bash "$GATE" --root "$SBX" --spec "$SBX/docs/specs/t.md" --phase review --diff-base "$DECOYBASE" >/dev/null 2>&1
check "positive control: same definition under lib/ DOES fire -> 11" 11 $?
( cd "$SBX" && git rm -q docs/specs/decoy.md lib/decoy2.ts && git commit -qm "drop decoys" ) >/dev/null 2>&1

# ── Case 23c: findings are CAPPED, and the cap announces itself ─────────────
# Queued rows can become an autonomous run's goal via followup-drain, so an
# uncapped detector is not merely noisy.
mkdir -p "$SBX/lib"
cat > "$SBX/docs/specs/many.md" <<'EOF'
# Feature: t
## Existing-Code Survey / Reuse Audit

| candidate | location | verdict |
| --------- | -------- | ------- |
| a | `lib/alpha.ts` | REUSE |
| b | `lib/bravo.ts` | REUSE |
| c | `lib/charlie.ts` | REUSE |
| d | `lib/delta.ts` | REUSE |

## Requirements
- x
EOF
( cd "$SBX" \
  && for n in alpha bravo charlie delta; do printf 'x\n' > "lib/$n.ts"; done \
  && git add -A && git commit -qm seed ) >/dev/null 2>&1
CAPBASE=$( cd "$SBX" && git rev-parse HEAD )
( cd "$SBX" \
  && for n in alpha bravo charlie delta; do printf 'function %s() { return 1 }\n' "$n" > "lib/new_$n.ts"; done \
  && git add -A && git commit -qm dupes ) >/dev/null 2>&1
CAPOUT=$(PWT_REUSE_RECHECK_MAX=2 bash "$GATE" --root "$SBX" --spec "$SBX/docs/specs/many.md" \
           --phase review --diff-base "$CAPBASE" 2>&1)
CAPRC=$?
check "four collisions under a cap of 2 still exits 11" 11 "$CAPRC"
if printf '%s' "$CAPOUT" | grep -q 'TRUNCATED'; then
  PASS=$((PASS + 1)); echo "  ok   cap announces truncation LOUDLY"
else
  FAIL=$((FAIL + 1)); echo "  FAIL cap truncated silently — findings vanished with no notice"
fi
CAPLINES=$(printf '%s' "$CAPOUT" | grep -c 'unhonored-verdict' || true)
if [ "$CAPLINES" = "2" ]; then
  PASS=$((PASS + 1)); echo "  ok   cap emitted exactly PWT_REUSE_RECHECK_MAX findings"
else
  FAIL=$((FAIL + 1)); echo "  FAIL cap emitted $CAPLINES finding line(s), expected 2"
fi

# ── Case 24: prose / env-var cells are not checkable, never findings ────────
mk_spec "$SBX/docs/specs/t.md" "REUSE" '`PLAN_W_TEAM_DISABLE_REUSE_AUDIT`'
bash "$GATE" --root "$SBX" --spec "$SBX/docs/specs/t.md" --phase review --diff-base "$BASE" >/dev/null 2>&1
check "bare env-var Location cell -> 0 (not checkable)" 0 $?

# ── Case 25: could-not-verify is NOT clean ─────────────────────────────────
mk_spec "$SBX/docs/specs/t.md" "REUSE" '`lib/money.ts`'
bash "$GATE" --root "$SBX" --spec "$SBX/docs/specs/t.md" --phase review --diff-base "$(cd "$SBX" && git rev-parse HEAD)" >/dev/null 2>&1
check "empty range (base==HEAD) -> 12 could-not-verify" 12 $?
bash "$GATE" --root "$TMPD" --spec "$SBX/docs/specs/t.md" --phase review >/dev/null 2>&1
check "non-repo root -> 12 could-not-verify" 12 $?

# ── Case 26: R1 back-compat, the ONLY input that could break it ─────────────
# The seeded-violation fixture returns 11 under review; under the default phase
# it must still return 0. This is where "spec phase never emits 11/12" can fail.
mk_spec "$SBX/docs/specs/t.md" "REUSE" '`lib/money.ts`'
bash "$GATE" --spec "$SBX/docs/specs/t.md" >/dev/null 2>&1
check "seeded-violation fixture under default phase -> 0 (never 11/12)" 0 $?

# ── Case 27: --help exposes --phase (the wrappers' capability probe) ────────
# A truncated help would hide the flag, the probe would find nothing, and the
# new rungs would silently no-op in every consumer repo.
if bash "$GATE" --help 2>/dev/null | grep -qF -- '--phase'; then
  PASS=$((PASS + 1)); echo "  ok   --help exposes --phase (capability probe works)"
else
  FAIL=$((FAIL + 1)); echo "  FAIL --help does not expose --phase — capability probe would silently disable the gate"
fi

echo ""
echo "plan-w-team-reuse-audit-gate.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
