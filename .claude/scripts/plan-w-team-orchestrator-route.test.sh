#!/usr/bin/env bash
# plan-w-team-orchestrator-route.test.sh
#
# RED-phase test suite for the orchestrator-interception router.
# Every test SHOULD FAIL until PWT-T1b ships:
#   - .claude/scripts/plan-w-team-orchestrator-route.sh  (router script)
#   - .claude/commands/plan-w-team/shared/orchestrator-interception.md (classifier)
#   - state-artifacts.md registry row for plan-w-team-orchestrator-decisions-*.jsonl
#
# Spec refs: .claude/commands/plan-w-team/shared/orchestrator-interception.md (canonical; AC1-AC7)
# Shell-safety patterns: .claude/commands/plan-w-team/shared/shell-safety.md
# State artifact pattern: .claude/commands/plan-w-team/shared/state-artifacts.md
#
# Example invocation:
#   bash .claude/scripts/plan-w-team-orchestrator-route.test.sh
#   bash .claude/scripts/plan-w-team-orchestrator-route.test.sh --verbose
#
# Expected output while router does not exist: 7 FAIL lines, exit 1.
# Expected output after PWT-T1b ships:       7 PASS lines, exit 0.
#
# Runner: pure bash (no bats dependency).
# Rationale: bats was not found in the environment at test-authoring time
# (`which bats` returned empty). Pure bash keeps the test runnable in every
# CI/CD environment without extra toolchain installation, mirrors the pattern
# of existing shell scripts in .claude/scripts/, and avoids a new dependency
# for a script that is itself a test harness (not a unit under test).

set -uo pipefail
# NOTE: -e is intentionally NOT set so individual test assertions can fail
#       without aborting the whole suite. Failures are collected and reported.

# ---------------------------------------------------------------------------
# Bash version guard — local -n (nameref) requires bash 4.3+
# ---------------------------------------------------------------------------
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] || \
   { [[ "${BASH_VERSINFO[0]}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]}" -lt 3 ]]; }; then
  echo "ERROR: bash 4.3+ required (found $BASH_VERSION)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Paths (absolute — worktree-cwd-safe)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROUTER_SCRIPT="$REPO_ROOT/.claude/scripts/plan-w-team-orchestrator-route.sh"
STATE_DIR="$REPO_ROOT/.claude/state"
SYMMETRY_CHECK="$REPO_ROOT/.claude/scripts/plan-w-team-symmetry-check.sh"
STATE_ARTIFACTS_REGISTRY="$REPO_ROOT/.claude/commands/plan-w-team/shared/state-artifacts.md"

# ---------------------------------------------------------------------------
# Test-run workspace — isolated per invocation
# ---------------------------------------------------------------------------
TEST_TMPDIR="$(mktemp -d "/tmp/pwt-router-test-XXXXXX")"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
FAIL_NAMES=()

_log() {
  [[ "$VERBOSE" -eq 1 ]] && printf '    [debug] %s\n' "$*" || true
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    _log "assert_eq PASS: $label (expected='$expected')"
    return 0
  else
    echo "    ASSERT FAIL [$label]" >&2
    echo "      expected: '$expected'" >&2
    echo "      actual:   '$actual'" >&2
    return 1
  fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" -eq "$actual" ]]; then
    _log "assert_exit_code PASS: $label (code=$expected)"
    return 0
  else
    echo "    ASSERT FAIL [$label]" >&2
    echo "      expected exit: $expected" >&2
    echo "      actual exit:   $actual" >&2
    return 1
  fi
}

assert_file_exists() {
  local label="$1" file="$2"
  if [[ -f "$file" ]]; then
    _log "assert_file_exists PASS: $label"
    return 0
  else
    echo "    ASSERT FAIL [$label] — file not found: $file" >&2
    return 1
  fi
}

assert_file_not_exists() {
  local label="$1" file="$2"
  if [[ ! -f "$file" ]]; then
    _log "assert_file_not_exists PASS: $label"
    return 0
  else
    echo "    ASSERT FAIL [$label] — file should NOT exist but does: $file" >&2
    return 1
  fi
}

