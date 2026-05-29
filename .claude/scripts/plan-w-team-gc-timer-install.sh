#!/usr/bin/env bash
# plan-w-team-gc-timer-install.sh — auto-install the worktree-GC timer (E3).
#
# Root cause #2 of the 2026-05-29 cleanscale ENOSPC incident: the GC
# launchd template shipped as a MANUAL template (WL-T5) and was NEVER installed,
# so no periodic sweep ever ran. This installer renders + loads it automatically
# and idempotently — never relying on a human — DAILY (not weekly), and runs the
# GC immediately when disk-budget.sh reports pressure.
#
# Wired into: session-start.sh (best-effort, backgrounded) and runnable by hand.
#
# Usage:
#   plan-w-team-gc-timer-install.sh            # install/refresh idempotently
#   plan-w-team-gc-timer-install.sh --status   # print installed state, exit 0
#   plan-w-team-gc-timer-install.sh --uninstall # remove the agent/timer
#
# Env knobs:
#   PWT_GC_TIMER_DISABLE=1        skip entirely (no install)
#   PWT_GC_TIMER_HOUR=<0-23>      daily run hour (default 3 = 03:00 local)
#   PWT_GC_TIMER_PRESSURE=1       also run the GC NOW if disk-budget says REDUCE+
#   PWT_GC_TIMER_AGENTS_DIR=DIR   LaunchAgents dir (default ~/Library/LaunchAgents) [test override]
#   PWT_GC_TIMER_NO_LOAD=1        render the plist but do NOT launchctl (test mode)
#   PWT_GC_TIMER_LABEL=<label>    reverse-DNS label (default derived from repo name)
#
# Fail-open: any error warns to stderr and exits 0 — installing the timer must
# NEVER block a session start.

set -u

ACTION="${1:-install}"
[ "${PWT_GC_TIMER_DISABLE:-0}" = "1" ] && { echo "[gc-timer] disabled (PWT_GC_TIMER_DISABLE=1)" >&2; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd 2>/dev/null)" || { echo "[gc-timer] cannot resolve script dir" >&2; exit 0; }
# Resolve REPO_PATH unambiguously. NOTE: `$(git ... || cd ... && pwd)` is a trap —
# `&&` binds after `||`, so pwd runs even when git succeeds, capturing TWO lines.
REPO_PATH="${PWT_PROJECT_ROOT_OVERRIDE:-}"
if [ -z "$REPO_PATH" ]; then
    REPO_PATH="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || REPO_PATH=""
    [ -z "$REPO_PATH" ] && REPO_PATH="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)"
fi
TEMPLATE="$SCRIPT_DIR/plan-w-team-worktree-gc.plist.template"
HOUR="${PWT_GC_TIMER_HOUR:-3}"

# Reverse-DNS label derived from the repo dir name (sanitized).
REPO_NAME="$(basename "$REPO_PATH" 2>/dev/null | tr -cd '[:alnum:]-' )"
[ -z "$REPO_NAME" ] && REPO_NAME="repo"
LABEL="${PWT_GC_TIMER_LABEL:-io.claudepattern.pwt-worktree-gc.${REPO_NAME}}"

PLATFORM="$(uname -s 2>/dev/null || echo unknown)"

# ── disk-pressure immediate sweep (free-GB based, supersedes raw % per the APFS
#    caveat in shared/disk-budget.md) ───────────────────────────────────────────
maybe_pressure_sweep() {
    [ "${PWT_GC_TIMER_PRESSURE:-1}" = "1" ] || return 0
    local db="$SCRIPT_DIR/disk-budget.sh" act gc
    [ -x "$db" ] || return 0
    act=$("$db" 2>/dev/null | grep -oE '"recommended_action": *"[^"]*"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
    case "$act" in
        REDUCE|AT_CAPACITY|BLOCK)
            gc="$SCRIPT_DIR/plan-w-team-worktree-gc.sh"
            if [ -x "$gc" ]; then
                echo "[gc-timer] disk pressure ($act) → running GC now" >&2
                ( cd "$REPO_PATH" && "$gc" --execute --json >/tmp/pwt-worktree-gc.out 2>/tmp/pwt-worktree-gc.err & )
            fi
            ;;
    esac
}

# ── render the daily plist (template is weekly → drop Weekday = run daily) ────
render_plist() {
    [ -r "$TEMPLATE" ] || { echo "[gc-timer] template missing: $TEMPLATE" >&2; return 1; }
    # Substitute placeholders, then collapse the StartCalendarInterval to daily
    # (remove the <key>Weekday</key><integer>N</integer> pair) and set the hour.
    sed -e "s|__REPO_PATH__|$REPO_PATH|g" -e "s|__LABEL__|$LABEL|g" "$TEMPLATE" \
      | awk -v hr="$HOUR" '
          /<key>Weekday<\/key>/ { skip=1; next }      # drop Weekday key line
          skip==1 { skip=0; next }                     # ...and its <integer> value line
          /<key>Hour<\/key>/ { print; getline; printf "        <integer>%s</integer>\n", hr; next }
          { print }
        '
}

