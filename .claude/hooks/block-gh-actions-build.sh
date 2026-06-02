#!/bin/bash
# block-gh-actions-build.sh — PreToolUse (Write+Edit) guard for the
# No-GitHub-Actions-for-build/CI/deploy governance rule (audit P9b).
#
# shared/no-github-actions.md self-labels "ENFORCING", but nothing actually
# blocked a write to .github/workflows/* — §6b-bis only echo'd a warning (never
# exit 1), and block-protected-paths.sh's project.json protectedPaths omits the
# path. "ENFORCING but doesn't enforce" is exactly the theater this audit hunts.
# This hook makes the rule real: it blocks creating/editing a GitHub Actions
# workflow that runs build/test/lint/deploy steps. Observer-only workflows
# (ci-alert*, board-auto-add*/board-sync*) are exempt — those are the sanctioned
# notification/board workflows the template ships.
#
# Kill switch: PLAN_W_TEAM_DISABLE_GH_ACTIONS_GUARD=1 (incident escape hatch).
[ "${PLAN_W_TEAM_DISABLE_GH_ACTIONS_GUARD:-}" = "1" ] && exit 0

INPUT=$(cat 2>/dev/null || echo "{}")

FILE_PATH=$(printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null || echo "")
[ -z "$FILE_PATH" ] && exit 0

# Only guard GitHub Actions workflow files.
case "$FILE_PATH" in
  */.github/workflows/*.yml|*/.github/workflows/*.yaml|.github/workflows/*.yml|.github/workflows/*.yaml) ;;
  *) exit 0 ;;
esac

# Observer-only workflows are the sanctioned exemptions (they watch other
# workflows / sync the board; they do not build/test/deploy the project).
BASE=$(basename "$FILE_PATH")
case "$BASE" in
  ci-alert*|board-auto-add*|board-sync*) exit 0 ;;
esac

# Extract the content being written (Write: content; Edit: new_string;
# MultiEdit: concatenate every edit's new_string).
CONTENT=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
ti = json.load(sys.stdin).get('tool_input', {})
parts = []
if ti.get('content'): parts.append(ti['content'])
if ti.get('new_string'): parts.append(ti['new_string'])
for e in ti.get('edits', []) or []:
    if e.get('new_string'): parts.append(e['new_string'])
print('\n'.join(parts))
" 2>/dev/null || echo "")

# Build/CI/deploy signal: a jobs: block that runs steps (run:/uses:).
if printf '%s' "$CONTENT" | grep -qE '^[[:space:]]*jobs:' \
   && printf '%s' "$CONTENT" | grep -qE '^[[:space:]]*-?[[:space:]]*(run|uses):'; then
    cat << JSONEOF
{
  "decision": "block",
  "reason": "No GitHub Actions for build/CI/deploy (governance rule)",
  "systemMessage": "⛔ BLOCKED (PWT-P9b): $FILE_PATH is a GitHub Actions workflow that runs build/CI/deploy steps (a jobs: block with run:/uses:). This repo's governance forbids GitHub Actions for build/CI/deploy — the canonical path is the local Makefile + admin-squash-merge (shared/no-github-actions.md), which saves GH-minutes and ships with /plan-w-team to every repo. Observer-only workflows (ci-alert*, board-auto-add*) are exempt; add a genuine exemption to the allowlist in this hook, or set PLAN_W_TEAM_DISABLE_GH_ACTIONS_GUARD=1 for a one-off."
}
JSONEOF
    exit 1
fi

exit 0