assert_file_contains() {
  local label="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    _log "assert_file_contains PASS: $label (pattern='$pattern')"
    return 0
  else
    echo "    ASSERT FAIL [$label] — pattern not found in file" >&2
    echo "      pattern: '$pattern'" >&2
    echo "      file:    $file" >&2
    [[ -f "$file" ]] && echo "      contents (head-5): $(head -5 "$file")" >&2
    return 1
  fi
}

assert_file_not_contains() {
  local label="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    echo "    ASSERT FAIL [$label] — pattern found in file but should NOT be" >&2
    echo "      pattern: '$pattern'" >&2
    echo "      file:    $file" >&2
    return 1
  else
    _log "assert_file_not_contains PASS: $label"
    return 0
  fi
}

assert_stderr_contains() {
  local label="$1" stderr_text="$2" pattern="$3"
  if printf '%s' "$stderr_text" | grep -qF "$pattern"; then
    _log "assert_stderr_contains PASS: $label"
    return 0
  else
    echo "    ASSERT FAIL [$label] — pattern not found in stderr" >&2
    echo "      pattern: '$pattern'" >&2
    echo "      stderr (head-5): $(printf '%s' "$stderr_text" | head -5)" >&2
    return 1
  fi
}

assert_stdout_contains() {
  local label="$1" stdout_text="$2" pattern="$3"
  if printf '%s' "$stdout_text" | grep -qF "$pattern"; then
    _log "assert_stdout_contains PASS: $label"
    return 0
  else
    echo "    ASSERT FAIL [$label] — pattern not found in stdout" >&2
    echo "      pattern: '$pattern'" >&2
    echo "      stdout (head-5): $(printf '%s' "$stdout_text" | head -5)" >&2
    return 1
  fi
}

assert_file_line_count_gte() {
  local label="$1" file="$2" min_lines="$3"
  local actual_lines
  actual_lines=$(wc -l < "$file" 2>/dev/null || echo "0")
  actual_lines=$(( actual_lines + 0 ))
  if [[ "$actual_lines" -ge "$min_lines" ]]; then
    _log "assert_file_line_count_gte PASS: $label ($actual_lines >= $min_lines)"
    return 0
  else
    echo "    ASSERT FAIL [$label] — file has $actual_lines lines, expected >= $min_lines" >&2
    echo "      file: $file" >&2
    return 1
  fi
}

assert_nonzero_exit() {
  local label="$1" actual="$2"
  if [[ "$actual" -ne 0 ]]; then
    _log "assert_nonzero_exit PASS: $label (exit=$actual)"
    return 0
  else
    echo "    ASSERT FAIL [$label] — expected non-zero exit, got 0" >&2
    return 1
  fi
}

run_test() {
  local name="$1"
  local fn="$2"
  printf 'TEST: %s\n' "$name"
  local failed=0
  "$fn" || failed=1
  if [[ "$failed" -eq 0 ]]; then
    printf '  PASS: %s\n' "$name"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
  else
    printf '  FAIL: %s\n' "$name"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    FAIL_NAMES+=("$name")
  fi
  printf '\n'
}

# ---------------------------------------------------------------------------
# Mock infrastructure
# ---------------------------------------------------------------------------
# The router script is expected to call two external "tool" helpers:
#   1. agent_invoke <call_site> <slug> [context...]  — spawns the orchestrator
#   2. ask_user_question <preamble> [question...]    — the AskUserQuestion path
#
# We shim these via a mock-bin directory prepended to PATH. Each shim records
# its call and returns canned output so the router can proceed without a real
# Claude Agent context.
#
# MOCK_AGENT_MODE env var controls agent_invoke output:
#   "ok"       — returns a valid, fully-fenced decision block (default)
#   "malformed" — returns prose + an unclosed decision fence (no closing ```)

