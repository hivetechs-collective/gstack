#!/bin/bash
# Claude Code Shell Integration
# Add to ~/.zshrc or ~/.bashrc:
#   source /path/to/claude-pattern/.claude/shell-integration.sh
#
# Or copy the functions below directly to your shell profile.

# ============================================================================
# CLAUDE WRAPPER - Auto-sets project-specific environment
# ============================================================================
claude() {
  # Auto-set task list ID based on git repo name
  if git rev-parse --show-toplevel &>/dev/null 2>&1; then
    export CLAUDE_CODE_TASK_LIST_ID="$(basename "$(git rev-parse --show-toplevel)")"
  fi

  # Set recommended defaults if not already set
  : "${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:=80}"
  : "${BASH_DEFAULT_TIMEOUT_MS:=300000}"

  export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
  export BASH_DEFAULT_TIMEOUT_MS

  # Run claude with all arguments
  command claude "$@"
}

# ============================================================================
# CONVENIENCE ALIASES
# ============================================================================

# Quick task list check
alias claude-tasks='claude --print "Show me the current task list with /tasks"'

# Continue last session
alias claude-resume='claude --continue'

# Start with specific model
alias claude-opus='claude --model opus'
alias claude-sonnet='claude --model sonnet'

# ============================================================================
# VERIFICATION
# ============================================================================
claude-env() {
  echo "Claude Code Environment:"
  echo "  CLAUDE_CODE_TASK_LIST_ID: ${CLAUDE_CODE_TASK_LIST_ID:-<not set>}"
  echo "  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: ${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-95 (default)}"
  echo "  BASH_DEFAULT_TIMEOUT_MS: ${BASH_DEFAULT_TIMEOUT_MS:-120000 (default)}"
  echo ""
  if git rev-parse --show-toplevel &>/dev/null 2>&1; then
    echo "  Current repo: $(basename "$(git rev-parse --show-toplevel)")"
  else
    echo "  Current repo: <not in a git repo>"
  fi
}

# ============================================================================
# INSTALLATION COMPLETE MESSAGE
# ============================================================================
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Being sourced
  echo "✅ Claude Code shell integration loaded"
  echo "   Run 'claude-env' to verify settings"
fi
