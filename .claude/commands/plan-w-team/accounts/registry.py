#!/usr/bin/env python3
"""Durable account-identity registry for /plan-w-team multi-account management.

Machine-global, skill-owned store at ``$XDG_CONFIG_HOME/claude-pwt/accounts.json``
(mode 0600, parent 0700). Holds DURABLE identity only —
``label, email, token, added_at, active`` — so the token file is written rarely.
Volatile per-account state (``limited_until``) lives in the sibling
``usage-cache.json`` owned by ``probe.py``, never here.

SECURITY INVARIANTS (INV-4, verbatim from the spec Threat Model):
  * Token VALUES are never printed, logged, passed on argv, or placed in a shell
    variable. They are read from the 0600 file and handed to a child via env / a
    0600 file only. Nothing in this module writes a token to stdout/stderr.
  * The registry file is opened O_NOFOLLOW; the module REFUSES to read it when it
    (or its parent) is group/world-accessible (``LoosePermsError``).
  * Writes are atomic (mkstemp 0600 in the same dir + fsync + os.replace) and
    serialized with ``fcntl.flock`` so concurrent lanes never lose an update.
  * Mass-assignment safe (INV-3): only the known schema keys are ever written;
    untrusted input is filtered through an allow-list, never spread.
"""
from __future__ import annotations

import errno
import fcntl
import json
import os
import stat
import tempfile
from contextlib import contextmanager

# ── schema allow-lists (INV-3: mass-assignment safety) ────────────────────────
_TOP_KEYS = ("version", "multi_account_enabled", "onboarding_answered",
             "active_label", "accounts")
_ACCT_KEYS = ("label", "email", "token", "added_at", "active")

# Sentinel for set_account_field() to drop an account row (see its docstring).
REMOVE = object()


class LoosePermsError(Exception):
    """Registry (or its parent dir) is group/world-accessible, or is a symlink.

    Refusing to read is deliberate: a loose-perms or swapped-symlink store may
    have been tampered with, and a token must never be read out of it.
    """


class RegistryMalformed(Exception):
    """The registry file exists and is non-empty but is not valid registry JSON.

    Distinct from an absent/empty registry (which is the dormant default): a
    malformed file is surfaced loudly so the CLI can decide, never silently
    treated as "no accounts".
    """


# ── path resolution ───────────────────────────────────────────────────────────
def _config_home() -> str:
    return os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")


def resolve_registry_path() -> str:
    """``$XDG_CONFIG_HOME/claude-pwt/accounts.json`` (``~/.config`` fallback)."""
    return os.path.join(_config_home(), "claude-pwt", "accounts.json")


def resolve_cache_path() -> str:
    """Sibling usage cache: ``$XDG_CONFIG_HOME/claude-pwt/usage-cache.json``."""
    return os.path.join(_config_home(), "claude-pwt", "usage-cache.json")


def _dormant_default() -> dict:
    return {
        "version": 1,
        "multi_account_enabled": False,
        "onboarding_answered": False,
        "active_label": None,
        "accounts": [],
    }


# ── perms enforcement (INV-4) ─────────────────────────────────────────────────
def _enforce_perms(path: str) -> None:
    """Raise LoosePermsError unless *path* is a plain 0600-tight file under a
    0700-tight parent. Symlinks are refused outright (swap-attack guard)."""
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        raise LoosePermsError("registry is a symlink; refusing: %s" % path)
    if st.st_mode & 0o077:
        raise LoosePermsError(
            "registry perms too loose (need 0600, has %o): %s"
            % (st.st_mode & 0o777, path))
    parent = os.path.dirname(os.path.abspath(path))
    try:
        pst = os.stat(parent)
    except OSError:
        return
    if pst.st_mode & 0o077:
        raise LoosePermsError(
            "registry parent dir perms too loose (need 0700, has %o): %s"
            % (pst.st_mode & 0o777, parent))


# ── low-level (unlocked) load / write ─────────────────────────────────────────
def _merge_defaults(data: dict) -> dict:
    """Fill any absent top-level keys from the dormant default (forward-compat)."""
    out = _dormant_default()
    for k in _TOP_KEYS:
        if k in data:
            out[k] = data[k]
    if not isinstance(out.get("accounts"), list):
        out["accounts"] = []
    return out


def _load_unlocked(path: str) -> dict:
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return _dormant_default()
    _enforce_perms(path)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as e:
        # ELOOP here means a symlink slipped past the lstat check (TOCTOU) — treat
        # it as the loose/tampered case, never fall back to reading it.
        if e.errno in (errno.ELOOP, errno.EMLINK):
            raise LoosePermsError("registry became a symlink; refusing: %s" % path)
        raise
    try:
        with os.fdopen(fd, "r", encoding="utf-8") as f:
            raw = f.read()
    except OSError as e:  # pragma: no cover - unexpected read failure
        raise RegistryMalformed("registry unreadable: %s" % type(e).__name__)
    try:
        data = json.loads(raw)
    except ValueError as e:
        raise RegistryMalformed("registry is not valid JSON: %s" % e)
    if not isinstance(data, dict):
        raise RegistryMalformed("registry root is not a JSON object")
    return _merge_defaults(data)


