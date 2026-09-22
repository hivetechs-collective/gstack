#!/usr/bin/env python3
"""Header-based usage gauge + the usage cache for multi-account routing.

The enabling fact (verified 2026-08-31): an ordinary ``max_tokens:1`` Claude Code
inference call returns the account's REAL 5h/7d utilization and exact reset epochs
in ``anthropic-ratelimit-unified-*`` response headers — needing only
``user:inference`` scope. This module reads that gauge and owns every mutation of
``usage-cache.json`` (all serialized with ``fcntl.flock``).

Model-scoped weekly buckets (2026-09-18, cache schema 2): probing with the FABLE
model (``_DEFAULT_PRIMARY_MODEL``) makes the same response carry a ``7d_oi-*`` triple
(utilization / status / reset) — the Fable weekly bucket, live, for ANY token kind.
Haiku/Opus probes omit it, and the server refuses the Fable model to a client
older than 2.1.251 (HTTP 400 ``claude_code_version_too_old``), so the probe sends
the INSTALLED CLI version as its user-agent and falls back to the haiku model in
the same tick when the primary is refused. The plan-usage.sh sample (login-only,
email-keyed) remains a second-choice source and is DISCARDED when it predates the
account's current 7-day window — that stale-sample path is what recommended an
account at "Fable 95 %" two days after its week had reset.

Account ``status`` derives from the PER-WINDOW statuses (worst of 5h / 7d) and
NEVER from the Fable bucket: a Fable-exhausted account answers a Fable probe with a
top-level ``status: rejected`` while its 5h/7d are fine, and an Opus/Sonnet lane
must still be able to use it. Callers that need Fable pass ``need="fable"`` to the
selector.

SECURITY:
  * The token is treated as OPAQUE — never decoded, never logged. It leaves the
    machine only as an ``Authorization: Bearer`` header to ``api.anthropic.com``.
  * Gauges NEVER carry a token (asserted below); the cache holds usage numbers +
    the reactive ``limited_until`` only.

FAIL-OPEN on measurement, FAIL-SAFE on correctness: a probe that fails for a
non-limit reason keeps the last reading (marked ``stale``) up to a staleness
ceiling, then reports UNKNOWN so the caller falls back to the ambient login — it
never idles a fleet because a measurement was missed. A real 429 (with headers)
is a valid measurement (auth proven) and is always honored.

Env knobs:
  PWT_ACCT_PROBE_MODEL           primary probe model   (default: _DEFAULT_PRIMARY_MODEL, the Fable model)
  PWT_ACCT_PROBE_FALLBACK_MODEL  fallback probe model  (default claude-haiku-4-5-20251001)
  PWT_ACCT_CLI_VERSION           user-agent version override (default: `claude --version`,
                                 cached 24 h beside the registry; fallback 2.1.276)
  PWT_ACCT_USAGE_TTL             cache freshness seconds (default 600)
  PWT_ACCT_MAX_STALE             staleness ceiling secs  (default 3600)
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from datetime import datetime, timezone

from registry import resolve_cache_path, resolve_registry_path  # sibling module

API_URL = "https://api.anthropic.com/v1/messages"
# The oauth usage endpoint plan-usage.sh samples (login tokens only; setup tokens
# answer 403/429 here). Kept as the opt-in second source.
SCOPED_URL = "https://api.anthropic.com/api/oauth/usage"
_PLAN_USAGE_DIR = os.path.join(os.path.expanduser("~"), ".config", "claude-pattern", "plan-usage")
SYSTEM_PROMPT = "You are Claude Code, Anthropic's official CLI for Claude."
_PROBE_TIMEOUT_S = 30
_HEADER_PREFIX = "anthropic-ratelimit-unified-"
CACHE_VERSION = 2

# Header bucket suffix → display name. ``7d_oi`` is the Fable weekly bucket
# (verified on five accounts, 2026-09-18). An unmapped ``7d_<bucket>`` is kept
# under its raw bucket name so a new scoped model shows up without a code edit.
SCOPED_BUCKETS = {"oi": "Fable"}
_SCOPED_RE = re.compile(r"^" + re.escape(_HEADER_PREFIX) + r"7d_([a-z0-9]+)-utilization$")
_STATUS_RANK = {"allowed": 0, "allowed_warning": 1, "rejected": 2}

_DEFAULT_PRIMARY_MODEL = "claude-fable-5-1"
_DEFAULT_FALLBACK_MODEL = "claude-haiku-4-5-20251001"
_UA_FALLBACK_VERSION = "2.1.276"
_UA_CACHE_TTL_S = 86400
_SEVEN_DAYS_S = 7 * 86400


class MeasurementError(Exception):
    """A probe failed for a non-limit reason (network/timeout). The caller keeps
    the last reading (fail-open); it is NOT a rate limit."""


def _probe_model() -> str:
    return os.environ.get("PWT_ACCT_PROBE_MODEL") or _DEFAULT_PRIMARY_MODEL


def _fallback_model() -> str:
    return os.environ.get("PWT_ACCT_PROBE_FALLBACK_MODEL") or _DEFAULT_FALLBACK_MODEL


def _warn(msg: str) -> None:
    print("pwt-accounts probe: %s" % msg, file=sys.stderr)


# ── user-agent: the INSTALLED CLI version ─────────────────────────────────────
def _ua_cache_path() -> str:
    return os.path.join(os.path.dirname(resolve_registry_path()), "cli-version")


def _cli_version(now: float = None) -> str:
    """The version string the user-agent carries. Order: ``PWT_ACCT_CLI_VERSION``,
    a < 24 h cache file beside the registry, ``claude --version`` (bounded, cached
    best-effort at 0600), then the last version this module was verified against.
    Never raises; never blocks longer than a few seconds."""
    env = (os.environ.get("PWT_ACCT_CLI_VERSION") or "").strip()
    if re.match(r"^\d+\.\d+\.\d+$", env):
        return env
    now = time.time() if now is None else now
    path = _ua_cache_path()
    try:
        st = os.stat(path)
        if now - st.st_mtime < _UA_CACHE_TTL_S:
            with open(path, encoding="utf-8") as f:
                v = f.read().strip()
            if re.match(r"^\d+\.\d+\.\d+$", v):
                return v
    except OSError:
        pass
    v = ""
    try:
        out = subprocess.run(["claude", "--version"], capture_output=True, text=True,
                             timeout=8, check=False).stdout
        m = re.search(r"(\d+\.\d+\.\d+)", out or "")
        if m:
            v = m.group(1)
    except (OSError, subprocess.SubprocessError, ValueError):
        v = ""
    if not v:
        return _UA_FALLBACK_VERSION
    try:
        d = os.path.dirname(path)
        if os.path.isdir(d):
            fd, tmp = tempfile.mkstemp(dir=d, prefix=".cli-version-")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                os.fchmod(f.fileno(), 0o600)
                f.write(v + "\n")
            os.replace(tmp, path)
    except OSError:
        pass
    return v


def _user_agent() -> str:
    return "claude-cli/%s (external, cli)" % _cli_version()


def _iso(epoch: float = None) -> str:
    ts = time.time() if epoch is None else epoch
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s) -> float:
    """ISO8601 (with optional fractional seconds / Z) → epoch float, or None."""
    if not s:
        return None
    t = str(s).strip().replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(t)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except ValueError:
        return None


def _parse_epoch(s):
    if s is None:
        return None
    try:
        return float(str(s).strip())
    except (TypeError, ValueError):
        return None


def _parse_ts_any(s):
    """``limited_until`` in EITHER form: epoch string (header-derived, 2.43.0)
    or ISO8601 (``mark_limited``'s reactive form) -> epoch float, or None."""
    v = _parse_epoch(s)
    return v if v is not None else _parse_iso(s)


def later_limited_until(a, b):
    """Merge two ``limited_until`` values: the LATER instant wins, an unparsable
    or missing side yields to the other. Pure."""
    ta, tb = _parse_ts_any(a), _parse_ts_any(b)
    if ta is None:
        return b
    if tb is None:
        return a
    return a if ta >= tb else b


# ── pure header → gauge ───────────────────────────────────────────────────────
def _header_items(headers):
    if hasattr(headers, "items"):
        return headers.items()
    return dict(headers).items()


def _worst_status(*statuses):
    """The worst of the given window statuses (None entries ignored); None when
    every input is None. Unknown strings rank as rejected (fail-safe)."""
    best = None
    for s in statuses:
        if s is None:
            continue
        r = _STATUS_RANK.get(str(s), 2)
        if best is None or r > best[0]:
            best = (r, s)
    return best[1] if best else None


def _scoped_gauge_keys() -> dict:
    return {"scoped": {}, "scoped_status": {}, "scoped_reset": {},
            "scoped_source": "unavailable", "scoped_at": None}


def parse_usage_headers(headers, now: float = None, label=None, email=None) -> dict:
    """PURE: map ``anthropic-ratelimit-unified-*`` response headers (case-
    insensitive keys) into the gauge schema (Appendix A, cache schema 2).
    ``label``/``email`` are filled by the caller.

    * ``status`` = worst of ``5h-status`` / ``7d-status`` when either is present;
      the top-level ``status`` header is the fallback only. The Fable bucket
      NEVER feeds it.
    * Every ``7d_<bucket>-utilization`` (today ``7d_oi`` = Fable) lands in
      ``scoped`` / ``scoped_status`` / ``scoped_reset`` with
      ``scoped_source: "ratelimit-header"``; a response without one leaves the
      scoped keys empty with ``scoped_source: "unavailable"`` (the caller may then
      fall back to a plan-usage sample).

    A response carrying NONE of the unified headers (e.g. an HTTP-200 with no
    rate-limit info) is a MISSED measurement → ``stale: true`` with null pcts,
    NEVER 0% (0% would attract every lane onto an account whose usage is
    actually unknown)."""
    low = {}
    for k, v in _header_items(headers):
        if isinstance(k, str):
            low[k.lower()] = v

    def g(suffix):
        return low.get(_HEADER_PREFIX + suffix)

    def pct_of(v):
        if v is None:
            return None
        try:
            return round(float(v) * 100, 1)
        except (TypeError, ValueError):
            return None

    def pct(suffix):
        return pct_of(g(suffix))

    have_any = any(
        g(s) is not None for s in
        ("status", "5h-utilization", "7d-utilization",
         "5h-reset", "7d-reset", "representative-claim"))
    measured_at = _iso(now)

    base = {
        "label": label, "email": email,
        "five_hour_pct": None, "seven_day_pct": None,
        "binding_window": None, "binding_pct": None,
        "five_hour_reset": None, "seven_day_reset": None,
        "five_hour_status": None, "seven_day_status": None,
        "status": None, "limited_until": None,
        "measured_at": measured_at, "source": "ratelimit-header",
        "stale": True,
    }
    base.update(_scoped_gauge_keys())
    if not have_any:
        return base

    fh = pct("5h-utilization")
    sd = pct("7d-utilization")
    binding_window = g("representative-claim")
    if binding_window == "five_hour":
        binding_pct = fh
    elif binding_window == "seven_day":
        binding_pct = sd
    else:
        # e.g. "seven_day_overage_included" — the Fable bucket is the binding
        # claim; it must not masquerade as the account's 7d headroom.
        binding_pct = None
    fh_status = g("5h-status")
    sd_status = g("7d-status")
    status = _worst_status(fh_status, sd_status)
    if status is None:
        status = g("status")

    scoped, scoped_status, scoped_reset = {}, {}, {}
    for key in low:
        m = _SCOPED_RE.match(key)
        if not m:
            continue
        bucket = m.group(1)
        name = SCOPED_BUCKETS.get(bucket, bucket)
        p = pct_of(low.get(key))
        if p is None:
            continue
        scoped[name] = p
        scoped_status[name] = g("7d_%s-status" % bucket)
        scoped_reset[name] = g("7d_%s-reset" % bucket)

    # A REJECTED window benches the account until that window resets: write it
    # as ``limited_until`` (epoch string, the same form as ``seven_day_reset``)
    # so a consumer that only knows the v1 backstop (a future ``limited_until``)
    # holds the account immediately, without learning the per-window statuses.
    # The Fable bucket never feeds it (a Fable-exhausted account stays open to
    # Opus/Sonnet lanes). Later of the two rejected windows wins.
    limited_until = None
    for st, reset in ((fh_status, g("5h-reset")), (sd_status, g("7d-reset"))):
        if st != "rejected":
            continue
        cand = _parse_epoch(reset)
        if cand is None:
            continue
        if limited_until is None or cand > limited_until:
            limited_until = cand

    base.update({
        "five_hour_pct": fh, "seven_day_pct": sd,
        "binding_window": binding_window, "binding_pct": binding_pct,
        "five_hour_reset": g("5h-reset"), "seven_day_reset": g("7d-reset"),
        "five_hour_status": fh_status, "seven_day_status": sd_status,
        "status": status,
        "limited_until": (str(int(limited_until)) if limited_until is not None else None),
        "stale": False,
    })
    if scoped:
        base.update({"scoped": scoped, "scoped_status": scoped_status,
                     "scoped_reset": scoped_reset,
                     "scoped_source": "ratelimit-header", "scoped_at": measured_at})
    return base


# ── the live probe (injectable transport) ─────────────────────────────────────
def _default_transport(url, data, headers, timeout):
    """POST via urllib. Returns ``(status, headers)``. A 429 (or other HTTPError)
    still carries the rate-limit headers, so it is a VALID measurement, not an
    error. Only a network/timeout failure raises MeasurementError."""
    req = urllib.request.Request(url, data=data, method="POST", headers=headers)
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        return r.status, r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.headers
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        # Message carries only the error TYPE — never the token/headers.
        raise MeasurementError("network: %s" % type(e).__name__)


def parse_scoped_usage(body) -> dict:
    """Pure: ``{display_name: percent}`` for every ``weekly_scoped`` limit in an
    oauth/usage body (bytes/str/dict). Anything unparseable → ``{}``."""
    try:
        if isinstance(body, (bytes, bytearray)):
            body = body.decode("utf-8", "replace")
        d = json.loads(body) if isinstance(body, str) else body
    except (ValueError, TypeError):
        return {}
    out = {}
    if not isinstance(d, dict):
        return out
    for lim in d.get("limits") or []:
        if not isinstance(lim, dict) or lim.get("kind") != "weekly_scoped":
            continue
        name = (((lim.get("scope") or {}).get("model") or {}).get("display_name")) or ""
        p = lim.get("percent")
        if name and isinstance(p, (int, float)) and not isinstance(p, bool):
            out[name] = float(p)
    return out


def _plan_usage_scoped_sample(email, cache_dir=None):
    """Newest plan-usage.sh sample for this email (its cache is the raw endpoint
    body + ``_meta.account_email`` / ``_meta.fetched_at``), as ``(scoped, at)`` or
    None. Email is OPTIONAL metadata (a registry row may carry ``null``) — no
    email means no sample, never an error. Never touches the network, never
    raises."""
    if not email:
        return None
    cache_dir = cache_dir or os.environ.get("PLAN_USAGE_CACHE_DIR") or _PLAN_USAGE_DIR
    best = None
    try:
        names = os.listdir(cache_dir)
    except OSError:
        return None
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(cache_dir, name)) as f:
                body = json.load(f)
            meta = body.get("_meta") or {}
            if meta.get("account_email") != email:
                continue
            at = float(meta.get("fetched_at") or 0)
        except (OSError, ValueError, AttributeError, TypeError):
            continue
        if at and (best is None or at > best[1]):
            best = (parse_scoped_usage(body), at)
    return best


