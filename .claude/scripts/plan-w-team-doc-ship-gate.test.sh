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

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
