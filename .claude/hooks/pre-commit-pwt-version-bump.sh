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
COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")

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
        .claude/commands/plan-w-team/*|.claude/scripts/pwt-goal.sh)
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

# Extract commit message: -m flag (short form) or -F file path (long form).
# Falls back to .git/COMMIT_EDITMSG if both are absent (interactive commit).
COMMIT_MSG=""
if echo "$COMMAND" | grep -qE '\-m[[:space:]]'; then
    COMMIT_MSG=$(echo "$COMMAND" | sed -n "s/.*-m[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    [ -z "$COMMIT_MSG" ] && COMMIT_MSG=$(echo "$COMMAND" | sed -n 's/.*-m[[:space:]]*\([^[:space:]]*\).*/\1/p')
fi
if [ -z "$COMMIT_MSG" ] && echo "$COMMAND" | grep -qE '\-F[[:space:]]'; then
    MSG_FILE=$(echo "$COMMAND" | sed -n 's/.*-F[[:space:]]*\([^[:space:]]*\).*/\1/p')
    [ -f "$MSG_FILE" ] && COMMIT_MSG=$(cat "$MSG_FILE" 2>/dev/null || echo "")
fi
if [ -z "$COMMIT_MSG" ] && [ -f "$PROJECT_ROOT/.git/COMMIT_EDITMSG" ]; then
    COMMIT_MSG=$(cat "$PROJECT_ROOT/.git/COMMIT_EDITMSG" 2>/dev/null || echo "")
fi

# Classify bump kind. Default PATCH (conservative — never silently MAJOR).
BUMP="patch"
if echo "$COMMIT_MSG" | grep -qE 'BREAKING[ _-]CHANGE|^[a-z]+(\([^)]+\))?!:'; then
    BUMP="major"
elif echo "$COMMIT_MSG" | grep -qE '^feat(\([^)]+\))?:'; then
    BUMP="minor"
elif echo "$COMMIT_MSG" | grep -qE '^(fix|docs|chore|refactor|test|perf|style|build|ci)(\([^)]+\))?:'; then
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
