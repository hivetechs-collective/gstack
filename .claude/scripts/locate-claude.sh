#!/bin/sh
# locate-claude.sh — emit absolute path to the Claude Code CLI binary.
#
# Why this exists: hooks and subscripts inherit a stripped $PATH from the
# Claude Code harness. A bare `claude --bg` then fails with
# "env: claude: No such file or directory" because the install directory
# (/Users/$USER/.local/bin by default on macOS) is not on the inherited PATH.
#
# Resolution order:
#   1. command -v claude            (honor any caller-installed PATH override / test stub)
#   2. /Users/$USER/.local/bin/claude   (Claude Code official installer default)
#   3. /opt/homebrew/bin/claude         (Homebrew on Apple Silicon)
#   4. /usr/local/bin/claude            (Homebrew on Intel / general /usr/local)
#   5. $HOME/.npm-global/bin/claude     (npm global install without sudo)
#
# Stdout (exit 0): absolute path to the claude binary, no trailing noise.
# Stderr (exit 1): a one-line error followed by every path tried, so the
#                   user can see exactly where to install or why discovery failed.
#
# POSIX sh — no bashisms. Safe to source or invoke from any shell.

# ─── Step 1: prefer command -v (caller has a working PATH or test stub) ─────
if command -v claude >/dev/null 2>&1; then
    p=$(command -v claude)
    # Resolve symlinks where realpath is available; fall back to the raw path.
    if command -v realpath >/dev/null 2>&1; then
        realpath "$p" 2>/dev/null || printf '%s\n' "$p"
    else
        printf '%s\n' "$p"
    fi
    exit 0
fi

# ─── Step 2: fallback cascade ───────────────────────────────────────────────
# Build the candidate list. $USER and $HOME may be empty in stripped envs;
# in that case the corresponding entries just won't match any real file.
USER_DIR="/Users/${USER}/.local/bin/claude"
HOMEBREW_ARM="/opt/homebrew/bin/claude"
HOMEBREW_INTEL="/usr/local/bin/claude"
NPM_GLOBAL="${HOME}/.npm-global/bin/claude"

CANDIDATES="$USER_DIR $HOMEBREW_ARM $HOMEBREW_INTEL $NPM_GLOBAL"

for candidate in $CANDIDATES; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
        if command -v realpath >/dev/null 2>&1; then
            realpath "$candidate" 2>/dev/null || printf '%s\n' "$candidate"
        else
            printf '%s\n' "$candidate"
        fi
        exit 0
    fi
done

# ─── Step 3: not found — emit clear error ───────────────────────────────────
{
    echo "locate-claude.sh: claude binary not found in PATH or known install locations:"
    echo "  searched PATH via 'command -v claude' (no match)"
    for candidate in $CANDIDATES; do
        echo "  searched: $candidate"
    done
    echo ""
    echo "Hint: install Claude Code (https://claude.com/claude-code) or set PATH to include the install directory."
} >&2
exit 1
