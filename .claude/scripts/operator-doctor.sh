#!/bin/bash
# operator-doctor.sh — preflight check for running unattended /goal runs.
#
# For operators (including non-developers): run this once after setup and before
# a long run. It checks every prerequisite and prints the exact fix command for
# anything missing. It never installs or changes anything itself.
#
#   ./.claude/scripts/operator-doctor.sh
#
# Platform-aware: the CHECKS are portable; only the fix HINTS differ by OS —
# Homebrew + keychain + pmset on macOS, apt + creds-file + Windows power settings
# on Linux / Windows-WSL2. bash 3.2 compatible (macOS system bash).

PASS=0; WARN=0; FAIL=0

ok()   { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
warn() { printf '  🟡 %s\n     → %s\n' "$1" "$2"; WARN=$((WARN+1)); }
bad()  { printf '  ❌ %s\n     → %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# version_ge A B → true if A >= B (dotted numerics)
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}

# --- Platform detection. Fix hints differ (Homebrew vs apt, keychain vs creds
# file, pmset vs Windows power settings); the checks themselves are portable. ---
OS="mac"
case "$(uname -s 2>/dev/null)" in
  Darwin) OS="mac" ;;
  Linux)
    if grep -qiE 'microsoft|WSL' /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
      OS="wsl"
    else
      OS="linux"
    fi
    ;;
esac