def _default_get_transport(url, headers, timeout):
    """GET via urllib. Returns ``(status, body_bytes)``; an HTTPError returns its
    status with an empty body (a 429 here is the endpoint's sample floor — no data,
    not a measurement). Network failures raise MeasurementError."""
    req = urllib.request.Request(url, method="GET", headers=headers)
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b""
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise MeasurementError("network: %s" % type(e).__name__)


def probe_scoped(token, email=None, transport=None, now: float = None):
    """SECOND-CHOICE model-scoped weekly percentages for one account as
    ``(scoped, at_epoch)`` — ``{display_name: pct}`` — or None when unavailable.
    Source: the newest plan-usage.sh sample for the email (free, no network). The
    direct GET of the usage endpoint is opt-in (``PWT_ACCT_SCOPED_PROBE=1``):
    registry setup-tokens answer 403/429 there, and a rejection still counts
    against the endpoint's rolling edge quota. Fail-open: any failure, 429 or
    non-200 → None. The caller (``resolve_usage``) applies the window check."""
    now = time.time() if now is None else now
    sample = _plan_usage_scoped_sample(email)
    if sample is not None:
        return sample
    if os.environ.get("PWT_ACCT_SCOPED_PROBE", "0") != "1" or not token:
        return None
    transport = transport or _default_get_transport
    headers = {"Authorization": "Bearer %s" % token,
               "anthropic-beta": "oauth-2025-04-20",
               "Accept": "application/json"}
    try:
        status, body = transport(SCOPED_URL, headers, _PROBE_TIMEOUT_S)
    except MeasurementError:
        return None
    if status != 200:
        return None
    scoped = parse_scoped_usage(body)
    return (scoped, now) if scoped else None


