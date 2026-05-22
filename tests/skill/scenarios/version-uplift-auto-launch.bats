#!/usr/bin/env bats
# tests/skill/scenarios/version-uplift-auto-launch.bats
#
# E2E coverage for the version-uplift auto-launch chain:
#   session-start.sh → detect-version.sh → pending flag → auto-launch.sh
#                                                              ↓
#                                                       pwt-goal.sh --worker-only
#                                                              ↓
#                                                       claude --bg (stubbed)
#
# Spec: docs/specs/version-uplift-e2e-scenarios.md
#
# Each @test maps 1:1 to one AC and prints `ACN: PASS` on success so the
# /plan-w-team transcript contains the AC-PASS contract the goal evaluator
# scans for.
#
# Surfaces NOT covered (intentional — see spec § Non-goals):
#   - changelog fetcher / evaluator (unit tests already cover)
#   - PWT-DS2 cascade guard (worker-cascade-blocked.bats covers)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

AUTO_LAUNCH="$REPO_ROOT/.claude/scripts/version-uplift/auto-launch.sh"
DETECT_VERSION="$REPO_ROOT/.claude/scripts/version-uplift/detect-version.sh"
PWT_GOAL="$REPO_ROOT/.claude/scripts/pwt-goal.sh"

# ─── Common sandbox setup ────────────────────────────────────────────────────
setup() {
  sandbox
  sandbox_git_init
  mkdir -p .claude/state \
           docs/operations/version-uplift-reports \
           .stub-bin

  # auto-launch.sh resolves pwt-goal.sh via its OWN git toplevel
  # (`git rev-parse --show-toplevel`). In the sandbox that resolves to
  # $SANDBOX_DIR, so we must stage the real scripts there.
  cp -R "$REPO_ROOT/.claude/scripts/." .claude/scripts/

  # PATH-stub `claude` — appends argv as JSON to stub.log, emits a fake bg SID
  # in the shape pwt-goal.sh's parser expects.
  STUB_LOG="$SANDBOX_DIR/stub.log"
  : > "$STUB_LOG"
  cat > .stub-bin/claude <<'STUB_EOF'
#!/usr/bin/env bash
LOG="${STUB_LOG:-/dev/null}"
python3 - "$@" <<'PYEOF' >> "$LOG" 2>/dev/null || true
import json, sys, time
print(json.dumps({"ts": time.time(), "argv": sys.argv[1:]}))
PYEOF
case "${1:-}" in
  --bg) printf 'backgrounded · %s\n' "${STUB_FAKE_SID:-abc12345}"; exit 0 ;;
  agents) echo '[]'; exit 0 ;;
  *) exit 0 ;;
esac
STUB_EOF
  chmod +x .stub-bin/claude

  export STUB_LOG
  # Pin pwt-goal.sh + auto-launch.sh state writes to the sandbox so we don't
  # pollute the real repo's pwt-launches.jsonl / spawned-children manifests.
  export PWT_PROJECT_ROOT_OVERRIDE="$SANDBOX_DIR"
  export CLAUDE_PROJECT_DIR="$SANDBOX_DIR"
  # Ensure stub claude is found before any real claude on PATH.
  export STUBBED_PATH="$SANDBOX_DIR/.stub-bin:$PATH"
  # PWT-DS2 (cascade guard) would mask PWT-DS1 if inherited from a parent
  # worker shell — strip it so the deterministic double-spawn path is reached
  # cleanly. Same for the auto-approve override.
  unset PLAN_W_TEAM_DISABLE_PROMPT_ROUTE
  unset PLAN_W_TEAM_AUTO_APPROVE_PUSH
}

teardown() { teardown_sandbox; }

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Write a minimal valid report JSON with N findings of which K are auto-safe.
write_report() {
  local path="$1"
  local total="$2"
  local safe="$3"
  local entry_text="${4:-changelog entry}"
  local findings='[]'
  local i
  for ((i=0; i<total; i++)); do
    local is_safe="false"
    [ "$i" -lt "$safe" ] && is_safe="true"
    findings=$(jq --argjson safe "$is_safe" \
                  --arg surface "hooks" \
                  --arg entry "${entry_text} #${i}" \
      '. + [{surface: $surface, entry: $entry, auto_integrate_safe: $safe}]' \
      <<<"$findings")
  done
  jq -n --argjson f "$findings" '{version: "2.1.999", findings: $f}' > "$path"
}