MOCK_SHIM_DIR="$TEST_TMPDIR/mock-bin"
mkdir -p "$MOCK_SHIM_DIR"

MOCK_AGENT_CALL_LOG="$TEST_TMPDIR/agent-calls.log"
MOCK_ASK_CALL_LOG="$TEST_TMPDIR/ask-calls.log"
touch "$MOCK_AGENT_CALL_LOG" "$MOCK_ASK_CALL_LOG"

# Shim: agent_invoke
# Records all argv into the call log, then writes a canned decision block
# (or a malformed one) based on MOCK_AGENT_MODE.
cat > "$MOCK_SHIM_DIR/agent_invoke" <<'SHIM_EOF'
#!/usr/bin/env bash
set -euo pipefail
# Record this invocation (safe: shell-safety.md argv-passing pattern)
printf 'agent_invoke called: %s\n' "$*" >> "${MOCK_AGENT_CALL_LOG:-/tmp/pwt-agent-calls.log}"
mode="${MOCK_AGENT_MODE:-ok}"
if [[ "$mode" == "malformed" ]]; then
  # Prose + unclosed fence — router must detect DecisionBlockParseError
  cat <<'PROSE'
I have analysed the scope-challenge context carefully. The scope mode ambiguity
points toward HOLD given the bounded and reversible nature of the work proposed.

```decision
{"choice":"HOLD","rationale":"scope is bounded","alternatives_considered":["EXPAND","REDUCE"]}
PROSE
  # Closing ``` intentionally omitted — malformed decision block
elif [[ "$mode" == "ok" ]]; then
  cat <<'DECISION'
After reviewing the scope challenge context, I recommend HOLD.

```decision
{"choice":"HOLD","rationale":"scope is bounded and reversible","alternatives_considered":["EXPAND","REDUCE"]}
```
DECISION
fi
SHIM_EOF
chmod +x "$MOCK_SHIM_DIR/agent_invoke"

# Shim: ask_user_question
# Records argv into the call log, returns a stub user answer.
cat > "$MOCK_SHIM_DIR/ask_user_question" <<'SHIM_EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ask_user_question called: %s\n' "$*" >> "${MOCK_ASK_CALL_LOG:-/tmp/pwt-ask-calls.log}"
# Stub answer so the ASK path doesn't block interactively
printf 'HOLD\n'
SHIM_EOF
chmod +x "$MOCK_SHIM_DIR/ask_user_question"

# ---------------------------------------------------------------------------
# Router invocation helper
# ---------------------------------------------------------------------------
# run_router_cmd <exit_var> <stdout_var> <stderr_var> \
#     [KEY=val ...]  -- <router_args...>
#
# env overrides are collected until "--", then remaining args go to the router.
# Uses bash 4.3+ namerefs to set caller variables.
run_router_cmd() {
  local -n _rc=$1
  local -n _out=$2
  local -n _err=$3
  shift 3

  local env_pairs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_pairs+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] && shift

  local router_args=("$@")
  local tmp_out tmp_err
  tmp_out="$TEST_TMPDIR/rout-stdout-$$-$RANDOM"
  tmp_err="$TEST_TMPDIR/rout-stderr-$$-$RANDOM"

  env \
    PATH="$MOCK_SHIM_DIR:$PATH" \
    MOCK_AGENT_CALL_LOG="$MOCK_AGENT_CALL_LOG" \
    MOCK_ASK_CALL_LOG="$MOCK_ASK_CALL_LOG" \
    MOCK_AGENT_MODE="${MOCK_AGENT_MODE:-ok}" \
    "${env_pairs[@]+"${env_pairs[@]}"}" \
    bash "$ROUTER_SCRIPT" "${router_args[@]+"${router_args[@]}"}" \
    >"$tmp_out" 2>"$tmp_err" \
  ; _rc=$?

  _out="$(cat "$tmp_out")"
  _err="$(cat "$tmp_err")"
  rm -f "$tmp_out" "$tmp_err"
}

