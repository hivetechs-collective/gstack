#!/usr/bin/env bash
# tests/skill/run.sh
#
# Single entry point for the /plan-w-team test harness.
#
# Responsibilities:
#   1. Ensure bats-core is available (vendored under tests/skill/.bats/, auto-cloned).
#   2. Discover all .bats files under tests/skill/cases/.
#   3. Run them with TAP output + JSON archival.
#   4. Archive each run's results under tests/skill/results/runs/<timestamp>.json
#      and update tests/skill/results/latest.json (symlink-like pointer).
#   5. Exit non-zero if any test failed.
#
# Anti-fragmentation lock-in: this is the ONLY way to run the suite. Do not
# add a `test-skill-fast`, a `test-snippets`, or a parallel runner. The whole
# suite runs together so passing tests cannot mask a regression elsewhere.
# (Filtering specific files for local dev iteration is supported via $1, but
# `make test-skill` always runs everything.)
#
# Usage:
#   tests/skill/run.sh                        # run all cases
#   tests/skill/run.sh cases/secret-scan.bats # run a single file (DEV ONLY)
#   tests/skill/run.sh --no-archive           # skip JSON write (CI smoke runs)
#   tests/skill/run.sh --setup                # bootstrap bats only, exit
#
# Exit codes:
#   0 — all tests passed
#   1 — at least one test failed
#   2 — bootstrap or environment failure (cannot run tests at all)

set -euo pipefail

# ── SUITE_EXIT marker (R1) ───────────────────────────────────────────────────
# Emit `SUITE_EXIT=<code>` as the literal FINAL stdout line, exactly once, then
# exit with that code. Deliberately NOT an EXIT trap: the suite runs phases in
# subshells, and a trap would risk a second emission from a subshell exit. Every
# deliberate exit path that represents a SUITE VERDICT routes through here; any
# path that terminates WITHOUT the marker (set -e abort, SIGKILL, truncated log)
# is RED by construction downstream — consumers require a literal trailing
# `SUITE_EXIT=0` and treat marker-absence as failure, never as green.
#
# --help/--setup do NOT emit: they are not suite runs (no verdict to report),
# and the wrapper's NO-SUITE guard covers "no suite here" separately.
__SUITE_EXIT_EMITTED=0
__suite_exit() {
  if [ "$__SUITE_EXIT_EMITTED" -eq 0 ]; then
    __SUITE_EXIT_EMITTED=1
    echo "SUITE_EXIT=$1"
  fi
  exit "$1"
}

# ── Sanitize inherited /plan-w-team worker env (test-hygiene) ─────────────────
# When pwt-goal.sh spawns a worker (claude --bg), it exports PLAN_W_TEAM_FORCE_SPAWN=1,
# PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1, and PLAN_W_TEAM_AUTO_APPROVE_PUSH=1 into the
# child. If the suite is run from INSIDE such a worker session (e.g. an autonomous
# /plan-w-team run testing itself, or the pre-commit gate firing under `claude --bg`),
# those leak into every pwt-goal.sh subprocess the tests invoke and silently BYPASS
# the cascade (PWT-DS2) + double-spawn (PWT-DS1) guards — producing FALSE guard-test
# failures that have nothing to do with the code under test (diagnosed 2026-05-29).
# Strip them so the suite always sees a pristine ambient env. Per-test explicit
# settings (`VAR=1 run …`) are unaffected — this only clears the inherited value.
unset PLAN_W_TEAM_FORCE_SPAWN PLAN_W_TEAM_DISABLE_PROMPT_ROUTE PLAN_W_TEAM_AUTO_APPROVE_PUSH

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARNESS_DIR="$REPO_ROOT/tests/skill"
BATS_DIR="$HARNESS_DIR/.bats"
BATS_BIN="$BATS_DIR/bin/bats"
CASES_DIR="$HARNESS_DIR/cases"
SCENARIOS_DIR="$HARNESS_DIR/scenarios"
# Consumer-authored scenarios live in a SIBLING dir (R5, 2026-06-09 design
# review) so the source's own scenarios/ stays the single-source-of-truth corpus
# while a consumer's product scenarios are owned/tracked by the consumer. Sibling
# (not nested) is deliberate: the tests/skill rsync's --delete-excluded would
# reap a nested dir, and the trailing-slash 'tests/skill/scenarios/' consumer
# gitignore does not match the sibling — so scenarios.local/ stays tracked with
# zero gitignore change.
SCENARIOS_LOCAL_DIR="$HARNESS_DIR/scenarios.local"
RESULTS_DIR="$HARNESS_DIR/results"
RUNS_DIR="$RESULTS_DIR/runs"