def _probe_once(token, model, transport, now):
    body = json.dumps({
        "model": model,
        "max_tokens": 1,
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": "."}],
    }).encode("utf-8")
    headers = {
        "authorization": "Bearer " + str(token),
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "oauth-2025-04-20",
        "user-agent": _user_agent(),
        "content-type": "application/json",
    }
    status, resp_headers = transport(API_URL, body, headers, _PROBE_TIMEOUT_S)
    g = parse_usage_headers(resp_headers, now=now)
    g["probe_model"] = model
    return status, g


def probe_usage(token, transport=None, now: float = None) -> dict:
    """Measure one account. ``transport`` is injectable for offline tests and
    defaults to a real urllib POST. Returns a gauge (label/email unset — the
    caller fills them). Raises MeasurementError only on a non-limit failure; a
    429-with-headers returns a normal (rejected) gauge. The token never touches a
    log or stdout.

    The primary (Fable) model yields the scoped bucket. When the server refuses
    it without a measurement — HTTP 400 ``claude_code_version_too_old``, an
    unknown model, anything that is neither 200 nor 429 and carries no unified
    headers — the haiku fallback is probed in the SAME tick so the 5h/7d gauge
    never goes missing because of a client-version bump; the gauge then reports
    ``scoped_source: "unavailable"`` and a one-line stderr warning names the
    status. A 401/403 fails on both models and returns the stale gauge as before."""
    transport = transport or _default_transport
    primary = _probe_model()
    status, g = _probe_once(token, primary, transport, now)
    if status in (200, 429) or not g.get("stale"):
        return g
    fallback = _fallback_model()
    if fallback == primary:
        return g
    _warn("primary probe model %s refused (HTTP %s) — falling back to %s; "
          "scoped (Fable) bucket unavailable this tick" % (primary, status, fallback))
    _status2, g2 = _probe_once(token, fallback, transport, now)
    g2["probe_fallback_from"] = primary
    g2["probe_fallback_http"] = status
    return g2


