#!/usr/bin/env bats
# tests/skill/cases/credential-wall.bats
#
# Coverage for the credential-wall escalation + step-completeness invariant
# (brief: credential-wall-escalation, 2026-06-02 cleanscale defect).
#
# Three composed pieces under test:
#   - credential-wall-detect.sh            (pure detector)
#   - plan-w-team-credential-wall-detect.sh (PostToolUse hook — persist + escalate)
#   - plan-w-team-credential-wall-gate.sh   (ENFORCING §6a-quinquies step gate)

load "$BATS_TEST_DIRNAME/../helpers/test_helper.bash"

DETECT="$SCRIPTS_DIR/credential-wall-detect.sh"
HOOK="$HOOKS_DIR/plan-w-team-credential-wall-detect.sh"
GATE="$SCRIPTS_DIR/plan-w-team-credential-wall-gate.sh"

setup() {
  TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/credwall-XXXXXX")"
  mkdir -p "$TMP/.claude/state"
}
teardown() { rm -rf "$TMP"; }

# ── AC1: canonical wrangler non-interactive CLOUDFLARE_API_TOKEN ──────────────
@test "AC1: detector flags wrangler non-interactive CLOUDFLARE_API_TOKEN" {
  run "$DETECT" --command "pnpm run deploy" \
      --output "In a non-interactive environment, it's necessary to set a CLOUDFLARE_API_TOKEN environment variable."
  [ "$status" -eq 0 ]
  [[ "$output" == *'"provider": "cloudflare"'* ]]
  [[ "$output" == *'"missing_secret": "CLOUDFLARE_API_TOKEN"'* ]]
}

# ── AC2: gh + vercel variants ────────────────────────────────────────────────
@test "AC2: detector flags gh not-logged-in wall (GH_TOKEN)" {
  run "$DETECT" --command "gh pr merge 1 --admin" \
      --output "To get started with GitHub CLI, please run: gh auth login. You are not logged into any GitHub hosts."
  [ "$status" -eq 0 ]
  [[ "$output" == *'"provider": "gh"'* ]]
  [[ "$output" == *'"missing_secret": "GH_TOKEN"'* ]]
}

@test "AC2: detector flags vercel no-credentials wall (VERCEL_TOKEN)" {
  run "$DETECT" --command "vercel deploy --prod" \
      --output 'Error: No existing credentials found. Please run `vercel login` or pass "--token".'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"provider": "vercel"'* ]]
  [[ "$output" == *'"missing_secret": "VERCEL_TOKEN"'* ]]
}

# ── AC3: negatives — success + prose must NOT trigger ────────────────────────
@test "AC3: a successful wrangler deploy does NOT trigger (exit 1)" {
  run "$DETECT" --command "pnpm run deploy" \
      --output "Total Upload: 1.2 KiB. Published cleanscale-api (3.1 sec) https://cleanscale-api.workers.dev"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "AC3: prose merely mentioning a deploy token does NOT trigger (exit 1)" {
  run "$DETECT" --command "cat docs/DEPLOY.md" \
      --output "We store the deploy token in a 0600 file outside the repo. Never commit it."
  [ "$status" -eq 1 ]
}

# ── AC4 + AC5: hook persists durable artifact + emits escalation ─────────────
@test "AC4/AC5: hook writes durable artifact and emits USER_ESCALATION_HALT block" {
  local payload
  payload=$(jq -nc '{tool_name:"Bash",
                     tool_input:{command:"pnpm run deploy"},
                     tool_response:{stdout:"",stderr:"In a non-interactive environment, set a CLOUDFLARE_API_TOKEN environment variable."}}')
  run bash -c "cd '$TMP' && printf '%s' '$payload' | PLAN_W_TEAM_SLUG=acme CLAUDE_PROJECT_DIR='$TMP' '$HOOK'"
  [ "$status" -eq 0 ]
  # systemMessage escalation surface (AC5)
  [[ "$output" == *"USER_ESCALATION_HALT"* ]]
  [[ "$output" == *"credential-wall"* ]]
  [[ "$output" == *"CLOUDFLARE_API_TOKEN"* ]]
  # durable artifact (AC4)
  local art="$TMP/.claude/state/plan-w-team-credwall-acme.json"
  [ -f "$art" ]
  run python3 -c "import json;d=json.load(open('$art'));print(d['missing_secret'],d['provider'],d['resolved'],bool(d['operator_action']))"
  [[ "$output" == "CLOUDFLARE_API_TOKEN cloudflare False True" ]]
}

@test "AC4: artifact name carries no secret VALUE — only the env-var NAME" {
  local payload
  payload=$(jq -nc '{tool_name:"Bash",
                     tool_input:{command:"wrangler deploy"},
                     tool_response:{stderr:"set a CLOUDFLARE_API_TOKEN environment variable"}}')
  bash -c "cd '$TMP' && printf '%s' '$payload' | PLAN_W_TEAM_SLUG=acme CLAUDE_PROJECT_DIR='$TMP' '$HOOK'" >/dev/null
  # The persisted artifact records a NAME, and the 'resolved' field starts false.
  run python3 -c "import json;d=json.load(open('$TMP/.claude/state/plan-w-team-credwall-acme.json'));assert d['resolved'] is False;print('ok')"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok" ]]
}

@test "hook no-ops on a non-deploy command (no artifact written)" {
  local payload
  payload=$(jq -nc '{tool_name:"Bash",tool_input:{command:"ls -la"},tool_response:{stdout:"a b c"}}')
  run bash -c "cd '$TMP' && printf '%s' '$payload' | CLAUDE_PROJECT_DIR='$TMP' '$HOOK'"
  [ "$status" -eq 0 ]
  run bash -c "ls '$TMP/.claude/state/' | grep -c credwall || true"
  [[ "$output" == "0" ]]
}

@test "kill switch PLAN_W_TEAM_DISABLE_CREDWALL_GUARD=1 disables the detector hook" {
  local payload
  payload=$(jq -nc '{tool_name:"Bash",tool_input:{command:"wrangler deploy"},
                     tool_response:{stderr:"set a CLOUDFLARE_API_TOKEN environment variable"}}')
  run bash -c "cd '$TMP' && printf '%s' '$payload' | PLAN_W_TEAM_DISABLE_CREDWALL_GUARD=1 PLAN_W_TEAM_SLUG=acme CLAUDE_PROJECT_DIR='$TMP' '$HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$TMP/.claude/state/plan-w-team-credwall-acme.json" ]
}