ARCHIVE=1
SETUP_ONLY=0
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-archive) ARCHIVE=0; shift ;;
    --setup)      SETUP_ONLY=1; shift ;;
    -h|--help)    grep '^#' "$0" | head -30; exit 0 ;;
    *)            TARGET="$1"; shift ;;
  esac
done

# ── Bootstrap bats-core ──────────────────────────────────────────────────────
# Vendored under .bats/ (gitignored). One-time clone on first run.
if [ ! -x "$BATS_BIN" ]; then
  echo "→ bootstrapping bats-core (one-time clone) …"
  rm -rf "$BATS_DIR"
  if ! command -v git >/dev/null 2>&1; then
    echo "✗ git required to bootstrap bats-core" >&2
    __suite_exit 2
  fi
  # Pin a known-good release tag — avoids surprise breakage from upstream main.
  if ! git clone --quiet --depth 1 --branch v1.11.0 \
        https://github.com/bats-core/bats-core.git "$BATS_DIR"; then
    echo "✗ failed to clone bats-core" >&2
    echo "  if offline, install via: brew install bats-core" >&2
    echo "  then re-run: tests/skill/run.sh" >&2
    __suite_exit 2
  fi
  echo "✓ bats-core v1.11.0 vendored under tests/skill/.bats/"
fi

if [ "$SETUP_ONLY" = "1" ]; then
  echo "✓ harness ready. run: tests/skill/run.sh"
  exit 0
fi

# ── Discover test files ──────────────────────────────────────────────────────
if [ -n "$TARGET" ]; then
  TARGET_PATH="$REPO_ROOT/$TARGET"
  [ -f "$TARGET_PATH" ] || TARGET_PATH="$HARNESS_DIR/$TARGET"
  if [ ! -f "$TARGET_PATH" ]; then
    echo "✗ no such test file: $TARGET" >&2
    __suite_exit 2
  fi
  TEST_FILES=("$TARGET_PATH")
else
  if [ ! -d "$CASES_DIR" ]; then
    echo "✗ cases directory missing: $CASES_DIR" >&2
    __suite_exit 2
  fi
  TEST_FILES=()
  # Walk cases/ (unit tests), scenarios/ (source E2E), and scenarios.local/
  # (consumer-authored E2E — R5). Anti-fragmentation lock-in: this single
  # discovery is the only place that decides what runs. `run-scenarios.sh` is a
  # dev-iteration shortcut; pre-commit and `make test-skill` always invoke this
  # runner so passing tests cannot mask a regression elsewhere. scenarios.local/
  # MUST be discovered here too — a consumer's pre-commit runs run-scenarios.sh
  # (which also discovers it), but this canonical runner is what gates them.
  while IFS= read -r f; do
    TEST_FILES+=("$f")
  done < <(
    {
      find "$CASES_DIR" -name '*.bats' -type f 2>/dev/null
      [ -d "$SCENARIOS_DIR" ] && find "$SCENARIOS_DIR" -name '*.bats' -type f 2>/dev/null
      [ -d "$SCENARIOS_LOCAL_DIR" ] && find "$SCENARIOS_LOCAL_DIR" -name '*.bats' -type f 2>/dev/null
    } | sort
  )
fi

if [ "${#TEST_FILES[@]}" -eq 0 ]; then
  echo "⚠ no .bats files found under $CASES_DIR or $SCENARIOS_DIR — nothing to run"
  __suite_exit 0
fi

# ── Run tests ────────────────────────────────────────────────────────────────
mkdir -p "$RUNS_DIR"
TIMESTAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
TAP_LOG=$(mktemp)
TS_LOG=""
trap 'rm -f "$TAP_LOG" ${TS_LOG:+"$TS_LOG"}' EXIT

echo "→ running ${#TEST_FILES[@]} bats file(s) under tests/skill/{cases,scenarios}/"

# ── State-leak guard: BEFORE snapshot (R6, 2026-06-09 design review) ──────────
# A well-behaved test mutates only its sandbox ($SANDBOX_DIR / $BATS_TEST_TMPDIR),
# never the LIVE .claude/state tree. A misbehaving one silently poisons real
# per-run state — the dmarc-monitor incident stamped a live .claude/state
# watermark from a scenario. Bracket the SINGLE merged bats invocation with a
# before/after `git status --porcelain -- .claude/state` snapshot and flag any
# NEW dirt. The diff is ADDITIVE (comm -13) so it tolerates the permanently-
# dirty baseline (this run's own goal-state / scope-lock / ac-snapshot files).
# Skips cleanly when git is unavailable; SKILL_SKIP_STATE_LEAK_GUARD=1 bypasses.
STATE_LEAK=0
STATE_LEAKED_PATHS=""
STATE_GUARD_ACTIVE=0
STATE_BEFORE=""
if [ "${SKILL_SKIP_STATE_LEAK_GUARD:-0}" != "1" ] && command -v git >/dev/null 2>&1 \
   && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  STATE_GUARD_ACTIVE=1
  STATE_BEFORE="$(git -C "$REPO_ROOT" status --porcelain -- .claude/state 2>/dev/null | LC_ALL=C sort)"