reset_mock_logs() {
  : > "$MOCK_AGENT_CALL_LOG"
  : > "$MOCK_ASK_CALL_LOG"
}

# ---------------------------------------------------------------------------
# AC1 — normal orchestrator path (PLAN_W_TEAM_DISABLE_ORCHESTRATOR unset)
# ---------------------------------------------------------------------------
# route_orchestrator scope-challenge-mode test-slug-1 ambiguous with the env
# var UNSET → spawns orchestrator, writes JSONL row, prints chosen option.
# FAILS IN RED: router script does not exist yet.
test_ac1() {
  reset_mock_logs

  local test_slug="test-slug-1"
  local decision_log="$STATE_DIR/plan-w-team-orchestrator-decisions-${test_slug}.jsonl"
  rm -f "$decision_log"

  MOCK_AGENT_MODE="ok"
  local exit_code stdout stderr
  run_router_cmd exit_code stdout stderr \
    MOCK_AGENT_MODE="ok" \
    -- \
    scope-challenge-mode "$test_slug" ambiguous

  # Exit 0
  assert_exit_code "AC1: exit 0" 0 "$exit_code" || return 1

  # JSONL file created
  assert_file_exists "AC1: JSONL created" "$decision_log" || return 1

  # JSONL has at least one row
  assert_file_line_count_gte "AC1: JSONL has >= 1 row" "$decision_log" 1 || return 1

  # Row contains call_site and slug fields
  assert_file_contains "AC1: JSONL call_site field" \
    "$decision_log" "scope-challenge-mode" || return 1
  assert_file_contains "AC1: JSONL slug field" \
    "$decision_log" "$test_slug" || return 1

  # agent_invoke was called
  assert_file_contains "AC1: agent_invoke called" \
    "$MOCK_AGENT_CALL_LOG" "agent_invoke called" || return 1

  # Chosen option printed to stdout
  assert_stdout_contains "AC1: choice on stdout" "$stdout" "HOLD" || return 1

  rm -f "$decision_log"
}

# ---------------------------------------------------------------------------
# AC2 — rollback toggle: PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1
# ---------------------------------------------------------------------------
# Same call with the toggle set → falls through to legacy AskUserQuestion,
# no agent spawn, no JSONL written.
# FAILS IN RED: router script does not exist yet.
test_ac2() {
  reset_mock_logs

  local test_slug="test-slug-2"
  local decision_log="$STATE_DIR/plan-w-team-orchestrator-decisions-${test_slug}.jsonl"
  rm -f "$decision_log"

  local exit_code stdout stderr
  run_router_cmd exit_code stdout stderr \
    PLAN_W_TEAM_DISABLE_ORCHESTRATOR="1" \
    MOCK_AGENT_MODE="ok" \
    -- \
    scope-challenge-mode "$test_slug" ambiguous

  # Exit 0 (ASK path returns stub answer)
  assert_exit_code "AC2: exit 0" 0 "$exit_code" || return 1

  # NO JSONL written
  assert_file_not_exists "AC2: no JSONL written" "$decision_log" || return 1

  # NO agent spawn
  local agent_calls
  agent_calls="$(cat "$MOCK_AGENT_CALL_LOG")"
  if [[ -n "$agent_calls" ]]; then
    echo "    ASSERT FAIL [AC2: agent NOT called] — log: $agent_calls" >&2
    return 1
  fi
  _log "AC2: agent_invoke not called (correct)"

  # AskUserQuestion was invoked
  assert_file_contains "AC2: ask_user_question called" \
    "$MOCK_ASK_CALL_LOG" "ask_user_question called" || return 1

  rm -f "$decision_log"
}

