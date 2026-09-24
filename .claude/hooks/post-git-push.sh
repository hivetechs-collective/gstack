#!/bin/bash
# PostToolUse hook for git push — the post-push full-suite confirm, plus an
# OPT-IN GitHub Actions status poll.
# Generic template - works with any project
#
# Wiring (.claude/settings.json): matcher "Bash" with three handlers whose `if`
# rules are "Bash(git push*)", "Bash(git -C *)" and "Bash(git -c *)", each with a
# 60 s timeout. A matcher compares the TOOL NAME only; `if` is checked against
# each subcommand of a parsed command line (quotes resolved), with NO wrapper
# stripping (unlike permission rules), and a command the CLI cannot parse
# simply always matches. So these reach this hook: `git push …`, `git -C dir
# push`, `git -c k=v push`, and any of them as one part of `&&` / `;` / `|`
# chains or a `( … )` subshell (`cd x && git push`). These do NOT: `timeout 60
# git push`, `nohup`/`time`/`sudo … git push`, `git --no-pager push`, `git
# --git-dir=… push`, `/usr/bin/git push`, `sh -c 'git push'`, and pushes made
# inside a script or make target. To confirm one of those, run the confirm by
# hand with no --command, pointed at the pushed checkout: `…/plan-w-team-post-
# push-confirm.sh --launch --cwd <checkout>` (git state decides; the push must be
# inside the reflog window), plus `--relaunch` to skip that window
# (docs/operations/post-push-confirm.md).
# The `if` is only a pre-filter (`git -C dir status` passes it): this hook
# re-checks the command itself (PWT_PUSH_RE below) and exits at once unless it
# has a git-push segment.
#
# ENV
#   PWT_DISABLE_POST_PUSH_CONFIRM=1   no confirm launch (docs/operations/post-push-confirm.md)
#   PWT_POST_PUSH_CI_POLL_ENABLE=1    also poll `gh run list` after the push (OFF by
#                                     default: it sleeps, needs gh + a GitHub remote,
#                                     and most consumers build locally, not in Actions)

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB_DIR="$PROJECT_ROOT/.claude/lib"

