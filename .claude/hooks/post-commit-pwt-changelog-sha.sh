#!/bin/bash
# Post-Commit /plan-w-team CHANGELOG SHA Backfill Hook
# PostToolUse hook (matcher: Bash) that resolves a `(PENDING)` placeholder in the
# skill CHANGELOG to the short SHA of the commit that just landed.
#
# WHY A FOLLOW-UP COMMIT AND NOT `--amend`: amending rewrites the commit, which
# changes its own hash — so a SHA written into amended content would name a commit
# that no longer exists. A SHA cannot exist before the commit it names, so the
# one-commit-later backfill is the only correct resolution. This hook does not
# change that; it removes the "remember to do it" step, which is what actually
# failed (1.65.1 needed a manual backfill; 1.57.0 never got one at all).
#
# Triggers when ALL of:
#   - the Bash command was `git commit` (not --amend)
#   - the command is not itself a backfill commit (recursion guard)
#   - the CHANGELOG in HEAD carries a `(PENDING)` release heading — i.e. the entry
#     actually landed, so HEAD is the commit the heading should name
#
# Fail-open by construction: every missing tool, path or git failure exits 0. This
# hook must never block or fail a commit — a missing SHA is a traceability nit, a
# blocked commit is a work stoppage.
#
# Spec: .claude/commands/plan-w-team/shared/versioning.md
# Companion: .claude/hooks/pre-commit-pwt-version-bump.sh (bumps VERSION)
#
# Exit codes:
#   0 - always (informational; may create one follow-up commit)

set -uo pipefail

INPUT=$(cat 2>/dev/null || echo "")

# Extract the Bash command. Same jq-first idiom as pre-commit-pwt-version-bump.sh:
# a plain grep truncates at the first ESCAPED quote inside `git commit -m "..."`.
if command -v jq >/dev/null 2>&1; then
    COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // empty' 2>/dev/null)
else
    COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "")
fi

# Only fire on `git commit` (not amend, not other git verbs).
echo "$COMMAND" | grep -qE '\bgit[[:space:]]+commit\b' || exit 0
echo "$COMMAND" | grep -q '\-\-amend' && exit 0

# Recursion guard: the backfill commit this hook creates must not re-trigger it.
printf '%s' "$COMMAND" | grep -qi 'backfill' && exit 0

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$PROJECT_ROOT" ] && exit 0

CHANGELOG_REL=".claude/commands/plan-w-team/CHANGELOG.md"
CHANGELOG="$PROJECT_ROOT/$CHANGELOG_REL"
[ -f "$CHANGELOG" ] || exit 0

# Only act when the PENDING heading actually LANDED in HEAD. If it exists solely in
# the working tree the commit did not include it (or failed), and naming HEAD would
# attribute the release to the wrong commit.
#
# CAPTURE FIRST, then match — do NOT pipe `git show` into `grep -q` under
# `set -o pipefail`. `grep -q` exits on the first match, SIGPIPEs the still-writing
# `git show`, and pipefail then reports the PIPELINE as failed even though the match
# SUCCEEDED. That inverts this guard into "never fire". It is size-dependent: a
# short CHANGELOG completes before grep exits and looks fine, while the real
# 3400-line file always breaks the pipe (observed 2026-08-03 on 1.66.0).
HEAD_CHANGELOG=$(git -C "$PROJECT_ROOT" show "HEAD:$CHANGELOG_REL" 2>/dev/null || echo "")
[ -n "$HEAD_CHANGELOG" ] || exit 0
printf '%s\n' "$HEAD_CHANGELOG" \
    | grep -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\][^(]*\(PENDING\)' >/dev/null || exit 0

# Refuse to bundle: a dirty tree means this commit would sweep unrelated work into
# a docs() commit. Surface it instead — the human backfills manually.
DIRTY=$(git -C "$PROJECT_ROOT" status --porcelain -- "$CHANGELOG_REL" 2>/dev/null || echo "")
OTHER_STAGED=$(git -C "$PROJECT_ROOT" diff --cached --name-only 2>/dev/null || echo "")
if [ -n "$OTHER_STAGED" ]; then
    echo "post-commit-pwt-changelog-sha: index not empty after commit — skipping auto-backfill" >&2
    exit 0
fi
if [ -n "$DIRTY" ]; then
    echo "post-commit-pwt-changelog-sha: CHANGELOG has uncommitted edits — skipping auto-backfill" >&2
    exit 0
fi

SHA=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "")
[ -z "$SHA" ] && exit 0

# Reuse the captured copy — `grep -m1` exits early too and would SIGPIPE a
# `git show` pipeline exactly like the guard above did.
VER=$(printf '%s\n' "$HEAD_CHANGELOG" \
    | grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' | head -1 | tr -d '#[] ' || echo "")

# Resolve PENDING -> SHA in the working tree, then commit just that file.
if command -v perl >/dev/null 2>&1; then
    perl -pi -e "s/\\(PENDING\\)/($SHA)/ if /^## \\[[0-9]+\\.[0-9]+\\.[0-9]+\\]/" "$CHANGELOG" 2>/dev/null || exit 0
else
    sed -i.bak -E "s/^(## \[[0-9]+\.[0-9]+\.[0-9]+\][^(]*)\(PENDING\)/\1($SHA)/" "$CHANGELOG" 2>/dev/null || exit 0
    rm -f "$CHANGELOG.bak" 2>/dev/null || true
fi

git -C "$PROJECT_ROOT" add -- "$CHANGELOG_REL" 2>/dev/null || exit 0
git -C "$PROJECT_ROOT" commit -q -m "docs(pwt): backfill the ${VER:-release} CHANGELOG SHA ($SHA)" 2>/dev/null || exit 0

echo "post-commit-pwt-changelog-sha: backfilled ${VER:-release} -> $SHA" >&2
exit 0