fi

# ── Session-registry leak guard: BEFORE (Governor Contract §3, AC6) ──────────
# run A's full-suite runs left ~12 REAL `claude --bg` sessions in the registry when a spawn test
# reached the real `claude` instead of a stub. Snapshot background session ids (+cwd) before/after
# and fail the suite if a NEW one appears whose cwd is under a TMPDIR sandbox (a leaked TEST spawn) —
# operator/fleet sessions in real project dirs are NOT flagged, and an unqueryable/empty registry
# SKIPS (fail-open — the flaky empty-but-exit-0 case must never fail a good suite).
# Bypass: SKILL_SKIP_SESSION_LEAK_GUARD=1.
SESSION_LEAK=0
SESSION_LEAKED=""
SESSION_GUARD_ACTIVE=0
SESSION_BEFORE=""
__run_session_ids() {   # emit "sid<TAB>cwd" per background session; nothing on any failure
  command -v claude >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  claude agents --json 2>/dev/null \
    | jq -r '.[]? | select((.kind//"")=="background") | "\(.sessionId // "")\t\(.cwd // "")"' 2>/dev/null
}
if [ "${SKILL_SKIP_SESSION_LEAK_GUARD:-0}" != "1" ]; then
  SESSION_BEFORE="$(__run_session_ids | LC_ALL=C sort)"
  [ -n "$SESSION_BEFORE" ] && SESSION_GUARD_ACTIVE=1
fi

# Use --tap to get machine-parseable output AND tee it to terminal for dev UX.
# `bats` exits non-zero on any failure; capture exit independently of the tee
# pipeline so PIPESTAT does not mask it.
set +e
"$BATS_BIN" --tap "${TEST_FILES[@]}" | tee "$TAP_LOG"
BATS_EXIT=${PIPESTATUS[0]}
set -e

# ── State-leak guard: AFTER snapshot + additive diff (R6) ────────────────────
if [ "$STATE_GUARD_ACTIVE" = "1" ]; then
  STATE_AFTER="$(git -C "$REPO_ROOT" status --porcelain -- .claude/state 2>/dev/null | LC_ALL=C sort)"
  # comm -13: lines in AFTER but not BEFORE = new dirt the bats phase introduced.
  STATE_LEAKED_PATHS="$(comm -13 \
    <(printf '%s\n' "$STATE_BEFORE") \
    <(printf '%s\n' "$STATE_AFTER") | sed '/^[[:space:]]*$/d')"
  if [ -n "$STATE_LEAKED_PATHS" ]; then
    STATE_LEAK=1
    echo "" >&2
    echo "✗ STATE LEAK — the bats phase introduced new .claude/state dirt:" >&2
    printf '%s\n' "$STATE_LEAKED_PATHS" | sed 's/^/    /' >&2
    echo "  A test wrote to the LIVE .claude/state tree instead of its sandbox" >&2
    echo "  (the dmarc-monitor watermark class). Fix the offending test to use the" >&2
    echo "  sandbox helper; set SKILL_SKIP_STATE_LEAK_GUARD=1 only to bypass." >&2
  fi
fi

