#!/usr/bin/env bash
# plan-usage.sh — plan-usage windows (5h / 7d / model-scoped weekly) for the
# status line. NON-BLOCKING, machine-wide, account-keyed, with a burn-rate ETA.
#
# ── WHY THIS SHAPE (2026-09-02 incident) ─────────────────────────────────────
# A pane read "5h 87%" while the account it was on was at 100% and every session
# on it was being rejected ("You've hit your session limit"). Four defects in the
# previous helper produced that reading, and this file fixes all four:
#
#   1. SYNCHRONOUS in the render path. It read the keychain and did an HTTPS GET
#      inline. Claude Code CANCELS an in-flight status-line command when the next
#      trigger fires (300 ms debounce, 5 s refreshInterval), so under load the
#      render was killed mid-fetch: the display froze on the last COMPLETED render
#      and the cache never committed. Now the refresh is a DETACHED, BOUNDED
#      singleton; the render only ever reads a file (stale-while-revalidate).
#   2. 300 s TTL + an UNMARKED 30-minute stale serve on API failure. Now TTL is 60 s
#      and every sample carries `_meta.fetched_at`, so the status line can show its
#      age and flag it loudly once it is genuinely old.
#   3. PER-REPO cache. Panes disagreed with each other (17% vs 6%), every checkout
#      made its own API calls, and nothing invalidated on `/login`. Now ONE cache
#      per machine, keyed by the ACCOUNT the session bills to (env token hash, else
#      the keychain login's accountUuid) — every pane on the same account reads the
#      same file, and a `/login` switches the key instantly.
#   4. No lead indicator. A percentage is a position, not a velocity: at fleet burn
#      rates 87% → 100% takes minutes. Every refresh appends a sample to a small
#      history ring and publishes `%/min` + ETA-to-100 for each window.
#
# ── CONTRACT ──────────────────────────────────────────────────────────────────
#   stdout : the last successful /api/oauth/usage response for the CURRENT account,
#            raw fields byte-preserved (five_hour, seven_day, limits[] …), plus an
#            ADDITIVE "_meta" object — or `{}` when nothing has been fetched yet.
#            Existing consumers keep working unchanged: the status line's plan
#            segment, plan-w-team-fable-guard.sh (the weekly_scoped Fable bucket).
#   exit   : always 0 (fail-open). Diagnostics go to stderr only.
#
#   _meta: { fetched_at (epoch s), source ("endpoint"|"ratelimit-header"),
#            account_key, account_email, ttl_s, stale_max_s,
#            rates: { five_hour: {rate_ppm, eta_s}, seven_day: {…},
#                     scoped: { "<display_name>": {rate_ppm, eta_s} } } }
#   rate_ppm = percentage points per minute over the recent window (null when
#   fewer than two samples ≥60 s apart). eta_s = seconds until 100% at that rate
#   (null when the rate is ≤ 0 or unmeasured). A window RESET (a drop of >20
#   points) discards the older samples.
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
#   plan-usage.sh            serve the cache; when older than TTL start ONE
#                            detached bounded refresh and return at once. On a
#                            COLD cache (first render on this account) wait up to
#                            PLAN_USAGE_COLD_WAIT seconds for that refresh to land.
#   plan-usage.sh --sync     refresh inline (bounded), then serve. For callers
#                            that need a fresh number NOW (fable-guard, tests).
#   plan-usage.sh --meta     print only the _meta object (diagnostics). ALWAYS carries
#                            accountUuid (the account key) + account_source
#                            (env|keychain|override), even on a cold cache — the
#                            founder-vs-fleet isolation proof (cleanscale #1953).
#   plan-usage.sh --refresh  (internal) the refresher body, run under the lock.
#
# ── ENV ───────────────────────────────────────────────────────────────────────
#   PLAN_USAGE_CACHE_TTL      seconds before a refresh is started      (60)
#   PLAN_USAGE_STALE_MAX      seconds after which the status line flags (900)
#                             the sample as STALE (published in _meta)
#   PLAN_USAGE_COLD_WAIT      cold-cache wait, seconds                 (2)
#   PLAN_USAGE_TIMEOUT_S      refresher bound, seconds                 (15)
#   PLAN_USAGE_CURL_MAX_TIME  per-request curl bound, seconds          (6)
#   PLAN_USAGE_CACHE_DIR      cache directory        ($HOME/.config/claude-pattern/plan-usage)
#   PLAN_USAGE_ACCOUNT_KEY    override the account key (tests)
#   PLAN_USAGE_FAIL_BACKOFF   seconds a render waits after a failed refresh before it
#                            spawns another (60); a 429 uses the Retry-After header
#                            instead, HONORED as sent (floor 30, ceiling
#                            PLAN_USAGE_RATE_LIMIT_MAX); unspecified/0 → the default below
#   PLAN_USAGE_RATE_LIMIT_DEFAULT  backoff when a 429 carries no usable Retry-After (3600).
#                            The endpoint edge quota is a ROLLING 1 h window that counts
#                            the rejections themselves, so any retry inside it re-arms it:
#                            the old 900 s clamp left a key refreshed more than once an
#                            hour rate-limited for ever (2026-09-02, claude-pattern#36)
#   PLAN_USAGE_RATE_LIMIT_MAX  ceiling on an honored Retry-After (21600)
#   PLAN_USAGE_SCOPE_MEMO_TTL  seconds a 401/403 "no user:profile scope" memo keeps an
#                            env-token key OFF the endpoint (604800 = 7 d): setup tokens
#                            never gain the scope, and every 403 counts against the edge
#                            quota above
#   PLAN_USAGE_PROBE_CMD      override the header probe (tests): prints the synthesized
#                            usage JSON; exit 0 = success
#   PLAN_USAGE_NOTOKEN_BACKOFF  seconds a render waits after a refresh that could not
#                            even read a token (no keychain item for this user, no
#                            curl/security/python3 on PATH) — 15, short on purpose:
#                            such a failure is the SPAWNER's environment, not the
#                            account's, and the cache is shared by every pane on
#                            that login (2026-09-02: a renderer with no USER in its
#                            env kept every pane ⚠ STALE for 37 min)
#   PLAN_USAGE_WRITER         identity of this renderer (the status line passes its
#                            session_id; default: the helper path). A failure backoff
#                            gates only its writer; a 429 window gates everyone.
#   PLAN_USAGE_SYSTEM_PATH    dirs appended to PATH so a lean spawner PATH still finds
#                            curl/security/python3 (default /usr/bin:/bin:/usr/sbin:
#                            /opt/homebrew/bin:/usr/local/bin; tests set it empty)
#   PLAN_USAGE_FETCH_RETRY_AFTER  (tests) Retry-After seconds when the fetch stub exits 29
#   PLAN_USAGE_FETCH_CMD      override the fetch (tests): a command that prints the
#                             usage JSON body on stdout; exit 0 = success, exit 22 =
#                             HTTP error. Gets `--source` as $1 for symmetry.
#   CLAUDE_CODE_OAUTH_TOKEN   when set, THIS token identifies and measures the
#                             account (fleet lanes); the endpoint refuses setup
#                             tokens (403, scope user:profile) so the refresher
#                             falls back to the rate-limit HEADER probe — and
#                             remembers the refusal (<key>.scope memo) so later
#                             refreshes go straight to the probe without touching
#                             the endpoint again for PLAN_USAGE_SCOPE_MEMO_TTL.
#                             A 429 gets the SAME probe fallback (#2012): the
#                             shared OPS setup token hits the endpoint's edge
#                             quota routinely, and until this fix a 429 left the
#                             cache un-refreshed for the whole Retry-After window
#                             (up to 6 h) with no fallback at all. $ERRF's
#                             "rate-limited" record (__rate_limited_fresh) keeps
#                             routing straight to the probe for the rest of that
#                             window, and the top-level backoff gate lets a
#                             refresh spawn during it specifically so the probe
#                             — a different call, a different quota — keeps
#                             getting a chance to run.
#
# ── SECURITY ──────────────────────────────────────────────────────────────────
#   The bearer token is never on argv (curl reads it from a stdin config: `-K -`),
#   never printed, never logged, never cached. The cache holds percentages only.
#   Cache dir is created 0700.
#
# bash 3.2 (mac-mini /bin/bash): no `declare -A`, no `${v,,}`, no mapfile.