# ---------------------------------------------------------------------------
# AC3 — unknown call-site label → non-zero exit + UnknownCallSiteError
# ---------------------------------------------------------------------------
# route_orchestrator unknown-call-site-label test-slug-3 → exits non-zero,
# stderr contains "UnknownCallSiteError" and the unrecognized label.
# FAILS IN RED: router script does not exist yet.
test_ac3() {
  reset_mock_logs

  local exit_code stdout stderr
  run_router_cmd exit_code stdout stderr \
    -- \
    "unknown-call-site-label" "test-slug-3"

  # Non-zero exit
  assert_nonzero_exit "AC3: non-zero exit" "$exit_code" || return 1

  # Stderr contains UnknownCallSiteError
  assert_stderr_contains "AC3: UnknownCallSiteError in stderr" \
    "$stderr" "UnknownCallSiteError" || return 1

  # Stderr names the bad label
  assert_stderr_contains "AC3: label name in stderr" \
    "$stderr" "unknown-call-site-label" || return 1
}

# ---------------------------------------------------------------------------
# AC4 — malformed decision block → fall through to ASK with prose preamble
# ---------------------------------------------------------------------------
# Mock agent returns a fence with no closing ```. Router must detect
# DecisionBlockParseError and fall through to AskUserQuestion with the
# orchestrator's prose as the question preamble. NOT silent failure.
# FAILS IN RED: router script does not exist yet.
test_ac4() {
  reset_mock_logs

  local test_slug="test-slug-4"
  local decision_log="$STATE_DIR/plan-w-team-orchestrator-decisions-${test_slug}.jsonl"
  rm -f "$decision_log"

  local exit_code stdout stderr
  run_router_cmd exit_code stdout stderr \
    MOCK_AGENT_MODE="malformed" \
    -- \
    scope-challenge-mode "$test_slug" ambiguous

  _log "AC4: exit=$exit_code"

  # AskUserQuestion must have been called (not silent failure)
  assert_file_contains "AC4: ask_user_question called after parse failure" \
    "$MOCK_ASK_CALL_LOG" "ask_user_question called" || return 1

  # The ask call must include the orchestrator's prose as preamble.
  # The mock agent_invoke writes "scope" and "HOLD" into its prose output;
  # the router must forward this prose text to ask_user_question as argv.
  # We check the ask log for a keyword from the prose body.
  assert_file_contains "AC4: prose preamble forwarded to ASK" \
    "$MOCK_ASK_CALL_LOG" "HOLD" || return 1

  # The ask log must not be empty (non-silent: something was communicated)
  local ask_log_size
  ask_log_size="$(wc -c < "$MOCK_ASK_CALL_LOG" || echo "0")"
  if [[ "$ask_log_size" -eq 0 ]]; then
    echo "    ASSERT FAIL [AC4: non-silent] — ask log is empty, silent failure" >&2
    return 1
  fi

  rm -f "$decision_log"
}