# ── AC6: the gate fails closed (step-completeness invariant) ─────────────────
@test "AC6: gate exits 0 when no credential-wall artifact exists" {
  run bash -c "CLAUDE_PROJECT_DIR='$TMP' '$GATE' --state-dir '$TMP/.claude/state'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no unresolved credential wall"* ]]
}

@test "AC6: gate FAILS CLOSED (exit 1) while an unresolved artifact exists" {
  printf '{"slug":"acme","provider":"cloudflare","missing_secret":"CLOUDFLARE_API_TOKEN","operator_action":"run wrangler login","resolved":false}\n' \
    > "$TMP/.claude/state/plan-w-team-credwall-acme.json"
  run bash -c "CLAUDE_PROJECT_DIR='$TMP' '$GATE' --state-dir '$TMP/.claude/state'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"CLOUDFLARE_API_TOKEN"* ]]
}

@test "AC6: gate exits 0 once the artifact is resolved=true" {
  printf '{"slug":"acme","provider":"cloudflare","missing_secret":"CLOUDFLARE_API_TOKEN","resolved":true}\n' \
    > "$TMP/.claude/state/plan-w-team-credwall-acme.json"
  run bash -c "CLAUDE_PROJECT_DIR='$TMP' '$GATE' --state-dir '$TMP/.claude/state'"
  [ "$status" -eq 0 ]
}

@test "AC6: gate FAILS CLOSED on a malformed artifact (un-bypassable)" {
  printf '{not valid json' > "$TMP/.claude/state/plan-w-team-credwall-bad.json"
  run bash -c "CLAUDE_PROJECT_DIR='$TMP' '$GATE' --state-dir '$TMP/.claude/state' --json"
  [ "$status" -eq 1 ]
  [[ "$output" == *'"verdict":"BLOCKED"'* ]]
}

@test "AC6: gate --slug targets a single artifact" {
  printf '{"resolved":false,"missing_secret":"VERCEL_TOKEN","provider":"vercel"}\n' \
    > "$TMP/.claude/state/plan-w-team-credwall-one.json"
  run bash -c "CLAUDE_PROJECT_DIR='$TMP' '$GATE' --state-dir '$TMP/.claude/state' --slug two"
  [ "$status" -eq 0 ]   # different slug → no match → clear
  run bash -c "CLAUDE_PROJECT_DIR='$TMP' '$GATE' --state-dir '$TMP/.claude/state' --slug one"
  [ "$status" -eq 1 ]   # the unresolved one blocks
}

# ── AC6 wiring: the ship stage references the gate as ENFORCING §6a-quinquies ─
@test "AC6: 05-ship.md wires the gate as ENFORCING §6a-quinquies" {
  run grep -F "plan-w-team-credential-wall-gate.sh" "$COMMANDS_DIR/05-ship.md"
  [ "$status" -eq 0 ]
  run grep -F "6a-quinquies" "$COMMANDS_DIR/05-ship.md"
  [ "$status" -eq 0 ]
}

# ── AC7: goal-evaluator recognizes the credential-wall hard-gate site ────────
@test "AC7: goal-evaluator hard-gate site set includes credential-wall" {
  run grep -E "for SITE in .*credential-wall" "$HOOKS_DIR/plan-w-team-goal-evaluator.sh"
  [ "$status" -eq 0 ]
}

# ── AC8: docs extend (not regress) REQ-5 / deploy standard ───────────────────
@test "AC8: secret-safety.md has REQ-6 and still has REQ-5 (extend, not regress)" {
  run grep -F "REQ-6" "$COMMANDS_DIR/shared/secret-safety.md"
  [ "$status" -eq 0 ]
  run grep -F "REQ-5" "$COMMANDS_DIR/shared/secret-safety.md"
  [ "$status" -eq 0 ]
}

@test "AC8: no-github-actions.md gains an Escalate-never-skip subsection" {
  run grep -iF "Escalate, never skip" "$COMMANDS_DIR/shared/no-github-actions.md"
  [ "$status" -eq 0 ]
}