set -u
# A renderer's PATH is whatever spawned its session; the tools this needs (curl,
# security, python3, sed, date) live in fixed places, so a lean PATH must never
# read as "no curl" (2.38.1).
PATH="$PATH:${PLAN_USAGE_SYSTEM_PATH-/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin:/usr/local/bin}"; export PATH

MODE=serve
META=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sync)    MODE=sync ;;
    --refresh) MODE=refresh ;;
    --meta)    META=1 ;;
    -h|--help) sed -n '2,70p' "$0"; exit 0 ;;
  esac
  shift
done

TTL="${PLAN_USAGE_CACHE_TTL:-120}"
STALE_MAX="${PLAN_USAGE_STALE_MAX:-900}"
FAIL_BACKOFF="${PLAN_USAGE_FAIL_BACKOFF:-60}"
NOTOKEN_BACKOFF="${PLAN_USAGE_NOTOKEN_BACKOFF:-15}"
RATE_LIMIT_DEFAULT="${PLAN_USAGE_RATE_LIMIT_DEFAULT:-300}"
RATE_LIMIT_MAX="${PLAN_USAGE_RATE_LIMIT_MAX:-21600}"
SCOPE_MEMO_TTL="${PLAN_USAGE_SCOPE_MEMO_TTL:-604800}"
COLD_WAIT="${PLAN_USAGE_COLD_WAIT:-2}"
BOUND_S="${PLAN_USAGE_TIMEOUT_S:-15}"
CURL_MAX="${PLAN_USAGE_CURL_MAX_TIME:-6}"
CACHE_DIR="${PLAN_USAGE_CACHE_DIR:-$HOME/.config/claude-pattern/plan-usage}"
USAGE_URL="https://api.anthropic.com/api/oauth/usage"
HIST_KEEP=120
RATE_WINDOW_S=900

