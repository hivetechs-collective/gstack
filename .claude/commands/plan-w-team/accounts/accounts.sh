#!/usr/bin/env bash
# accounts.sh — operator CLI for /plan-w-team multi-account management.
#
# A NON-INTERACTIVE, headless-safe wrapper over the Python core in this same
# directory (registry.py / probe.py / selector.py). It NEVER prints, logs, or
# passes a token on argv: a token is read from stdin / an env var / a file, and
# handed to Python ONLY via the child's stdin (a pipe) — never on the command
# line and never echoed back.
#
# bash 3.2 compatible (mac-mini portability): no `declare -A`, no `mapfile`,
# no `${x^^}`, no associative arrays.
#
# Exit codes (uniform across subcommands):
#   0  ok
#   1  usage error (unknown subcommand / missing/invalid flags / no python3)
#   2  registry perms too loose — refused (fail-closed)
#   3  add-account: token rejected (invalid / could not confirm)
#   4  add-account: network/measurement failure (token NOT stored)
#   5  account not found (remove/activate/deactivate/set-active on a missing label)
#   6  add-account: cannot obtain a token (mint refused under CLAUDECODE, or a
#      non-TTY with no --token-stdin/--token-env/--token-file source)
#   7  registry malformed

set -euo pipefail

# ── resolve our own directory (works from any cwd; follows symlinks) ───────────
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  _dir="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in
    /*) ;;
    *) SOURCE="$_dir/$SOURCE" ;;
  esac
done
ACCT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# shellcheck source=/dev/null
. "$ACCT_DIR/lib.sh"

PYBIN=""

err() { printf '%s\n' "accounts.sh: $*" >&2; }

usage() {
  cat >&2 <<'EOF'
accounts.sh — /plan-w-team multi-account operator CLI

Usage: accounts.sh <subcommand> [flags]

Subcommands:
  add-account --label L --email E [<token source>]
      Register/validate an account. Token source, first available wins:
        --token-stdin          read the token from a piped stdin
        --token-env VARNAME    read the token from env var VARNAME
                               (falls back to $PWT_ACCT_TOKEN_ENV as the name)
        --token-file PATH      read the token from the first line of PATH
        (interactive TTY only) mint via 'claude setup-token'
                               — REFUSED when CLAUDECODE is set
  setup [--no-validate] [--no-enable]     (alias: authorize)
      GUIDED onboarding. Scaffolds a secrets.env (0600) if you have none, then
      imports every saved token from it and the other known stores. Re-run any time
      after filling more slots. This is the entry point for a new operator.
  check                                   read-only: what WOULD import + live status
  import [--source PATH]... [--dry-run] [--no-validate] [--no-enable]
      Discover + bulk-register tokens you ALREADY have saved (no re-minting).
      Scans, by default (first match wins per token, deduped by fingerprint):
        secrets.env  CLAUDE_MAX_SETUP_TOKEN_<LABEL>= lines — the canonical store;
                     searched at $PWT_SECRETS_ENV (: -separated) else
                     ~/.config/claude-pwt/secrets.env, ~/.config/cleanrev/secrets.env
        ~/.config/cleanrev/claude-accounts.json   (label+email+token rows)
        ~/.helm/tokens/*.token                     (bare token files)
      Each new token is validated by one probe before it is stored (dedupe is by
      fingerprint, so re-running is idempotent). --dry-run reports without storing;
      --no-validate stores offline without a probe; --no-enable skips the flip.
  launch [--pinned L] [-- <cmd...>]       (default cmd: claude)
      Start an interactive session on the SAME optimal account the fleet would pick,
      handing the token to the child via env only (never argv/stdout). Dormant/loose
      registry ⇒ launches unchanged (ambient login). Shadow `claude` in your shell
      rc to make every session ride the rotation (see docs).
  which-account [--pinned L]              print the label a session WOULD run as
  remove-account     --label L            drop an account row entirely
  deactivate-account --label L            mark active=false
  activate-account   --label L            mark active=true
  set-active (--label L | --clear)        set / clear the active_label pin
  status                                  live usage table (or a dormant line)
  onboard [--enable | --disable]          one-time setup question (idempotent)

Exit codes:
  0 ok   1 usage/no-python   2 registry perms too loose   3 token rejected
  4 network/measurement failure   5 account not found   6 cannot obtain token
  7 registry malformed
EOF
}

# ── cross-cutting guards ───────────────────────────────────────────────────────

# Fail-closed perms gate: refuse loudly if the registry exists with loose perms.
require_perms_ok() {
  local reg
  reg="$(pwt_acct_registry_path)"
  if [ -e "$reg" ] && ! pwt_acct_perms_ok "$reg"; then
    err "registry perms too loose — refusing. Fix with: chmod 600 \"$reg\""
    exit 2
  fi
}

# Resolve python3 or exit 1 (used by every subcommand that must talk to Python).
require_python() {
  PYBIN="$(pwt_acct_python)"
  if [ -z "$PYBIN" ]; then
    err "python3 not found on PATH — required for this subcommand"
    exit 1
  fi
}

# Run a Python -c program with our package on PYTHONPATH. $1=source, rest=argv.
# stdin is passed through untouched (the add path pipes the token in this way).
acct_py() {
  local src="$1"; shift
  PYTHONPATH="$ACCT_DIR" "$PYBIN" -c "$src" "$@"
}

# ── inline Python programs (single-quoted heredocs: no shell expansion) ────────

IFS= read -r -d '' PY_ADD <<'PYEOF' || true
import sys
import registry
import probe

label = sys.argv[1]
email = sys.argv[2]
token = sys.stdin.read().strip()
if not token:
    sys.stderr.write("empty token\n")
    sys.exit(6)

# Validate BEFORE storing: exactly one probe. Never persist an unvalidated
# credential. A 200/429 WITH rate-limit headers => stale is False => valid
# (a 429 just means cooling; it is still a registered, authenticated token).
try:
    gauge = probe.probe_usage(token)
except probe.MeasurementError as e:
    sys.stderr.write(
        "could not reach api.anthropic.com to validate token (%s); NOT stored\n" % e)
    sys.exit(4)

if gauge.get("stale"):
    sys.stderr.write(
        "token rejected: api.anthropic.com returned no rate-limit headers "
        "(invalid or unauthorized token); NOT stored\n")
    sys.exit(3)

# Valid — persist. upsert writes the durable row; force active=True (upsert only
# sets it for brand-new rows), then flip multi_account_enabled on (the feature
# stays DORMANT until >=2 accounts are active, so this is safe on the 1st add).
try:
    registry.upsert_account(label, email, token)
    registry.set_account_field(label, "active", True)
    data = registry.load()
    data["multi_account_enabled"] = True
    registry.save(data)
except registry.LoosePermsError as e:
    sys.stderr.write("registry perms too loose — refused: %s\n" % e)
    sys.exit(2)

st = gauge.get("status")
fh = gauge.get("five_hour_pct")
sd = gauge.get("seven_day_pct")
# label + email ONLY — never the token.
print("added account '%s' (%s) — validated (5h=%s%% 7d=%s%% status=%s)"
      % (label, email, fh, sd, st))
sys.exit(0)
PYEOF

IFS= read -r -d '' PY_MUTATE <<'PYEOF' || true
import sys
import registry

op = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else None

try:
    data = registry.load()
except registry.LoosePermsError as e:
    sys.stderr.write("registry perms too loose — refused: %s\n" % e)
    sys.exit(2)
except registry.RegistryMalformed as e:
    sys.stderr.write("registry malformed: %s\n" % e)
    sys.exit(7)

labels = [a.get("label") for a in (data.get("accounts") or [])]

def need_label():
    if label not in labels:
        sys.stderr.write("no account labeled '%s'\n" % label)
        sys.exit(5)

if op == "activate":
    need_label()
    registry.set_account_field(label, "active", True)
    print("activated '%s'" % label)
elif op == "deactivate":
    need_label()
    registry.set_account_field(label, "active", False)
    print("deactivated '%s'" % label)
elif op == "set-active":
    need_label()
    registry.set_account_field(label, "active_label", label)
    print("active pin set to '%s'" % label)
elif op == "clear-active":
    registry.set_account_field(None, "active_label", None)
    print("active pin cleared")
elif op == "remove":
    need_label()
    data["accounts"] = [a for a in (data.get("accounts") or [])
                        if a.get("label") != label]
    if data.get("active_label") == label:
        data["active_label"] = None
    registry.save(data)
    print("removed '%s'" % label)
else:
    sys.stderr.write("internal: bad op %r\n" % op)
    sys.exit(1)
sys.exit(0)
PYEOF

IFS= read -r -d '' PY_ONBOARD <<'PYEOF' || true
import sys
import registry

flag = sys.argv[1] if len(sys.argv) > 1 else "keep"  # enable | disable | keep

try:
    data = registry.load()
except registry.LoosePermsError as e:
    sys.stderr.write("registry perms too loose — refused: %s\n" % e)
    sys.exit(2)
except registry.RegistryMalformed as e:
    sys.stderr.write("registry malformed: %s\n" % e)
    sys.exit(7)

already = bool(data.get("onboarding_answered"))
changed = False
if not already:
    data["onboarding_answered"] = True
    changed = True
if flag == "enable" and not data.get("multi_account_enabled"):
    data["multi_account_enabled"] = True
    changed = True
elif flag == "disable" and data.get("multi_account_enabled"):
    data["multi_account_enabled"] = False
    changed = True
if changed:
    registry.save(data)

en = "enabled" if data.get("multi_account_enabled") else "disabled"
ans = "yes" if data.get("onboarding_answered") else "no"
if already and flag == "keep":
    print("onboarding already answered (multi-account %s)" % en)
else:
    print("onboarding recorded (answered=%s, multi-account %s)" % (ans, en))
sys.exit(0)
PYEOF

IFS= read -r -d '' PY_IMPORT <<'PYEOF' || true
import sys
import import_stores
sys.exit(import_stores.main(sys.argv[1:]))
PYEOF

IFS= read -r -d '' PY_SETUP <<'PYEOF' || true
import sys
import import_stores
sys.exit(import_stores.setup_main(sys.argv[1:]))
PYEOF

IFS= read -r -d '' PY_LAUNCH <<'PYEOF' || true
import sys
import session_cred
sys.exit(session_cred.main(sys.argv[1:]))
PYEOF

IFS= read -r -d '' PY_STATUS <<'PYEOF' || true
import sys
import time
from datetime import datetime
import registry
import probe

try:
    reg = registry.load()
except registry.LoosePermsError as e:
    sys.stderr.write("registry perms too loose — refused: %s\n" % e)
    sys.exit(2)
except registry.RegistryMalformed as e:
    sys.stderr.write("registry malformed: %s\n" % e)
    sys.exit(0)  # status stays tolerant; do not crash

accounts = reg.get("accounts") or []
active_label = reg.get("active_label")
now = time.time()

# Fail-open live gauges for ACTIVE accounts (resolve_usage never raises).
try:
    gauges = probe.resolve_usage(reg)
except Exception:
    gauges = []
gmap = {}
for g in gauges:
    if isinstance(g, dict):
        gmap[g.get("label")] = g

def epoch(s):
    if s is None:
        return None
    try:
        return float(str(s).strip())
    except (TypeError, ValueError):
        return None

def parse_iso(s):
    if not s:
        return None
    t = str(s).strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(t)
        return dt.timestamp()
    except ValueError:
        return None

def binding_reset(g):
    bw = g.get("binding_window")
    if bw == "five_hour":
        return epoch(g.get("five_hour_reset"))
    if bw == "seven_day":
        return epoch(g.get("seven_day_reset"))
    cands = [x for x in (epoch(g.get("five_hour_reset")),
                         epoch(g.get("seven_day_reset"))) if x is not None]
    return min(cands) if cands else None

def hms(target):
    if target is None:
        return "-"
    d = target - now
    if d <= 0:
        return "now"
    m = int(d // 60)
    h = m // 60
    m = m % 60
    if h >= 24:
        return "%dd%dh" % (h // 24, h % 24)
    if h > 0:
        return "%dh%02dm" % (h, m)
    return "%dm" % m

def pct(v):
    if isinstance(v, (int, float)):
        return "%.1f" % v
    return "?"

hdr = ["PIN", "LABEL", "EMAIL", "5h%", "7d%", "WINDOW", "RESET-IN", "STATUS", "FRESH"]
rows = [hdr]
for a in accounts:
    label = a.get("label") or ""
    email = a.get("email") or ""
    pin = "*" if (active_label and label == active_label) else ""
    if not a.get("active"):
        rows.append([pin, label, email, "-", "-", "-", "-", "deactivated", "-"])
        continue
    g = gmap.get(label) or {}
    fh = g.get("five_hour_pct")
    sd = g.get("seven_day_pct")
    bw = g.get("binding_window") or "-"
    stale = bool(g.get("stale"))
    unknown = (g.get("status") == "UNKNOWN") or (fh is None and sd is None)
    lim_ts = parse_iso(g.get("limited_until"))
    if lim_ts is not None and now < lim_ts:
        status = "cooling"
    elif g.get("status") == "rejected":
        status = "cooling"
    elif unknown:
        status = "unknown"
    elif stale:
        status = "stale"
    else:
        status = "ok"
    rows.append([pin, label, email, pct(fh), pct(sd), bw,
                 hms(binding_reset(g)), status, "stale" if stale else "fresh"])

widths = [0] * len(hdr)
for r in rows:
    for i, c in enumerate(r):
        if len(c) > widths[i]:
            widths[i] = len(c)
for r in rows:
    print("  ".join(c.ljust(widths[i]) for i, c in enumerate(r)).rstrip())
sys.exit(0)
PYEOF

# ── subcommands ────────────────────────────────────────────────────────────────

cmd_add() {
  local label="" email="" opt_token_stdin=0 opt_token_env="" opt_token_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --label)      label="${2:-}";      [ -n "$label" ] || { err "--label needs a value"; return 1; }; shift 2 ;;
      --email)      email="${2:-}";      [ -n "$email" ] || { err "--email needs a value"; return 1; }; shift 2 ;;
      --token-stdin) opt_token_stdin=1;  shift ;;
      --token-env)  opt_token_env="${2:-}"; [ -n "$opt_token_env" ] || { err "--token-env needs a VARNAME"; return 1; }; shift 2 ;;
      --token-file) opt_token_file="${2:-}"; [ -n "$opt_token_file" ] || { err "--token-file needs a path"; return 1; }; shift 2 ;;
      -h|--help)    usage; return 0 ;;
      *)            err "unknown flag: $1"; usage; return 1 ;;
    esac
  done
  [ -n "$label" ] || { err "add-account requires --label"; return 1; }
  [ -n "$email" ] || { err "add-account requires --email"; return 1; }

  require_perms_ok
  require_python

  # env-var name: explicit --token-env wins, else the $PWT_ACCT_TOKEN_ENV name.
  local env_var_name="$opt_token_env"
  [ -n "$env_var_name" ] || env_var_name="${PWT_ACCT_TOKEN_ENV:-}"

  # Acquire the token by priority. It lives only in this local until it is piped
  # to Python's stdin — never on argv, never echoed.
  local token="" src=""
  if [ "$opt_token_stdin" = "1" ] && [ ! -t 0 ]; then
    token="$(cat)"; src="stdin"
  elif [ -n "$env_var_name" ] && [ -n "${!env_var_name:-}" ]; then
    token="${!env_var_name}"; src="env:$env_var_name"
  elif [ -n "$opt_token_file" ]; then
    [ -r "$opt_token_file" ] || { err "token file not readable: $opt_token_file"; return 6; }
    IFS= read -r token < "$opt_token_file" || true
    src="file"
  else
    # Would fall through to interactive minting.
    if [ -n "${CLAUDECODE:-}" ]; then
      err "refusing to mint a token inside a Claude Code session (CLAUDECODE set) —"
      err "minting here would print the token into tool output. Mint in a real"
      err "terminal and pipe it in:  claude setup-token | accounts.sh add-account \\"
      err "  --label $label --email $email --token-stdin"
      return 6
    fi
    if [ -t 0 ] && [ -t 1 ]; then
      command -v claude >/dev/null 2>&1 || { err "'claude' not on PATH — cannot mint a token"; return 6; }
      token="$(claude setup-token)"; src="mint"
    else
      err "no token source: not a TTY and none of --token-stdin/--token-env/--token-file given"
      return 6
    fi
  fi

  [ -n "$token" ] || { err "empty token from $src"; return 6; }

  # Hand the token to Python via stdin ONLY (pipe). label/email are not secret.
  local rc=0
  printf '%s' "$token" | acct_py "$PY_ADD" "$label" "$email" || rc=$?
  return "$rc"
}

cmd_simple_label() {
  # $1 = op keyword for PY_MUTATE; parses --label from "$@" (the rest).
  local op="$1"; shift
  local label=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --label)   label="${2:-}"; [ -n "$label" ] || { err "--label needs a value"; return 1; }; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *)         err "unknown flag: $1"; usage; return 1 ;;
    esac
  done
  [ -n "$label" ] || { err "$op requires --label"; return 1; }
  require_perms_ok
  require_python
  local rc=0
  acct_py "$PY_MUTATE" "$op" "$label" || rc=$?
  return "$rc"
}

cmd_set_active() {
  local label="" clear=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --label)   label="${2:-}"; [ -n "$label" ] || { err "--label needs a value"; return 1; }; shift 2 ;;
      --clear)   clear=1; shift ;;
      -h|--help) usage; return 0 ;;
      *)         err "unknown flag: $1"; usage; return 1 ;;
    esac
  done
  if [ "$clear" = "1" ] && [ -n "$label" ]; then
    err "set-active: give either --label or --clear, not both"; return 1
  fi
  if [ "$clear" != "1" ] && [ -z "$label" ]; then
    err "set-active requires --label L or --clear"; return 1
  fi
  require_perms_ok
  require_python
  local rc=0
  if [ "$clear" = "1" ]; then
    acct_py "$PY_MUTATE" clear-active || rc=$?
  else
    acct_py "$PY_MUTATE" set-active "$label" || rc=$?
  fi
  return "$rc"
}

cmd_status() {
  require_perms_ok
  local reg
  reg="$(pwt_acct_registry_path)"

  if pwt_acct_is_dormant; then
    local enabled="false" total=0 active=0
    if [ -s "$reg" ]; then
      if command -v jq >/dev/null 2>&1 && jq empty "$reg" >/dev/null 2>&1; then
        enabled="$(jq -r '.multi_account_enabled // false' "$reg" 2>/dev/null || echo false)"
        total="$(jq -r '(.accounts // []) | length' "$reg" 2>/dev/null || echo 0)"
        active="$(jq -r '[(.accounts // [])[] | select(.active==true)] | length' "$reg" 2>/dev/null || echo 0)"
      else
        printf '%s\n' "multi-account dormant — registry present but unreadable/malformed: $reg"
        return 0
      fi
    fi
    if [ "$enabled" != "true" ]; then
      printf '%s\n' "multi-account dormant — not enabled ($total account(s), $active active). Enable with: accounts.sh onboard --enable"
    else
      printf '%s\n' "multi-account dormant — need >=2 active accounts (have $active of $total)."
    fi
    return 0
  fi

  # Not dormant → render the live table. Degrade (never crash) if python3 is gone.
  PYBIN="$(pwt_acct_python)"
  if [ -z "$PYBIN" ]; then
    printf '%s\n' "python3 unavailable — showing static registry (no live usage):"
    if command -v jq >/dev/null 2>&1; then
      jq -r '(.accounts // [])[] | "  " + (.label // "?") + "  " + (.email // "?") + "  active=" + ((.active // false)|tostring)' "$reg" 2>/dev/null || true
    fi
    return 0
  fi
  acct_py "$PY_STATUS" || true
  return 0
}

cmd_import() {
  # Discover + bulk-register pre-existing saved tokens. All flag parsing and the
  # discover/validate/store logic live in import_stores.py (testable in isolation);
  # this wrapper only enforces the perms gate + python availability, then delegates.
  require_perms_ok
  require_python
  local rc=0
  acct_py "$PY_IMPORT" "$@" || rc=$?
  return "$rc"
}

cmd_setup() {
  # Guided onboarding entry point: scaffold a secrets.env if the operator has
  # none, then import every saved token from it (and the other known stores). All
  # logic lives in import_stores.setup_main; this wrapper only gates perms/python.
  require_perms_ok
  require_python
  local rc=0
  acct_py "$PY_SETUP" "$@" || rc=$?
  return "$rc"
}

cmd_check() {
  # Read-only: show what WOULD be imported (dry-run, nothing stored) + live status.
  require_perms_ok
  require_python
  printf '%s\n' "== accounts discovery (dry-run — nothing stored) =="
  acct_py "$PY_IMPORT" --dry-run "$@" || true
  printf '\n%s\n' "== current account status =="
  cmd_status
  return 0
}

# Fallback used by cmd_launch ONLY when python3 is unavailable: peel our own flags
# and exec the command unchanged (ambient login) so a missing python never blocks a
# foreground session. Default command is `claude`.
_launch_fallback_no_python() {
  local which=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --pinned) shift 2 ;;
      --which)  which=1; shift ;;
      --)       shift; break ;;
      -*)       shift ;;
      *)        break ;;
    esac
  done
  if [ "$which" = "1" ]; then printf '%s\n' "(ambient)"; return 0; fi
  [ $# -gt 0 ] || set -- claude
  err "python3 unavailable — launching '$1' on ambient login"
  exec "$@"
}

cmd_launch() {
  case "${1:-}" in -h|--help) usage; return 0 ;; esac
  # NOTE: no require_perms_ok here — a loose/absent registry must NOT block a
  # foreground session; session_cred falls back to ambient (loudly) and still execs.
  PYBIN="$(pwt_acct_python)"
  if [ -z "$PYBIN" ]; then
    _launch_fallback_no_python "$@"
    return $?
  fi
  # session_cred.main parses --pinned/--which/-- <cmd...>, selects the optimal
  # account, and execs the command with the token in its ENV only (never argv).
  acct_py "$PY_LAUNCH" "$@"
  return $?
}

cmd_onboard() {
  local opt_enable=0 opt_disable=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --enable)  opt_enable=1; shift ;;
      --disable) opt_disable=1; shift ;;
      -h|--help) usage; return 0 ;;
      *)         err "unknown flag: $1"; usage; return 1 ;;
    esac
  done
  if [ "$opt_enable" = "1" ] && [ "$opt_disable" = "1" ]; then
    err "onboard: give either --enable or --disable, not both"; return 1
  fi
  require_perms_ok
  require_python

  local reg answered="false" flag="keep"
  reg="$(pwt_acct_registry_path)"
  if [ -s "$reg" ] && command -v jq >/dev/null 2>&1; then
    answered="$(jq -r '.onboarding_answered // false' "$reg" 2>/dev/null || echo false)"
  fi

  if [ "$opt_enable" = "1" ]; then
    flag="enable"
  elif [ "$opt_disable" = "1" ]; then
    flag="disable"
  elif [ "$answered" != "true" ] && [ -t 0 ] && [ -t 1 ]; then
    printf '%s' "Manage multiple Claude accounts with /plan-w-team? [y/N] " >&2
    local ans=""
    IFS= read -r ans || ans=""
    case "$ans" in
      [yY]*) flag="enable" ;;
      *)     flag="disable" ;;
    esac
  fi

  local rc=0
  acct_py "$PY_ONBOARD" "$flag" || rc=$?
  return "$rc"
}

# ── dispatch ───────────────────────────────────────────────────────────────────
main() {
  if [ $# -eq 0 ]; then usage; return 1; fi
  local sub="$1"; shift
  case "$sub" in
    add-account)        cmd_add "$@" ;;
    import)             cmd_import "$@" ;;
    setup|authorize)    cmd_setup "$@" ;;
    check)              cmd_check "$@" ;;
    launch)             cmd_launch "$@" ;;
    which-account)      cmd_launch --which "$@" ;;
    remove-account)     cmd_simple_label remove "$@" ;;
    deactivate-account) cmd_simple_label deactivate "$@" ;;
    activate-account)   cmd_simple_label activate "$@" ;;
    set-active)         cmd_set_active "$@" ;;
    status)             cmd_status "$@" ;;
    onboard)            cmd_onboard "$@" ;;
    -h|--help|help)     usage; return 0 ;;
    *)                  err "unknown subcommand: $sub"; usage; return 1 ;;
  esac
}

rc=0
main "$@" || rc=$?
exit "$rc"
