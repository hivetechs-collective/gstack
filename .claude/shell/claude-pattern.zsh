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

# Multi-account rotation CLI, resolved relative to THIS sourced file so it works
# from any clone location on any machine (`${(%):-%x}` = the file being sourced;
# :h:h climbs .claude/shell -> .claude). Used by `claude-account` (advisory) and
# by the fleet/bg rotation. Absent/older clone => `claude-account` reports it.
_CP_SHELL_SELF="${(%):-%x}"
_CP_ACCOUNTS_CLI="${_CP_SHELL_SELF:A:h:h}/commands/plan-w-team/accounts/accounts.sh"

# ── Model Tiering v7 (2026-09-02): ONE Fable lead session per host ─────────────
# Fable is the design tier only. Every interactive session takes the model in
# ~/.claude/settings.json (claude-opus-4-8 under v7); the ONE session that needs
# Fable is launched with CLAUDE_LEAD=1, which adds `--model claude-fable-5-1` and
# holds a pid lock (CP_FABLE_LEAD_LOCK, default ~/.config/claude-pattern/fable-lead.pid).
# A second CLAUDE_LEAD=1 launch while that lead is live is downgraded to Opus 4.8
# with a notice — never a second Fable. An explicit --model in argv always wins.
# The lead compacts at CP_LEAD_WINDOW (200000, founder 2026-09-02); every other terminal
# at 150000; an explicit CLAUDE_CODE_AUTO_COMPACT_WINDOW wins over both.
# Seams: CP_LEAD_MODEL, CP_NONLEAD_MODEL, CP_LEAD_WINDOW, CP_FABLE_LEAD_LOCK; tests override
# _cp_fable_lead_live to simulate a live lead.
_cp_fable_lead_live() {   # $1 = lock file; true when its pid is alive AND hosts a claude child
  local p; p="$(cat "$1" 2>/dev/null)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && pgrep -P "$p" -f claude >/dev/null 2>&1
}
_cp_fable_lead_gate() {   # prints the --model args to add (nothing when not a lead launch)
  [ "${CLAUDE_LEAD:-0}" = 1 ] || return 0
  local lock="${CP_FABLE_LEAD_LOCK:-$HOME/.config/claude-pattern/fable-lead.pid}"
  mkdir -p "${lock:h}" 2>/dev/null
  if _cp_fable_lead_live "$lock" && [ "$(cat "$lock" 2>/dev/null)" != "$$" ]; then
    echo "⚠️  A Fable lead session is already live (pid $(cat "$lock")) — one Fable lead per host (Model Tiering v7). Launching this one on ${CP_NONLEAD_MODEL:-claude-opus-4-8}." >&2
    printf -- "--model\n%s\n" "${CP_NONLEAD_MODEL:-claude-opus-4-8}"
  else
    printf "%s\n" "$$" > "$lock"
    printf -- "--model\n%s\n" "${CP_LEAD_MODEL:-claude-fable-5-1}"
  fi
}
_cp_fable_lead_release() {
  local lock="${CP_FABLE_LEAD_LOCK:-$HOME/.config/claude-pattern/fable-lead.pid}"
  [ "$(cat "$lock" 2>/dev/null)" = "$$" ] && rm -f "$lock"
  return 0
}