# ---------------------------------------------------------------------------
# AC5 — concurrent invocations → mkdir lock serializes, no torn JSONL writes
# ---------------------------------------------------------------------------
# Spawn 2 background route_orchestrator calls for the same slug simultaneously.
# Both must complete cleanly and both JSONL rows must be valid JSON (no torn
# writes from a race condition). Lock dir must be cleaned up.
# FAILS IN RED: router script does not exist yet.
test_ac5() {
  reset_mock_logs

  local test_slug="test-slug-5"
  local decision_log="$STATE_DIR/plan-w-team-orchestrator-decisions-${test_slug}.jsonl"
  local lock_dir="$STATE_DIR/plan-w-team-orchestrator-decisions-${test_slug}.lock"

  rm -f "$decision_log"
  rmdir "$lock_dir" 2>/dev/null || true

  # Spawn two concurrent router processes
  local pid1 pid2 exit1 exit2

  env \
    PATH="$MOCK_SHIM_DIR:$PATH" \
    MOCK_AGENT_CALL_LOG="$MOCK_AGENT_CALL_LOG" \
    MOCK_ASK_CALL_LOG="$MOCK_ASK_CALL_LOG" \
    MOCK_AGENT_MODE="ok" \
    bash "$ROUTER_SCRIPT" scope-challenge-mode "$test_slug" ambiguous \
    >"$TEST_TMPDIR/c1-out" 2>&1 &
  pid1=$!

  env \
    PATH="$MOCK_SHIM_DIR:$PATH" \
    MOCK_AGENT_CALL_LOG="$MOCK_AGENT_CALL_LOG" \
    MOCK_ASK_CALL_LOG="$MOCK_ASK_CALL_LOG" \
    MOCK_AGENT_MODE="ok" \
    bash "$ROUTER_SCRIPT" scope-challenge-mode "$test_slug" ambiguous \
    >"$TEST_TMPDIR/c2-out" 2>&1 &
  pid2=$!

  wait $pid1; exit1=$?
  wait $pid2; exit2=$?

  _log "AC5: exit1=$exit1 exit2=$exit2"

  # Both processes must exit 0
  assert_exit_code "AC5: process 1 exit 0" 0 "$exit1" || return 1
  assert_exit_code "AC5: process 2 exit 0" 0 "$exit2" || return 1

  # JSONL must exist with at least 2 rows (one per invocation)
  assert_file_exists "AC5: JSONL created" "$decision_log" || return 1
  assert_file_line_count_gte "AC5: JSONL has 2 rows" "$decision_log" 2 || return 1

  # Each line must be valid JSON (no torn writes)
  local line_num=0 torn=0
  while IFS= read -r line; do
    line_num=$(( line_num + 1 ))
    # Skip blank lines
    [[ -z "$line" ]] && continue
    if ! printf '%s\n' "$line" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
      echo "    ASSERT FAIL [AC5: no torn writes] — line $line_num invalid JSON" >&2
      echo "      line: $line" >&2
      torn=1
    fi
  done < "$decision_log"
  [[ "$torn" -eq 1 ]] && return 1
  _log "AC5: all JSONL lines are valid JSON (no torn writes)"

  # Lock dir must have been cleaned up
  if [[ -d "$lock_dir" ]]; then
    echo "    ASSERT FAIL [AC5: lock cleaned up] — lock dir still exists: $lock_dir" >&2
    return 1
  fi
  _log "AC5: lock dir cleaned up"

  rm -f "$decision_log"
}

# ---------------------------------------------------------------------------
# AC6 — symmetry check exits 0 after router + registry row exist (T1b)
# ---------------------------------------------------------------------------
# For T1a (RED): this test FAILS because the registry row for
# plan-w-team-orchestrator-decisions-*.jsonl is NOT in state-artifacts.md yet,
# and the router script is not yet written. The failure message is:
# "missing writer/reader greps for plan-w-team-orchestrator-decisions-*.jsonl"
#
# After T1b ships: registry row present, router script writes to the artifact,
# symmetry-check exits 0, this test PASSES.
test_ac6() {
  local artifact_pattern="plan-w-team-orchestrator-decisions-"

  # Check 1: registry row must exist in state-artifacts.md
  if ! grep -qF "$artifact_pattern" "$STATE_ARTIFACTS_REGISTRY" 2>/dev/null; then
    echo "    ASSERT FAIL [AC6: registry row] — missing writer/reader greps" \
         "for plan-w-team-orchestrator-decisions-*.jsonl in state-artifacts.md" >&2
    echo "      registry: $STATE_ARTIFACTS_REGISTRY" >&2
    echo "      This is the expected RED-phase failure. PWT-T1b must add this row." >&2
    return 1
  fi
  _log "AC6: registry row found in state-artifacts.md"

  # Check 2: router script must exist (it's the writer)
  if [[ ! -f "$ROUTER_SCRIPT" ]]; then
    echo "    ASSERT FAIL [AC6: router script] — writer script not found: $ROUTER_SCRIPT" >&2
    return 1
  fi
  _log "AC6: router script exists"

  # Check 3: symmetry-check must pass
  if [[ ! -f "$SYMMETRY_CHECK" ]]; then
    echo "    ASSERT FAIL [AC6: symmetry-check] — check script not found: $SYMMETRY_CHECK" >&2
    return 1
  fi

  local sc_exit
  bash "$SYMMETRY_CHECK" >"$TEST_TMPDIR/sc-out" 2>&1 || true
  sc_exit=$?

  if [[ "$sc_exit" -ne 0 ]]; then
    echo "    ASSERT FAIL [AC6: symmetry-check exit 0] — exits $sc_exit" >&2
    echo "      output: $(cat "$TEST_TMPDIR/sc-out")" >&2
    return 1
  fi
  _log "AC6: symmetry-check exits 0"
}

