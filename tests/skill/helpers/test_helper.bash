#!/usr/bin/env bash
# tests/skill/helpers/test_helper.bash
#
# Shared bats helpers loaded by every .bats file via:
#   load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"
#
# Conventions enforced here:
#   - REPO_ROOT, SCRIPTS_DIR, COMMANDS_DIR available in every test
#   - sandbox/teardown_sandbox: per-test temp dir, auto-cleaned
#   - assert_success / assert_failure / assert_output_contains: thin wrappers
#     around bats' run/$status/$output (no bats-assert dependency).
#   - run_in_sandbox: invoke a script with $BATS_TEST_TMPDIR as cwd

# Resolve repo root once. BATS_TEST_DIRNAME is set by bats per-test.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/.claude/scripts"
COMMANDS_DIR="$REPO_ROOT/.claude/commands/plan-w-team"
HOOKS_DIR="$REPO_ROOT/.claude/hooks"

export REPO_ROOT SCRIPTS_DIR COMMANDS_DIR HOOKS_DIR

# ── Sandbox helpers ─────────────────────────────────────────────────────────
# Create a per-test temp directory that gets nuked at teardown. Use this for
# any test that writes files or runs scripts that mutate state.
sandbox() {
  SANDBOX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/plan-w-team-test.XXXXXX")"
  export SANDBOX_DIR
  cd "$SANDBOX_DIR"

  # Test isolation for the cross-repo RAM claims registry. Without this, any
  # test that invokes pwt-goal.sh, pwt-ram-claim.sh, pwt-fair-share.sh, or
  # ram-budget.sh would read/write the production registry at
  # ~/.claude/state/pwt-ram-claims.jsonl, leaving orphan rows that cause
  # AT_FAIR_SHARE refusals in subsequent real spawns.
  # See docs/specs/pwt-test-isolation-fair-share.md.
  export PWT_RAM_CLAIMS_PATH="$SANDBOX_DIR/test-claims.jsonl"

  # Corpus goal-state isolation (1.48.0). pwt-goal.sh seeds the anti-skip
  # goal-state FAMILY (plan-w-team-{goal,manifest,spawned-children,stage-events,
  # skill-version}-<slug>) to MAIN_REPO_ROOT/.claude/state, which __pwt_main_repo_root
  # resolves via git-common-dir (= the real source repo) when the sandbox CWD is a
  # non-git tmp dir — so a test that actually spawns (FORCE_SPAWN escape hatch, etc.)
  # leaks no-owner-SID families into the LIVE source .claude/state that the fail-closed
  # janitor cannot reap. PWT_PROJECT_ROOT_OVERRIDE is the test-only lever pwt-goal honors
  # at EVERY root-resolution site (incl. __pwt_main_repo_root); pointing it at the sandbox
  # makes every family write land in tmp and tear down with the test. Same isolation
  # intent as PWT_RAM_CLAIMS_PATH above.
  export PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX_DIR"
}

teardown_sandbox() {
  if [ -n "${SANDBOX_DIR:-}" ] && [ -d "$SANDBOX_DIR" ]; then
    # Safety: refuse to rm anything outside /tmp or $TMPDIR.
    case "$SANDBOX_DIR" in
      /tmp/*|/var/folders/*|"${TMPDIR:-/dev/null}"/*)
        rm -rf "$SANDBOX_DIR"
        ;;
      *)
        echo "⚠ refusing to clean SANDBOX_DIR outside tmp: $SANDBOX_DIR" >&2
        ;;
    esac
  fi
  unset SANDBOX_DIR
  unset PWT_RAM_CLAIMS_PATH
}

# Initialize a tiny git repo inside the sandbox. Several scripts under test
# require `git rev-parse --show-toplevel` to succeed.
sandbox_git_init() {
  git init -q -b main >/dev/null
  git config user.email "test@example.com"
  git config user.name "Test"
  git commit -q --allow-empty -m "init" >/dev/null
}

# ── Assertion shims (no bats-assert dependency) ─────────────────────────────
assert_success() {
  if [ "$status" -ne 0 ]; then
    printf 'expected success, got exit %d\n--- output ---\n%s\n' "$status" "$output" >&2
    return 1
  fi
}

assert_failure() {
  local expected="${1:-}"
  if [ "$status" -eq 0 ]; then
    printf 'expected failure, got exit 0\n--- output ---\n%s\n' "$output" >&2
    return 1
  fi
  if [ -n "$expected" ] && [ "$status" -ne "$expected" ]; then
    printf 'expected exit %s, got exit %d\n--- output ---\n%s\n' \
      "$expected" "$status" "$output" >&2
    return 1
  fi
}

assert_output_contains() {
  local needle="$1"
  if ! grep -qF -- "$needle" <<<"$output"; then
    printf 'output did not contain: %s\n--- output ---\n%s\n' "$needle" "$output" >&2
    return 1
  fi
}

assert_output_not_contains() {
  local needle="$1"
  if grep -qF -- "$needle" <<<"$output"; then
    printf 'output unexpectedly contained: %s\n--- output ---\n%s\n' "$needle" "$output" >&2
    return 1
  fi
}

# Skip a test if a required binary is unavailable. Use sparingly — most tests
# should set up their own deps in the sandbox.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || skip "requires '$1' on PATH"
}