# ── Phase 2: shell integration tests (.test.sh) ──────────────────────────────
# Anti-fragmentation lock-in (extended 2026-05-25 complexity audit): the
# .claude/{scripts,hooks}/*.test.sh integration tests (pwt-goal, goal-evaluator,
# route-prompt, worktree-gc, supervisor-route, …) were historically orphaned —
# run by NEITHER this canonical runner NOR the .githooks/pre-commit guard — so
# stale assertions bit-rotted undetected (4 stale test files found in that
# audit). They are now part of THE single suite: one runner discovers and runs
# ALL tests so a passing bats run cannot mask a regression in a shell test.
#
# Skipped in single-file TARGET mode (dev iteration on one bats file). Each test
# gets an optional wall-clock timeout (portable: timeout/gtimeout if present,
# else bare) so a hung test cannot stall the whole suite. Disable via
# SKILL_SKIP_SHELL_TESTS=1 (escape hatch, mirrors the bats --no-archive intent).
SHELL_TOTAL=0
SHELL_PASSED=0
SHELL_FAILED=0
SHELL_FAILED_NAMES=""
if [ -z "$TARGET" ] && [ "${SKILL_SKIP_SHELL_TESTS:-0}" != "1" ]; then
  TIMEOUT_BIN=""
  if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"; fi
  # This cap is a HANG guard, not a performance budget. At 180s it was killing a
  # test that completes correctly: plan-w-team-worktree-gc.test.sh runs 131 cases,
  # each doing real `git init` + worktree plumbing in its own sandbox, and takes
  # ~220-240s on an M-series laptop. Measured at b12ccac (i.e. before the change
  # that surfaced this), so the miscalibration is not new — it just needs a
  # machine slow enough, or a suite loaded enough, to bite. A killed-at-cap test
  # reports as a plain FAIL with no timing hint, which is why this went unnoticed.
  # 420s keeps a genuine hang bounded while leaving real headroom.
  # Raise per-invocation with SHELL_TEST_TIMEOUT=<seconds> if a slower box needs it.
  SHELL_TEST_TIMEOUT="${SHELL_TEST_TIMEOUT:-420}"

  # The canonical suite may be invoked from INSIDE a /plan-w-team worker session
  # (e.g. Step 6 ship, or an autonomous run auditing the skill). That ambient
  # environment carries the pwt control vars — PLAN_W_TEAM_DISABLE_PROMPT_ROUTE=1
  # (PWT-DS2 cascade guard → pwt-goal.sh exits 4), AUTO_APPROVE_PUSH=1, etc. The
  # shell tests assert DEFAULT behavior and set their own per-case env when they
  # need the kill-switch, so we scrub these inherited vars before each test. This
  # is the systemic counterpart to the per-test `unset` guards (see the
  # route-prompt-recursion test) and prevents worker-session ambient state from
  # producing spurious failures (2026-05-25 audit: spawn-registry, heredoc-size).
  # Pin CLAUDE_PROJECT_DIR to the checkout the suite runs in (1.48.0 worktree-fragility
  # fix). State-reading tests (goal-evaluator, antipark-*, supervisor-state-detection)
  # resolve their PROJECT_ROOT from the test script's own location (= $REPO_ROOT) but
  # the hooks under test resolve theirs from CLAUDE_PROJECT_DIR. When the suite runs
  # inside a `.claude/worktrees/<slug>/` checkout (an autonomous self-hosted run) the
  # AMBIENT CLAUDE_PROJECT_DIR points at the MAIN checkout, so the hook reads main's
  # live .claude/state (active-run goal-state + any leaked debris) while the test only
  # stashes the worktree's — a false failure that has nothing to do with the code under
  # test (memory: test-worktree-cwd-fragility). Pinning it to $REPO_ROOT aligns hook and
  # test on ONE state dir; it is a NO-OP when the suite runs from main (REPO_ROOT==main),
  # and any test that sets its own CLAUDE_PROJECT_DIR (the sandbox-isolated corpus tests)
  # overrides this inherited value.
  run_one_shell_test() {
    if [ -n "$TIMEOUT_BIN" ]; then
      env -u PLAN_W_TEAM_DISABLE_PROMPT_ROUTE -u PLAN_W_TEAM_AUTO_APPROVE_PUSH \
          -u PLAN_W_TEAM_FORCE_SPAWN -u PLAN_W_TEAM_DISABLE_GOAL \
          CLAUDE_PROJECT_DIR="$REPO_ROOT" \
          "$TIMEOUT_BIN" "$SHELL_TEST_TIMEOUT" bash "$1" >/dev/null 2>&1
    else
      env -u PLAN_W_TEAM_DISABLE_PROMPT_ROUTE -u PLAN_W_TEAM_AUTO_APPROVE_PUSH \
          -u PLAN_W_TEAM_FORCE_SPAWN -u PLAN_W_TEAM_DISABLE_GOAL \
          CLAUDE_PROJECT_DIR="$REPO_ROOT" \
          bash "$1" >/dev/null 2>&1
    fi
  }

  echo ""
  echo "→ running shell integration tests under .claude/{scripts,hooks}/ + tests/version-uplift/"

  # ── State-leak guard: Phase-2 BEFORE snapshot (R6 extension, 1.48.0) ─────────
  # R6 originally bracketed only the bats phase, but the shell-test (.test.sh)
  # phase is exactly where the corpus-goalstate-leak class lived (spawn-registry,
  # surface-status seeded goal-state FAMILIES into the LIVE .claude/state tree via
  # the real pwt-goal.sh). Extend the same before/after additive diff over Phase 2
  # so a FUTURE leaking .test.sh is caught at authoring time, not swept by hand.
  # Re-snapshot here (not reuse the bats STATE_AFTER) so this run's own bats dirt is
  # part of the Phase-2 baseline and only NEW Phase-2 dirt is attributed.
  STATE_BEFORE_SHELL=""
  if [ "$STATE_GUARD_ACTIVE" = "1" ]; then
    STATE_BEFORE_SHELL="$(git -C "$REPO_ROOT" status --porcelain -- .claude/state 2>/dev/null | LC_ALL=C sort)"
  fi

  while IFS= read -r tf; do
    [ -z "$tf" ] && continue
    SHELL_TOTAL=$((SHELL_TOTAL + 1))
    rel="${tf#"$REPO_ROOT"/}"
    if run_one_shell_test "$tf"; then
      SHELL_PASSED=$((SHELL_PASSED + 1))
      echo "  ok   $rel"
    else
      SHELL_FAILED=$((SHELL_FAILED + 1))
      SHELL_FAILED_NAMES="${SHELL_FAILED_NAMES}${rel}"$'\n'
      echo "  FAIL $rel"
    fi
  done < <(
    {
      [ -d "$REPO_ROOT/.claude/scripts" ] && find "$REPO_ROOT/.claude/scripts" -name '*.test.sh' -type f 2>/dev/null
      [ -d "$REPO_ROOT/.claude/hooks" ]   && find "$REPO_ROOT/.claude/hooks"   -name '*.test.sh' -type f 2>/dev/null
      [ -d "$REPO_ROOT/tests/version-uplift" ] && find "$REPO_ROOT/tests/version-uplift" -name '*.test.sh' -type f 2>/dev/null
    } | sort
  )
  echo "→ shell integration tests: $SHELL_PASSED/$SHELL_TOTAL passed"

  # ── State-leak guard: Phase-2 AFTER snapshot + additive diff (R6 extension) ──
  # Fold any NEW Phase-2 .claude/state dirt into the SAME STATE_LEAK verdict the
  # bats phase uses, so the final gate (below) fails the suite identically whether
  # the leak came from a .bats scenario or a .test.sh integration test.
  if [ "$STATE_GUARD_ACTIVE" = "1" ]; then
    STATE_AFTER_SHELL="$(git -C "$REPO_ROOT" status --porcelain -- .claude/state 2>/dev/null | LC_ALL=C sort)"
    SHELL_LEAKED_PATHS="$(comm -13 \
      <(printf '%s\n' "$STATE_BEFORE_SHELL") \
      <(printf '%s\n' "$STATE_AFTER_SHELL") | sed '/^[[:space:]]*$/d')"
    if [ -n "$SHELL_LEAKED_PATHS" ]; then
      STATE_LEAK=1
      STATE_LEAKED_PATHS="$(printf '%s\n%s' "$STATE_LEAKED_PATHS" "$SHELL_LEAKED_PATHS" | sed '/^[[:space:]]*$/d')"
      echo "" >&2
      echo "✗ STATE LEAK — the shell-test (.test.sh) phase introduced new .claude/state dirt:" >&2
      printf '%s\n' "$SHELL_LEAKED_PATHS" | sed 's/^/    /' >&2
      echo "  A .test.sh wrote to the LIVE .claude/state tree instead of its sandbox" >&2
      echo "  (the corpus-goalstate-leak class). Redirect the test's STATE_DIR + " >&2
      echo "  CLAUDE_PROJECT_DIR/PWT_PROJECT_ROOT_OVERRIDE at a mktemp sandbox; set" >&2
      echo "  SKILL_SKIP_STATE_LEAK_GUARD=1 only to bypass." >&2
    fi
  fi
