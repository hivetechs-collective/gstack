#!/usr/bin/env bash
# plan-w-team-sync-allowlist-check.test.sh
#
# BDD regression suite for plan-w-team-sync-allowlist-check.sh.
#
# Guards the two confirmed consumer-repo failure modes (Helm bug report,
# 2026-06-28) plus the gate's load-bearing value:
#
#   Bug 2 (silent abort): `set -euo pipefail` + an empty `grep` aborted the whole
#     script via pipefail, so REAL drift in the source repo NEVER printed its
#     offenders. Scenario A proves diagnostics now surface.
#   Bug 1 (consumer false-positive): inferring "sync-to-project.sh present ⟹
#     source repo" hard-failed any consumer carrying an older / different-format
#     copy with no `cp "$SOURCE_DIR/scripts/…"` lines (ALLOW empty → every
#     candidate flagged "missing"). Scenario B proves it now soft-skips.
#   Gate value preserved: Scenario C proves a fully-symmetric source repo still
#     reports "verified" (exit 0).
#
# Fully mktemp-isolated: each scenario builds a throwaway git repo with its own
# .claude/scripts/ fixture and runs the REAL check from inside it (so the check's
# `git rev-parse --show-toplevel` resolves REPO_ROOT to the fixture, never the
# live repo). Nothing is written to the live tree or to .claude/state. bash 3.2
# safe (no associative arrays, no `realpath`/`readlink -f`).
#
# Usage: bash .claude/scripts/plan-w-team-sync-allowlist-check.test.sh
# Exits 0 on all-pass, 1 on any failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/plan-w-team-sync-allowlist-check.sh"

PASS=0
FAIL=0
ROOTS=""

cleanup() {
    for r in $ROOTS; do
        [ -n "$r" ] && [ -d "$r" ] && rm -rf "$r"
    done
}
trap cleanup EXIT

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; FAIL=$((FAIL + 1)); }

# mk_fixture — create a throwaway git repo with an empty .claude/scripts/ dir.
# Echoes the fixture root path. Each fixture is its own git repo so the check's
# `git rev-parse --show-toplevel` (run with CWD inside it) resolves to it.
mk_fixture() {
    local root
    root="$(mktemp -d -t pwt-syncallow.XXXXXX)"
    ROOTS="$ROOTS $root"
    git -C "$root" init -q
    git -C "$root" config user.email t@t.t
    git -C "$root" config user.name t
    mkdir -p "$root/.claude/scripts"
    echo "$root"
}

# add_candidate — drop a plan-w-team-* candidate script into the fixture.
add_candidate() {
    local root="$1" name="$2"
    printf '#!/usr/bin/env bash\ntrue\n' > "$root/.claude/scripts/$name"
    chmod +x "$root/.claude/scripts/$name"
}

# run_check — run the REAL check from inside the fixture; capture combined
# output to a file and the exit code. Args: <root> <outfile>; echoes exit code.
run_check() {
    local root="$1" out="$2" rc
    ( cd "$root" && bash "$CHECK" ) > "$out" 2>&1
    rc=$?
    echo "$rc"
}

# ── Scenario A — Given a SOURCE-format sync-to-project.sh WITH cp lines AND a
#    candidate NOT in the allowlist, When the check runs, Then it exits 1 AND
#    names the offender (Bug-2 fix: diagnostics surface; gate value preserved). ──
echo "Scenario A: source-format + real drift → exit 1 + offender named"
A="$(mk_fixture)"
cat > "$A/.claude/scripts/sync-to-project.sh" <<'EOF'
#!/usr/bin/env bash
cp "$SOURCE_DIR/scripts/plan-w-team-present.sh" "$TARGET_DIR/scripts/plan-w-team-present.sh"
EOF
add_candidate "$A" "plan-w-team-present.sh"
add_candidate "$A" "plan-w-team-orphan.sh"   # the offender — no cp line
A_OUT="$A/out.txt"
A_RC="$(run_check "$A" "$A_OUT")"
if [ "$A_RC" = "1" ]; then
    pass "drift exits 1"
else
    fail "drift exits 1" "expected rc=1, got rc=$A_RC"
fi
if grep -q 'plan-w-team-orphan.sh' "$A_OUT"; then
    pass "offender plan-w-team-orphan.sh named in output"
else
    fail "offender named in output" "output: $(cat "$A_OUT")"
fi

# ── Scenario B — Given a CONSUMER-format sync-to-project.sh present but with NO
#    cp lines AND candidates present, When the check runs, Then it soft-skips
#    (exit 0 + warning), NOT a silent exit-1 hard fail (Bug-1 fix). ──
echo "Scenario B: consumer-format (no cp lines) → exit 0 + warning, not hard fail"
B="$(mk_fixture)"
cat > "$B/.claude/scripts/sync-to-project.sh" <<'EOF'
#!/usr/bin/env bash
# An older / different-format consumer copy that carries no source allowlist lines.
echo "syncing (legacy consumer format)"
EOF
add_candidate "$B" "plan-w-team-present.sh"
B_OUT="$B/out.txt"
B_RC="$(run_check "$B" "$B_OUT")"
if [ "$B_RC" = "0" ]; then
    pass "consumer-format soft-skips (exit 0)"
else
    fail "consumer-format soft-skips (exit 0)" "expected rc=0, got rc=$B_RC; output: $(cat "$B_OUT")"
fi
if grep -qi 'skipping\|consumer' "$B_OUT"; then
    pass "consumer-format prints a soft-skip warning"
else
    fail "consumer-format prints a warning" "output: $(cat "$B_OUT")"
fi
if grep -q 'drift detected' "$B_OUT"; then
    fail "consumer-format must NOT report drift" "output: $(cat "$B_OUT")"
else
    pass "consumer-format does NOT report false drift"
fi

# ── Scenario C — Given a SOURCE-format sync-to-project.sh whose cp lines cover
#    EVERY candidate, When the check runs, Then it exits 0 and reports verified. ──
echo "Scenario C: source-format full symmetry → exit 0 + verified"
C="$(mk_fixture)"
cat > "$C/.claude/scripts/sync-to-project.sh" <<'EOF'
#!/usr/bin/env bash
cp "$SOURCE_DIR/scripts/plan-w-team-present.sh" "$TARGET_DIR/scripts/plan-w-team-present.sh"
EOF
add_candidate "$C" "plan-w-team-present.sh"
C_OUT="$C/out.txt"
C_RC="$(run_check "$C" "$C_OUT")"
if [ "$C_RC" = "0" ]; then
    pass "symmetry exits 0"
else
    fail "symmetry exits 0" "expected rc=0, got rc=$C_RC; output: $(cat "$C_OUT")"
fi
if grep -qi 'verified' "$C_OUT"; then
    pass "symmetry reports verified"
else
    fail "symmetry reports verified" "output: $(cat "$C_OUT")"
fi

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
