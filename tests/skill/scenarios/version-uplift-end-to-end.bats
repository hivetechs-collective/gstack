#!/usr/bin/env bats
# tests/skill/scenarios/version-uplift-end-to-end.bats
#
# Spec: docs/specs/version-uplift-auto-chain.md (AC2, AC3)
#
# Verifies the bash-only automated chain runs end-to-end with no LLM in the
# loop. Stubs `claude --version` and `curl` so the test is hermetic and
# never touches the network.

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

setup() {
  sandbox
  sandbox_git_init
  mkdir -p .claude/state \
           .claude/scripts/version-uplift \
           .claude/commands/plan-w-team/version-uplift \
           docs/operations/version-uplift-reports \
           .stub-bin

  cp -R "$REPO_ROOT/.claude/scripts/." .claude/scripts/
  cp -R "$REPO_ROOT/.claude/commands/plan-w-team/version-uplift/." \
        .claude/commands/plan-w-team/version-uplift/

  # Stub curl — returns a synthetic 2.1.149 changelog. Used by
  # fetch-changelog.sh --curl, which the uplift.sh orchestrator picks
  # automatically when no mirror is present.
  cat > .stub-bin/curl <<'STUB_EOF'
#!/usr/bin/env bash
# Minimal stub: ignore all flags, emit fixture body.
cat <<'PAYLOAD'
## 2.1.149

- `/usage` now shows a per-category breakdown
- Fixed `find` exhausting vnode table

## 2.1.148

- Some earlier entry
PAYLOAD
STUB_EOF
  chmod +x .stub-bin/curl

  # Stub claude — produces "2.1.149 (Claude Code)" for --version. Also
  # records --bg invocations for the (optional) auto-launch chaining
  # assertion. Note: end-to-end test focuses on REPORT WRITTEN, not
  # worker spawn (spawn is covered by version-uplift-auto-launch.bats).
  STUB_LOG="$SANDBOX_DIR/stub.log"
  : > "$STUB_LOG"
  cat > .stub-bin/claude <<STUB_EOF
#!/usr/bin/env bash
LOG="$STUB_LOG"
case "\${1:-}" in
  --version) echo "2.1.149 (Claude Code)"; exit 0 ;;
  --bg) echo "argv=\$*" >> "\$LOG"; printf 'backgrounded · abc12345\\n'; exit 0 ;;
  agents) echo '[]'; exit 0 ;;
  *) exit 0 ;;
esac
STUB_EOF
  chmod +x .stub-bin/claude

  export STUB_LOG
  # Stub PATH so curl/claude come from .stub-bin.
  export STUBBED_PATH="$SANDBOX_DIR/.stub-bin:$PATH"
  # No mirror, no fixture — force curl path. We DO want curl to be picked.
  rm -f .claude/state/claude-code-changelog-mirror.md
  unset CLAUDE_PATTERN_CHANGELOG_MIRROR
  unset PLAN_W_TEAM_DISABLE_PROMPT_ROUTE
}

teardown() { teardown_sandbox; }

# ─── AC2/AC3 — Full chain ────────────────────────────────────────────────────
@test "AC2 happy path: detect → pending flag → uplift writes report (via curl)" {
  # No prior state file → detect.changed=true on first run.
  PATH="$STUBBED_PATH" run .claude/commands/plan-w-team/version-uplift/uplift.sh --force --quiet
  assert_success

  # Report must exist for today's date + detected version.
  TODAY=$(date -u +%Y-%m-%d)
  REPORT_JSON="docs/operations/version-uplift-reports/${TODAY}-2.1.149.json"
  [ -f "$REPORT_JSON" ]
  jq -e '.findings | type == "array" and length > 0' "$REPORT_JSON"

  echo "AC2: PASS"
}

@test "AC3 end-to-end: chain writes report that auto-launch can consume" {
  PATH="$STUBBED_PATH" .claude/commands/plan-w-team/version-uplift/uplift.sh --force --quiet

  TODAY=$(date -u +%Y-%m-%d)
  REPORT_JSON="docs/operations/version-uplift-reports/${TODAY}-2.1.149.json"
  [ -f "$REPORT_JSON" ]

  # auto-launch.sh should find the report (whether or not it spawns depends
  # on whether any finding is auto_integrate_safe=true; that path is
  # covered exhaustively by version-uplift-auto-launch.bats).
  cat > .claude/state/version-uplift-pending.flag <<EOF
previous=2.1.148
current=2.1.149
detected_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  PATH="$STUBBED_PATH" run .claude/scripts/version-uplift/auto-launch.sh \
    --report="$REPORT_JSON"
  assert_success

  echo "AC3: PASS"
}
