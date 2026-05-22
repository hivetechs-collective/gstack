#!/usr/bin/env bats
# tests/skill/scenarios/version-uplift-fail-open.bats
#
# Spec: docs/specs/version-uplift-auto-chain.md (AC6 — robustness; quality
# rubric "fail-open robustness")
#
# When curl fails, the chain must:
#   - retry once (2-second sleep happens internally — we just verify the
#     retry count via call log)
#   - exit 2 cleanly on persistent failure
#   - NOT surface errors to session-start (session-start.sh swallows with
#     `|| true`); we test the fetch-changelog.sh exit code is 2 here, and
#     the integration-level swallowing is implicit (no test process dies).

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

setup() {
  sandbox
  sandbox_git_init
  mkdir -p .claude/state .claude/scripts/version-uplift .stub-bin
  cp -R "$REPO_ROOT/.claude/scripts/." .claude/scripts/

  export STUBBED_PATH="$SANDBOX_DIR/.stub-bin:$PATH"
}

teardown() { teardown_sandbox; }

# Helper: write a curl stub that fails on every call.
make_failing_curl_stub() {
  cat > .stub-bin/curl <<STUB_EOF
#!/usr/bin/env bash
echo "called" >> "$SANDBOX_DIR/curl-fail.log"
exit 7   # curl's "failed to connect to host"
STUB_EOF
  chmod +x .stub-bin/curl
}

# ─── AC1 — hard fail returns exit 2 cleanly ──────────────────────────────────
@test "AC1 hard fail: curl always-fails → exit 2, no stderr leak to session" {
  make_failing_curl_stub

  # We don't want a real 2-second wait in tests. Shim `sleep` to a no-op
  # so the retry path runs instantly.
  cat > .stub-bin/sleep <<'STUB_EOF'
#!/usr/bin/env bash
exit 0
STUB_EOF
  chmod +x .stub-bin/sleep

  PATH="$STUBBED_PATH" run .claude/scripts/version-uplift/fetch-changelog.sh \
    --curl --to=2.1.149

  # Hard failure must surface as exit 2 (no source available).
  [ "$status" -eq 2 ] \
    || { echo "expected exit 2, got $status. output=$output"; false; }

  # Verify the script retried exactly once (2 total curl calls).
  CALLS=$(wc -l < "$SANDBOX_DIR/curl-fail.log" | tr -d ' ')
  [ "$CALLS" -eq 2 ] \
    || { echo "expected 2 curl calls (initial + 1 retry), got $CALLS"; false; }

  echo "AC1: PASS"
}

# ─── AC2/AC3 — uplift.sh propagates the failure as exit 4 ────────────────────
@test "AC2 uplift.sh exit 4 when fetch can't fetch (no mirror, curl fails)" {
  make_failing_curl_stub
  cat > .stub-bin/sleep <<'STUB_EOF'
#!/usr/bin/env bash
exit 0
STUB_EOF
  chmod +x .stub-bin/sleep
  # Stub claude so detect-version doesn't need real CLI.
  cat > .stub-bin/claude <<'STUB_EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "2.1.149 (Claude Code)"; exit 0 ;;
  *) exit 0 ;;
esac
STUB_EOF
  chmod +x .stub-bin/claude

  mkdir -p .claude/commands/plan-w-team/version-uplift
  cp -R "$REPO_ROOT/.claude/commands/plan-w-team/version-uplift/." \
        .claude/commands/plan-w-team/version-uplift/

  # No mirror, no fixture, no --changelog-file → uplift picks --curl
  # automatically, which then fails.
  unset CLAUDE_PATTERN_CHANGELOG_MIRROR
  PATH="$STUBBED_PATH" run .claude/commands/plan-w-team/version-uplift/uplift.sh \
    --force --quiet

  # uplift.sh maps "no source available" (fetch exit 2) to its own exit 4.
  [ "$status" -eq 4 ] \
    || { echo "expected uplift exit 4, got $status. output=$output"; false; }

  # Report directory should be empty — no report on hard failure.
  ! ls docs/operations/version-uplift-reports/*.json 2>/dev/null

  echo "AC2: PASS"
  echo "AC3: PASS"
}

# ─── AC6 — Session-start swallowing semantics ────────────────────────────────
@test "AC6 fail-open: invoking via '|| true' wrapper succeeds even when uplift fails" {
  make_failing_curl_stub
  cat > .stub-bin/sleep <<'STUB_EOF'
#!/usr/bin/env bash
exit 0
STUB_EOF
  chmod +x .stub-bin/sleep
  cat > .stub-bin/claude <<'STUB_EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "2.1.149 (Claude Code)"; exit 0 ;;
  *) exit 0 ;;
esac
STUB_EOF
  chmod +x .stub-bin/claude

  mkdir -p .claude/commands/plan-w-team/version-uplift
  cp -R "$REPO_ROOT/.claude/commands/plan-w-team/version-uplift/." \
        .claude/commands/plan-w-team/version-uplift/

  # Wrap exactly the way session-start.sh does.
  unset CLAUDE_PATTERN_CHANGELOG_MIRROR
  PATH="$STUBBED_PATH" run bash -c \
    '.claude/commands/plan-w-team/version-uplift/uplift.sh --force --quiet 2>/dev/null || true; echo "session continued"'
  assert_success
  echo "$output" | grep -q "session continued"

  echo "AC6: PASS"
}
