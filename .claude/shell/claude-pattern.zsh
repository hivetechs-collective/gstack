# claude-pattern shared shell configuration
# ---------------------------------------------------------------------------
# Installed by .claude/scripts/operator-shell-setup.sh, which puts a managed
# block in ~/.zshrc that sources THIS file from the clone. Never copy it
# anywhere — it updates with `git pull` in the claude-pattern clone, so every
# operator stays current with zero reinstall.
#
# Curated from the maintainer's working configuration: only the pieces that
# pair with this repo's pipeline (/plan-w-team, hooks, statusline) and that
# are portable to a fresh machine. Personal toolchain (nvm, bun, private
# ~/.claude/commands aliases) is deliberately excluded — dead paths on any
# machine but the maintainer's.

# Homebrew on PATH first — every tool Step 0 installs lives there.
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# Seed a CLAUDE.md in any git repo that lacks one. Points at your global
# instructions only when you actually have them — a dangling @-import would
# error on every session start.
_cp_seed_claude_md() {
  { [ -d .git ] && [ ! -f CLAUDE.md ]; } || return 0
  if [ -f "$HOME/.claude/CLAUDE.md" ]; then
    printf '@~/.claude/CLAUDE.md\n\n# Project-Specific Instructions\n' > CLAUDE.md
  else
    printf '# Project-Specific Instructions\n' > CLAUDE.md
  fi
}

cd() { builtin cd "$@" && _cp_seed_claude_md; }

git() {
  command git "$@"
  local _cp_rc=$?
  [ "$1" = "init" ] && [ "$_cp_rc" -eq 0 ] && _cp_seed_claude_md
  return $_cp_rc
}

# Claude Code launcher — per-repo task lists plus the defaults long
# /plan-w-team runs depend on.
claude() {
  _cp_seed_claude_md
  # ANTHROPIC_MODEL outranks the model in ~/.claude/settings.json for every
  # session it reaches, and it is easy to inherit from an old shell config or
  # a tool that exports it. Drop it here so the saved model actually applies,
  # and say so once rather than failing silently.
  if [ -n "${ANTHROPIC_MODEL:-}" ]; then
    echo "⚠️  Ignoring ANTHROPIC_MODEL=$ANTHROPIC_MODEL — your model comes from"
    echo "   ~/.claude/settings.json. Change it any time by typing /model."
    unset ANTHROPIC_MODEL
  fi
  if command git rev-parse --show-toplevel >/dev/null 2>&1; then
    export CLAUDE_CODE_TASK_LIST_ID="$(basename "$(command git rev-parse --show-toplevel)")"
  fi
  unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE   # REMOVED 2026-08-30: undocumented; stacked on AUTO_COMPACT_WINDOW it compacted at ~25% of the window (62K) and thrashed every new session
  : "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:=250000}"   # documented knob (tokens): compact interactive sessions at ~250K instead of the 1M limit (2026-08-30 burn audit)
  export CLAUDE_CODE_AUTO_COMPACT_WINDOW
  : "${BASH_DEFAULT_TIMEOUT_MS:=300000}"
  export BASH_DEFAULT_TIMEOUT_MS
  # Restore built-in Grep/Glob tools (removed by default since CC 2.1.216;
  # listing them in --allowedTools flips the internal searchToolsOptIn).
  # Only inject on session launches — the variadic flag would swallow
  # subcommands like `claude mcp list` if always prepended.
  if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
    command claude --allowedTools "Grep,Glob" "$@"
  else
    command claude "$@"
  fi
}

claude-env() {
  echo "Claude Code Environment:"
  echo "  CLAUDE_CODE_TASK_LIST_ID: ${CLAUDE_CODE_TASK_LIST_ID:-<not set>}"
  echo "  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: ${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-95 (default)}"
  echo "  BASH_DEFAULT_TIMEOUT_MS: ${BASH_DEFAULT_TIMEOUT_MS:-120000 (default)}"
  if command git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "  Current repo: $(basename "$(command git rev-parse --show-toplevel)")"
  fi
}

# /plan-w-team long-run support — let the Stop hook keep a multi-hour /goal
# pipeline alive instead of halting at the default cap.
export CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=200