# ─── what ran, and where ────────────────────────────────────────────────────
PWT_PUSH_CMD=""
PWT_HOOK_CWD=""
if [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
    PWT_HOOK_INPUT=$(cat 2>/dev/null || echo "")
    PWT_PUSH_CMD=$(printf '%s' "$PWT_HOOK_INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
    PWT_HOOK_CWD=$(printf '%s' "$PWT_HOOK_INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
fi

# No git-push segment → nothing to do (the settings `if` also admits every
# `git -C … <anything>` / `git -c … <anything>`). `git`, its global options
# (-C dir, -c k=v, --flag), then `push` as the subcommand, inside one ; & |
# segment. An option or its argument is a word whose pieces are plain chars,
# "…" or '…' strings, so a quote may open mid-word and hold spaces:
# `git -C ./"sp ace" push`, `git -c core.sshCommand="ssh -o X=1" push` (the
# 2.53.0 round-2 pattern took a quoted argument only when the WHOLE word was
# quoted, and dropped both). A leading `if`/`!`/`VAR=…` is fine: any blank,
# `(` or `{` may precede `git`. This is only a pre-filter — the confirm parses.
_pwt_q="'"
_pwt_w='([^[:space:];&|"'$_pwt_q']|"[^"]*"|'$_pwt_q'[^'$_pwt_q']*'$_pwt_q')'   # a word piece
_pwt_w1='([^-[:space:];&|"'$_pwt_q']|"[^"]*"|'$_pwt_q'[^'$_pwt_q']*'$_pwt_q')' # … not a leading -
PWT_PUSH_RE='(^|[;&|({[:space:]])([^[:space:];&|]*/)?git([[:space:]]+-'"$_pwt_w"'+([[:space:]]+'"$_pwt_w1$_pwt_w"'*)?)*[[:space:]]+push([[:space:];&|)}]|$)'
if ! printf '%s\n' "$PWT_PUSH_CMD" | grep -Eq "$PWT_PUSH_RE"; then
    exit 0
fi

# Source configuration helper
if [ -f "$LIB_DIR/config.sh" ]; then
    source "$LIB_DIR/config.sh"
fi

PROJECT_NAME="${PROJECT_NAME:-$(get_project_name 2>/dev/null || echo 'Project')}"

# Post-push full-suite confirm (2.51.0, docs/operations/post-push-confirm.md): a
# commit may have passed the gate on a targeted retest, so a push that moves the
# default branch to a commit without a matching FULL green verdict gets one
# detached, niced, bounded full run of that commit. Launch-and-return; it never
# blocks the push or this hook. It reads git state (origin/<default> and its
# reflog) in the repo the push ran in, so a dry run or a feature push launches
# nothing. The hook input cwd is the cwd AFTER the command ran, so the confirm
# tries, in order, the command's `git -C` / `cd` target, the hook cwd,
# CLAUDE_PROJECT_DIR and this checkout, takes the first that is a git work tree,
# and logs a one-line note when it had to fall back or skip.
# Kill switch: PWT_DISABLE_POST_PUSH_CONFIRM=1.
PWT_POST_PUSH_CONFIRM="$PROJECT_ROOT/.claude/scripts/plan-w-team-post-push-confirm.sh"
if [ -x "$PWT_POST_PUSH_CONFIRM" ] && [ "${PWT_DISABLE_POST_PUSH_CONFIRM:-0}" != "1" ]; then
    if [ -n "$PWT_HOOK_CWD" ]; then
        "$PWT_POST_PUSH_CONFIRM" --launch --root "$PROJECT_ROOT" --cwd "$PWT_HOOK_CWD" --command "$PWT_PUSH_CMD" 2>/dev/null || true
    else
        "$PWT_POST_PUSH_CONFIRM" --launch --root "$PROJECT_ROOT" --command "$PWT_PUSH_CMD" 2>/dev/null || true
    fi
fi

# ─── opt-in: GitHub Actions status poll ─────────────────────────────────────
[ "${PWT_POST_PUSH_CI_POLL_ENABLE:-0}" = "1" ] || exit 0

echo ""
echo "==============================================================="
echo "  CI MONITORING (Auto-triggered after git push)"
echo "==============================================================="

# Check if gh CLI is available
if ! command -v gh &> /dev/null; then
    echo " GitHub CLI (gh) not found - cannot check CI status"
    echo "   Install: brew install gh"
    exit 0
fi

# Wait a moment for GitHub to register the push
sleep 2

echo ""
echo " Recent CI Runs:"
echo "---------------------------------------------------------------"

# Get the most recent run
LATEST_RUN=$(gh run list --limit 1 --json databaseId,status,conclusion,name,headBranch 2>/dev/null)

if [ -z "$LATEST_RUN" ] || [ "$LATEST_RUN" = "[]" ]; then
    echo "   No CI runs found. Workflow may not be triggered yet."
    echo "   Check again in 30 seconds: gh run list --limit 1"
else
    # Parse and display
    gh run list --limit 3 2>/dev/null || echo "   Unable to fetch run list"
fi

echo ""
echo "---------------------------------------------------------------"
echo " REQUIRED ACTIONS:"
echo "   - Monitor until completion: gh run view <run-id> --watch"
echo "   - If failure detected: gh run view <run-id> --log-failed"
echo "   - Do NOT start new features until CI passes"
echo "==============================================================="

# Check for immediate failures (within 5 seconds - fast checks)
FAILED=$(gh run list --limit 1 --json conclusion --jq '.[0].conclusion // empty' 2>/dev/null)
if [ "$FAILED" = "failure" ]; then
    echo ""
    echo " IMMEDIATE CI FAILURE DETECTED"
    echo "   Run: gh run view <run-id> --log-failed"
    echo "   Fix before continuing with development"
fi

exit 0