case "$TTL$STALE_MAX$COLD_WAIT$BOUND_S$CURL_MAX" in *[!0-9]*) TTL=60; STALE_MAX=900; COLD_WAIT=2; BOUND_S=15; CURL_MAX=6 ;; esac
case "$RATE_LIMIT_DEFAULT$RATE_LIMIT_MAX$SCOPE_MEMO_TTL" in *[!0-9]*) RATE_LIMIT_DEFAULT=300; RATE_LIMIT_MAX=21600; SCOPE_MEMO_TTL=604800 ;; esac

# ── account identity ────────────────────────────────────────────────────────
# The key names WHO IS BILLED for this session's requests, which is what the
# number must describe. An env token (fleet lane) outranks the keychain login for
# model requests, so it outranks it here too. Never the raw token: a 12-hex prefix
# of its SHA-256, piped (not argv). The keychain case uses the login's accountUuid
# from ~/.claude.json — the file `/login` rewrites, so a switch re-keys at once.
__sha12() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 2>/dev/null | cut -c1-12
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum 2>/dev/null | cut -c1-12
  else cksum 2>/dev/null | cut -d' ' -f1; fi
}
ACCOUNT_EMAIL=""
# ACCOUNT_SOURCE names WHICH identity the key was derived from — the cleanscale #1953
# isolation proof reads this: a fleet lane resolves `env` (the ops setup token) while the
# founder's interactive session resolves `keychain` (their login's accountUuid), so `--meta`
# on the two never reports the same accountUuid. env|keychain|override.
ACCOUNT_SOURCE="keychain"
if [ -n "${PLAN_USAGE_ACCOUNT_KEY:-}" ]; then
  KEY="$PLAN_USAGE_ACCOUNT_KEY"; ACCOUNT_SOURCE="override"
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  KEY="env-$(printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" | __sha12)"; ACCOUNT_SOURCE="env"
else
  KEY=""
  if [ -r "$HOME/.claude.json" ]; then
    KEY=$(sed -n 's/.*"accountUuid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HOME/.claude.json" 2>/dev/null | head -1)
    ACCOUNT_EMAIL=$(sed -n 's/.*"emailAddress"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HOME/.claude.json" 2>/dev/null | head -1)
  fi
  [ -n "$KEY" ] || KEY="keychain"
fi
KEY=$(printf '%s' "$KEY" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80)
[ -n "$KEY" ] || KEY="unknown"

CACHE="$CACHE_DIR/$KEY.json"
HIST="$CACHE_DIR/$KEY.history"
LOCK="$CACHE_DIR/$KEY.lock"
ERRF="$CACHE_DIR/$KEY.err"
SCOPEF="$CACHE_DIR/$KEY.scope"   # 401/403 memo: this key lacks user:profile → header probe only
# Who is refreshing. The status line passes its session_id; a bare call is the
# helper path. A failure backoff is honored ONLY by its writer (2.38.1): every
# pane on a login shares this cache, and on 2026-09-02 a 2.37.0 helper copy inside
# a worktree (no backoff logic at all) failed every 10 s and re-minted .err, which
# every newer pane obeyed for 60 s — ⚠ STALE 37m while a foreground --sync worked.
# A 429 window stays shared: that is the account's state, not the writer's.
WRITER=$(printf '%s' "${PLAN_USAGE_WRITER:-$0}" | tr -c 'A-Za-z0-9._/-' '_' | cut -c1-200)

__age_s() {
  local f="$1" m
  [ -e "$f" ] || { echo 999999; return 0; }
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")
  case "$m" in ''|*[!0-9]*) echo 999999; return 0 ;; esac
  echo $(( $(date +%s) - m ))
}
__serve() {
  if [ "$META" = "1" ]; then __serve_meta; return 0; fi
  if [ -s "$CACHE" ]; then cat "$CACHE" 2>/dev/null || echo '{}'; else echo '{}'; fi
  return 0
}
__serve_meta() {
  # cleanscale #1953: ALWAYS surface accountUuid + account_source (the founder-vs-fleet
  # isolation proof), merged over whatever the cache's _meta already carries. The measured
  # account's identity must be visible even on a cold cache, so these are injected here
  # rather than read out of a cached probe response.
  if command -v python3 >/dev/null 2>&1; then
    PU_KEY="$KEY" PU_SRC="$ACCOUNT_SOURCE" PU_CACHE="$CACHE" python3 -c 'import json,os
m={}
c=os.environ.get("PU_CACHE","")
if c and os.path.exists(c):
    try: m=json.load(open(c)).get("_meta",{}) or {}
    except Exception: m={}
m["accountUuid"]=os.environ.get("PU_KEY","")
m["account_source"]=os.environ.get("PU_SRC","")
print(json.dumps(m,separators=(",",":")))' 2>/dev/null || printf '{"accountUuid":"%s","account_source":"%s"}\n' "$KEY" "$ACCOUNT_SOURCE"
  else printf '{"accountUuid":"%s","account_source":"%s"}\n' "$KEY" "$ACCOUNT_SOURCE"; fi
}

# ── python bodies (script on argv, DATA on stdin — a heredoc on `python3 -`
#    would steal stdin from the pipe that carries the token / the body) ──────
PROBE_PY=$(cat <<'PY'
import sys, json, time, datetime, urllib.request, urllib.error
tok = sys.stdin.read().strip()
body = json.dumps({"model": "claude-haiku-4-5-20251001", "max_tokens": 1,
                   "messages": [{"role": "user", "content": "."}]}).encode()
req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, method="POST", headers={
    "authorization": "Bearer " + tok, "anthropic-version": "2023-06-01",
    "anthropic-beta": "oauth-2025-04-20", "content-type": "application/json",
    "user-agent": "claude-cli/2.1.0 (external, cli)"})
try:
    r = urllib.request.urlopen(req, timeout=8); h = r.headers
except urllib.error.HTTPError as e:
    h = e.headers
except Exception:
    sys.exit(1)
low = {k.lower(): v for k, v in h.items()}
P = "anthropic-ratelimit-unified-"
def pct(s):
    v = low.get(P + s)
    try: return round(float(v) * 100, 1)
    except Exception: return None
def iso(s):
    v = low.get(P + s)
    try: return datetime.datetime.fromtimestamp(int(float(v)), datetime.timezone.utc).isoformat()
    except Exception: return None
fh, sd = pct("5h-utilization"), pct("7d-utilization")
if fh is None and sd is None: sys.exit(1)
rep = low.get(P + "representative-claim") or ""
status = low.get(P + "status") or "allowed"
locked = None if status in ("allowed", "allowed_warning") else status
out = {"five_hour": {"utilization": fh, "resets_at": iso("5h-reset"), "locked_reason": locked if rep == "five_hour" else None},
       "seven_day": {"utilization": sd, "resets_at": iso("7d-reset"), "locked_reason": locked if rep == "seven_day" else None},
       "limits": [
         {"kind": "session", "group": "session", "percent": fh, "severity": "normal", "resets_at": iso("5h-reset"), "scope": None, "is_active": rep == "five_hour"},
         {"kind": "weekly_all", "group": "weekly", "percent": sd, "severity": "normal", "resets_at": iso("7d-reset"), "scope": None, "is_active": rep == "seven_day"}]}
out["_source"] = "ratelimit-header"
print(json.dumps(out, separators=(",", ":")))
PY
)
META_PY=$(cat <<'PY'
import os, sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.exit(3)
if not isinstance(d, dict) or not isinstance(d.get("five_hour"), dict):
    sys.exit(3)
fh = d["five_hour"].get("utilization")
sd = (d.get("seven_day") or {}).get("utilization")
if not isinstance(fh, (int, float)):
    sys.exit(3)
now = int(os.environ["PU_NOW"])
# Model-scoped weekly buckets (e.g. Fable) by display name.
scoped = {}
for lim in d.get("limits") or []:
    if not isinstance(lim, dict) or lim.get("kind") != "weekly_scoped":
        continue
    name = (((lim.get("scope") or {}).get("model") or {}).get("display_name")) or ""
    p = lim.get("percent")
    if name and isinstance(p, (int, float)):
        scoped[name] = float(p)
# ── history ring: one line per sample ──
hist_path = os.environ["PU_HIST"]; keep = int(os.environ["PU_KEEP"]); win = int(os.environ["PU_WIN"])
rows = []
try:
    with open(hist_path) as f:
        for line in f:
            try:
                r = json.loads(line)
                if isinstance(r, dict) and isinstance(r.get("t"), int):
                    rows.append(r)
            except Exception:
                pass
except Exception:
    pass
rows.append({"t": now, "fh": float(fh), "sd": (float(sd) if isinstance(sd, (int, float)) else None), "sc": scoped})
rows = [r for r in rows if r["t"] <= now][-keep:]
try:
    tmp = hist_path + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f:
        for r in rows:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")
    os.replace(tmp, hist_path)
except Exception:
    pass
def rate(getter):
    """%/min over samples in the window since the last RESET (a drop >20 pts)."""
    pts = []
    for r in rows:
        if now - r["t"] > win:
            continue
        v = getter(r)
        if isinstance(v, (int, float)):
            pts.append((r["t"], float(v)))
    if len(pts) < 2:
        return {"rate_ppm": None, "eta_s": None}
    start = 0
    for i in range(1, len(pts)):
        if pts[i][1] < pts[i-1][1] - 20:
            start = i
    pts = pts[start:]
    if len(pts) < 2 or pts[-1][0] - pts[0][0] < 60:
        return {"rate_ppm": None, "eta_s": None}
    dt_min = (pts[-1][0] - pts[0][0]) / 60.0
    rpm = (pts[-1][1] - pts[0][1]) / dt_min
    eta = None
    if rpm > 0.05 and pts[-1][1] < 100:
        eta = int((100.0 - pts[-1][1]) / rpm * 60)
    return {"rate_ppm": round(rpm, 2), "eta_s": eta}
rates = {"five_hour": rate(lambda r: r.get("fh")), "seven_day": rate(lambda r: r.get("sd")),
         "scoped": {name: rate(lambda r, n=name: (r.get("sc") or {}).get(n)) for name in scoped}}
src = d.pop("_source", None) or "endpoint"
d["_meta"] = {"fetched_at": now, "source": src,
              "account_key": os.environ["PU_KEY"], "account_email": os.environ["PU_EMAIL"],
              "ttl_s": int(os.environ["PU_TTL"]), "stale_max_s": int(os.environ["PU_STALE"]),
              "samples": len(rows), "rates": rates}
sys.stdout.write(json.dumps(d, separators=(",", ":")))
PY
)

