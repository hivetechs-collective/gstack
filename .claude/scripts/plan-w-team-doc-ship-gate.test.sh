#!/usr/bin/env bash
# Tests for plan-w-team-doc-ship-gate.sh (gap A3).
#
# Coverage:
#   T1  net-new public surface, no doc, no waiver  → refuse (exit 1)
#   T2  net-new public surface + CHANGELOG touched  → allow (exit 0)
#   T3  net-new public surface + waiver file        → allow (exit 0)
#   T4  no net-new surface (doc-only diff)          → allow (exit 0)
#   T5  kill switch (PLAN_W_TEAM_NETNEW_DISABLE=1)   → allow (exit 0)

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/plan-w-team-doc-ship-gate.sh"

PASS=0; FAIL=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}

newrepo() {
    local d; d=$(mktemp -d)
    ( cd "$d"; git init -q; git config user.email t@t.t; git config user.name t
      mkdir -p src .claude/state docs
      echo "# base" > README.md; echo "# changes" > CHANGELOG.md
      git add -A; git commit -qm base )
    echo "$d"
}

# T1 — net-new public file, no doc/CHANGELOG, no waiver → refuse.
D=$(newrepo)
( cd "$D"; printf 'export const widget=1\n' > src/foo.ts; git add -A; git commit -qm add )
RC=$( cd "$D"; "$GATE" --slug run --range HEAD~1..HEAD >/dev/null 2>&1; echo $? )
assert "T1 surface w/o docs refuses" "1" "$RC"
rm -rf "$D"

# T2 — net-new public file + CHANGELOG touched → allow.
D=$(newrepo)
( cd "$D"; printf 'export const widget=1\n' > src/foo.ts; printf '\n- new widget\n' >> CHANGELOG.md; git add -A; git commit -qm add )
RC=$( cd "$D"; "$GATE" --slug run --range HEAD~1..HEAD >/dev/null 2>&1; echo $? )
assert "T2 surface + CHANGELOG allows" "0" "$RC"
rm -rf "$D"

# T3 — net-new public file + waiver file → allow.
D=$(newrepo)
( cd "$D"; printf 'export const widget=1\n' > src/foo.ts
  printf 'src/foo.ts\nwidget\n' > .claude/state/plan-w-team-docs-waived-run.txt
  git add src/foo.ts; git commit -qm add )   # waiver file is untracked, not in diff — fine
RC=$( cd "$D"; "$GATE" --slug run --range HEAD~1..HEAD >/dev/null 2>&1; echo $? )
assert "T3 surface + waiver allows" "0" "$RC"
rm -rf "$D"

# T4 — doc-only diff (no net-new surface) → allow.
D=$(newrepo)
( cd "$D"; printf '\nmore docs\n' >> README.md; git add -A; git commit -qm docedit )
RC=$( cd "$D"; "$GATE" --slug run --range HEAD~1..HEAD >/dev/null 2>&1; echo $? )
assert "T4 doc-only diff allows" "0" "$RC"
rm -rf "$D"

# T5 — kill switch.
D=$(newrepo)
( cd "$D"; printf 'export const widget=1\n' > src/foo.ts; git add -A; git commit -qm add )
RC=$( cd "$D"; PLAN_W_TEAM_NETNEW_DISABLE=1 "$GATE" --slug run --range HEAD~1..HEAD >/dev/null 2>&1; echo $? )
assert "T5 kill switch allows" "0" "$RC"
rm -rf "$D"

# T6 — a docs/specs/ touch does NOT discharge the documentation duty (row-12
# re-audit). netnew excludes docs/specs from the docs it will accept, and
# 01-specification.md says specs do not satisfy it; this gate accepted them anyway,
# so a net-new script documented ONLY in the run's own spec passed the ship gate.
D=$(newrepo)
( cd "$D"; mkdir -p docs/specs
  printf 'export const widget=1\n' > src/foo.ts
  echo "spec mentioning widget and src/foo.ts" > docs/specs/my-feature.md
  git add -A; git commit -qm add )
RC=$( cd "$D"; "$GATE" --slug run --range HEAD~1..HEAD >/dev/null 2>&1; echo $? )
assert "T6 docs/specs alone does NOT satisfy" "1" "$RC"
rm -rf "$D"

# T7 — a missing/non-executable subscanner must fail CLOSED. Without it the gate
# tests nothing, and reporting a pass is the C7-part-2 silent-degradation shape.
D=$(newrepo)
( cd "$D"; printf 'export const widget=1\n' > src/foo.ts; git add -A; git commit -qm add )
FAKE="$D/fakebin"; mkdir -p "$FAKE"
cp "$GATE" "$FAKE/plan-w-team-doc-ship-gate.sh"    # sibling subscanner deliberately absent
RC=$( cd "$D"; "$FAKE/plan-w-team-doc-ship-gate.sh" --slug run --range HEAD~1..HEAD >/dev/null 2>&1; echo $? )
assert "T7 missing subscanner fails closed" "1" "$RC"
rm -rf "$D"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
