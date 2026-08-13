#!/bin/bash
# operator-doctor.sh — preflight check for running unattended /goal runs on a Mac.
#
# For operators (including non-developers): run this once after setup and before
# a long run. It checks every prerequisite and prints the exact fix command for
# anything missing. It never installs or changes anything itself.
#
#   ./.claude/scripts/operator-doctor.sh
#
# bash 3.2 compatible (macOS system bash).

PASS=0; WARN=0; FAIL=0

ok()   { printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); }
warn() { printf '  🟡 %s\n     → %s\n' "$1" "$2"; WARN=$((WARN+1)); }
bad()  { printf '  ❌ %s\n     → %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# version_ge A B → true if A >= B (dotted numerics)
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}

echo "Operator preflight — unattended /goal runs"
echo

echo "Required:"

# Claude Code CLI
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

# Logged in (macOS keychain credential)
if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  ok "Claude login credential present (keychain)"
else
  bad "Not logged in to Claude" "run: claude   then type /login (use your own Claude account; Max plan recommended — the pipeline is Opus-heavy)"
fi

# git
if command -v git >/dev/null 2>&1; then
  ok "git $(git --version | awk '{print $3}')"
else
  bad "git missing" "run: xcode-select --install"
fi

# node >= 22
if command -v node >/dev/null 2>&1; then
  NV=$(node -v 2>/dev/null | sed 's/^v//')
  NMAJ=$(printf '%s' "$NV" | cut -d. -f1)
  if [ -n "$NMAJ" ] && [ "$NMAJ" -ge 22 ] 2>/dev/null; then
    ok "Node.js $NV"
  else
    bad "Node.js $NV is older than 22 (TypeScript validators need 22+)" "run: brew install node"
  fi
else
  bad "Node.js missing" "run: brew install node   (install Homebrew first from https://brew.sh if needed)"
fi

# python3
if command -v python3 >/dev/null 2>&1; then
  ok "python3 $(python3 -V 2>&1 | awk '{print $2}')"
else
  bad "python3 missing" "run: xcode-select --install"
fi

# ripgrep (test suites and search paths depend on it; absence causes phantom failures)
if command -v rg >/dev/null 2>&1; then
  ok "ripgrep $(rg --version | head -1 | awk '{print $2}')"
else
  bad "ripgrep (rg) missing — test suites silently misbehave without it" "run: brew install ripgrep"
fi

# jq (the statusline is built on it — without jq the status bar shows nothing useful)
if command -v jq >/dev/null 2>&1; then
  ok "jq $(jq --version 2>/dev/null | sed 's/^jq-//')"
else
  bad "jq missing — the statusline (repo/model/usage bar) cannot render" "run: brew install jq"
fi

# Model default for your own sessions, and nothing shadowing it. An
# ANTHROPIC_MODEL export silently outranks settings.json for every session.
# This script syncs into consumer repos; the installer does not. Point at the
# clone explicitly so the fix is runnable from wherever the check was run.
SETUP_FIX="run in your claude-pattern clone: ./.claude/scripts/operator-shell-setup.sh   (then open a new terminal)"
if [ -n "${ANTHROPIC_MODEL:-}" ]; then
  # Two different problems with two different fixes: still written in a shell
  # config (re-run the installer), or merely inherited by this terminal from
  # before it was removed (just open a new one).
  MODEL_SRC=""
  for f in "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zlogin" \
           "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
    if [ -f "$f" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?ANTHROPIC_MODEL=' "$f"; then
      MODEL_SRC="$f"; break
    fi
  done
  if [ -n "$MODEL_SRC" ]; then
    bad "ANTHROPIC_MODEL=$ANTHROPIC_MODEL is set in $MODEL_SRC — it overrides your saved model everywhere" "$SETUP_FIX"
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

# GNU coreutils (gdate/gtimeout — statusline timing niceties)
if command -v gdate >/dev/null 2>&1; then
  ok "GNU coreutils (gdate/gtimeout)"
else
  warn "GNU coreutils missing (statusline timing falls back gracefully)" "run: brew install coreutils"
fi

# tmux
if command -v tmux >/dev/null 2>&1; then
  ok "tmux $(tmux -V | awk '{print $2}') (live agent panes)"
else
  warn "tmux missing (optional — enables live agent panes)" "run: brew install tmux"
fi

# Mac never idle-sleeps on the charger
AC_SLEEP=$(pmset -g custom 2>/dev/null | awk '/AC Power/{f=1} f && $1=="sleep"{print $2; exit}')
if [ "$AC_SLEEP" = "0" ]; then
  ok "Mac never idle-sleeps on the charger (pmset AC sleep=0)"
else
  warn "Mac idle-sleeps on the charger — unattended runs will freeze" "run once in Terminal: sudo pmset -c sleep 0   (then run goals plugged in)"
fi

# Halt-alert phone channel
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