# ---------------------------------------------------------------------------
# AC7 — --resume with pre-existing slug (no decision log) → legacy ASK path
# ---------------------------------------------------------------------------
# route_orchestrator --resume scenario-slug-no-decision-log → detects missing
# decision log, treats as legacy SLUG, uses ASK path. No new JSONL created,
# no warnings emitted.
# FAILS IN RED: router script does not exist yet.
test_ac7() {
  reset_mock_logs

  local legacy_slug="scenario-slug-no-decision-log"
  local decision_log="$STATE_DIR/plan-w-team-orchestrator-decisions-${legacy_slug}.jsonl"
  rm -f "$decision_log"

  local exit_code stdout stderr
  run_router_cmd exit_code stdout stderr \
    MOCK_AGENT_MODE="ok" \
    -- \
    --resume "$legacy_slug"

  # Exit 0
  assert_exit_code "AC7: exit 0" 0 "$exit_code" || return 1

  # No JSONL created
  assert_file_not_exists "AC7: no JSONL created" "$decision_log" || return 1

  # No warnings on stderr (legacy path is silent)
  if [[ -n "$stderr" ]]; then
    echo "    ASSERT FAIL [AC7: silent stderr] — unexpected stderr:" >&2
    echo "      $stderr" >&2
    return 1
  fi
  _log "AC7: stderr empty (correct — legacy path is silent)"

  # No agent spawn
  local agent_calls
  agent_calls="$(cat "$MOCK_AGENT_CALL_LOG")"
  if [[ -n "$agent_calls" ]]; then
    echo "    ASSERT FAIL [AC7: no agent spawn] — log: $agent_calls" >&2
    return 1
  fi
  _log "AC7: agent_invoke not called (correct)"
}

# ---------------------------------------------------------------------------
# Pre-flight info block
# ---------------------------------------------------------------------------
preflight_info() {
  printf 'Pre-flight check\n'
  if [[ -f "$ROUTER_SCRIPT" ]]; then
    printf '  WARNING: router script EXISTS (%s)\n' "$ROUTER_SCRIPT"
    printf '           If PWT-T1b has shipped, tests should PASS not FAIL.\n'
  else
    printf '  router script: ABSENT (expected for RED phase)\n'
    printf '    %s\n' "$ROUTER_SCRIPT"
  fi
  if grep -qF "plan-w-team-orchestrator-decisions-" "$STATE_ARTIFACTS_REGISTRY" 2>/dev/null; then
    printf '  registry row:  PRESENT\n'
  else
    printf '  registry row:  ABSENT (expected for RED phase)\n'
    printf '    pattern: plan-w-team-orchestrator-decisions-\n'
  fi
  printf '\n'
}

# ---------------------------------------------------------------------------
# AC8 — PWT-P4 hard-gate floor (audit pwt-principles-enforcement-2026-06-02)
# ---------------------------------------------------------------------------
# The 3 irreversible one-way doors (push-ack, secret-scan-allow,
# scope-unlock-for-drift) must route to the USER even when the classifier
# table is tampered to say `orchestrator`. The router hardcodes a floor that
# forces `user` for these labels regardless of the (editable) table.
make_tampered_classifier() {
  # Copy the real classifier doc, flip all 3 hard-gate verdicts to orchestrator.
  # Single-quoted sed exprs → backticks are literal, not command substitution.
  local out="$TEST_TMPDIR/tampered-interception.md"
  sed -E \
    -e 's/(`push-ack`[[:space:]]*[|][[:space:]]*)`user`/\1`orchestrator`/' \
    -e 's/(`secret-scan-allow`[[:space:]]*[|][[:space:]]*)`user`/\1`orchestrator`/' \
    -e 's/(`scope-unlock-for-drift`[[:space:]]*[|][[:space:]]*)`user`/\1`orchestrator`/' \
    "$REPO_ROOT/.claude/commands/plan-w-team/shared/orchestrator-interception.md" > "$out"
  printf '%s' "$out"
}

