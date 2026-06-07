#!/usr/bin/env bash
# Tests for plan-w-team-netnew-surface.sh (gaps A1/A6/C2).
#
# Coverage:
#   T1  net-new file with no doc reference         → UNDOCUMENTED (exit 1)
#   T2  net-new file referenced by a doc           → DOCUMENTED
#   T3  net-new hook/script needs docs/operations  → UNDOCUMENTED until ops doc exists (A6)
#   T4  net-new hook/script WITH docs/operations    → DOCUMENTED (A6)
#   T5  net-new env var read in added lines no doc  → UNDOCUMENTED
#   T6  waiver file suppresses residual             → exit 0
#   T7  no net-new surface                          → clean exit 0

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SS="$SCRIPT_DIR/plan-w-team-netnew-surface.sh"

PASS=0; FAIL=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}

newrepo() {
    local d; d=$(mktemp -d)
    ( cd "$d"; git init -q; git config user.email t@t.t; git config user.name t
      mkdir -p src docs/operations .claude/scripts .claude/state
      echo "# base" > README.md; git add README.md; git commit -qm base )
    echo "$d"
}

# T1 — net-new file, no doc.
D=$(newrepo)
( cd "$D"; printf 'export const widget = 1\n' > src/foo.ts; git add -A; git commit -qm add )
OUT=$( cd "$D"; "$SS" --range HEAD~1..HEAD 2>/dev/null ); RC=$?
assert "T1 undocumented new file exit 1" "1" "$RC"
case "$OUT" in *"UNDOCUMENTED file    src/foo.ts"*) F=1 ;; *) F=0 ;; esac
assert "T1 reports src/foo.ts UNDOCUMENTED" "1" "$F"
rm -rf "$D"

# T2 — net-new file referenced by a doc.
D=$(newrepo)
( cd "$D"; printf 'x\n' > src/bar.ts; echo "see src/bar.ts" > docs/bar.md; git add -A; git commit -qm add )
RC=$( cd "$D"; "$SS" --range HEAD~1..HEAD --quiet 2>/dev/null; echo $? )
assert "T2 documented new file exit 0" "0" "$RC"
rm -rf "$D"

# T3 — hook/script with only a generic (non-ops) doc → still UNDOCUMENTED (A6).
D=$(newrepo)
( cd "$D"; printf '#!/bin/bash\n' > .claude/scripts/baz.sh; echo "baz.sh mention" > docs/generic.md; git add -A; git commit -qm add )
OUT=$( cd "$D"; "$SS" --range HEAD~1..HEAD 2>/dev/null ); RC=$?
assert "T3 hook/script w/o ops doc exit 1" "1" "$RC"
case "$OUT" in *"UNDOCUMENTED file    .claude/scripts/baz.sh"*) F=1 ;; *) F=0 ;; esac
assert "T3 baz.sh flagged needs ops doc" "1" "$F"
rm -rf "$D"

# T4 — hook/script WITH docs/operations doc → DOCUMENTED (A6).
D=$(newrepo)
( cd "$D"; printf '#!/bin/bash\n' > .claude/scripts/baz.sh; echo "baz.sh runbook" > docs/operations/baz.md; git add -A; git commit -qm add )
RC=$( cd "$D"; "$SS" --range HEAD~1..HEAD --quiet 2>/dev/null; echo $? )
assert "T4 hook/script w/ ops doc exit 0" "0" "$RC"
rm -rf "$D"

# T5 — net-new env var.
D=$(newrepo)
( cd "$D"; printf 'const v = process.env.MY_BRAND_NEW_VAR\n' > src/cfg.ts; echo "see src/cfg.ts file" > docs/cfg.md; git add -A; git commit -qm add )
OUT=$( cd "$D"; "$SS" --range HEAD~1..HEAD 2>/dev/null ); RC=$?
assert "T5 env var undocumented exit 1" "1" "$RC"
case "$OUT" in *"UNDOCUMENTED env     MY_BRAND_NEW_VAR"*) F=1 ;; *) F=0 ;; esac
assert "T5 reports MY_BRAND_NEW_VAR" "1" "$F"
rm -rf "$D"

# T6 — waiver suppresses.
D=$(newrepo)
( cd "$D"; printf 'export const widget = 1\n' > src/foo.ts
  printf 'src/foo.ts\nwidget\n' > .claude/state/plan-w-team-docs-waived-run.txt
  git add -A; git commit -qm add )
RC=$( cd "$D"; "$SS" --range HEAD~1..HEAD --slug run --quiet 2>/dev/null; echo $? )
assert "T6 waiver → exit 0" "0" "$RC"
rm -rf "$D"

# T7 — no net-new surface (only a doc edit).
D=$(newrepo)
( cd "$D"; echo "more" >> README.md; git add -A; git commit -qm docedit )
RC=$( cd "$D"; "$SS" --range HEAD~1..HEAD --quiet 2>/dev/null; echo $? )
assert "T7 no new surface → exit 0" "0" "$RC"
rm -rf "$D"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