# ── cache I/O (flock-serialized, atomic 0600) ─────────────────────────────────
def _empty_cache() -> dict:
    return {"version": CACHE_VERSION, "gauges": {}}


@contextmanager
def _flock(path: str):
    d = os.path.dirname(os.path.abspath(path))
    if not os.path.isdir(d):
        os.makedirs(d, mode=0o700, exist_ok=True)
        try:
            os.chmod(d, 0o700)
        except OSError:
            pass
    lockpath = os.path.join(d, "." + os.path.basename(path) + ".lock")
    fd = os.open(lockpath, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)


def _read_cache_unlocked(path: str) -> dict:
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return _empty_cache()
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (ValueError, OSError):
        return _empty_cache()
    if not isinstance(data, dict):
        return _empty_cache()
    data.setdefault("version", 1)
    if not isinstance(data.get("gauges"), dict):
        data["gauges"] = {}
    return data


def _write_cache_unlocked(data: dict, path: str) -> None:
    d = os.path.dirname(os.path.abspath(path))
    if not os.path.isdir(d):
        os.makedirs(d, mode=0o700, exist_ok=True)
        try:
            os.chmod(d, 0o700)
        except OSError:
            pass
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".usage-cache-", suffix=".json")
    try:
        os.chmod(tmp, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            # Defense in depth: a cache must never carry a token.
            _scrub_tokens(data)
            json.dump(data, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _scrub_tokens(data: dict) -> None:
    for g in (data.get("gauges") or {}).values():
        if isinstance(g, dict):
            g.pop("token", None)


def read_cache(path: str = None) -> dict:
    """Best-effort read of the usage cache (never raises; missing/corrupt →
    empty). The cache is 0600 and holds no token, so a loose-perms cache is
    warned about but still read — write_cache resets it to 0600."""
    path = path or resolve_cache_path()
    if os.path.exists(path):
        try:
            st = os.stat(path)
            if st.st_mode & 0o077:
                print("pwt-accounts: warning — usage cache perms loose; "
                      "resetting to 0600 on next write: %s" % path, file=sys.stderr)
        except OSError:
            pass
    return _read_cache_unlocked(path)


def write_cache(data: dict, path: str = None) -> None:
    """Atomic, flock-serialized 0600 write of the usage cache."""
    path = path or resolve_cache_path()
    with _flock(path):
        _write_cache_unlocked(data, path)


def mark_limited(label, until_iso, cache_path: str = None) -> None:
    """Reactive 429 backstop: bench *label* until *until_iso* (ISO8601). Serialized
    under flock; creates a minimal cache entry if the account has none yet."""
    path = cache_path or resolve_cache_path()
    with _flock(path):
        cur = _read_cache_unlocked(path)
        gauges = cur.setdefault("gauges", {})
        entry = gauges.get(label) or {"label": label}
        entry["limited_until"] = until_iso
        gauges[label] = entry
        _write_cache_unlocked(cur, path)


def _is_unknown(gauge: dict) -> bool:
    if not gauge:
        return True
    if gauge.get("status") == "UNKNOWN":
        return True
    return gauge.get("five_hour_pct") is None and gauge.get("seven_day_pct") is None


def _unknown_gauge(label, email, now) -> dict:
    g = {
        "label": label, "email": email,
        "five_hour_pct": None, "seven_day_pct": None,
        "binding_window": None, "binding_pct": None,
        "five_hour_reset": None, "seven_day_reset": None,
        "five_hour_status": None, "seven_day_status": None,
        "status": "UNKNOWN", "limited_until": None,
        "measured_at": _iso(now), "source": "ratelimit-header",
        "stale": True,
    }
    g.update(_scoped_gauge_keys())
    return g


# ── window-aware scoped fallback + burn since the previous sample ─────────────
def scoped_sample_in_window(sample_at, seven_day_reset, now) -> bool:
    """PURE: True when a scoped sample taken at ``sample_at`` (epoch) belongs to
    the account's CURRENT 7-day window. The Fable weekly bucket resets at the
    same instant as the 7d window (verified on every stored sample), so a sample
    older than ``seven_day_reset - 7d`` — or from the future — describes a
    previous week and must not be shown. An unknown reset keeps the sample only
    while it is younger than 7 days."""
    if sample_at is None:
        return False
    if sample_at > now + 60:
        return False
    reset = _parse_epoch(seven_day_reset)
    # A reset more than 7 days out (or already past) cannot bound a real
    # window — treat it as unknown rather than compute a start in the future.
    if reset is None or reset > now + _SEVEN_DAYS_S or reset < now:
        return (now - sample_at) < _SEVEN_DAYS_S
    return sample_at >= reset - _SEVEN_DAYS_S


def _attach_scoped_fallback(g: dict, prev: dict, token, email, scoped_transport, now) -> None:
    """When the header probe carried no scoped bucket, attach the newest
    window-valid candidate: a plan-usage sample for the email, or the previous
    cached scoped reading (keeping its own source label). Anything outside the
    current 7-day window is discarded → ``scoped_source: "unavailable"``."""
    candidates = []
    sample = probe_scoped(token, email, transport=scoped_transport, now=now)
    if sample is not None and sample[0]:
        candidates.append((sample[1], sample[0], "plan-usage-sample", {}, {}))
    if prev.get("scoped"):
        p_at = _parse_iso(prev.get("scoped_at"))
        if p_at is not None:
            candidates.append((p_at, prev["scoped"], prev.get("scoped_source") or "plan-usage-sample",
                               prev.get("scoped_status") or {}, prev.get("scoped_reset") or {}))
    candidates.sort(key=lambda c: c[0], reverse=True)
    for at, scoped, source, st, rs in candidates:
        if scoped_sample_in_window(at, g.get("seven_day_reset"), now):
            g["scoped"], g["scoped_at"], g["scoped_source"] = scoped, _iso(at), source
            g["scoped_status"], g["scoped_reset"] = st, rs
            return
    g.update(_scoped_gauge_keys())


def _burn_ppm(prev_pct, cur_pct, prev_at, cur_at):
    """Points per minute between two samples; None when either is missing, the
    interval is under a minute, or the window reset (pct dropped)."""
    if not all(isinstance(v, (int, float)) for v in (prev_pct, cur_pct)):
        return None
    if prev_at is None or cur_at is None or (cur_at - prev_at) < 60:
        return None
    if cur_pct < prev_pct:
        return None
    return round((cur_pct - prev_pct) / ((cur_at - prev_at) / 60.0), 3)


def _attach_previous(g: dict, prev: dict, now: float) -> None:
    """Carry the previous DISTINCT measurement so a consumer can compute burn vs
    reset (cleanscale ask, 2026-09-18). A stale/unknown previous is not a sample."""
    if not prev or _is_unknown(prev) or prev.get("stale"):
        g.update({"prev_five_hour_pct": None, "prev_seven_day_pct": None,
                  "prev_scoped": {}, "prev_measured_at": None,
                  "five_hour_burn_ppm": None, "seven_day_burn_ppm": None})
        return
    p_at = _parse_iso(prev.get("measured_at"))
    g["prev_five_hour_pct"] = prev.get("five_hour_pct")
    g["prev_seven_day_pct"] = prev.get("seven_day_pct")
    g["prev_scoped"] = dict(prev.get("scoped") or {})
    g["prev_measured_at"] = prev.get("measured_at")
    g["five_hour_burn_ppm"] = _burn_ppm(prev.get("five_hour_pct"), g.get("five_hour_pct"), p_at, now)
    g["seven_day_burn_ppm"] = _burn_ppm(prev.get("seven_day_pct"), g.get("seven_day_pct"), p_at, now)


def resolve_usage(registry: dict, cache_path: str = None, ttl: int = None,
                  max_stale: int = None, transport=None, now: float = None,
                  scoped_transport=None) -> list:
    """Return one gauge per ACTIVE account, reading the cache when fresh (< ttl)
    and probing otherwise. Fail-open: a probe failure keeps the last cached
    reading (marked stale) until it ages past ``max_stale``, then reports UNKNOWN.
    ``limited_until`` is merged from the cache (the reactive backstop). A probe
    error for one account NEVER raises out of this function, and no gauge ever
    carries a token. Gauges are LABEL-keyed; ``email`` is metadata and may be
    null."""
    cache_path = cache_path or resolve_cache_path()
    if ttl is None:
        ttl = int(os.environ.get("PWT_ACCT_USAGE_TTL", "600"))
    if max_stale is None:
        max_stale = int(os.environ.get("PWT_ACCT_MAX_STALE", "3600"))
    now = time.time() if now is None else now

    cache = _read_cache_unlocked(cache_path)
    cached = cache.get("gauges") or {}

    results = {}
    for acct in (registry.get("accounts") or []):
        if not acct.get("active"):
            continue
        label = acct.get("label")
        email = acct.get("email")
        token = acct.get("token")
        prev = cached.get(label) or {}
        prev_at = _parse_iso(prev.get("measured_at"))
        fresh = (prev and prev_at is not None
                 and (now - prev_at) < ttl and not _is_unknown(prev))

        if fresh:
            g = dict(prev)
        else:
            try:
                g = probe_usage(token, transport=transport, now=now)
                g["label"] = label
                g["email"] = email
                if g.get("scoped_source") != "ratelimit-header":
                    _attach_scoped_fallback(g, prev, token, email, scoped_transport, now)
                _attach_previous(g, prev, now)
            except MeasurementError:
                if (prev and prev_at is not None
                        and (now - prev_at) < max_stale and not _is_unknown(prev)):
                    g = dict(prev)
                    g["stale"] = True
                else:
                    g = _unknown_gauge(label, email, now)

        # Merge the reactive backstop from the cache (later instant wins over a
        # header-derived one; a fresh probe's own value is kept); never surface a token.
        g["limited_until"] = later_limited_until(g.get("limited_until"), prev.get("limited_until"))
        g.pop("token", None)
        # Invariant: a gauge must never carry a token.
        assert "token" not in g
        results[label] = g

    # Persist merged readings under flock, preserving a concurrently-written
    # limited_until (a racing mark_limited between our read and this write).
    try:
        with _flock(cache_path):
            cur = _read_cache_unlocked(cache_path)
            gmap = cur.get("gauges") or {}
            for label, gauge in results.items():
                merged = dict(gauge)
                existing = gmap.get(label) or {}
                if existing.get("limited_until") is not None:
                    merged["limited_until"] = later_limited_until(
                        merged.get("limited_until"), existing["limited_until"])
                gmap[label] = merged
            cur["gauges"] = gmap
            cur["version"] = CACHE_VERSION
            _write_cache_unlocked(cur, cache_path)
    except OSError:
        pass  # fail-open on cache write — dispatch continues on the in-memory result

    return list(results.values())
