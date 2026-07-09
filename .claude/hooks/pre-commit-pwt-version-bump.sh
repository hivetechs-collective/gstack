#!/bin/bash
# Pre-Commit /plan-w-team VERSION Bump Hook
# PreToolUse hook (matcher: Bash) that auto-bumps the /plan-w-team VERSION file
# when a commit touches the skill's source paths.
#
# Triggers when ALL of:
#   - Bash command is `git commit` (not amend)
#   - Staged files include any of:
#       .claude/commands/plan-w-team/**
#       .claude/scripts/pwt-goal.sh
#   - VERSION itself is not already staged (avoids double-bump)
#
# Bump kind is derived from the commit message via conventional-commits prefix:
#   feat(...)!:        / "BREAKING CHANGE" in body  → MAJOR
#   feat(...):                                       → MINOR
#   fix|docs|chore|refactor|test|perf(...):          → PATCH
#   (no recognized prefix)                           → PATCH (conservative default)
#
# The hook NEVER blocks the commit — it only stages an updated VERSION file
# alongside the user's changes so the bump rides along. If anything goes wrong
# (missing VERSION, malformed semver, jq unavailable), the hook logs to stderr
# and exits 0.
#
# Spec: .claude/commands/plan-w-team/shared/versioning.md
#
# Exit codes:
#   0 - allow (always; this hook is informational + stages bump file)

set -uo pipefail

INPUT=$(cat 2>/dev/null || echo "")
# Extract the Bash command robustly. The PreToolUse payload nests it under
# .tool_input.command. A plain grep for "command" truncates at the first
# ESCAPED quote (\") inside `git commit -m "..."`, dropping the message and
# silently defaulting every bump to PATCH (so feat: never became MINOR). Parse
# with jq; fall back to the (lossy) grep only when jq is unavailable.
if command -v jq >/dev/null 2>&1; then
    COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // empty' 2>/dev/null)
else
    COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
fi

# Only fire on `git commit` (not amend, not other git verbs).
if ! echo "$COMMAND" | grep -qE '\bgit[[:space:]]+commit\b'; then
    exit 0
fi
if echo "$COMMAND" | grep -q '\-\-amend'; then
    exit 0
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$PROJECT_ROOT" ] && exit 0

VERSION_FILE="$PROJECT_ROOT/.claude/commands/plan-w-team/VERSION"
[ -f "$VERSION_FILE" ] || exit 0

# What's staged? --diff-filter=ACMR catches add/copy/modify/rename (the kinds
# that can affect the skill); --cached restricts to the index.
STAGED=$(git -C "$PROJECT_ROOT" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || echo "")
[ -z "$STAGED" ] && exit 0

# Trigger condition: any staged file under the skill's tracked paths.
TRIGGER=0
echo "$STAGED" | while IFS= read -r f; do
    case "$f" in
        .claude/commands/plan-w-team/*|.claude/scripts/pwt-goal.sh|.claude/agents/team/*|.claude/agents/implementation/react-typescript-specialist.md|.claude/agents/implementation/rust-backend-specialist.md)
            echo "trigger"
            break
            ;;
    esac
done | grep -q "trigger" && TRIGGER=1
[ "$TRIGGER" -eq 1 ] || exit 0

# If VERSION is already staged, the human (or a prior run) bumped it — defer.
if echo "$STAGED" | grep -q '^\.claude/commands/plan-w-team/VERSION$'; then
    echo "pre-commit-pwt-version-bump: VERSION already staged, skipping auto-bump" >&2
    exit 0
fi

# CHANGELOG sha-backfill commits update an already-shipped release's sha only —
# bumping VERSION for them would mint a phantom release. Skip explicitly.
if printf '%s' "$COMMAND" | grep -qi 'backfill'; then
    echo "pre-commit-pwt-version-bump: CHANGELOG sha backfill commit, skipping auto-bump" >&2
    exit 0
fi

# Build the text to classify. COMMAND is now fully unescaped (jq), so a
# `-m "feat(scope): ..."` subject is intact. Prefer an explicit -F message file
# or the interactive COMMIT_EDITMSG when there's no inline -m.
CLASSIFY_TEXT="$COMMAND"
case "$COMMAND" in
    *" -F "*)
        MSG_FILE="${COMMAND#* -F }"; MSG_FILE="${MSG_FILE%% *}"
        [ -f "$MSG_FILE" ] && CLASSIFY_TEXT=$(cat "$MSG_FILE" 2>/dev/null || echo "$COMMAND")
        ;;
esac
if [ "$CLASSIFY_TEXT" = "$COMMAND" ] && ! printf '%s' "$COMMAND" | grep -qE "\-m[[:space:]\"']"; then
    # No inline -m and no -F → interactive commit; classify the prepared message.
    [ -f "$PROJECT_ROOT/.git/COMMIT_EDITMSG" ] && CLASSIFY_TEXT=$(cat "$PROJECT_ROOT/.git/COMMIT_EDITMSG" 2>/dev/null || echo "$COMMAND")
fi

# Classify bump kind from the FIRST conventional-commit token in the text.
# Default PATCH (conservative — never silently MAJOR).
BUMP="patch"
PREFIX=$(printf '%s' "$CLASSIFY_TEXT" | grep -oiE '(feat|fix|docs|chore|refactor|test|perf|style|build|ci)(\([^)]*\))?!?:' | head -1)
if printf '%s' "$CLASSIFY_TEXT" | grep -q 'BREAKING[ _-]CHANGE' || printf '%s' "$PREFIX" | grep -q '!:'; then
    BUMP="major"
elif printf '%s' "$PREFIX" | grep -qiE '^feat'; then
    BUMP="minor"
elif printf '%s' "$PREFIX" | grep -qiE '^(fix|docs|chore|refactor|test|perf|style|build|ci)'; then
    BUMP="patch"
fi

CURRENT=$(head -1 "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')
# Semver parse: MAJOR.MINOR.PATCH (no pre-release/build suffix support — KISS).
if ! echo "$CURRENT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "pre-commit-pwt-version-bump: VERSION '$CURRENT' is not semver MAJOR.MINOR.PATCH; skipping" >&2
    exit 0
fi
MAJOR=$(echo "$CURRENT" | cut -d. -f1)
MINOR=$(echo "$CURRENT" | cut -d. -f2)
PATCH=$(echo "$CURRENT" | cut -d. -f3)

case "$BUMP" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"

printf '%s\n' "$NEW_VERSION" > "$VERSION_FILE"
git -C "$PROJECT_ROOT" add "$VERSION_FILE" 2>/dev/null || true

echo "pre-commit-pwt-version-bump: ${CURRENT} → ${NEW_VERSION} (${BUMP}) — staged with commit" >&2
exit 0