def _sanitize(data: dict) -> dict:
    """Allow-list the payload down to the known schema (INV-3). Never spreads
    untrusted keys into the stored object."""
    out = _dormant_default()
    for k in _TOP_KEYS:
        if k in data:
            out[k] = data[k]
    clean_accounts = []
    for a in (out.get("accounts") or []):
        if not isinstance(a, dict):
            continue
        clean_accounts.append({k: a[k] for k in _ACCT_KEYS if k in a})
    out["accounts"] = clean_accounts
    out["multi_account_enabled"] = bool(out.get("multi_account_enabled"))
    out["onboarding_answered"] = bool(out.get("onboarding_answered"))
    if not isinstance(out.get("version"), int):
        out["version"] = 1
    return out


def _write_unlocked(data: dict, path: str) -> dict:
    data = _sanitize(data)
    d = os.path.dirname(os.path.abspath(path))
    if not os.path.isdir(d):
        os.makedirs(d, mode=0o700, exist_ok=True)
        try:
            os.chmod(d, 0o700)
        except OSError:
            pass
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".accounts-", suffix=".json")
    try:
        os.chmod(tmp, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
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
    return data


# ── flock serialization ───────────────────────────────────────────────────────
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


# ── public API ─────────────────────────────────────────────────────────────────
def load(path: str = None) -> dict:
    """Load the registry. Absent/empty → the dormant default (no error). Loose
    perms/symlink → LoosePermsError. Malformed JSON → RegistryMalformed (the
    CLI, not this function, decides whether to treat malformed as dormant)."""
    path = path or resolve_registry_path()
    return _load_unlocked(path)


def save(data: dict, path: str = None) -> dict:
    """Atomically persist *data* (allow-listed to the known schema) under flock.

    Returns the sanitized object actually written."""
    path = path or resolve_registry_path()
    with _flock(path):
        return _write_unlocked(data, path)


def upsert_account(label, email, token, path: str = None) -> dict:
    """Insert or replace one account by label under a single flock (read-modify-
    write). New accounts are created ``active: True`` with an ``added_at`` stamp;
    replacing preserves the existing ``active``/``added_at``. Only known fields
    are written (INV-3)."""
    from datetime import datetime, timezone
    path = path or resolve_registry_path()
    with _flock(path):
        data = _load_unlocked(path)
        accounts = data.setdefault("accounts", [])
        for a in accounts:
            if a.get("label") == label:
                a["email"] = email
                a["token"] = token
                break
        else:
            accounts.append({
                "label": label,
                "email": email,
                "token": token,
                "added_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "active": True,
            })
        if data.get("active_label") is None:
            data["active_label"] = label
        return _write_unlocked(data, path)


def set_account_field(label, field, value, path: str = None) -> dict:
    """Single-field mutation under flock. Supports the whole lifecycle surface:

    * ``field="active"``, value True/False   → activate / deactivate an account.
    * ``field="active_label"``               → set the registry hard-pin;
      ``value`` is the label to pin (or None to clear). The ``label`` arg is
      ignored for this op.
    * ``value is REMOVE``                     → drop the account row named
      ``label`` (and clear ``active_label`` if it pointed at it).

    ``field`` for a per-account mutation must be in the account allow-list
    (INV-3); anything else raises ``KeyError``."""
    path = path or resolve_registry_path()
    with _flock(path):
        data = _load_unlocked(path)
        accounts = data.setdefault("accounts", [])

        if value is REMOVE:
            data["accounts"] = [a for a in accounts if a.get("label") != label]
            if data.get("active_label") == label:
                data["active_label"] = None
            return _write_unlocked(data, path)

        if field == "active_label":
            data["active_label"] = value
            return _write_unlocked(data, path)

        if field not in _ACCT_KEYS:
            raise KeyError("unknown account field: %r" % field)
        for a in accounts:
            if a.get("label") == label:
                a[field] = value
                break
        return _write_unlocked(data, path)


def is_dormant(path: str = None) -> bool:
    """True when the multi-account path must NOT activate: the feature is
    disabled, or fewer than 2 accounts are active. An unusable registry (loose
    perms / malformed) also reads as dormant — the safest default is today's
    single-account behavior. A faster pure-bash equivalent lives in lib.sh; this
    is the Python-side check."""
    try:
        data = load(path)
    except (LoosePermsError, RegistryMalformed):
        return True
    if not data.get("multi_account_enabled"):
        return True
    active = [a for a in (data.get("accounts") or []) if a.get("active")]
    return len(active) < 2