# ── refresher ───────────────────────────────────────────────────────────────
# Runs under $LOCK (owned by whoever created it). Every failure leaves the cache
# UNTOUCHED (the status line shows the growing age instead of a blank) and records
# the reason in $ERRF; success replaces the cache atomically and clears $ERRF.
FETCH_DETAIL=""   # on 3/4: WHICH tool or keychain step failed (never a token); __fetch prints it
__fail() {  # <reason> [http_code]
  printf '{"at":%s,"reason":"%s","code":"%s","detail":"%s","writer":"%s"}\n' "$(date +%s)" "$1" "${2:-}" "$FETCH_DETAIL" "$WRITER" > "$ERRF" 2>/dev/null || true
  echo "plan-usage: refresh failed: $1 ${2:-} $FETCH_DETAIL" >&2
  return 0
}
# HTTP 429 → the backoff window. Two different 429s come off this endpoint and they
# must not be confused (2026-09-03, claude-pattern 2.38.9):
#   • a POSITIVE Retry-After is the edge quota — a ROLLING 1 h window that counts the
#     rejections themselves. HONOR it as sent (floor 30 s, ceiling RATE_LIMIT_MAX): the
#     old 30..900 clamp re-armed the window on every retry and a key refreshed more than
#     once an hour never came back (measured Retry-After 2668 s, claude-pattern#36).
#   • NO header / "retry-after: 0" is the endpoint's ordinary sample floor (~5 min per
#     account, live 2026-09-02), sent between successes. 2.38.3 mapped it to the same 1 h
#     default and one routine rejection froze a keychain login's sample for an hour
#     (knox: 115 clean 120 s samples, then a single header-less 429 → `⚠ STALE`).
#     It now backs off RATE_LIMIT_DEFAULT (300 s) and DOUBLES per consecutive
#     header-less 429 — a rejected retry after the floor means the quota is really
#     drained — up to RATE_LIMIT_MAX; a success clears $ERRF and so the streak.
# `.err` records `retry-after=<n>` (sent) or `retry-after=none streak=<k>` in `detail`.
__rate_limited() {  # [retry-after-seconds]
  local ra="${1:-}" streak=1 prev_reason prev_detail prev_streak i
  case "$ra" in ''|*[!0-9]*) ra=0 ;; esac
  if [ "$ra" -gt 0 ] 2>/dev/null; then
    [ "$ra" -lt 30 ] 2>/dev/null && ra=30
    [ "$ra" -gt "$RATE_LIMIT_MAX" ] 2>/dev/null && ra=$RATE_LIMIT_MAX
    FETCH_DETAIL="retry-after=$ra"
  else
    if [ -s "$ERRF" ]; then   # a success removes $ERRF, so a rate-limited record = no success since
      prev_reason=$(sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' "$ERRF" 2>/dev/null | head -1)
      prev_detail=$(sed -n 's/.*"detail":"\([^"]*\)".*/\1/p' "$ERRF" 2>/dev/null | head -1)
      prev_streak=$(printf '%s' "$prev_detail" | sed -n 's/.*streak=\([0-9]*\).*/\1/p')
      if [ "$prev_reason" = "rate-limited" ]; then
        case "$prev_streak" in ''|*[!0-9]*) prev_streak=1 ;; esac
        streak=$(( prev_streak + 1 ))
      fi
    fi
    ra=$RATE_LIMIT_DEFAULT; i=1
    while [ "$i" -lt "$streak" ] && [ "$ra" -lt "$RATE_LIMIT_MAX" ]; do ra=$(( ra * 2 )); i=$(( i + 1 )); done
    [ "$ra" -lt 30 ] 2>/dev/null && ra=30
    [ "$ra" -gt "$RATE_LIMIT_MAX" ] 2>/dev/null && ra=$RATE_LIMIT_MAX
    FETCH_DETAIL="retry-after=none streak=$streak"
  fi
  __fail "rate-limited" "$ra"
}
# 401/403 on the endpoint for an env token = missing user:profile scope (setup tokens
# never gain it). Remember it so the next refreshes skip the endpoint — every 403 counts
# against the same edge quota — and go straight to the header probe. A 200 clears it.
__scope_memo_fresh() {
  local at now
  [ -s "$SCOPEF" ] || return 1
  at=$(sed -n 's/.*"at":\([0-9]*\).*/\1/p' "$SCOPEF" 2>/dev/null | head -1)
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s); [ $(( now - at )) -lt "$SCOPE_MEMO_TTL" ]
}
__scope_memo_write() {  # <http-code>
  printf '{"at":%s,"code":"%s","reason":"no-user-profile-scope"}\n' "$(date +%s)" "$1" > "$SCOPEF" 2>/dev/null || true
}
# #2012: a 429 on the endpoint for an env token is the SAME situation as a 401/403 —
# the shared edge quota, not this key's scope — so it gets the same treatment: fall
# through to the header probe right away, and while $ERRF still records a live
# "rate-limited" window (honoring Retry-After, claude-pattern#36), later refreshes
# route straight to the probe too rather than re-touching the endpoint. Reads $ERRF
# directly (no separate memo file needed — __rate_limited already wrote it).
__rate_limited_fresh() {
  local at reason code now
  [ -s "$ERRF" ] || return 1
  at=$(sed -n 's/.*"at":\([0-9]*\).*/\1/p' "$ERRF" 2>/dev/null | head -1)
  reason=$(sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' "$ERRF" 2>/dev/null | head -1)
  code=$(sed -n 's/.*"code":"\([0-9]*\)".*/\1/p' "$ERRF" 2>/dev/null | head -1)
  [ "$reason" = "rate-limited" ] || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  case "$code" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $(( now - at )) -lt "$code" ]
}
# The rate-limit HEADER probe (max_tokens:1 /v1/messages); PLAN_USAGE_PROBE_CMD = test seam.
__probe() {  # reads $tok (caller's local) → prints usage JSON; 0 = ok, 22 = probe failed
  if [ -n "${PLAN_USAGE_PROBE_CMD:-}" ]; then "$PLAN_USAGE_PROBE_CMD" 2>/dev/null; return $?; fi
  command -v python3 >/dev/null 2>&1 || return 22
  printf '%s' "$tok" | python3 -c "$PROBE_PY" 2>/dev/null
  [ "${PIPESTATUS[1]:-1}" = "0" ] && return 0
  return 22
}
# Seconds a render must still wait before spawning another refresh (0 = none):
# Retry-After after a 429, FAIL_BACKOFF after any other failure; a success clears it.
__backoff_left() {
  local at reason code until now writer
  [ -s "$ERRF" ] || { echo 0; return 0; }
  at=$(sed -n 's/.*"at":\([0-9]*\).*/\1/p' "$ERRF" 2>/dev/null | head -1)
  reason=$(sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' "$ERRF" 2>/dev/null | head -1)
  code=$(sed -n 's/.*"code":"\([0-9]*\)".*/\1/p' "$ERRF" 2>/dev/null | head -1)
  writer=$(sed -n 's/.*"writer":"\([^"]*\)".*/\1/p' "$ERRF" 2>/dev/null | head -1)
  case "$at" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  # Another renderer's failure (or a record from a helper too old to sign one) is
  # information, not a gate: its environment broke, mine may work.
  if [ "$reason" != "rate-limited" ] && [ "$writer" != "$WRITER" ]; then echo 0; return 0; fi
  if [ "$reason" = "rate-limited" ] && [ -n "$code" ]; then until=$(( at + code ))
  elif [ "$reason" = "no-token" ] || [ "$reason" = "no-tool" ]; then until=$(( at + NOTOKEN_BACKOFF ))
  else until=$(( at + FAIL_BACKOFF )); fi
  now=$(date +%s)
  if [ "$until" -gt "$now" ]; then echo $(( until - now )); else echo 0; fi
}

__fetch() {  # → prints body; return 0 = HTTP 200 body, 22 = HTTP error, 3 = no token, 4 = no tool, 1 = other
  local tok src="$1" body code hdr ra frc acct kc_out kc_rc
  FETCH_DETAIL=""
  if [ -n "${PLAN_USAGE_FETCH_CMD:-}" ]; then
    if [ "$src" = "env" ] && __scope_memo_fresh; then __probe; return $?; fi   # memo: endpoint never touched
    if [ "$src" = "env" ] && __rate_limited_fresh; then                       # memo: endpoint never touched
      __probe && return 0
      return 29   # probe ALSO failed: return 29 (not 22) so __refresh's rc=29 short-circuit
    fi            # leaves $ERRF's "rate-limited" record alone instead of __fail("fetch") clobbering it
    "$PLAN_USAGE_FETCH_CMD" "--$src" 2>/dev/null; frc=$?
    if [ "$frc" = "29" ]; then                                               # tests: exit 29 = HTTP 429
      __rate_limited "${PLAN_USAGE_FETCH_RETRY_AFTER:-}"
      if [ "$src" = "env" ]; then                                            # #2012: env token -> header probe, not a 22-min blank
        __probe && return 0
        return 29
      fi
      return 29
    fi
    if [ "$frc" = "43" ] && [ "$src" = "env" ]; then __scope_memo_write 403; __probe; return $?; fi   # tests: exit 43 = HTTP 403
    [ "$frc" = "0" ] && rm -f "$SCOPEF" 2>/dev/null
    return $frc
  fi
  command -v curl >/dev/null 2>&1 || { printf 'missing=curl'; return 4; }
  if [ "$src" = "env" ]; then
    tok="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  else
    command -v security >/dev/null 2>&1 || { printf 'missing=security'; return 4; }
    command -v python3  >/dev/null 2>&1 || { printf 'missing=python3'; return 4; }
    # The keychain item is per login user. A renderer spawned without USER in its
    # environment (a bg daemon session) asked for account "" and got nothing —
    # then its failure backoff starved every pane on that login (2026-09-02).
    acct="${USER:-$(id -un 2>/dev/null)}"
    kc_out=$(security find-generic-password -s "Claude Code-credentials" -a "$acct" -w 2>/dev/null); kc_rc=$?
    tok=$(printf '%s' "$kc_out" | python3 -c 'import sys,json
try:
    print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])
except Exception:
    pass' 2>/dev/null)
    # Diagnosable, never sensitive: the security exit status (44 = no item for this
    # account, 36 = keychain locked / no UI), the account asked for, the blob size.
    # __fetch runs inside $(…), so on 3/4 the detail IS the printed body.
    [ -n "$tok" ] || { printf 'keychain rc=%s acct=%s bytes=%s' "$kc_rc" "$acct" "${#kc_out}"; return 3; }
    kc_out=""
  fi
  [ -n "$tok" ] || { printf 'env token empty'; return 3; }
  if [ "$src" = "env" ] && __scope_memo_fresh; then __probe; return $?; fi   # memo: endpoint never touched
  if [ "$src" = "env" ] && __rate_limited_fresh; then                       # memo: endpoint never touched
    __probe && return 0
    return 29   # probe ALSO failed: return 29 (not 22) so __refresh's rc=29 short-circuit
  fi            # leaves $ERRF's "rate-limited" record alone instead of __fail("fetch") clobbering it
  body="$CACHE.body.$$"; hdr="$CACHE.hdr.$$"
  # `-K -`: the Authorization header travels in a curl CONFIG on stdin, so the
  # token is not on argv (readable by any process of this user via `ps`).
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" \
    | curl -sS -K - -H "anthropic-beta: oauth-2025-04-20" -H "Accept: application/json" \
        --max-time "$CURL_MAX" -o "$body" -D "$hdr" -w '%{http_code}' "$USAGE_URL" 2>/dev/null)
  if [ "$code" = "200" ]; then cat "$body" 2>/dev/null; rm -f "$body" "$hdr" "$SCOPEF"; return 0; fi
  if [ "$code" = "429" ]; then
    ra=$(tr -d '\r' < "$hdr" 2>/dev/null | awk 'tolower($1)=="retry-after:" {print $2; exit}')
    rm -f "$body" "$hdr"; __rate_limited "$ra"
    if [ "$src" = "env" ]; then   # #2012: env token -> header probe, not a 22-min blank
      __probe && return 0
      return 29
    fi
    return 29
  fi
  rm -f "$hdr"
  # Setup tokens (sk-ant-oat…, fleet lanes) lack the user:profile scope the usage
  # endpoint demands (403). The rate-limit HEADERS of a max_tokens:1 call carry
  # the same 5h/7d gauge and work for every token kind — the accounts skill's
  # probe. Synthesize the endpoint's shape from them (limits[] included) so the
  # consumer never branches on the source.
  rm -f "$body"
  if [ "$src" = "env" ] && { [ "$code" = "403" ] || [ "$code" = "401" ]; }; then
    __scope_memo_write "$code"; __probe; return $?
  fi
  return 22
}