_hard_gate_floor_case() {
  local site="$1"
  reset_mock_logs
  local tdoc; tdoc="$(make_tampered_classifier)"
  local exit_code stdout stderr
  run_router_cmd exit_code stdout stderr \
    PWT_CLASSIFIER_DOC_OVERRIDE="$tdoc" \
    PLAN_W_TEAM_AUTO_APPROVE_PUSH="" \
    MOCK_AGENT_MODE="ok" \
    -- \
    "$site" "test-slug-p4-${site}" ctx
  # Tampered table said `orchestrator`, but the floor must NOT spawn the agent
  assert_file_not_contains "P4/$site: no agent_invoke despite tampered table" \
    "$MOCK_AGENT_CALL_LOG" "agent_invoke called" || return 1
  # …and must route to the user instead
  assert_file_contains "P4/$site: ask_user_question called" \
    "$MOCK_ASK_CALL_LOG" "ask_user_question called" || return 1
  # …and must announce the floor override on stderr
  assert_stderr_contains "P4/$site: hard-gate floor warning" \
    "$stderr" "PWT-P4 hard-gate floor" || return 1
}

test_ac8a() { _hard_gate_floor_case "push-ack"; }
test_ac8b() { _hard_gate_floor_case "secret-scan-allow"; }
test_ac8c() { _hard_gate_floor_case "scope-unlock-for-drift"; }

# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------
printf 'plan-w-team-orchestrator-route.test.sh\n'
printf '  Spec: shared/orchestrator-interception.md (canonical; AC1-AC7)\n'
printf '  Mode: RED phase — all 7 tests SHOULD FAIL until PWT-T1b ships\n'
printf '  Runner: pure bash (bats not used — not available in this environment)\n'
printf '\n'

preflight_info

run_test "AC1: orchestrator route: spawns agent, writes JSONL row, prints choice" test_ac1
run_test "AC2: PLAN_W_TEAM_DISABLE_ORCHESTRATOR=1: ASK path, no agent, no JSONL" test_ac2
run_test "AC3: unknown call-site label: non-zero exit + UnknownCallSiteError" test_ac3
run_test "AC4: malformed decision block: fall through to ASK with prose preamble" test_ac4
run_test "AC5: concurrent invocations: mkdir lock serializes, no torn JSONL" test_ac5
run_test "AC6: symmetry-check exits 0 after router + registry row exist (T1b)" test_ac6
run_test "AC7: --resume with no decision log: legacy ASK, no JSONL, no warnings" test_ac7
run_test "AC8a: P4 hard-gate floor: push-ack forced to user despite tampered table" test_ac8a
run_test "AC8b: P4 hard-gate floor: secret-scan-allow forced to user despite tampered table" test_ac8b
run_test "AC8c: P4 hard-gate floor: scope-unlock-for-drift forced to user despite tampered table" test_ac8c

printf -- '---\n'
printf 'Results: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf '\nFailed tests:\n'
  for name in "${FAIL_NAMES[@]+"${FAIL_NAMES[@]}"}"; do
    printf '  - %s\n' "$name"
  done
  printf '\n'
  if [[ ! -f "$ROUTER_SCRIPT" ]]; then
    printf 'Reason: router script (%s) does not exist.\n' "$ROUTER_SCRIPT"
    printf 'These failures confirm the RED phase (PWT-T1a #198).\n'
    printf 'Ship PWT-T1b to make them pass.\n'
  fi
  exit 1
fi

exit 0
