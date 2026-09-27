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

# ── ONE lead session per host (Model Tiering v7 2026-09-02; v9 2.50.0) ──────────
# Every interactive session takes the model in ~/.claude/settings.json (Opus 5.5).
# Model Tiering v9 (operator ruling 2026-09-22) retired Fable 5.1 — no Fable
# anywhere — so CLAUDE_LEAD=1 now adds `--model claude-opus-5-5`; what still sets
# the lead apart is its larger compaction window (CP_LEAD_WINDOW, below). It holds
# a pid lock (CP_FABLE_LEAD_LOCK — name kept for compatibility, default
# ~/.config/claude-pattern/fable-lead.pid); a second CLAUDE_LEAD=1 launch while that
# lead is live gets the non-lead model and window with a notice. An explicit
# --model in argv always wins.
# CLAUDE_LEAD reaches a child's environment ONLY from the launch that holds the lock
# (cand-launcher-lead-marker): a downgraded second lead, an explicit --model launch
# and a utility subcommand all run their child with it removed (`env -u`, child env
# only — the operator's shell keeps its export), so CLAUDE_LEAD=1 inside a session
# means "this is the lead". The gate runs in a $(…) subshell and cannot do this itself.
# The lead compacts at CP_LEAD_WINDOW (300000, 2026-09-08); every other terminal
# at 250000; an explicit CLAUDE_CODE_AUTO_COMPACT_WINDOW wins over both.
# Seams: CP_LEAD_MODEL, CP_NONLEAD_MODEL, CP_LEAD_WINDOW, CP_FABLE_LEAD_LOCK; tests override
# _cp_fable_lead_live to simulate a live lead.
_cp_fable_lead_live() {   # $1 = lock file; true when its pid is alive AND hosts a claude child
  local p; p="$(cat "$1" 2>/dev/null)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && pgrep -P "$p" -f claude >/dev/null 2>&1
}
# CP_LEAD_MODEL / CP_NONLEAD_MODEL are checked on a key: the id lower-cased, with any provider
# prefix, Bedrock -vN suffix, @version, [1m] tag and -YYYYMMDD date stripped. Fable, claude-opus-5
# in any provider form, a CLI-version-dependent alias (opus, opusplan, best, default), or a value
# with whitespace inside it is refused with one warning and the launch runs claude-opus-5-5.
# Anything else launches as given, trimmed.
_cp_lead_model() {   # $1 = variable name (for the warning), $2 = requested model
  local v="$2" k r=""
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  k="$(printf '%s' "$v" | LC_ALL=C tr -d '\200-\377[:space:]' | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's/\[.*$//; s#^.*/##; s/@.*$//; s/-v[0-9]+(:[0-9]+)?$//; s/^([a-z0-9-]+\.)?anthropic\.//; s/-[0-9]{8}$//')"
  case "$k" in
    '') v=claude-opus-5-5 ;;
    *fable*|claude-opus-5|opus|opusplan|best|default) r=1 ;;
  esac
  case "$v" in *[[:space:]]*) r=1 ;; esac
  if [ -n "$r" ]; then
    echo "⚠️  $1=$v refused (Model Tiering v9: no Fable, no claude-opus-5, no CLI-version-dependent alias, no whitespace) — using claude-opus-5-5." >&2
    v=claude-opus-5-5
  fi
  printf '%s\n' "$v"
}
_cp_fable_lead_gate() {   # prints the --model args to add (nothing when not a lead launch)
  [ "${CLAUDE_LEAD:-0}" = 1 ] || return 0
  local lock="${CP_FABLE_LEAD_LOCK:-$HOME/.config/claude-pattern/fable-lead.pid}" m
  mkdir -p "${lock:h}" 2>/dev/null
  if _cp_fable_lead_live "$lock" && [ "$(cat "$lock" 2>/dev/null)" != "$$" ]; then
    m="$(_cp_lead_model CP_NONLEAD_MODEL "${CP_NONLEAD_MODEL:-claude-opus-5-5}")"
    echo "⚠️  A lead session is already live (pid $(cat "$lock")) — one lead per host (Model Tiering v7/v9). Launching this one as a non-lead on $m." >&2
    printf -- "--model\n%s\n" "$m"
  else
    printf "%s\n" "$$" > "$lock"
    printf -- "--model\n%s\n" "$(_cp_lead_model CP_LEAD_MODEL "${CP_LEAD_MODEL:-claude-opus-5-5}")"
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
  # Window (tokens; documented knob). Default 250000 for a terminal (2026-09-08).
  # History: v6 ran 250K; Model Tiering v7 (2026-09-02) cut terminals to 150K because
  # burn ∝ turns × context and 4–5 Fable terminals ate a 5-hour window in a morning.
  # Measured 2026-09-08 from transcript usage: the FIXED prompt floor (tool schemas, both
  # CLAUDE.md files, memory index, MCP servers) is 74–82K in claude-pattern/cleanscale
  # sessions, not the ~40K v7 assumed, and auto-compact fires at ≈77% of the window
  # (114–133K observed). 150K therefore left ~32K of working room: compaction every
  # 7–12 minutes (20 compactions in one claude-pattern session, 680 in a cleanscale
  # terminal), each one re-ingesting the 74–82K floor — MORE burn than the room it
  # saved, plus lost context. 250K gives ~110K of room; the lead (CP_LEAD_WINDOW,
  # 300000) ~150K. Lanes are unaffected (PWT_BG_AUTOCOMPACT, 200K on the mac-mini).
  # A value the USER set always wins; a value THIS launcher exported on an earlier
  # launch in the same shell is re-derived every launch (plain → 250K, lead → 300K),
  # so it is never mistaken for the user's.
  local _cp_win_explicit=1
  if [ -z "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" ] || [ "${CLAUDE_CODE_AUTO_COMPACT_WINDOW}" = "${_CP_WINDOW_LAUNCHER_SET:-}" ]; then
    _cp_win_explicit=0; CLAUDE_CODE_AUTO_COMPACT_WINDOW=250000
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
    local -a _cp_model_args _cp_lead_env; _cp_model_args=(); _cp_lead_env=(-u CLAUDE_LEAD)
    if [[ " $* " != *" --model "* && " $* " != *" --model="* ]]; then
      _cp_model_args=("${(@f)$(_cp_fable_lead_gate)}")
      [ -n "${_cp_model_args[1]:-}" ] || _cp_model_args=()
      # The lead is the CLAUDE_LEAD=1 launch that HOLDS the lead lock (this shell's pid). Only
      # it passes CLAUDE_LEAD=1 to its child and compacts at CP_LEAD_WINDOW (v7 lead window);
      # a downgraded second lead keeps the terminal default and loses the marker; explicit env
      # wins for the window.
      if [ "${CLAUDE_LEAD:-0}" = 1 ] && [ "$(cat "${CP_FABLE_LEAD_LOCK:-$HOME/.config/claude-pattern/fable-lead.pid}" 2>/dev/null)" = "$$" ]; then
        _cp_lead_env=(CLAUDE_LEAD=1)
        if [ "$_cp_win_explicit" = 0 ]; then
          export CLAUDE_CODE_AUTO_COMPACT_WINDOW="${CP_LEAD_WINDOW:-300000}"; _CP_WINDOW_LAUNCHER_SET="$CLAUDE_CODE_AUTO_COMPACT_WINDOW"
        fi
      fi
    fi
    # `env` execs claude in place, so the session stays a direct child of this shell
    # (_cp_fable_lead_live's `pgrep -P` depends on that).
    command env "${_cp_lead_env[@]}" claude --allowedTools "Grep,Glob" "${_cp_model_args[@]}" "$@"
    local _cp_rc=$?; _cp_fable_lead_release; return $_cp_rc
  else
    # Utility subcommands (`claude mcp list`, `claude agents`, …) are never the lead.
    command env -u CLAUDE_LEAD claude "$@"
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

# CLI 2.1.268 gated the task-tracking tools (TaskCreate/Get/Update/List, TodoWrite)
# to pre-Claude-5 models. Every /plan-w-team tier runs on Opus 5.5 / Sonnet 5
# and the Step 2-8 task graph is built on those tools, so re-enable
# them explicitly (mirrors .claude/settings.json env; uplift 2026-09-18).
export CLAUDE_CODE_ENABLE_TODO_TOOLS=1