__refresh() {
  local src body rc now tmp
  src=keychain; [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && src=env
  command -v python3 >/dev/null 2>&1 || { __fail "no-python3"; return 0; }
  body=$(__fetch "$src"); rc=$?
  [ "$rc" = "29" ] && return 0                     # 429: __rate_limited already recorded the window
  [ "$rc" = "3" ] && { FETCH_DETAIL="$body"; __fail "no-token" "$rc"; return 0; }   # spawner's environment, short backoff
  [ "$rc" = "4" ] && { FETCH_DETAIL="$body"; __fail "no-tool" "$rc"; return 0; }
  if [ "$rc" != "0" ] || [ -z "$body" ]; then __fail "fetch" "$rc"; return 0; fi
  now=$(date +%s); tmp="$CACHE.tmp.$$"
  # Validate, stamp _meta, append the history sample, compute rates — one python.
  printf '%s' "$body" | PU_NOW="$now" PU_SRC="$src" PU_KEY="$KEY" PU_EMAIL="$ACCOUNT_EMAIL" \
    PU_HIST="$HIST" PU_TTL="$TTL" PU_STALE="$STALE_MAX" PU_KEEP="$HIST_KEEP" PU_WIN="$RATE_WINDOW_S" \
    python3 -c "$META_PY" > "$tmp" 2>/dev/null
  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$CACHE" 2>/dev/null && rm -f "$ERRF" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null; __fail "invalid-response"
  fi
  return 0
}

# ── lock helpers ─────────────────────────────────────────────────────────────
# mkdir is atomic on every filesystem we run on. A lock older than 4× the bound
# cannot belong to a live bounded refresh → orphan (killed shell), reclaimed.
__lock() {
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
  chmod 700 "$CACHE_DIR" 2>/dev/null || true
  if mkdir "$LOCK" 2>/dev/null; then printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null; return 0; fi
  if [ "$(__age_s "$LOCK")" -gt $(( BOUND_S * 4 )) ] 2>/dev/null; then
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null && { printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null; return 0; }
  fi
  return 1
}
__unlock() { rm -rf "$LOCK" 2>/dev/null; }

__timeout_bin() {
  if command -v gtimeout >/dev/null 2>&1; then echo gtimeout
  elif command -v timeout >/dev/null 2>&1; then echo timeout
  else echo ""; fi
}

# Wait (poll) until the cache is newer than $1 (epoch) or $2 seconds elapse.
__wait_for_fresh() {
  local since="$1" max="$2" i=0 m
  while [ "$i" -lt $(( max * 5 )) ]; do
    if [ -s "$CACHE" ]; then
      m=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
      [ "${m:-0}" -ge "$since" ] 2>/dev/null && return 0
    fi
    sleep 0.2 2>/dev/null || sleep 1
    i=$(( i + 1 ))
  done
  return 1
}

# ── modes ────────────────────────────────────────────────────────────────────
case "$MODE" in
  refresh)
    # Internal: the detached body. The lock was created by the spawning render and
    # is ours to release. Bounded by the parent's timeout binary when present.
    trap '__unlock' EXIT INT TERM
    __refresh
    exit 0 ;;
  sync)
    since=$(date +%s)
    if __lock; then
      trap '__unlock' EXIT INT TERM
      __refresh
    else
      # A refresh is already in flight (another pane) — wait for it to land.
      __wait_for_fresh "$since" "$BOUND_S" || true
    fi
    __serve; exit 0 ;;
