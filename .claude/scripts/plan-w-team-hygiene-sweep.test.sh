#!/usr/bin/env bash
# plan-w-team-hygiene-sweep.test.sh — AC7 standing pre-flight/supervisor-wake hygiene.
# Stubs the three composed layer scripts (worktree-gc, companion-gc, disk-budget) so
# the sweep's rollup + one-line summary + dry-run-default are asserted deterministically.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWEEP="$SCRIPT_DIR/plan-w-team-hygiene-sweep.sh"
[ -x "$SWEEP" ] || { echo "FAIL: sweep not executable"; exit 1; }

PASS=0; FAIL=0; ROOTS=()
pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; echo "    $2"; FAIL=$((FAIL+1)); }
assert_eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "expected=[$2] actual=[$3]"; }
cleanup() { for r in "${ROOTS[@]:-}"; do [ -n "${r:-}" ] && rm -rf "$r"; done; }
trap cleanup EXIT

mkstubs() {  # $1 root → creates gc/companion/disk stubs that record their argv + emit JSON
    local r="$1"
    cat > "$r/gc.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$ARGLOG_GC"
echo '{"totals":{"scanned":3,"removed":2,"kept":1},"worktrees":[{"orphan_dir":true},{"orphan_dir":false},{"orphan_dir":false}]}'
EOF
    cat > "$r/companion.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$ARGLOG_COMP"
echo '{"totals":{"scanned":2,"killed":1,"kept":1}}'
EOF
    cat > "$r/disk.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"free_gb": 42.5, "recommended_action": "SPAWN_OK"}'
EOF
    chmod +x "$r/gc.sh" "$r/companion.sh" "$r/disk.sh"
}

run_sweep() {  # $1 root, rest = args
    local r="$1"; shift
    ARGLOG_GC="$r/gc.args" ARGLOG_COMP="$r/comp.args" \
    PWT_HYGIENE_GC="$r/gc.sh" PWT_HYGIENE_COMPANION_GC="$r/companion.sh" PWT_HYGIENE_DISK_BUDGET="$r/disk.sh" \
    bash "$SWEEP" "$@"
}

echo "── plan-w-team-hygiene-sweep tests ──"

# [1] dry-run default: one-line summary with parsed counts; layer scripts NOT --execute
echo "[1] dry-run default → one-line summary, no --execute passed down"
R=$(mktemp -d -t pwt-hyg.XXXXXX); ROOTS+=("$R"); mkstubs "$R"
OUT=$(run_sweep "$R")
printf '%s' "$OUT" | grep -q '^hygiene-sweep: ' && pass "emits one-line summary" || fail "one-line summary" "got: $OUT"
printf '%s' "$OUT" | grep -q 'wt_reaped=2' && pass "parses wt_reaped from GC json" || fail "wt_reaped" "got: $OUT"
printf '%s' "$OUT" | grep -q 'companions_reaped=1' && pass "parses companions_reaped" || fail "companions_reaped" "got: $OUT"
printf '%s' "$OUT" | grep -q 'orphan_dirs=1' && pass "parses orphan_dirs" || fail "orphan_dirs" "got: $OUT"
printf '%s' "$OUT" | grep -q 'df_free_gb=42.5' && pass "includes df headroom" || fail "df_free_gb" "got: $OUT"
printf '%s' "$OUT" | grep -q 'mode=dry-run' && pass "default mode is dry-run" || fail "mode dry-run" "got: $OUT"
GC_ARGS=$(cat "$R/gc.args" 2>/dev/null)
case "$GC_ARGS" in *--execute*) fail "dry-run must NOT pass --execute to GC" "args=$GC_ARGS" ;; *) pass "dry-run does not pass --execute to GC" ;; esac

# [2] --execute passes --execute down to both GCs; mode=execute
echo "[2] --execute → propagates --execute to layer scripts"
R=$(mktemp -d -t pwt-hyg.XXXXXX); ROOTS+=("$R"); mkstubs "$R"
OUT=$(run_sweep "$R" --execute)
printf '%s' "$OUT" | grep -q 'mode=execute' && pass "mode=execute reported" || fail "mode execute" "got: $OUT"
grep -q -- '--execute' "$R/gc.args" && pass "GC received --execute" || fail "GC --execute" "args=$(cat "$R/gc.args")"
grep -q -- '--execute' "$R/comp.args" && pass "companion-GC received --execute" || fail "companion --execute" "args=$(cat "$R/comp.args")"

# [3] --orphans-ok propagates to the worktree GC only
echo "[3] --orphans-ok → passed to worktree GC"
R=$(mktemp -d -t pwt-hyg.XXXXXX); ROOTS+=("$R"); mkstubs "$R"
run_sweep "$R" --execute --orphans-ok >/dev/null
grep -q -- '--orphans-ok' "$R/gc.args" && pass "GC received --orphans-ok" || fail "GC --orphans-ok" "args=$(cat "$R/gc.args")"

# [4] --json rollup is well-formed and carries the parsed counts
echo "[4] --json rollup well-formed"
R=$(mktemp -d -t pwt-hyg.XXXXXX); ROOTS+=("$R"); mkstubs "$R"
JOUT=$(run_sweep "$R" --json)
OK=$(printf '%s' "$JOUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
need=["schema","mode","df_free_gb","worktrees_reaped","companions_reaped","orphan_dirs"]
print("ok" if all(k in d for k in need) and d["schema"]=="plan-w-team-hygiene-sweep/v1"
      and d["worktrees_reaped"]==2 and d["companions_reaped"]==1 and d["orphan_dirs"]==1 else "bad")' 2>/dev/null || echo bad)
assert_eq "json rollup has all keys + correct counts" "ok" "$OK"

# [5] disable kill-switch → no-op skip
echo "[5] PWT_HYGIENE_SWEEP_DISABLE=1 → skip"
R=$(mktemp -d -t pwt-hyg.XXXXXX); ROOTS+=("$R"); mkstubs "$R"
OUT=$(PWT_HYGIENE_SWEEP_DISABLE=1 run_sweep "$R")
printf '%s' "$OUT" | grep -q '"skipped":true' && pass "disable → skipped:true" || fail "disable skip" "got: $OUT"

# [6] bash 3.2 compatibility
echo "[6] runs clean under bash 3.2 (/bin/bash on macOS)"
if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
    R=$(mktemp -d -t pwt-hyg.XXXXXX); ROOTS+=("$R"); mkstubs "$R"; ERRF="$R/b32.err"
    OUT=$( ARGLOG_GC="$R/gc.args" ARGLOG_COMP="$R/comp.args" \
           PWT_HYGIENE_GC="$R/gc.sh" PWT_HYGIENE_COMPANION_GC="$R/companion.sh" PWT_HYGIENE_DISK_BUDGET="$R/disk.sh" \
           /bin/bash "$SWEEP" 2>"$ERRF" ); RC=$?
    ERR=$(cat "$ERRF" 2>/dev/null)
    case "$ERR" in *"invalid option"*|*"declare:"*|*"unbound variable"*|*"bad substitution"*) E32=1 ;; *) E32=0 ;; esac
    assert_eq "bash 3.2: no bash-4 error signature" "0" "$E32"
    assert_eq "bash 3.2: exits 0" "0" "$RC"
else
    echo "  ⊘ skipped (no bash 3.2 at /bin/bash)"
fi

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
