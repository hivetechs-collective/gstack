#!/usr/bin/env bash
# worktree-deps-share.test.sh — test harness for worktree-deps-share.sh
#
# Builds fixture main-repos + worktrees on a tmpdir, runs the sharing script
# in --json mode, and asserts on detection + per-stack action outcomes.
#
# Covers (per directive TESTS section):
#   - Stack detection for each manifest combo + multi-stack repo
#   - Per-stack sharing: pnpm/npm symlink, cargo CARGO_TARGET_DIR, uv .venv,
#     maven/gradle/go no-op
#   - Lockfile-divergence: mismatch → isolate that stack only
#   - Idempotency: re-run = no-op (shared-already), no errors
#   - Safety: existing real node_modules NOT removed without --force
#   - Env override: WORKTREE_DEPS_STRATEGY=isolate, WORKTREE_DEPS_DISABLE_STACKS=cargo
#   - Monorepo: nested workspace node_modules + cargo workspace member
#
# Usage:  ./worktree-deps-share.test.sh
# Exit:   0 on full pass, 1 on any failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WTDS="$SCRIPT_DIR/worktree-deps-share.sh"

if [ ! -x "$WTDS" ]; then
    echo "FAIL: worktree-deps-share.sh not found or not executable at $WTDS" >&2
    exit 1
fi

PASS=0
FAIL=0

# ── helpers ───────────────────────────────────────────────────────────────────

# mktmp creates a tmpdir and returns its CANONICAL path (collapses any //)
# so string comparisons against the script's normalized symlink targets match.
mktmp() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/wtds.XXXXXX")"
    ( cd "$d" && pwd )
}

# action_for <json> <stack>  → prints the action(s) for a stack (space-joined)
action_for() {
    echo "$1" | jq -r --arg s "$2" '.stacks[] | select(.stack==$s) | .action' 2>/dev/null | tr '\n' ' '
}

# detail_for <json> <stack>
detail_for() {
    echo "$1" | jq -r --arg s "$2" '.stacks[] | select(.stack==$s) | .detail' 2>/dev/null | tr '\n' '|'
}

assert_eq() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $label"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label"
        echo "      expected: [$expected]"
        echo "      actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "  ✓ $label"; PASS=$((PASS + 1)) ;;
        *) echo "  ✗ $label"; echo "      [$haystack] does not contain [$needle]"; FAIL=$((FAIL + 1)) ;;
    esac
}

assert_true() {
    local label="$1"; shift
    if "$@"; then echo "  ✓ $label"; PASS=$((PASS + 1));
    else echo "  ✗ $label (command failed: $*)"; FAIL=$((FAIL + 1)); fi
}

assert_false() {
    local label="$1"; shift
    if "$@"; then echo "  ✗ $label (command unexpectedly succeeded: $*)"; FAIL=$((FAIL + 1));
    else echo "  ✓ $label"; PASS=$((PASS + 1)); fi
}

run_wtds() { "$WTDS" "$@"; }

section() { echo ""; echo "── $1 ──"; }

