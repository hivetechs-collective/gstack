#!/usr/bin/env python3
"""Header-based usage gauge + the usage cache for multi-account routing.

The enabling fact (verified 2026-08-31): an ordinary ``max_tokens:1`` Claude Code
inference call returns the account's REAL 5h/7d utilization and exact reset epochs
in ``anthropic-ratelimit-unified-*`` response headers — needing only
``user:inference`` scope. This module reads that gauge and owns every mutation of
``usage-cache.json`` (all serialized with ``fcntl.flock``).

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
  PWT_ACCT_PROBE_MODEL   probe model             (default claude-haiku-4-5-20251001)
  PWT_ACCT_USAGE_TTL     cache freshness seconds (default 600)
  PWT_ACCT_MAX_STALE     staleness ceiling secs  (default 3600)
"""
from __future__ import annotations

import fcntl
import json
import os
import tempfile
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from datetime import datetime, timezone

from registry import resolve_cache_path  # sibling module

API_URL = "https://api.anthropic.com/v1/messages"
# Model-scoped weekly buckets (e.g. Fable) are NOT in the rate-limit headers; they
# only come from the oauth usage endpoint that plan-usage.sh already samples.
SCOPED_URL = "https://api.anthropic.com/api/oauth/usage"
_PLAN_USAGE_DIR = os.path.join(os.path.expanduser("~"), ".config", "claude-pattern", "plan-usage")
SYSTEM_PROMPT = "You are Claude Code, Anthropic's official CLI for Claude."
_PROBE_TIMEOUT_S = 30
_HEADER_PREFIX = "anthropic-ratelimit-unified-"


class MeasurementError(Exception):
    """A probe failed for a non-limit reason (network/timeout). The caller keeps
    the last reading (fail-open); it is NOT a rate limit."""


def _probe_model() -> str:
    return os.environ.get("PWT_ACCT_PROBE_MODEL", "claude-haiku-4-5-20251001")


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


# ── pure header → gauge ───────────────────────────────────────────────────────
def _header_items(headers):
    if hasattr(headers, "items"):
        return headers.items()
    return dict(headers).items()


def parse_usage_headers(headers, now: float = None, label=None, email=None) -> dict:
    """PURE: map ``anthropic-ratelimit-unified-*`` response headers (case-
    insensitive keys) into the frozen gauge schema (Appendix A). ``label``/
    ``email`` are filled by the caller.

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

    def pct(suffix):
        v = g(suffix)
        if v is None:
            return None
        try:
            return round(float(v) * 100, 1)
        except (TypeError, ValueError):
            return None

    have_any = any(
        g(s) is not None for s in
        ("status", "5h-utilization", "7d-utilization",
         "5h-reset", "7d-reset", "representative-claim"))
    measured_at = _iso(now)

    if not have_any:
        return {
            "label": label, "email": email,
            "five_hour_pct": None, "seven_day_pct": None,
            "binding_window": None, "binding_pct": None,
            "five_hour_reset": None, "seven_day_reset": None,
            "status": None, "limited_until": None,
            "measured_at": measured_at, "source": "ratelimit-header",
            "stale": True,
        }

    fh = pct("5h-utilization")
    sd = pct("7d-utilization")
    binding_window = g("representative-claim")
    if binding_window == "five_hour":
        binding_pct = fh
    elif binding_window == "seven_day":
        binding_pct = sd
    else:
        binding_pct = None
    return {
        "label": label, "email": email,
        "five_hour_pct": fh, "seven_day_pct": sd,
        "binding_window": binding_window, "binding_pct": binding_pct,
        "five_hour_reset": g("5h-reset"), "seven_day_reset": g("7d-reset"),
        "status": g("status"), "limited_until": None,
        "measured_at": measured_at, "source": "ratelimit-header",
        "stale": False,
    }


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
    None. Registry setup-tokens are 403 on the usage endpoint (no user:profile
    scope), so a login's own sample is the ONLY source of model-scoped buckets.
    Never touches the network, never raises."""
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
    """Model-scoped weekly percentages for one account as ``(scoped, at_epoch)``
    — ``{display_name: pct}`` — or None when unavailable. Source: the newest
    plan-usage.sh sample for the email (free, no network). The direct GET of the
    usage endpoint is opt-in (``PWT_ACCT_SCOPED_PROBE=1``): registry setup-tokens
    answer 403 there, and a rejection still counts against the endpoint's rolling
    edge quota. Fail-open: any failure, 429 or non-200 → None (the caller keeps
    its previous value)."""
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


def probe_usage(token, transport=None, now: float = None) -> dict:
    """Measure one account. ``transport`` is injectable for offline tests and
    defaults to a real urllib POST. Returns a gauge (label/email unset — the
    caller fills them). Raises MeasurementError only on a non-limit failure; a
    429-with-headers returns a normal (rejected) gauge. The token never touches a
    log or stdout."""
    transport = transport or _default_transport
    body = json.dumps({
        "model": _probe_model(),
        "max_tokens": 1,
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": "."}],
    }).encode("utf-8")
    headers = {
        "authorization": "Bearer " + str(token),
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "oauth-2025-04-20",
        "user-agent": "claude-cli/2.1.0 (external, cli)",
        "content-type": "application/json",
    }
    _status, resp_headers = transport(API_URL, body, headers, _PROBE_TIMEOUT_S)
    return parse_usage_headers(resp_headers, now=now)


# ── cache I/O (flock-serialized, atomic 0600) ─────────────────────────────────
def _empty_cache() -> dict:
    return {"version": 1, "gauges": {}}


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
                import sys
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
    return {
        "label": label, "email": email,
        "five_hour_pct": None, "seven_day_pct": None,
        "binding_window": None, "binding_pct": None,
        "five_hour_reset": None, "seven_day_reset": None,
        "status": "UNKNOWN", "limited_until": None,
        "measured_at": _iso(now), "source": "ratelimit-header",
        "stale": True,
    }


def resolve_usage(registry: dict, cache_path: str = None, ttl: int = None,
                  max_stale: int = None, transport=None, now: float = None,
                  scoped_transport=None) -> list:
    """Return one gauge per ACTIVE account, reading the cache when fresh (< ttl)
    and probing otherwise. Fail-open: a probe failure keeps the last cached
    reading (marked stale) until it ages past ``max_stale``, then reports UNKNOWN.
    ``limited_until`` is merged from the cache (the reactive backstop). A probe
    error for one account NEVER raises out of this function, and no gauge ever
    carries a token."""
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
                # Additive: model-scoped weekly buckets (Fable). A miss keeps the
                # last cached value; consumers ignore the key.
                sample = probe_scoped(token, email, transport=scoped_transport, now=now)
                if sample is not None:
                    g["scoped"], g["scoped_at"] = sample[0], _iso(sample[1])
                elif prev.get("scoped") is not None:
                    g["scoped"], g["scoped_at"] = prev["scoped"], prev.get("scoped_at")
            except MeasurementError:
                if (prev and prev_at is not None
                        and (now - prev_at) < max_stale and not _is_unknown(prev)):
                    g = dict(prev)
                    g["stale"] = True
                else:
                    g = _unknown_gauge(label, email, now)

        # Merge the reactive backstop from the cache; never surface a token.
        g["limited_until"] = prev.get("limited_until")
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
                    merged["limited_until"] = existing["limited_until"]
                gmap[label] = merged
            cur["gauges"] = gmap
            cur.setdefault("version", 1)
            _write_cache_unlocked(cur, cache_path)
    except OSError:
        pass  # fail-open on cache write — dispatch continues on the in-memory result

    return list(results.values())
