#!/usr/bin/env bash
# Tests for pre-commit-quality.sh B4 fix: secret-scan allow-file STALENESS control.
# A fresh allow-file suppresses its finding (commit allowed); an allow-file older
# than PLAN_W_TEAM_ALLOW_MAX_AGE_DAYS is SKIPPED (commit blocked) so a real secret
# at that path:line is caught again.
#
# NOTE: the planted secret token is assembled at runtime so this source file has
# no literal pattern match.
#
# Coverage:
#   T1  fresh allow-file suppresses finding   → commit allowed (exit 0)
#   T2  stale allow-file skipped              → commit blocked (exit 2)
#   T3  age check disabled (env=0) suppresses → commit allowed (exit 0)

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/pre-commit-quality.sh"
AKIA="AKIA""Z9Q7W2P1N4K8T6RB"

PASS=0; FAIL=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name (expected '$expected', got '$actual')"; FAIL=$((FAIL+1)); fi
}

# Set mtime to N days ago (BSD `date -v`, GNU `date -d` fallback).
set_age_days() {
    local f="$1" days="$2" stamp
    stamp=$(date -v-"${days}"d +%Y%m%d%H%M 2>/dev/null) \
      || stamp=$(date -d "${days} days ago" +%Y%m%d%H%M 2>/dev/null)
    [ -n "$stamp" ] && touch -t "$stamp" "$f"
}

setup_repo() {  # prints repo dir; stages a file with a secret + writes an allow-file
    local d; d=$(mktemp -d)
    (
      cd "$d"
      git init -q; git config user.email t@t.t; git config user.name t
      mkdir -p .claude/state
      printf 'aws_key = "%s"\n' "$AKIA" > leak.txt
      git add leak.txt
      printf 'leak.txt:1:aws\n' > .claude/state/plan-w-team-secret-scan-allow-foo
    )
    echo "$d"
}

COMMIT_JSON='{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}'

# T1 — fresh allow-file → suppressed → allowed.
D=$(setup_repo)
RC=$( cd "$D"; CLAUDE_HOOK_PROFILE=standard printf '%s' "$COMMIT_JSON" | CLAUDE_HOOK_PROFILE=standard bash "$HOOK" >/dev/null 2>&1; echo $? )
assert "T1 fresh allow-file → commit allowed" "0" "$RC"
rm -rf "$D"

# T2 — stale allow-file → skipped → secret caught → blocked.
D=$(setup_repo)
set_age_days "$D/.claude/state/plan-w-team-secret-scan-allow-foo" 40
RC=$( cd "$D"; printf '%s' "$COMMIT_JSON" | CLAUDE_HOOK_PROFILE=standard PLAN_W_TEAM_ALLOW_MAX_AGE_DAYS=30 bash "$HOOK" >/dev/null 2>&1; echo $? )
assert "T2 stale allow-file → commit blocked" "2" "$RC"
rm -rf "$D"

# T3 — stale allow-file but age check disabled (env=0) → suppressed → allowed.
D=$(setup_repo)
set_age_days "$D/.claude/state/plan-w-team-secret-scan-allow-foo" 40
RC=$( cd "$D"; printf '%s' "$COMMIT_JSON" | CLAUDE_HOOK_PROFILE=standard PLAN_W_TEAM_ALLOW_MAX_AGE_DAYS=0 bash "$HOOK" >/dev/null 2>&1; echo $? )
assert "T3 age check disabled → commit allowed" "0" "$RC"
rm -rf "$D"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