esac

# ── default: stale-while-revalidate ─────────────────────────────────────────
if [ -s "$CACHE" ] && [ "$(__age_s "$CACHE")" -lt "$TTL" ] 2>/dev/null; then
  __serve; exit 0
fi
# Backing off after a failed refresh (429 Retry-After, else FAIL_BACKOFF): serve what
# we have and spawn nothing — every render retrying is what drained the bucket.
# #2012 exception: an env-token 429 backoff is honored for the ENDPOINT only — the
# header probe is a different call (max_tokens:1 /v1/messages, not /api/oauth/usage)
# and __fetch/__rate_limited_fresh already route this account straight to it, so
# skipping the spawn here would just mean the probe fallback never runs again until
# the whole Retry-After window (up to 6h) elapses.
if [ "$(__backoff_left)" -gt 0 ] 2>/dev/null; then
  __bo_reason=""
  [ -s "$ERRF" ] && __bo_reason=$(sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' "$ERRF" 2>/dev/null | head -1)
  if [ "$__bo_reason" != "rate-limited" ] || [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    __serve; exit 0
  fi
fi

since=$(date +%s)
if __lock; then
  TB=$(__timeout_bin)
  (
    set -m 2>/dev/null
    if [ -n "$TB" ]; then
      nohup "$TB" "${BOUND_S}s" bash "$0" --refresh </dev/null >/dev/null 2>&1 &
    else
      nohup bash "$0" --refresh </dev/null >/dev/null 2>&1 &
    fi
  ) 2>/dev/null
  # Belt and braces: if the child never runs (fork failure) the orphan rule
  # reclaims the lock after 4× the bound.
fi

if [ -s "$CACHE" ]; then
  __serve; exit 0
fi
# Cold cache: this account has never been sampled on this machine. Give the
# detached refresh a moment so the very first render is not blank.
__wait_for_fresh "$since" "$COLD_WAIT" || true
__serve
exit 0