# Claude Code launcher — per-repo task lists and long-run defaults. It does NOT
# rotate the account (interactive identity is keychain/`/login` bound; an env
# token can't switch it). The status line shows which account to move to, and
# `claude-account` prints the full picture.
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
  # Window (tokens; documented knob). Default 150000 for a terminal — Model Tiering v7
  # (2026-09-02): burn ∝ turns × context; 250K (v6) let 4–5 Fable terminals eat a 5-hour
  # window in a morning. The ONE Fable lead gets CP_LEAD_WINDOW (200000; founder 2026-09-02:
  # a design/crisis session loses the most at every compaction — ~40K of fixed prompt
  # overhead re-ingested each time plus re-orientation reads — and one lead process was
  # never where the burn came from). A value the USER set always wins; a value THIS
  # launcher exported on an earlier launch in the same shell is re-derived every launch
  # (plain → 150K, lead → 200K), so it is never mistaken for the user's.
  local _cp_win_explicit=1
  if [ -z "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" ] || [ "${CLAUDE_CODE_AUTO_COMPACT_WINDOW}" = "${_CP_WINDOW_LAUNCHER_SET:-}" ]; then
    _cp_win_explicit=0; CLAUDE_CODE_AUTO_COMPACT_WINDOW=150000
  fi
  export CLAUDE_CODE_AUTO_COMPACT_WINDOW; _CP_WINDOW_LAUNCHER_SET="$CLAUDE_CODE_AUTO_COMPACT_WINDOW"
  : "${BASH_DEFAULT_TIMEOUT_MS:=300000}"
  export BASH_DEFAULT_TIMEOUT_MS
  # Restore built-in Grep/Glob tools (removed by default since CC 2.1.216;
  # listing them in --allowedTools flips the internal searchToolsOptIn).
  # Only inject on session launches — the variadic flag would swallow
  # subcommands like `claude mcp list` if always prepended.
  if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
    # Interactive session launch (no args, or a flag like -r /
    # --dangerously-skip-permissions). We deliberately do NOT rotate the account
    # here: interactive Claude Code ties its identity (status line, /usage,
    # Remote Control, ~/.claude.json) to the keychain /login, and a
    # CLAUDE_CODE_OAUTH_TOKEN env token can't switch it — it only redirected
    # model requests while breaking Remote Control and leaving the status line on
    # the old account (2026-08-31 finding). Interactive rotation is ADVISORY:
    # the status line shows the account to move to, and `claude-account` /
    # `/login` switch it. Fleet/bg-worker rotation is separate and unaffected.
    local -a _cp_model_args; _cp_model_args=()
    if [[ " $* " != *" --model "* && " $* " != *" --model="* ]]; then
      _cp_model_args=("${(@f)$(_cp_fable_lead_gate)}")
      [ -n "${_cp_model_args[1]:-}" ] || _cp_model_args=()
      # v7 lead window: only the launch that HOLDS the lead lock (this shell's pid) compacts at
      # CP_LEAD_WINDOW; a downgraded second lead keeps the terminal default; explicit env wins.
      if [ "$_cp_win_explicit" = 0 ] && [ "$(cat "${CP_FABLE_LEAD_LOCK:-$HOME/.config/claude-pattern/fable-lead.pid}" 2>/dev/null)" = "$$" ]; then
        export CLAUDE_CODE_AUTO_COMPACT_WINDOW="${CP_LEAD_WINDOW:-200000}"; _CP_WINDOW_LAUNCHER_SET="$CLAUDE_CODE_AUTO_COMPACT_WINDOW"
      fi
    fi
    command claude --allowedTools "Grep,Glob" "${_cp_model_args[@]}" "$@"
    local _cp_rc=$?; _cp_fable_lead_release; return $_cp_rc
  else
    # Utility subcommands (`claude mcp list`, `claude agents`, …).
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

# claude-account — advisory account picker for INTERACTIVE sessions. Interactive
# Claude Code can't be rotated by an env token (its identity — status line,
# /usage, Remote Control, ~/.claude.json — is keychain/`/login` bound), so this
# TELLS you which account has the most 5h/7d headroom; you switch with `/login`.
# Fleet/bg-worker rotation is automatic and separate (lane_cred.py).
claude-account() {
  if [ ! -x "$_CP_ACCOUNTS_CLI" ]; then
    echo "claude-account: rotation CLI not found (need a claude-pattern clone)."
    return 1
  fi
  "$_CP_ACCOUNTS_CLI" status || return $?
  local best
  best="$("$_CP_ACCOUNTS_CLI" which-account 2>/dev/null)"
  echo
  if [ -n "$best" ] && [ "$best" != "(ambient)" ]; then
    echo "→ Most headroom right now: '$best' (the '*' row above)."
    echo "  To use it: type  /login  in Claude and sign in as that row's EMAIL."
    echo "  (Interactive sessions don't auto-switch — this is advisory.)"
  else
    echo "→ Rotation dormant or every account is hot — stay on your current login."
  fi
}

# /plan-w-team long-run support — let the Stop hook keep a multi-hour /goal
# pipeline alive instead of halting at the default cap.
export CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=200
