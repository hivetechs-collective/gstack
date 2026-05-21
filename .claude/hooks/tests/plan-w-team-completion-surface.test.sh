#!/usr/bin/env bash
# Tests for plan-w-team-completion-surface.sh
#
# Strategy: sandbox CLAUDE_PROJECT_DIR with mock state/ dir containing
# pwt-completion-summary-<sid>.md files. Send a JSON prompt on stdin and
# assert:
#   - hook output is valid JSON with systemMessage + additionalContext
#   - summary file moved to .claude/state/archive/
#   - second invocation finds nothing to surface (idempotent)

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/plan-w-team-completion-surface.sh"
[ -x "$HOOK" ] || { echo "FAIL: hook not executable: $HOOK"; exit 1; }

PASS=0
FAIL=0
FAIL_NAMES=()

setup_sandbox() {
    SANDBOX=$(mktemp -d -t pwt-completion-test.XXXXXX)
    mkdir -p "$SANDBOX/.claude/state"
    export CLAUDE_PROJECT_DIR="$SANDBOX"
}

teardown_sandbox() {
    [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
    unset CLAUDE_PROJECT_DIR
}

run_hook() {
    printf '%s' "$1" | bash "$HOOK" 2>/dev/null
}

echo "Testing plan-w-team-completion-surface.sh"
echo

# ─── 1. Summary file present → surfaced and archived ────────────────────────
setup_sandbox
SUMMARY="$SANDBOX/.claude/state/pwt-completion-summary-aabbccdd.md"
cat > "$SUMMARY" <<EOF
## Outcome: SUCCESS

## Goal
ship the payment API

## Files changed
src/api/payments.ts
src/api/payments.test.ts
EOF

OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
EXIT=$?
if [ "$EXIT" = "0" ] && echo "$OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert 'systemMessage' in d
assert 'additionalContext' in d
assert 'Outcome' in d['additionalContext']
assert 'completed' in d['systemMessage'].lower()
" 2>/dev/null; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "summary file surfaced via systemMessage + additionalContext"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("summary file surfaced")
    printf "  \033[31m✗\033[0m %s (exit=%s)\n" "summary file surfaced" "$EXIT"
    printf "      stdout: %s\n" "$OUT"
fi

if [ ! -f "$SUMMARY" ] && ls "$SANDBOX/.claude/state/archive/"*.md >/dev/null 2>&1; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "summary file moved to archive/"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("summary moved to archive")
    printf "  \033[31m✗\033[0m %s\n" "summary moved to archive/"
fi
teardown_sandbox

# ─── 2. Second invocation finds nothing — idempotent ────────────────────────
setup_sandbox
# no summary file
OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
EXIT=$?
if [ "$EXIT" = "0" ] && [ -z "$OUT" ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "no summary → silent passthrough"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("no summary silent")
    printf "  \033[31m✗\033[0m %s (exit=%s out=%s)\n" "no summary silent" "$EXIT" "$OUT"
fi
teardown_sandbox

# ─── 3. Multiple summary files → all surfaced ───────────────────────────────
setup_sandbox
echo "summary 1 content" > "$SANDBOX/.claude/state/pwt-completion-summary-aaaaaaaa.md"
echo "summary 2 content" > "$SANDBOX/.claude/state/pwt-completion-summary-bbbbbbbb.md"
OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
if echo "$OUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ctx=d.get('additionalContext','')
assert 'summary 1 content' in ctx
assert 'summary 2 content' in ctx
" 2>/dev/null; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "multiple summaries concatenated"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("multiple summaries")
    printf "  \033[31m✗\033[0m %s\n" "multiple summaries concatenated"
    printf "      stdout: %s\n" "$OUT"
fi
teardown_sandbox

# ─── 4. Empty summary file → ignored, no output ─────────────────────────────
setup_sandbox
touch "$SANDBOX/.claude/state/pwt-completion-summary-empty00.md"
OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
EXIT=$?
if [ "$EXIT" = "0" ] && [ -z "$OUT" ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "empty file produces no output"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("empty file")
    printf "  \033[31m✗\033[0m %s (out=%s)\n" "empty file" "$OUT"
fi
teardown_sandbox

# ─── 5. Missing .claude/state dir → silent passthrough ──────────────────────
SANDBOX=$(mktemp -d -t pwt-completion-test.XXXXXX)
export CLAUDE_PROJECT_DIR="$SANDBOX"
OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
EXIT=$?
if [ "$EXIT" = "0" ] && [ -z "$OUT" ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "missing state dir → silent"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("missing state dir")
    printf "  \033[31m✗\033[0m %s (exit=%s out=%s)\n" "missing state dir" "$EXIT" "$OUT"
fi
rm -rf "$SANDBOX"; unset CLAUDE_PROJECT_DIR

# ─── 6. Malformed input JSON → still operates, doesn't crash ────────────────
setup_sandbox
echo "summary content" > "$SANDBOX/.claude/state/pwt-completion-summary-malf0000.md"
OUT=$(run_hook 'not valid json {{{')
EXIT=$?
if [ "$EXIT" = "0" ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "malformed input → exit 0"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("malformed input")
    printf "  \033[31m✗\033[0m %s (exit=%s)\n" "malformed input" "$EXIT"
fi
teardown_sandbox

# ─── 7. Goal JSON terminal_state set → surfaced with required fields ────────
# AC1, AC2, AC4: surface MUST fire for terminal goal JSON, with the six required
# fields (slug, terminal_state, terminal_reason, ac_counts, files_touched, next_action).
setup_sandbox
GOAL_JSON="$SANDBOX/.claude/state/plan-w-team-goal-fix-login.json"
cat > "$GOAL_JSON" <<'EOF'
{
  "slug": "fix-login",
  "started_at": "2026-05-20T22:32:05Z",
  "terminal_state": "user_halted",
  "terminal_reason": "bg supervisor hung after 30 min silent",
  "terminated_at": "2026-05-20T22:35:57Z"
}
EOF
OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
EXIT=$?
if [ "$EXIT" = "0" ] && echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ctx = d.get('additionalContext','') + d.get('systemMessage','')
assert 'fix-login' in ctx, 'slug missing'
assert 'user_halted' in ctx, 'terminal_state missing'
assert 'supervisor hung' in ctx, 'terminal_reason missing'
assert 'slug' in ctx.lower(), 'slug label missing'
assert 'terminal' in ctx.lower(), 'terminal label missing'
" 2>/dev/null; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "T7: goal JSON terminal → surfaced with required fields"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("T7: goal JSON terminal surfaced")
    printf "  \033[31m✗\033[0m %s (exit=%s)\n" "T7: goal JSON terminal surfaced" "$EXIT"
    printf "      stdout: %s\n" "$OUT"
fi
teardown_sandbox

# ─── 8. Goal JSON with terminal_state=null → NOT surfaced ───────────────────
# AC1: surface only when terminal_state != null
setup_sandbox
cat > "$SANDBOX/.claude/state/plan-w-team-goal-inflight.json" <<'EOF'
{"slug":"inflight","started_at":"2026-05-20T22:00:00Z","terminal_state":null,"terminal_reason":null}
EOF
OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
EXIT=$?
if [ "$EXIT" = "0" ] && [ -z "$OUT" ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "T8: terminal_state=null → silent"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("T8: null terminal silent")
    printf "  \033[31m✗\033[0m %s (out=%s)\n" "T8: terminal_state=null silent" "$OUT"
fi
teardown_sandbox

# ─── 9. Goal JSON surfaced=true → NOT re-surfaced (idempotent) ──────────────
# AC3: idempotency via surfaced flag
setup_sandbox
cat > "$SANDBOX/.claude/state/plan-w-team-goal-already-shown.json" <<'EOF'
{
  "slug": "already-shown",
  "started_at": "2026-05-20T22:00:00Z",
  "terminal_state": "SUCCESS",
  "terminal_reason": "all AC pass",
  "surfaced": true,
  "surfaced_at": "2026-05-20T22:30:00Z"
}
EOF
OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
EXIT=$?
if [ "$EXIT" = "0" ] && [ -z "$OUT" ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "T9: surfaced=true → not re-surfaced"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("T9: idempotent")
    printf "  \033[31m✗\033[0m %s (out=%s)\n" "T9: surfaced=true silent" "$OUT"
fi
teardown_sandbox

# ─── 10. After emission, goal JSON has surfaced=true + surfaced_at ─────────
# AC3: writer side of idempotency
setup_sandbox
GOAL_JSON="$SANDBOX/.claude/state/plan-w-team-goal-mark-it.json"
cat > "$GOAL_JSON" <<'EOF'
{
  "slug": "mark-it",
  "started_at": "2026-05-20T22:00:00Z",
  "terminal_state": "SUCCESS",
  "terminal_reason": "done"
}
EOF
OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
if python3 -c "
import json, sys
d = json.load(open('$GOAL_JSON'))
assert d.get('surfaced') is True, 'surfaced not set to true'
assert isinstance(d.get('surfaced_at'), str) and len(d['surfaced_at']) > 0, 'surfaced_at not set'
assert d.get('terminal_state') == 'SUCCESS', 'terminal_state mutated'
" 2>/dev/null; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "T10: surfaced flag written back to goal JSON"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("T10: surfaced writeback")
    printf "  \033[31m✗\033[0m %s\n" "T10: surfaced flag written back"
    printf "      goal JSON: %s\n" "$(cat "$GOAL_JSON" 2>/dev/null)"
fi
teardown_sandbox

# ─── 11. Goal JSON with extended fields → all surface in output ────────────
# AC2: ac_counts, files_touched, next_action surface
setup_sandbox
cat > "$SANDBOX/.claude/state/plan-w-team-goal-rich.json" <<'EOF'
{
  "slug": "rich-run",
  "started_at": "2026-05-20T22:00:00Z",
  "terminal_state": "SUCCESS",
  "terminal_reason": "all green",
  "ac_counts": {"passed": 5, "failed": 0, "total": 5},
  "files_touched": ["src/login.ts", "src/login.test.ts"],
  "next_action": "review PR #42 and merge"
}
EOF
OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
if echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ctx = d.get('additionalContext','') + d.get('systemMessage','')
assert 'rich-run' in ctx
assert '5/5' in ctx or 'passed: 5' in ctx or '5 passed' in ctx, 'ac_counts not surfaced'
assert 'src/login.ts' in ctx, 'files_touched not surfaced'
assert 'review PR #42' in ctx, 'next_action not surfaced'
" 2>/dev/null; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "T11: extended fields surface in output"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("T11: extended fields")
    printf "  \033[31m✗\033[0m %s\n" "T11: extended fields surface"
    printf "      stdout: %s\n" "$OUT"
fi
teardown_sandbox

# ─── 12. Both markdown + terminal goal JSON → both in one emission ─────────
# AC6: combined emission, no double-fire
setup_sandbox
echo "## Outcome: SUCCESS\nfrom markdown summary" > \
    "$SANDBOX/.claude/state/pwt-completion-summary-combosid.md"
cat > "$SANDBOX/.claude/state/plan-w-team-goal-combo.json" <<'EOF'
{"slug":"combo","started_at":"2026-05-20T22:00:00Z","terminal_state":"SUCCESS","terminal_reason":"from goal json"}
EOF
OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
if echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ctx = d.get('additionalContext','') + d.get('systemMessage','')
assert 'from markdown summary' in ctx, 'markdown content missing'
assert 'from goal json' in ctx, 'goal json content missing'
assert 'combo' in ctx, 'goal slug missing'
" 2>/dev/null; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "T12: markdown + goal JSON combined in one emission"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("T12: combined emission")
    printf "  \033[31m✗\033[0m %s\n" "T12: combined emission"
    printf "      stdout: %s\n" "$OUT"
fi
teardown_sandbox

# ─── 13. Malformed goal JSON → fail-open (exit 0, no crash) ───────────────
# AC7: fail-open contract
setup_sandbox
echo '{ "slug": "broken", malformed json no closing' > \
    "$SANDBOX/.claude/state/plan-w-team-goal-broken.json"
OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
EXIT=$?
if [ "$EXIT" = "0" ]; then
    PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "T13: malformed goal JSON → fail-open"
else
    FAIL=$((FAIL+1)); FAIL_NAMES+=("T13: malformed goal JSON")
    printf "  \033[31m✗\033[0m %s (exit=%s)\n" "T13: malformed goal JSON" "$EXIT"
fi
teardown_sandbox

# ─── 14. Surface fires across all four canonical terminal states ──────────
# AC4: every terminal state surfaces
for STATE in "SUCCESS" "USER_ESCALATION_HALT" "LOW_CONFIDENCE_STREAK" "user_halted"; do
    setup_sandbox
    cat > "$SANDBOX/.claude/state/plan-w-team-goal-state-${STATE}.json" <<EOF
{"slug":"state-${STATE}","started_at":"2026-05-20T22:00:00Z","terminal_state":"${STATE}","terminal_reason":"reason for ${STATE}"}
EOF
    OUT=$(run_hook '{"prompt":"continue","session_id":"x"}')
    EXIT=$?
    if [ "$EXIT" = "0" ] && echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ctx = d.get('additionalContext','') + d.get('systemMessage','')
assert '$STATE' in ctx, '$STATE not surfaced'
assert 'state-$STATE' in ctx, 'slug not surfaced'
" 2>/dev/null; then
        PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "T14[$STATE]: surfaced"
    else
        FAIL=$((FAIL+1)); FAIL_NAMES+=("T14[$STATE]")
        printf "  \033[31m✗\033[0m %s (exit=%s)\n" "T14[$STATE]: surfaced" "$EXIT"
    fi
    teardown_sandbox
done

echo
echo "─────────────────────────────────────────"
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed cases:"
    for n in "${FAIL_NAMES[@]}"; do echo "  - $n"; done
    exit 1
fi
exit 0
