#!/usr/bin/env bash
# Tests for plan-w-team-symmetry-check.sh A4 fix: phantom-reader detection.
# A handoff/enforcing artifact whose only "reader" is a bare-filename mention inside the
# WRITER's own markdown stage file is a phantom (the post-ship→retro §8d bug). It must be
# flagged; a reader in a NON-writer file, or a VAR= style reader, must pass.
#
# Coverage:
#   T1  reader only in writer's own .md (bare filename)  → phantom orphan (exit 1)
#   T2  same + a real reader in a non-writer .md         → ok (exit 0)
#   T3  identical writer/reader pattern (same-symbol)    → exempt, ok (exit 0)
#   T4  VAR="…"-style reader in writer file only         → exempt, ok (exit 0)
#   T5  the REAL repo registry+scope                     → exit 0 (no regression; §8d reader wired)

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/plan-w-team-symmetry-check.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}

make_registry() {  # $1=dir ; writes a minimal registry with the given rows on stdin
    local d="$1"; shift
    {
      echo "| pattern | writer_grep | reader_grep | mode | purpose |"
      echo "| ------- | ----------- | ----------- | ---- | ------- |"
      cat
    } > "$d/registry.md"
}

# ─── T1 — phantom: reader is a bare filename only in the writer's own .md ─────
D=$(mktemp -d); mkdir -p "$D/scope"
cat > "$D/scope/writer.md" <<'EOF'
ARTIFACT=".claude/state/plan-w-team-foo-$SLUG.json"
Step 8 retro consumes plan-w-team-foo-$SLUG.json to score things.
EOF
make_registry "$D" <<'EOF'
| `.claude/state/plan-w-team-foo-$SLUG.json` | `ARTIFACT=".claude/state/plan-w-team-foo` | `plan-w-team-foo-\$SLUG\.json` | handoff | phantom fixture |
EOF
RC=$(PWT_SYMMETRY_SCOPE="$D/scope" "$CHECK" --registry "$D/registry.md" >/tmp/ph1.$$ 2>&1; echo $?)
assert "T1 phantom reader → exit 1" "1" "$RC"
grep -q "phantom reader" /tmp/ph1.$$ && PH=1 || PH=0
assert "T1 emits phantom message" "1" "$PH"
rm -rf "$D" /tmp/ph1.$$

# ─── T2 — real reader in a non-writer .md → ok ───────────────────────────────
D=$(mktemp -d); mkdir -p "$D/scope"
cat > "$D/scope/writer.md" <<'EOF'
ARTIFACT=".claude/state/plan-w-team-foo-$SLUG.json"
EOF
cat > "$D/scope/reader.md" <<'EOF'
Retro reads plan-w-team-foo-$SLUG.json here (the real consumer).
EOF
make_registry "$D" <<'EOF'
| `.claude/state/plan-w-team-foo-$SLUG.json` | `ARTIFACT=".claude/state/plan-w-team-foo` | `plan-w-team-foo-\$SLUG\.json` | handoff | real reader fixture |
EOF
RC=$(PWT_SYMMETRY_SCOPE="$D/scope" "$CHECK" --registry "$D/registry.md" >/dev/null 2>&1; echo $?)
assert "T2 non-writer reader → exit 0" "0" "$RC"
rm -rf "$D"

# ─── T3 — identical writer/reader pattern (same-symbol) → exempt ──────────────
D=$(mktemp -d); mkdir -p "$D/scope"
cat > "$D/scope/writer.md" <<'EOF'
FOO=".claude/state/plan-w-team-foo-$SLUG.json"   # write + read via same var
EOF
make_registry "$D" <<'EOF'
| `.claude/state/plan-w-team-foo-$SLUG.json` | `FOO=".claude/state/plan-w-team-foo` | `FOO=".claude/state/plan-w-team-foo` | handoff | same-symbol fixture |
EOF
RC=$(PWT_SYMMETRY_SCOPE="$D/scope" "$CHECK" --registry "$D/registry.md" >/dev/null 2>&1; echo $?)
assert "T3 identical pattern → exit 0" "0" "$RC"
rm -rf "$D"

# ─── T4 — VAR="…"-style reader in writer file only → exempt (has '=') ─────────
D=$(mktemp -d); mkdir -p "$D/scope"
cat > "$D/scope/writer.md" <<'EOF'
cat > ".claude/state/plan-w-team-bar-$SLUG.json"
BARREAD=".claude/state/plan-w-team-bar-$SLUG.json"
EOF
make_registry "$D" <<'EOF'
| `.claude/state/plan-w-team-bar-$SLUG.json` | `cat > ".claude/state/plan-w-team-bar` | `BARREAD=".claude/state/plan-w-team-bar` | handoff | var-reader fixture |
EOF
RC=$(PWT_SYMMETRY_SCOPE="$D/scope" "$CHECK" --registry "$D/registry.md" >/dev/null 2>&1; echo $?)
assert "T4 VAR= reader → exit 0" "0" "$RC"
rm -rf "$D"

# ─── T5 — real repo (regression: §8d reader wired, no phantom) ────────────────
RC=$( cd "$REPO_ROOT"; "$CHECK" >/dev/null 2>&1; echo $? )
assert "T5 real repo symmetry-check → exit 0" "0" "$RC"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