case "$ACTION" in
  --status)
      if [ "$PLATFORM" = "Darwin" ]; then
          AGENTS_DIR="${PWT_GC_TIMER_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
          PLIST="$AGENTS_DIR/$LABEL.plist"
          if [ -f "$PLIST" ]; then echo "installed: $PLIST (daily ${HOUR}:00)"; else echo "not installed (label $LABEL)"; fi
      else
          echo "platform $PLATFORM (systemd path)"
      fi
      exit 0
      ;;
  --uninstall)
      if [ "$PLATFORM" = "Darwin" ]; then
          AGENTS_DIR="${PWT_GC_TIMER_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
          PLIST="$AGENTS_DIR/$LABEL.plist"
          [ "${PWT_GC_TIMER_NO_LOAD:-0}" = "1" ] || launchctl unload "$PLIST" 2>/dev/null || true
          rm -f "$PLIST" 2>/dev/null || true
          echo "[gc-timer] uninstalled $LABEL" >&2
      fi
      exit 0
      ;;
esac

# ── worktree guard (install path only) ────────────────────────────────────────
# The GC timer belongs to the MAIN checkout — ONE per repo, pointing at the repo
# root. A bg worker / Agent-tool subagent runs with a worktree as its cwd, so
# `git rev-parse --show-toplevel` returns the WORKTREE; without this guard EVERY
# worker's session-start would leak a per-worktree timer pointing at a dir that is
# later reaped (observed 2026-05-29: io.claudepattern.pwt-worktree-gc.integration-cap
# pointed at .claude/worktrees/integration-cap). Skip install inside a worktree —
# the main checkout's interactive session installs the (idempotent) timer.
case "$REPO_PATH" in
    */.claude/worktrees/*)
        echo "[gc-timer] inside a worktree ($REPO_PATH) — skipping; the main checkout owns the timer" >&2
        exit 0 ;;
esac
__gc_gitdir="$(git -C "$REPO_PATH" rev-parse --git-dir 2>/dev/null || echo "")"
case "$__gc_gitdir" in
    */worktrees/*)
        echo "[gc-timer] linked worktree (git-dir=$__gc_gitdir) — skipping; main checkout owns the timer" >&2
        exit 0 ;;
esac

# ── install (idempotent) ──────────────────────────────────────────────────────
if [ "$PLATFORM" = "Darwin" ]; then
    AGENTS_DIR="${PWT_GC_TIMER_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
    mkdir -p "$AGENTS_DIR" 2>/dev/null || { echo "[gc-timer] cannot mkdir $AGENTS_DIR — fail-open" >&2; exit 0; }
    PLIST="$AGENTS_DIR/$LABEL.plist"
    RENDERED="$(render_plist)" || exit 0
    # Idempotency: only rewrite + reload when the content actually changed.
    if [ -f "$PLIST" ] && [ "$(cat "$PLIST" 2>/dev/null)" = "$RENDERED" ]; then
        echo "[gc-timer] already current: $PLIST" >&2
        maybe_pressure_sweep
        exit 0
    fi
    printf '%s\n' "$RENDERED" > "$PLIST" 2>/dev/null || { echo "[gc-timer] write failed $PLIST — fail-open" >&2; exit 0; }
    if [ "${PWT_GC_TIMER_NO_LOAD:-0}" != "1" ]; then
        launchctl unload "$PLIST" 2>/dev/null || true   # in case an older copy is loaded
        launchctl load  "$PLIST" 2>/dev/null || echo "[gc-timer] launchctl load returned nonzero (non-fatal)" >&2
    fi
    echo "[gc-timer] installed daily GC timer: $LABEL @ ${HOUR}:00 → $PLIST" >&2
    maybe_pressure_sweep
    exit 0
elif [ "$PLATFORM" = "Linux" ]; then
    # systemd --user .timer + .service (daily). Fail-open if systemd is absent.
    UNIT_DIR="${PWT_GC_TIMER_AGENTS_DIR:-$HOME/.config/systemd/user}"
    mkdir -p "$UNIT_DIR" 2>/dev/null || { echo "[gc-timer] cannot mkdir $UNIT_DIR — fail-open" >&2; exit 0; }
    SVC="$UNIT_DIR/pwt-worktree-gc-${REPO_NAME}.service"
    TMR="$UNIT_DIR/pwt-worktree-gc-${REPO_NAME}.timer"
    cat > "$SVC" 2>/dev/null <<SVC_EOF || { echo "[gc-timer] write failed — fail-open" >&2; exit 0; }
[Unit]
Description=plan-w-team worktree GC ($REPO_NAME)
[Service]
Type=oneshot
Nice=10
ExecStart=/bin/bash -lc 'cd "$REPO_PATH" && .claude/scripts/plan-w-team-worktree-gc.sh --execute --json && .claude/scripts/plan-w-team-companion-gc.sh --execute --json'
SVC_EOF
    cat > "$TMR" 2>/dev/null <<TMR_EOF || { echo "[gc-timer] write failed — fail-open" >&2; exit 0; }
[Unit]
Description=Daily plan-w-team worktree GC ($REPO_NAME)
[Timer]
OnCalendar=*-*-* ${HOUR}:00:00
Persistent=true
[Install]
WantedBy=timers.target
TMR_EOF
    if [ "${PWT_GC_TIMER_NO_LOAD:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable --now "pwt-worktree-gc-${REPO_NAME}.timer" 2>/dev/null \
          || echo "[gc-timer] systemctl enable returned nonzero (non-fatal)" >&2
    fi
    echo "[gc-timer] installed daily GC systemd timer for $REPO_NAME @ ${HOUR}:00" >&2
    maybe_pressure_sweep
    exit 0
else
    echo "[gc-timer] unsupported platform $PLATFORM — fail-open (no timer installed)" >&2
    exit 0
fi