fi

# ── Phase 2b: TypeScript analyzer tests (.test.ts) ───────────────────────────
# The import-coupling analyzer (.claude/scripts/plan-w-team-import-coupling.ts)
# is a hard pre-fork spawn gate (03-execute.md "Verify import-coupling gate"),
# but its .test.ts suite was historically orphaned — Phase 1 globs only *.bats
# and Phase 2 only *.test.sh, so it ran NOWHERE (F26, 2026-06-09 audit). Same
# anti-fragmentation rule as Phase 2: run.sh stays the ONLY runner, so the TS
# tests are a phase here rather than a parallel npm/vitest entry point.
#
# Unlike Phase 2 (dozens of shell files — too slow for single-file dev
# iteration), this is a single hard-gate suite, so it also runs in TARGET
# mode: a silently-rotting spawn gate is worse than the wait. Escape hatch:
# SKILL_SKIP_TS_TESTS=1 (mirrors SKILL_SKIP_SHELL_TESTS).
#
# Toolchain contract (consumer-repo safe): the phase needs a TS runner — tsx
# on PATH or node_modules/.bin/tsx (npm install) — AND the analyzer's runtime
# npm deps resolvable from the repo root. claude-pattern vendors both in
# devDependencies; a consumer repo without a node toolchain cannot run it,
# so when NO runner is found OR a runtime dep is missing the phase emits a
# LOUD [SKIP] line and does not fail the suite. Contract documented in
# tests/skill/CONVENTIONS.md ("TypeScript test phase").
TS_TOTAL=0
TS_PASSED=0
TS_FAILED=0
TS_FAILED_NAMES=""
TS_SKIPPED_NO_RUNNER=0
TS_SKIPPED_NO_DEP=0
if [ "${SKILL_SKIP_TS_TESTS:-0}" != "1" ]; then
  TS_TEST_FILES=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    TS_TEST_FILES+=("$f")
  done < <(
    {
      [ -d "$REPO_ROOT/.claude/scripts" ] && find "$REPO_ROOT/.claude/scripts" -name '*.test.ts' -type f 2>/dev/null
      [ -d "$REPO_ROOT/.claude/hooks" ]   && find "$REPO_ROOT/.claude/hooks"   -name '*.test.ts' -type f 2>/dev/null
    } | sort
  )
  if [ "${#TS_TEST_FILES[@]}" -gt 0 ]; then
    # Resolve a tsx runner: global tsx, then repo-local node_modules/.bin.
    # The repo's node_modules/.bin is prepended to PATH at run time so the
    # test's own `npx tsx` child spawns (cwd = os.tmpdir fixture) resolve the
    # same local tsx instead of hitting the registry.
    TSX_BIN=""
    if command -v tsx >/dev/null 2>&1; then TSX_BIN="tsx"
    elif [ -x "$REPO_ROOT/node_modules/.bin/tsx" ]; then TSX_BIN="$REPO_ROOT/node_modules/.bin/tsx"
    fi
    # A runner alone is not enough: the import-coupling analyzer imports the
    # `typescript` npm package at runtime (AST parsing), which tsx does NOT
    # bundle. A consumer repo with a global tsx but no local node_modules/
    # typescript crashes every assertion with "Cannot find module 'typescript'"
    # — env noise, not a skill regression. Probe resolution from the repo root
    # (the same walk node performs for the test file itself) and SKIP loudly
    # when missing, exactly like the no-runner path.
    TS_MISSING_DEP=""
    if [ -n "$TSX_BIN" ]; then
      # shellcheck disable=SC2043  # single-item list IS the extension point for future runtime deps
      for ts_dep in typescript; do
        if ! (cd "$REPO_ROOT" && node -e "require.resolve('$ts_dep')") >/dev/null 2>&1; then
          TS_MISSING_DEP="$ts_dep"
          break
        fi
      done
    fi
    if [ -z "$TSX_BIN" ]; then
      TS_SKIPPED_NO_RUNNER="${#TS_TEST_FILES[@]}"
      echo ""
      for tf in "${TS_TEST_FILES[@]}"; do
        echo "[SKIP] ${tf#"$REPO_ROOT"/}: no TS runner (tsx not found — npm install in repo root to enable)"
      done
    elif [ -n "$TS_MISSING_DEP" ]; then
      TS_SKIPPED_NO_DEP="${#TS_TEST_FILES[@]}"
      echo ""
      for tf in "${TS_TEST_FILES[@]}"; do
        echo "[SKIP] ${tf#"$REPO_ROOT"/}: missing npm dep '$TS_MISSING_DEP' (runner found, but the analyzer imports it at runtime — npm install in repo root to enable)"
      done
    else
      # Per-file hang protection, mirroring Phase 2 (timeout/gtimeout if
      # present, else bare). Not a suite cap — only a stuck-process guard.
      TS_TIMEOUT_BIN=""
      if command -v timeout >/dev/null 2>&1; then TS_TIMEOUT_BIN="timeout"
      elif command -v gtimeout >/dev/null 2>&1; then TS_TIMEOUT_BIN="gtimeout"; fi
      TS_TEST_TIMEOUT="${TS_TEST_TIMEOUT:-300}"

      run_one_ts_test() {
        if [ -n "$TS_TIMEOUT_BIN" ]; then
          PATH="$REPO_ROOT/node_modules/.bin:$PATH" \
            "$TS_TIMEOUT_BIN" "$TS_TEST_TIMEOUT" "$TSX_BIN" "$1" >"$TS_LOG" 2>&1
        else
          PATH="$REPO_ROOT/node_modules/.bin:$PATH" \
            "$TSX_BIN" "$1" >"$TS_LOG" 2>&1
        fi
      }

      echo ""
      echo "→ running TypeScript analyzer tests (.test.ts) via tsx"
      TS_LOG=$(mktemp)
      for tf in "${TS_TEST_FILES[@]}"; do
        TS_TOTAL=$((TS_TOTAL + 1))
        rel="${tf#"$REPO_ROOT"/}"
        if run_one_ts_test "$tf"; then
          TS_PASSED=$((TS_PASSED + 1))
          echo "  ok   $rel ($(tail -1 "$TS_LOG"))"
        else
          TS_FAILED=$((TS_FAILED + 1))
          TS_FAILED_NAMES="${TS_FAILED_NAMES}${rel}"$'\n'
          echo "  FAIL $rel"
          sed 's/^/       /' "$TS_LOG"
        fi
      done
      echo "→ TypeScript tests: $TS_PASSED/$TS_TOTAL file(s) passed"
    fi
  fi