# fix_for <macOS-hint> <apt-based-hint> → the hint matching this platform
fix_for() { if [ "$OS" = "mac" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

PLAT_LABEL="macOS"
[ "$OS" = "wsl" ]   && PLAT_LABEL="Windows (WSL2)"
[ "$OS" = "linux" ] && PLAT_LABEL="Linux"

echo "Operator preflight — unattended /goal runs  [$PLAT_LABEL]"
echo

echo "Required:"

# Claude Code CLI (install command is identical on every platform)
if command -v claude >/dev/null 2>&1; then
  CV=$(claude --version 2>/dev/null | awk '{print $1}')
  if [ -n "$CV" ] && version_ge "$CV" "2.1.221"; then
    ok "Claude Code $CV (has the wake-from-sleep auth-race fix, 2.1.221+)"
  else
    bad "Claude Code $CV is older than 2.1.221 (auth-race fix missing)" "run: claude update"
  fi
else
  bad "Claude Code not installed" "run: curl -fsSL https://claude.ai/install.sh | bash"
fi

# Logged in — the credential store differs by OS (macOS keychain vs a creds
# file / an env token on Linux/WSL, where the exact path can vary by version).
LOGIN_OK=0
if [ "$OS" = "mac" ]; then
  security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 && LOGIN_OK=1
else
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && LOGIN_OK=1
  [ -s "$HOME/.claude/.credentials.json" ] && LOGIN_OK=1
fi
if [ "$LOGIN_OK" -eq 1 ]; then
  ok "Claude login credential present"
elif [ "$OS" = "mac" ]; then
  bad "Not logged in to Claude" "run: claude   then type /login (use your own Claude account; Max plan recommended — the pipeline is Opus-heavy)"
else
  # Don't hard-fail on Linux/WSL: the credential path can vary, so a miss here
  # is 'could not confirm', not a proven logout.
  warn "Could not confirm a Claude login on this platform" "if you have already run /login you are set; otherwise run: claude   then type /login (Max plan recommended)"
fi

# git
if command -v git >/dev/null 2>&1; then
  ok "git $(git --version | awk '{print $3}')"
else
  bad "git missing" "$(fix_for 'run: xcode-select --install' 'run: sudo apt install -y git')"
fi

# node >= 22
NODE_APT_FIX='run: curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs'
if command -v node >/dev/null 2>&1; then
  NV=$(node -v 2>/dev/null | sed 's/^v//')
  NMAJ=$(printf '%s' "$NV" | cut -d. -f1)
  if [ -n "$NMAJ" ] && [ "$NMAJ" -ge 22 ] 2>/dev/null; then
    ok "Node.js $NV"
  else
    bad "Node.js $NV is older than 22 (TypeScript validators need 22+)" "$(fix_for 'run: brew install node' "$NODE_APT_FIX")"
  fi
else
  bad "Node.js missing" "$(fix_for 'run: brew install node   (install Homebrew first from https://brew.sh if needed)' "$NODE_APT_FIX")"
fi

# python3
if command -v python3 >/dev/null 2>&1; then
  ok "python3 $(python3 -V 2>&1 | awk '{print $2}')"
else
  bad "python3 missing" "$(fix_for 'run: xcode-select --install' 'run: sudo apt install -y python3')"
fi

# ripgrep (test suites and search paths depend on it; absence causes phantom failures)
if command -v rg >/dev/null 2>&1; then
  ok "ripgrep $(rg --version | head -1 | awk '{print $2}')"
else
  bad "ripgrep (rg) missing — test suites silently misbehave without it" "$(fix_for 'run: brew install ripgrep' 'run: sudo apt install -y ripgrep')"
fi

# jq (the statusline is built on it — without jq the status bar shows nothing useful)
if command -v jq >/dev/null 2>&1; then
  ok "jq $(jq --version 2>/dev/null | sed 's/^jq-//')"
else
  bad "jq missing — the statusline (repo/model/usage bar) cannot render" "$(fix_for 'run: brew install jq' 'run: sudo apt install -y jq')"
fi

# Model default for your own sessions, and nothing shadowing it. An
# ANTHROPIC_MODEL export silently outranks settings.json for every session.
# macOS wires this via operator-shell-setup.sh; Linux/WSL skips that script
# (it is the maintainer's personal zsh env), so the fix there is direct.
SETUP_FIX="$(fix_for 'run in your claude-pattern clone: ./.claude/scripts/operator-shell-setup.sh   (then open a new terminal)' 'run /model inside a Claude session to set your default (it saves to ~/.claude/settings.json)')"
if [ -n "${ANTHROPIC_MODEL:-}" ]; then
  # Two different problems with two different fixes: still written in a shell
  # config (fix the config), or merely inherited by this terminal from before
  # it was removed (just open a new one).
  MODEL_SRC=""
  for f in "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zlogin" \
           "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
    if [ -f "$f" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?ANTHROPIC_MODEL=' "$f"; then
      MODEL_SRC="$f"; break
    fi
  done
  if [ -n "$MODEL_SRC" ]; then
    bad "ANTHROPIC_MODEL=$ANTHROPIC_MODEL is set in $MODEL_SRC — it overrides your saved model everywhere" "$(fix_for "$SETUP_FIX" "remove the ANTHROPIC_MODEL line from $MODEL_SRC, then open a new terminal")"
  else
    bad "ANTHROPIC_MODEL=$ANTHROPIC_MODEL is left over in this terminal — it overrides your saved model here" "close this terminal window and open a new one (it is already gone from your shell config)"
  fi
elif command -v python3 >/dev/null 2>&1 && [ -f "$HOME/.claude/settings.json" ]; then
  MODEL=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("model",""))
except Exception: print("")' "$HOME/.claude/settings.json" 2>/dev/null)
  if [ -n "$MODEL" ]; then
    ok "model default: $MODEL (change it any time with /model)"
  else
    bad "no model default saved — sessions fall back to whatever the CLI picks" "$SETUP_FIX"
  fi
else
  bad "no ~/.claude/settings.json — model default and permission mode unset" "$SETUP_FIX"
fi

echo
echo "Recommended:"

# ccusage (plan-usage percentages in the statusline: '5h 0% · 7d 18%')
if command -v ccusage >/dev/null 2>&1; then
  ok "ccusage (plan-usage line in the statusline)"
else
  warn "ccusage missing — statusline uses its slower fallback for plan-usage data" "run: npm install -g ccusage"
fi

# GNU coreutils (gdate/gtimeout — statusline timing niceties). On Linux/WSL the
# GNU tools ARE the system default, so this is satisfied without gdate.
if [ "$OS" = "mac" ]; then
  if command -v gdate >/dev/null 2>&1; then
    ok "GNU coreutils (gdate/gtimeout)"
  else
    warn "GNU coreutils missing (statusline timing falls back gracefully)" "run: brew install coreutils"
  fi
else
  ok "GNU coreutils (system default on $PLAT_LABEL)"
fi

# tmux
if command -v tmux >/dev/null 2>&1; then
  ok "tmux $(tmux -V | awk '{print $2}') (live agent panes)"
else
  warn "tmux missing (optional — enables live agent panes)" "$(fix_for 'run: brew install tmux' 'run: sudo apt install -y tmux')"
fi

# The machine must not sleep during an unattended run.
if [ "$OS" = "mac" ]; then
  AC_SLEEP=$(pmset -g custom 2>/dev/null | awk '/AC Power/{f=1} f && $1=="sleep"{print $2; exit}')
  if [ "$AC_SLEEP" = "0" ]; then
    ok "Mac never idle-sleeps on the charger (pmset AC sleep=0)"
  else
    warn "Mac idle-sleeps on the charger — unattended runs will freeze" "run once in Terminal: sudo pmset -c sleep 0   (then run goals plugged in)"
  fi
elif [ "$OS" = "wsl" ]; then
  # Can't read the Windows-side power policy from inside WSL — surface it as guidance.
  warn "Keep Windows awake — WSL freezes when Windows sleeps (not checkable from inside WSL)" "in Windows: Settings → System → Power → sleep = Never (plugged in); or in an Admin PowerShell: powercfg /change standby-timeout-ac 0"
else
  warn "Ensure this machine does not suspend during unattended runs" "e.g. systemd: sudo systemctl mask sleep.target suspend.target hibernate.target"
fi

# Halt-alert phone channel (OS-independent — a topic file the hooks read)
if [ -s "$HOME/.config/claude/halt-ntfy-topic" ]; then
  ok "halt-alert phone topic configured (~/.config/claude/halt-ntfy-topic)"
else
  warn "no phone alerts for halted runs (desktop-only)" "see README → 'Arm halt alerts' to create your private ntfy topic"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: READY ($PASS ok, $WARN recommended items open)"
else
  echo "RESULT: NOT READY — fix the ❌ items above ($FAIL blocking, $WARN recommended)"
fi
exit 0