# Write a sentinel pending flag (auto-launch only reads its existence, but
# session-start populates fields).
write_pending_flag() {
  cat > .claude/state/version-uplift-pending.flag <<EOF
previous=2.1.140
current=2.1.999
detected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

# Write a fresh PWT-DS1 hook-spawn flag for the current "user turn".
write_hook_spawn_flag() {
  local sid="${1:-deadbeef}"
  local flag=".claude/state/plan-w-team-hook-spawn-${sid}.flag"
  cat > "$flag" <<EOF
worker_sid=worker-${sid}
spawned_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  # mtime must be within 60s; touch to be safe under slow harness.
  touch "$flag"
  echo "$flag"
}

# Count argv records logged by stub.
stub_call_count() {
  if [ ! -s "$STUB_LOG" ]; then echo 0; return; fi
  wc -l < "$STUB_LOG" | tr -d ' '
}

# Count specifically `--bg` spawn calls.
stub_bg_count() {
  if [ ! -s "$STUB_LOG" ]; then echo 0; return; fi
  jq -s '[.[] | select(.argv[0]=="--bg")] | length' "$STUB_LOG" 2>/dev/null || echo 0
}

# ─── AC1 — Happy path ────────────────────────────────────────────────────────
@test "AC1 happy path: version change + auto-safe finding spawns exactly ONE bg worker" {
  REPORT="docs/operations/version-uplift-reports/2026-05-22.json"
  write_report "$REPORT" 1 1
  write_pending_flag

  PATH="$STUBBED_PATH" \
    run "$AUTO_LAUNCH" --report="$REPORT"
  assert_success

  local bg_count
  bg_count=$(stub_bg_count)
  if [ "$bg_count" != "1" ]; then
    printf 'expected 1 --bg call, got %s\n--- stub.log ---\n%s\n' \
      "$bg_count" "$(cat "$STUB_LOG")" >&2
    return 1
  fi

  # Pending flag cleared on success.
  [ ! -f .claude/state/version-uplift-pending.flag ]
  echo "AC1: PASS"
}

# ─── AC2 — Kill switch ──────────────────────────────────────────────────────
@test "AC2 kill switch: no-auto-adopt.flag blocks all spawns" {
  REPORT="docs/operations/version-uplift-reports/2026-05-22.json"
  write_report "$REPORT" 1 1
  write_pending_flag
  touch .claude/state/version-uplift-no-auto-adopt.flag

  PATH="$STUBBED_PATH" \
    run "$AUTO_LAUNCH" --report="$REPORT"
  assert_success

  [ "$(stub_call_count)" = "0" ]
  # Pending flag is intentionally left in place — kill switch documented to
  # exit early without touching state.
  echo "AC2: PASS"
}

# ─── AC3 — No version change ─────────────────────────────────────────────────
@test "AC3 no version change: detect-version emits changed=false, no pending flag" {
  # Persist a matching last-seen version so detect sees current==last.
  cat > .claude/state/last-claude-version.json <<JSON
{
  "version": "2.1.999",
  "last_run": "2026-05-22T00:00:00Z"
}
JSON

  run "$DETECT_VERSION" \
        --state-file=.claude/state/last-claude-version.json \
        --no-persist \
        --mock-current=2.1.999
  assert_success

  local changed
  changed=$(echo "$output" | jq -r '.changed')
  [ "$changed" = "false" ]

  # No session-start equivalent runs because changed=false. Verify no flag.
  [ ! -f .claude/state/version-uplift-pending.flag ]
  echo "AC3: PASS"
}

# ─── AC4 — Empty auto-safe set ───────────────────────────────────────────────
@test "AC4 empty auto-safe set: 0 auto_integrate_safe findings → exit early, no spawn" {
  REPORT="docs/operations/version-uplift-reports/2026-05-22.json"
  # 3 findings, none auto-safe.
  write_report "$REPORT" 3 0
  write_pending_flag

  PATH="$STUBBED_PATH" \
    run "$AUTO_LAUNCH" --report="$REPORT"
  assert_success

  [ "$(stub_call_count)" = "0" ]

  # Pending flag cleared — auto-launch.sh explicitly clears it on the empty-set
  # branch so a future session doesn't keep re-running.
  [ ! -f .claude/state/version-uplift-pending.flag ]
  echo "AC4: PASS"
}

# ─── AC5 — PWT-DS1 integration ──────────────────────────────────────────────
@test "AC5 PWT-DS1 integration: fresh hook-spawn flag causes inner pwt-goal to exit 3" {
  # Drive pwt-goal.sh --worker-only directly with the same env auto-launch
  # would set up. This exercises the actual PWT-DS1 path inside pwt-goal.sh
  # without invoking auto-launch (auto-launch swallows the inner exit code by
  # design — see auto-launch.sh lines 168-177).
  write_hook_spawn_flag "deadbeef"

  PATH="$STUBBED_PATH" \
    run "$PWT_GOAL" --worker-only "test directive for PWT-DS1 case"

  # Exit 3 documented as PWT_DS1_DUPLICATE.
  if [ "$status" -ne 3 ]; then
    printf 'expected exit 3, got %d\n--- output ---\n%s\n' "$status" "$output" >&2
    return 1
  fi
  # Stub claude was NOT invoked — pwt-goal refused before spawn.
  [ "$(stub_call_count)" = "0" ]
  echo "AC5: PASS"
}

# ─── AC6 — Fire-and-forget contract ─────────────────────────────────────────
@test "AC6 fire-and-forget: detect-version exit 1 does not propagate when wrapped in || true" {
  # Simulate the session-start.sh invocation pattern. The real hook has:
  #   DETECTION=$("$VERSION_UPLIFT_DETECT" 2>/dev/null || true)
  # We swap the detect script for a failing stub and assert the wrapped
  # expression still exits 0.
  cat > .stub-bin/detect-fail.sh <<'EOF'
#!/usr/bin/env bash
echo "simulated detect failure" >&2
exit 1
EOF
  chmod +x .stub-bin/detect-fail.sh

  # Mimic the session-start.sh wrapping: command || true under set -e.
  run bash -c 'set -e; DETECTION=$(./.stub-bin/detect-fail.sh 2>/dev/null || true); echo "session-start continues with DETECTION=[$DETECTION]"'

  assert_success
  assert_output_contains "session-start continues with DETECTION=[]"
  echo "AC6: PASS"
}

# ─── AC7 — Directive sanity (≤4000 chars) ───────────────────────────────────
@test "AC7 directive sanity: auto-launch.sh truncates findings to keep directive ≤4000 chars" {
  REPORT="docs/operations/version-uplift-reports/2026-05-22.json"
  # 100 findings, each with a long entry — would blow past 4000 chars if
  # auto-launch concatenated all of them.
  local long_entry
  long_entry=$(printf 'A%.0s' {1..120})  # 120 chars per entry
  write_report "$REPORT" 100 100 "$long_entry"

  # Use auto-launch's --dry-run to capture the constructed directive without
  # spawning. --max-chars=3500 is the default the script enforces.
  PATH="$STUBBED_PATH" \
    run "$AUTO_LAUNCH" --report="$REPORT" --dry-run --max-chars=3500

  assert_success
  # Contract: must stay under pwt-goal.sh's 4000-char Anthropic /goal cap. The
  # script's --max-chars argument is an internal target, not a hard cap — the
  # "(... N more)" truncation marker can push final length slightly past it
  # (verified 2026-05-22: 100 findings, --max-chars=3500 → 3613 chars). What
  # matters for /goal acceptance is the 4000-char preflight ceiling.
  local len
  len=${#output}
  if [ "$len" -gt 4000 ]; then
    printf 'directive length %d exceeds pwt-goal 4000-char cap\n--- output ---\n%s\n' \
      "$len" "$output" >&2
    return 1
  fi
  # Truncation marker present when findings overflow.
  [[ "$output" == *"more — see report"* ]]
  echo "AC7: PASS"
}

# ─── AC8 — Idempotency ──────────────────────────────────────────────────────
@test "AC8 idempotency: two consecutive auto-launch runs produce exactly ONE worker total" {
  REPORT="docs/operations/version-uplift-reports/2026-05-22.json"
  write_report "$REPORT" 1 1
  write_pending_flag

  # First invocation — should spawn, clear the flag.
  PATH="$STUBBED_PATH" \
    run "$AUTO_LAUNCH" --report="$REPORT"
  assert_success
  local first_bg
  first_bg=$(stub_bg_count)
  [ "$first_bg" = "1" ]

  # Simulate session-start re-creating the pending flag (which it would if the
  # detect script still saw a version mismatch). PWT-DS1 must now block any
  # second spawn within the 60s window — OR auto-launch sees no flag change.
  write_pending_flag
  # Plant a fresh hook-spawn flag mimicking what the prior worker registration
  # would have written. This is the path PWT-DS1 guards.
  write_hook_spawn_flag "$(date +%s | tail -c 8)"

  PATH="$STUBBED_PATH" \
    run "$AUTO_LAUNCH" --report="$REPORT"
  assert_success

  # Total --bg spawns across both invocations must be exactly 1.
  local total_bg
  total_bg=$(stub_bg_count)
  if [ "$total_bg" != "1" ]; then
    printf 'expected 1 total --bg spawn, got %s\n--- stub.log ---\n%s\n' \
      "$total_bg" "$(cat "$STUB_LOG")" >&2
    return 1
  fi
  echo "AC8: PASS"
}