fi

# ── Archive ──────────────────────────────────────────────────────────────────
if [ "$ARCHIVE" = "1" ]; then
  RUN_FILE="$RUNS_DIR/$TIMESTAMP.json"

  # Parse TAP for counts. Format:
  #   1..N
  #   ok 1 - description
  #   not ok 2 - description
  TOTAL=$(grep -E '^1\.\.[0-9]+' "$TAP_LOG" | head -1 | sed -E 's/1\.\.//')
  PASSED=$(grep -cE '^ok [0-9]' "$TAP_LOG" || true)
  FAILED=$(grep -cE '^not ok [0-9]' "$TAP_LOG" || true)
  SKIPPED=$(grep -cE '^ok [0-9]+.*# skip' "$TAP_LOG" || true)

  # Collect failing test names for trend analysis. Empty on green runs — guard
  # against jq choking on empty input by short-circuiting to "[]".
  FAILED_RAW=$(grep -E '^not ok [0-9]' "$TAP_LOG" | sed -E 's/^not ok [0-9]+ - //' || true)
  if [ -z "$FAILED_RAW" ]; then
    FAILED_NAMES='[]'
  else
    FAILED_NAMES=$(printf '%s\n' "$FAILED_RAW" | jq -R . | jq -s . 2>/dev/null || echo '[]')
  fi

  GIT_SHA=$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  GIT_BRANCH=$(cd "$REPO_ROOT" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  # Shell-test failed names as a JSON array (empty → []).
  if [ -z "$SHELL_FAILED_NAMES" ]; then
    SHELL_FAILED_JSON='[]'
  else
    SHELL_FAILED_JSON=$(printf '%s' "$SHELL_FAILED_NAMES" | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo '[]')
  fi

  # TS-test failed names as a JSON array (empty → []).
  if [ -z "$TS_FAILED_NAMES" ]; then
    TS_FAILED_JSON='[]'
  else
    TS_FAILED_JSON=$(printf '%s' "$TS_FAILED_NAMES" | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo '[]')
  fi

  # State-leak guard (R6): leaked .claude/state paths as a JSON array (empty → []).
  if [ -z "$STATE_LEAKED_PATHS" ]; then
    STATE_LEAKED_JSON='[]'
  else
    STATE_LEAKED_JSON=$(printf '%s' "$STATE_LEAKED_PATHS" | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo '[]')
  fi
  STATE_LEAKED_BOOL=$([ "${STATE_LEAK:-0}" -eq 1 ] && echo true || echo false)

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg sha "$GIT_SHA" \
      --arg branch "$GIT_BRANCH" \
      --argjson total "${TOTAL:-0}" \
      --argjson passed "${PASSED:-0}" \
      --argjson failed "${FAILED:-0}" \
      --argjson skipped "${SKIPPED:-0}" \
      --argjson exit_code "$BATS_EXIT" \
      --argjson failed_names "$FAILED_NAMES" \
      --argjson shell_total "${SHELL_TOTAL:-0}" \
      --argjson shell_passed "${SHELL_PASSED:-0}" \
      --argjson shell_failed "${SHELL_FAILED:-0}" \
      --argjson shell_failed_names "$SHELL_FAILED_JSON" \
      --argjson ts_total "${TS_TOTAL:-0}" \
      --argjson ts_passed "${TS_PASSED:-0}" \
      --argjson ts_failed "${TS_FAILED:-0}" \
      --argjson ts_skipped_no_runner "${TS_SKIPPED_NO_RUNNER:-0}" \
      --argjson ts_skipped_no_dep "${TS_SKIPPED_NO_DEP:-0}" \
      --argjson ts_failed_names "$TS_FAILED_JSON" \
      --argjson state_leaked "$STATE_LEAKED_BOOL" \
      --argjson leaked_paths "$STATE_LEAKED_JSON" \
      '{
        timestamp: $ts,
        git_sha: $sha,
        git_branch: $branch,
        total: $total,
        passed: $passed,
        failed: $failed,
        skipped: $skipped,
        exit_code: $exit_code,
        failed_tests: $failed_names,
        shell_total: $shell_total,
        shell_passed: $shell_passed,
        shell_failed: $shell_failed,
        shell_failed_tests: $shell_failed_names,
        ts_total: $ts_total,
        ts_passed: $ts_passed,
        ts_failed: $ts_failed,
        ts_skipped_no_runner: $ts_skipped_no_runner,
        ts_skipped_no_dep: $ts_skipped_no_dep,
        ts_failed_tests: $ts_failed_names,
        state_leaked: $state_leaked,
        leaked_paths: $leaked_paths
      }' > "$RUN_FILE"

    cp "$RUN_FILE" "$RESULTS_DIR/latest.json"
    echo ""
    echo "→ archived: tests/skill/results/runs/$TIMESTAMP.json"
  else
    echo "⚠ jq not found — skipping JSON archival" >&2
  fi