# ══════════════════════════════════════════════════════════════════════════════
# TEST 1 — pnpm single-repo: matching lockfile → node_modules symlinked
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 1: pnpm single-repo share (matching lockfile)"
T1="$(mktmp)"; MAIN="$T1/main"; WT="$T1/wt"
mkdir -p "$MAIN/node_modules/foo" "$WT"
echo '{"name":"app"}' > "$MAIN/package.json"; cp "$MAIN/package.json" "$WT/package.json"
echo 'lockfile-content-v1' > "$MAIN/pnpm-lock.yaml"; cp "$MAIN/pnpm-lock.yaml" "$WT/pnpm-lock.yaml"
JSON="$(run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T1/state" --slug t1 --json)"
assert_eq "pnpm detected and shared" "$(action_for "$JSON" pnpm)" "shared "
assert_true "worktree node_modules is a symlink" test -L "$WT/node_modules"
assert_eq "symlink points at main node_modules" "$(readlink "$WT/node_modules")" "$MAIN/node_modules"
assert_true "hash state file written" test -f "$T1/state/worktree-deps-hash-t1.json"
rm -rf "$T1"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 2 — npm detection (package-lock, no pnpm-lock)
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 2: npm detection + share"
T2="$(mktmp)"; MAIN="$T2/main"; WT="$T2/wt"
mkdir -p "$MAIN/node_modules" "$WT"
echo '{}' > "$MAIN/package.json"; cp "$MAIN/package.json" "$WT/package.json"
echo 'npmlock' > "$MAIN/package-lock.json"; cp "$MAIN/package-lock.json" "$WT/package-lock.json"
JSON="$(run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T2/state" --slug t2 --json)"
assert_eq "npm detected and shared" "$(action_for "$JSON" npm)" "shared "
assert_true "npm node_modules symlinked" test -L "$WT/node_modules"
rm -rf "$T2"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 3 — cargo: CARGO_TARGET_DIR via .cargo/config.toml (no symlink)
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 3: cargo CARGO_TARGET_DIR"
T3="$(mktmp)"; MAIN="$T3/main"; WT="$T3/wt"
mkdir -p "$MAIN/target/debug" "$WT"
echo '[package]' > "$MAIN/Cargo.toml"; cp "$MAIN/Cargo.toml" "$WT/Cargo.toml"
echo 'cargolock' > "$MAIN/Cargo.lock"; cp "$MAIN/Cargo.lock" "$WT/Cargo.lock"
JSON="$(run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T3/state" --slug t3 --json)"
assert_eq "cargo detected and shared" "$(action_for "$JSON" cargo)" "shared "
assert_true "no target/ symlink in worktree" test ! -e "$WT/target"
assert_true ".cargo/config.toml created" test -f "$WT/.cargo/config.toml"
assert_true "config points target-dir at main" grep -qF "$MAIN/target" "$WT/.cargo/config.toml"
rm -rf "$T3"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 3b — cargo MERGE into existing .cargo/config.toml (don't clobber)
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 3b: cargo merge preserves existing config keys"
T3b="$(mktmp)"; MAIN="$T3b/main"; WT="$T3b/wt"
mkdir -p "$MAIN/target" "$WT/.cargo"
echo '[package]' > "$MAIN/Cargo.toml"; cp "$MAIN/Cargo.toml" "$WT/Cargo.toml"
echo 'cl' > "$MAIN/Cargo.lock"; cp "$MAIN/Cargo.lock" "$WT/Cargo.lock"
printf '[registries.my-registry]\nindex = "https://example.com/git/index"\n' > "$WT/.cargo/config.toml"
run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T3b/state" --slug t3b --json >/dev/null
assert_true "existing registries key preserved" grep -qF "registries.my-registry" "$WT/.cargo/config.toml"
assert_true "build target-dir appended" grep -qF "$MAIN/target" "$WT/.cargo/config.toml"
rm -rf "$T3b"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 4 — uv: .venv symlink
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 4: uv .venv symlink"
T4="$(mktmp)"; MAIN="$T4/main"; WT="$T4/wt"
mkdir -p "$MAIN/.venv/bin" "$WT"
echo '[project]' > "$MAIN/pyproject.toml"; cp "$MAIN/pyproject.toml" "$WT/pyproject.toml"
echo 'uvlock' > "$MAIN/uv.lock"; cp "$MAIN/uv.lock" "$WT/uv.lock"
JSON="$(run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T4/state" --slug t4 --json)"
assert_eq "uv detected and shared" "$(action_for "$JSON" uv)" "shared "
assert_true "uv .venv symlinked" test -L "$WT/.venv"
rm -rf "$T4"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 5 — maven / gradle / go no-op
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 5: maven/gradle/go no-op"
T5="$(mktmp)"; MAIN="$T5/main"; WT="$T5/wt"
mkdir -p "$MAIN" "$WT"
echo '<project/>' > "$MAIN/pom.xml"; cp "$MAIN/pom.xml" "$WT/pom.xml"
echo 'plugins {}' > "$MAIN/build.gradle"; cp "$MAIN/build.gradle" "$WT/build.gradle"
echo 'module x' > "$MAIN/go.mod"; cp "$MAIN/go.mod" "$WT/go.mod"
echo 'sum' > "$MAIN/go.sum"; cp "$MAIN/go.sum" "$WT/go.sum"
JSON="$(run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T5/state" --slug t5 --json)"
assert_eq "maven no-op" "$(action_for "$JSON" maven)" "noop "
assert_eq "gradle no-op" "$(action_for "$JSON" gradle)" "noop "
assert_eq "go no-op" "$(action_for "$JSON" go)" "noop "
rm -rf "$T5"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 6 — lockfile divergence → isolate that stack only
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 6: lockfile divergence isolates the diverged stack only"
T6="$(mktmp)"; MAIN="$T6/main"; WT="$T6/wt"
mkdir -p "$MAIN/node_modules" "$MAIN/.venv" "$WT"
echo '{}' > "$MAIN/package.json"; cp "$MAIN/package.json" "$WT/package.json"
echo 'pnpm-v1' > "$MAIN/pnpm-lock.yaml"
echo 'pnpm-v2-DIVERGED' > "$WT/pnpm-lock.yaml"     # mismatch
echo '[project]' > "$MAIN/pyproject.toml"; cp "$MAIN/pyproject.toml" "$WT/pyproject.toml"
echo 'uvlock' > "$MAIN/uv.lock"; cp "$MAIN/uv.lock" "$WT/uv.lock"   # match
JSON="$(run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T6/state" --slug t6 --json)"
assert_eq "pnpm isolated due to divergence" "$(action_for "$JSON" pnpm)" "isolate "
assert_true "pnpm node_modules NOT symlinked" test ! -e "$WT/node_modules"
assert_eq "uv still shared (matched)" "$(action_for "$JSON" uv)" "shared "
assert_true "uv .venv symlinked" test -L "$WT/.venv"
rm -rf "$T6"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 7 — idempotency: re-run = shared-already, no error
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 7: idempotency"
T7="$(mktmp)"; MAIN="$T7/main"; WT="$T7/wt"
mkdir -p "$MAIN/node_modules" "$WT"
echo '{}' > "$MAIN/package.json"; cp "$MAIN/package.json" "$WT/package.json"
echo 'l' > "$MAIN/pnpm-lock.yaml"; cp "$MAIN/pnpm-lock.yaml" "$WT/pnpm-lock.yaml"
run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T7/state" --slug t7 --json >/dev/null
JSON2="$(run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T7/state" --slug t7 --json)"
RC=$?
assert_eq "second run exit code 0" "$RC" "0"
assert_eq "pnpm reports shared-already on re-run" "$(action_for "$JSON2" pnpm)" "shared-already "
assert_true "symlink still valid" test -L "$WT/node_modules"
rm -rf "$T7"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 8 — safety: existing REAL node_modules left alone without --force
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 8: real node_modules not removed without --force"
T8="$(mktmp)"; MAIN="$T8/main"; WT="$T8/wt"
mkdir -p "$MAIN/node_modules" "$WT/node_modules/realpkg" "$WT"
echo '{}' > "$MAIN/package.json"; cp "$MAIN/package.json" "$WT/package.json"
echo 'l' > "$MAIN/pnpm-lock.yaml"; cp "$MAIN/pnpm-lock.yaml" "$WT/pnpm-lock.yaml"
echo 'precious' > "$WT/node_modules/realpkg/index.js"
JSON="$(run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T8/state" --slug t8 --json)"
assert_eq "pnpm skipped (real dir present)" "$(action_for "$JSON" pnpm)" "skip "
assert_true "real node_modules still a directory" test -d "$WT/node_modules"
assert_false "not a symlink" test -L "$WT/node_modules"
assert_true "precious file intact" test -f "$WT/node_modules/realpkg/index.js"
# Now with --force it should replace
run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T8/state" --slug t8 --force --json >/dev/null
assert_true "with --force node_modules becomes symlink" test -L "$WT/node_modules"
rm -rf "$T8"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 9 — env override: WORKTREE_DEPS_STRATEGY=isolate skips all sharing
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 9: WORKTREE_DEPS_STRATEGY=isolate"
T9="$(mktmp)"; MAIN="$T9/main"; WT="$T9/wt"
mkdir -p "$MAIN/node_modules" "$MAIN/target" "$WT"
echo '{}' > "$MAIN/package.json"; cp "$MAIN/package.json" "$WT/package.json"
echo 'l' > "$MAIN/pnpm-lock.yaml"; cp "$MAIN/pnpm-lock.yaml" "$WT/pnpm-lock.yaml"
echo '[package]' > "$MAIN/Cargo.toml"; cp "$MAIN/Cargo.toml" "$WT/Cargo.toml"
echo 'cl' > "$MAIN/Cargo.lock"; cp "$MAIN/Cargo.lock" "$WT/Cargo.lock"
JSON="$(WORKTREE_DEPS_STRATEGY=isolate run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T9/state" --slug t9 --json)"
assert_eq "pnpm isolated by env" "$(action_for "$JSON" pnpm)" "isolate "
assert_eq "cargo isolated by env" "$(action_for "$JSON" cargo)" "isolate "
assert_true "no node_modules symlink" test ! -e "$WT/node_modules"
assert_true "no .cargo config" test ! -e "$WT/.cargo/config.toml"
rm -rf "$T9"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 10 — WORKTREE_DEPS_DISABLE_STACKS=cargo: share everything else, skip cargo
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 10: WORKTREE_DEPS_DISABLE_STACKS=cargo"
T10="$(mktmp)"; MAIN="$T10/main"; WT="$T10/wt"
mkdir -p "$MAIN/node_modules" "$MAIN/target" "$WT"
echo '{}' > "$MAIN/package.json"; cp "$MAIN/package.json" "$WT/package.json"
echo 'l' > "$MAIN/pnpm-lock.yaml"; cp "$MAIN/pnpm-lock.yaml" "$WT/pnpm-lock.yaml"
echo '[package]' > "$MAIN/Cargo.toml"; cp "$MAIN/Cargo.toml" "$WT/Cargo.toml"
echo 'cl' > "$MAIN/Cargo.lock"; cp "$MAIN/Cargo.lock" "$WT/Cargo.lock"
JSON="$(WORKTREE_DEPS_DISABLE_STACKS=cargo run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T10/state" --slug t10 --json)"
assert_eq "pnpm shared" "$(action_for "$JSON" pnpm)" "shared "
assert_eq "cargo isolated (disabled)" "$(action_for "$JSON" cargo)" "isolate "
assert_true "node_modules symlinked" test -L "$WT/node_modules"
assert_true "no .cargo config (cargo disabled)" test ! -e "$WT/.cargo/config.toml"
rm -rf "$T10"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 11 — multi-stack repo: node + cargo + uv all detected & applied
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 11: multi-stack repo (node + cargo + uv)"
T11="$(mktmp)"; MAIN="$T11/main"; WT="$T11/wt"
mkdir -p "$MAIN/node_modules" "$MAIN/target" "$MAIN/.venv" "$WT"
echo '{}' > "$MAIN/package.json"; cp "$MAIN/package.json" "$WT/package.json"
echo 'l' > "$MAIN/pnpm-lock.yaml"; cp "$MAIN/pnpm-lock.yaml" "$WT/pnpm-lock.yaml"
echo '[package]' > "$MAIN/Cargo.toml"; cp "$MAIN/Cargo.toml" "$WT/Cargo.toml"
echo 'cl' > "$MAIN/Cargo.lock"; cp "$MAIN/Cargo.lock" "$WT/Cargo.lock"
echo '[project]' > "$MAIN/pyproject.toml"; cp "$MAIN/pyproject.toml" "$WT/pyproject.toml"
echo 'uvl' > "$MAIN/uv.lock"; cp "$MAIN/uv.lock" "$WT/uv.lock"
JSON="$(run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T11/state" --slug t11 --json)"
assert_eq "pnpm shared" "$(action_for "$JSON" pnpm)" "shared "
assert_eq "cargo shared" "$(action_for "$JSON" cargo)" "shared "
assert_eq "uv shared" "$(action_for "$JSON" uv)" "shared "
assert_true "node_modules symlink" test -L "$WT/node_modules"
assert_true "cargo config" test -f "$WT/.cargo/config.toml"
assert_true "uv .venv symlink" test -L "$WT/.venv"
rm -rf "$T11"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 12 — monorepo: nested workspace node_modules + cargo workspace member
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 12: monorepo nested manifests"
T12="$(mktmp)"; MAIN="$T12/main"; WT="$T12/wt"
# pnpm workspace: root + packages/web
mkdir -p "$MAIN/node_modules" "$MAIN/packages/web/node_modules" "$WT"
echo '{}' > "$MAIN/package.json"; cp "$MAIN/package.json" "$WT/package.json"
echo 'l' > "$MAIN/pnpm-lock.yaml"; cp "$MAIN/pnpm-lock.yaml" "$WT/pnpm-lock.yaml"
mkdir -p "$WT/packages/web"
echo '{}' > "$MAIN/packages/web/package.json"; cp "$MAIN/packages/web/package.json" "$WT/packages/web/package.json"
echo 'l' > "$MAIN/packages/web/pnpm-lock.yaml"; cp "$MAIN/packages/web/pnpm-lock.yaml" "$WT/packages/web/pnpm-lock.yaml"
# cargo workspace: root + crates/core
mkdir -p "$MAIN/target" "$MAIN/crates/core/target" "$WT/crates/core"
echo '[workspace]' > "$MAIN/Cargo.toml"; cp "$MAIN/Cargo.toml" "$WT/Cargo.toml"
echo 'cl' > "$MAIN/Cargo.lock"; cp "$MAIN/Cargo.lock" "$WT/Cargo.lock"
echo '[package]' > "$MAIN/crates/core/Cargo.toml"; cp "$MAIN/crates/core/Cargo.toml" "$WT/crates/core/Cargo.toml"
echo 'cl' > "$MAIN/crates/core/Cargo.lock"; cp "$MAIN/crates/core/Cargo.lock" "$WT/crates/core/Cargo.lock"
JSON="$(run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T12/state" --slug t12 --json)"
assert_true "root node_modules symlinked" test -L "$WT/node_modules"
assert_true "workspace web node_modules symlinked" test -L "$WT/packages/web/node_modules"
assert_eq "workspace web symlink target" "$(readlink "$WT/packages/web/node_modules")" "$MAIN/packages/web/node_modules"
assert_true "root .cargo config created" test -f "$WT/.cargo/config.toml"
assert_true "crate .cargo config created" test -f "$WT/crates/core/.cargo/config.toml"
rm -rf "$T12"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 13 — dry-run changes nothing
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 13: dry-run makes no filesystem changes"
T13="$(mktmp)"; MAIN="$T13/main"; WT="$T13/wt"
mkdir -p "$MAIN/node_modules" "$WT"
echo '{}' > "$MAIN/package.json"; cp "$MAIN/package.json" "$WT/package.json"
echo 'l' > "$MAIN/pnpm-lock.yaml"; cp "$MAIN/pnpm-lock.yaml" "$WT/pnpm-lock.yaml"
JSON="$(run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T13/state" --slug t13 --dry-run --json)"
assert_eq "dry-run reports would-share" "$(action_for "$JSON" pnpm)" "would-share "
assert_true "no symlink created" test ! -e "$WT/node_modules"
assert_true "no hash state written on dry-run" test ! -f "$T13/state/worktree-deps-hash-t13.json"
assert_eq "dry_run flag true in report" "$(echo "$JSON" | jq -r '.dry_run')" "true"
rm -rf "$T13"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 14 — main source missing → skip (don't symlink a dangling target)
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 14: missing main source skips"
T14="$(mktmp)"; MAIN="$T14/main"; WT="$T14/wt"
mkdir -p "$MAIN" "$WT"   # main has NO node_modules
echo '{}' > "$MAIN/package.json"; cp "$MAIN/package.json" "$WT/package.json"
echo 'l' > "$MAIN/pnpm-lock.yaml"; cp "$MAIN/pnpm-lock.yaml" "$WT/pnpm-lock.yaml"
JSON="$(run_wtds --worktree "$WT" --main "$MAIN" --state-dir "$T14/state" --slug t14 --json)"
assert_eq "pnpm skipped (main source missing)" "$(action_for "$JSON" pnpm)" "skip "
assert_true "no dangling symlink created" test ! -e "$WT/node_modules"
rm -rf "$T14"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 15 — usage errors
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 15: usage / safety errors"
T15="$(mktmp)"; mkdir -p "$T15/repo"
assert_false "missing --main fails" run_wtds --worktree "$T15/repo"
assert_false "same path refused" run_wtds --worktree "$T15/repo" --main "$T15/repo"
assert_false "bad strategy fails" run_wtds --worktree "$T15/repo" --main "$T15" --strategy bogus
rm -rf "$T15"

# ══════════════════════════════════════════════════════════════════════════════
# TEST 16 — bash 3.2 compatibility (macOS /bin/bash; mac-mini deployment target)
# Regression guard: the engine once used `declare -A` (bash 4+), a fatal
# "invalid option" on macOS stock /bin/bash 3.2 that silently broke deps-share
# on the mac-mini. `bash -n` can't catch it (runtime error), so run for real.
# ══════════════════════════════════════════════════════════════════════════════
section "TEST 16: runs clean under bash 3.2 (/bin/bash on macOS)"
if [ -x /bin/bash ] && /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
    T16="$(mktmp)"; MAIN="$T16/main"; WT="$T16/wt"
    mkdir -p "$MAIN/node_modules" "$WT"
    echo '{}' > "$MAIN/package.json"; cp "$MAIN/package.json" "$WT/package.json"
    echo 'l' > "$MAIN/pnpm-lock.yaml"; cp "$MAIN/pnpm-lock.yaml" "$WT/pnpm-lock.yaml"
    B32_OUT="$(/bin/bash "$WTDS" --worktree "$WT" --main "$MAIN" --state-dir "$T16/state" --slug t16 --dry-run --json 2>&1)"; B32_RC=$?
    case "$B32_OUT" in
        *"invalid option"*|*"declare:"*|*"unbound variable"*) B32_ERR=1 ;;
        *) B32_ERR=0 ;;
    esac
    assert_eq "bash 3.2 run exits 0" "$B32_RC" "0"
    assert_eq "no bash-4 error signature under bash 3.2" "$B32_ERR" "0"
    assert_contains "valid stack report under bash 3.2" "$B32_OUT" '"stack": "pnpm"'
    rm -rf "$T16"
else
    echo "  ⊘ skipped (no bash 3.2 at /bin/bash — not the regression-risk host)"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  PASS: $PASS    FAIL: $FAIL"
echo "════════════════════════════════════════"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
