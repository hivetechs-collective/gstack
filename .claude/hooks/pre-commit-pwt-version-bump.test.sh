#!/usr/bin/env bash
# pre-commit-pwt-version-bump.test.sh — tests for the /plan-w-team VERSION bump hook.
#
# Regression anchor: the hook once extracted the Bash command with a grep that
# truncated at the first ESCAPED quote (\") inside `git commit -m "..."`, losing
# the commit message so EVERY commit silently defaulted to PATCH (feat: never
# became MINOR) and — combined with merges/amends bypassing it — VERSION never
# moved off 1.0.0. These tests feed real-shaped PreToolUse payloads (escaped
# quotes) and assert the correct bump kind + the gating rules.
#
# Usage:  ./pre-commit-pwt-version-bump.test.sh   Exit: 0 pass, 1 fail.

set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/pre-commit-pwt-version-bump.sh"
PASS=0; FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; echo "    $2"; FAIL=$((FAIL + 1)); }

# Build a throwaway repo with VERSION=1.0.0; optionally stage a path.
# fire <payload-json> <stage-path|""> [pre-stage-version-bump:1|0] → echoes resulting VERSION
fire() {
    local payload="$1" stage="$2" stageversion="${3:-0}"
    local T; T="$(mktemp -d -t pwtvbump.XXXXXX)"
    git -C "$T" init -q
    mkdir -p "$T/.claude/commands/plan-w-team" "$T/.claude/scripts"
    echo "1.0.0" > "$T/.claude/commands/plan-w-team/VERSION"
    [ -n "$stage" ] && { mkdir -p "$T/$(dirname "$stage")"; echo x > "$T/$stage"; git -C "$T" add "$stage" 2>/dev/null; }
    [ "$stageversion" = "1" ] && git -C "$T" add .claude/commands/plan-w-team/VERSION 2>/dev/null
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$T" bash "$HOOK" >/dev/null 2>&1
    cat "$T/.claude/commands/plan-w-team/VERSION"
    rm -rf "$T"
}
assert_ver() { # label payload stage expected [stageversion]
    local got; got=$(fire "$2" "$3" "${5:-0}")
    [ "$got" = "$4" ] && pass "$1" || fail "$1" "expected=$4 got=$got"
}

echo "── pre-commit-pwt-version-bump tests ──"

# Classification — payloads carry escaped quotes exactly as PreToolUse delivers.
SKILL=".claude/commands/plan-w-team/03-execute.md"
assert_ver "feat → MINOR"            '{"tool_input":{"command":"git commit -m \"feat(plan-w-team): s\""}}'      "$SKILL" "1.1.0"
assert_ver "fix → PATCH"             '{"tool_input":{"command":"git commit -m \"fix(plan-w-team): s\""}}'       "$SKILL" "1.0.1"
assert_ver "feat! → MAJOR"           '{"tool_input":{"command":"git commit -m \"feat(plan-w-team)!: s\""}}'     "$SKILL" "2.0.0"
assert_ver "BREAKING body → MAJOR"   '{"tool_input":{"command":"git commit -m \"feat: s\n\nBREAKING CHANGE: x\""}}' "$SKILL" "2.0.0"
assert_ver "docs → PATCH"            '{"tool_input":{"command":"git commit -m \"docs(plan-w-team): s\""}}'      "$SKILL" "1.0.1"
assert_ver "multi-line feat → MINOR" '{"tool_input":{"command":"git commit -m \"feat(plan-w-team): s\n\nbody\""}}' "$SKILL" "1.1.0"
assert_ver "no prefix → PATCH"       '{"tool_input":{"command":"git commit -m \"wip on the thing\""}}'          "$SKILL" "1.0.1"

# Gating rules.
assert_ver "non-skill path staged → no bump" '{"tool_input":{"command":"git commit -m \"feat(x): s\""}}' "README.md"               "1.0.0"
assert_ver "pwt-goal.sh staged → bumps"       '{"tool_input":{"command":"git commit -m \"feat(pwt): s\""}}' ".claude/scripts/pwt-goal.sh" "1.1.0"
assert_ver "VERSION already staged → defer"  '{"tool_input":{"command":"git commit -m \"feat(plan-w-team): s\""}}' "$SKILL" "1.0.0" 1
assert_ver "--amend → skip"                  '{"tool_input":{"command":"git commit --amend --no-edit"}}'   "$SKILL" "1.0.0"
assert_ver "non-commit git verb → skip"      '{"tool_input":{"command":"git merge --no-ff feature"}}'      "$SKILL" "1.0.0"

echo ""
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