fi

# ── Session-registry leak guard: AFTER + diff (Governor Contract §3, AC6) ────
if [ "$SESSION_GUARD_ACTIVE" = "1" ]; then
  SESSION_AFTER="$(__run_session_ids | LC_ALL=C sort)"
  if [ -n "$SESSION_AFTER" ]; then
    NEW_SESSIONS="$(comm -13 <(printf '%s\n' "$SESSION_BEFORE") <(printf '%s\n' "$SESSION_AFTER") | sed '/^[[:space:]]*$/d')"
    # Flag only NEW sessions whose cwd is under a TMPDIR sandbox — a leaked TEST spawn. A legit
    # operator/fleet session lives under a real project dir and is never flagged.
    SESSION_LEAKED="$(printf '%s\n' "$NEW_SESSIONS" | awk -F'\t' -v t="${TMPDIR:-/tmp}" '
      $2 != "" && (index($2, t)==1 || index($2, "/tmp/")==1 || index($2, "/var/folders/")==1 \
                   || index($2, "/private/tmp/")==1 || index($2, "plan-w-team-test")>0) { print }')"
    [ -n "$SESSION_LEAKED" ] && SESSION_LEAK=1
  fi
fi

# Final summary line for human eyes. The suite is green only when the bats
# phase, the shell-integration phase, the TypeScript phase all pass AND no test
# leaked into the live .claude/state tree (R6 state-leak guard) or the session
# registry (Governor Contract §3 session-leak guard).
if [ "$BATS_EXIT" -eq 0 ] && [ "${SHELL_FAILED:-0}" -eq 0 ] && [ "${TS_FAILED:-0}" -eq 0 ] \
   && [ "${STATE_LEAK:-0}" -eq 0 ] && [ "${SESSION_LEAK:-0}" -eq 0 ]; then
  echo "✓ all tests passed (bats + ${SHELL_PASSED:-0} shell integration tests + ${TS_PASSED:-0} TS test file(s))"
  __suite_exit 0
fi
[ "$BATS_EXIT" -ne 0 ] && echo "✗ bats phase failed (exit $BATS_EXIT)"
if [ "${SHELL_FAILED:-0}" -ne 0 ]; then
  echo "✗ shell integration phase failed ($SHELL_FAILED of $SHELL_TOTAL):"
  printf '%s' "$SHELL_FAILED_NAMES" | grep -v '^$' | sed 's/^/    - /'
fi
if [ "${TS_FAILED:-0}" -ne 0 ]; then
  echo "✗ TypeScript phase failed ($TS_FAILED of $TS_TOTAL):"
  printf '%s' "$TS_FAILED_NAMES" | grep -v '^$' | sed 's/^/    - /'
fi
if [ "${STATE_LEAK:-0}" -ne 0 ]; then
  echo "✗ state-leak guard failed — bats phase dirtied the live .claude/state tree:"
  printf '%s\n' "$STATE_LEAKED_PATHS" | grep -v '^$' | sed 's/^/    /'
fi
if [ "${SESSION_LEAK:-0}" -ne 0 ]; then
  echo "✗ session-registry leak — the suite left NEW background session(s) in the registry (a spawn test reached the real claude):"
  printf '%s\n' "$SESSION_LEAKED" | grep -v '^$' | sed 's/^/    /'
  echo "  stop them (claude stop <handle>) and stub PWT_CLAUDE_BIN (or set PWT_CLAUDE_BIN_STRICT=1) in the offending spawn test."
fi
__suite_exit 1
