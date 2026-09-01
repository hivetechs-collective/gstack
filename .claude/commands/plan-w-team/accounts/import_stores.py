#!/usr/bin/env python3
"""Auto-discovery + bulk-import of pre-existing Claude tokens into the registry.

The operator almost always already has Max-account OAuth tokens saved on the
machine (a local-first, no-vault posture: tokens live in 0600 files under
``~/.config``, never a third-party vault). Re-minting them by hand, per account,
is the friction this module removes: one ``accounts.sh import`` discovers those
saved tokens, validates each with the SAME single probe ``add-account`` uses, and
bulk-registers them — reusing ``registry.upsert_account`` for storage (never
re-implemented here) so every write lands 0600 under flock exactly like an
interactive add.

Discovered by default: a ``secrets.env`` store (see below). Two other store shapes
are supported via ``--source PATH`` but are NEVER default-scanned, so no vendor or
business path is baked into the shipped skill:
  * a JSON account store — schema
    ``{"accounts": [{"label", "email", "token", "added_at", "note"}, ...]}``.
    Rows carrying label + email + token are *fully identified* → auto-registered.
  * a directory of bare single-token ``*.token`` files (no identity). These are
    *partial* → reported with the exact ``add-account --token-file`` command to
    finish them, never auto-stored under a guessed identity/email.

SECURITY INVARIANTS (identical to registry.py / the add path):
  * Token VALUES are never printed, logged, or placed on argv. They are read from
    the source files into memory and handed to ``registry.upsert_account`` /
    ``probe.probe_usage`` only. The summary layer prints label / email / source /
    a truncated sha256 fingerprint — NEVER the token.
  * Dedupe is by full sha256 fingerprint, so re-running is idempotent and a token
    saved in two stores collapses to one account.
  * "Never persist an unvalidated credential": each new token is probed before it
    is stored (a 200/429-with-headers proves auth ⇒ store; a header-less response
    ⇒ invalid ⇒ NOT stored; a network error ⇒ NOT stored). ``--no-validate`` is an
    explicit escape hatch for offline bulk import, reported as unvalidated.
  * The registry's own loose-perms / symlink refusal is inherited unchanged (this
    module never writes the store directly; it goes through registry.py).
"""
from __future__ import annotations

import glob
import hashlib
import json
import os
import stat
import tempfile

import registry
import probe

# Legacy account stores (a JSON store, a directory of *.token files) are reachable
# via --source but are NOT default-scanned: their paths are vendor/tool-specific
# and must never be baked into a skill shared across machines and operators. The
# portable default store is the secrets.env below.

# ── secrets.env source (the canonical, portable Claude-token store) ────────────
# The operator saves one setup-token per account as a shell-style ``KEY=value``
# line in a 0600 env file (``make secrets-set`` style). This is the primary store
# a fleet + shared-skill users are expected to keep, so import reads it FIRST and
# scaffolds one when it is absent.
#
# Business-agnostic by construction:
#   * the KEY convention (``CLAUDE_MAX_SETUP_TOKEN_<LABEL>``) carries no business
#     identity — the <LABEL> is whatever the operator chose;
#   * the default search path is neutral, and ``$PWT_SECRETS_ENV`` (``:``-separated)
#     overrides it entirely, so nothing business-specific is baked into the shipped
#     skill — a store kept elsewhere is reached with one env var.
_TOKEN_KEY_PREFIX = "CLAUDE_MAX_SETUP_TOKEN_"     # CLAUDE_MAX_SETUP_TOKEN_<LABEL>=sk-ant-…
_EMAIL_KEY_PREFIX = "CLAUDE_MAX_EMAIL_"           # optional CLAUDE_MAX_EMAIL_<LABEL>=you@…
_FAILOVER_KEY = "ACCOUNT_FAILOVER_ORDER"          # optional "<label1> <label2> …"

# The single neutral, skill-owned default (also the scaffold target). This is the
# ONLY path baked in; anything else comes from $PWT_SECRETS_ENV. Absent paths are
# silently skipped.
_SECRETS_ENV_DEFAULTS = (
    "~/.config/claude-pwt/secrets.env",
)
# The path a fresh operator's store is CREATED at (never an auto-detected one).
_SCAFFOLD_TARGET = "~/.config/claude-pwt/secrets.env"


def _secrets_env_search_paths():
    """Ordered, de-duplicated list of secrets.env paths to scan. ``$PWT_SECRETS_ENV``
    (``:``-separated) replaces the default when set; otherwise the single neutral
    default is used. Returned paths are expanded but NOT filtered for existence
    (the caller skips missing ones and reports nothing for them)."""
    override = os.environ.get("PWT_SECRETS_ENV")
    if override:
        raw = [p for p in override.split(os.pathsep) if p.strip()]
    else:
        raw = list(_SECRETS_ENV_DEFAULTS)
    out = []
    seen = set()
    for p in raw:
        ep = os.path.expanduser(p.strip())
        if ep and ep not in seen:
            seen.add(ep)
            out.append(ep)
    return out


# ── fingerprints (safe to log; NOT the token) ─────────────────────────────────
def _fingerprint(token: str) -> str:
    """Full sha256 hex of a token. Used only for dedupe + a truncated display."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def fp_short(token: str) -> str:
    return _fingerprint(token)[:12]


# ── source reading ────────────────────────────────────────────────────────────
def _warn_loose_source(path: str, notes: list) -> None:
    """A source token file readable by group/world is the operator's own lax perms,
    not ours to refuse — but we surface it so they can tighten it. We never widen
    anything and never copy the perms onto our 0600 registry."""
    try:
        st = os.lstat(path)
    except OSError:
        return
    if stat.S_ISLNK(st.st_mode):
        notes.append("source is a symlink (read anyway, but verify it): %s" % path)
        return
    if st.st_mode & 0o077:
        notes.append("source is group/world-readable (chmod 600 recommended): %s" % path)


def _read_json_store(path: str, notes: list):
    """Yield (label, email, token) candidate tuples from a JSON account store.
    A row missing email OR label (but carrying a token) is yielded with that field
    as None so the caller can classify it partial."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        notes.append("could not read JSON store %s (%s)" % (path, type(e).__name__))
        return
    accounts = (data or {}).get("accounts") if isinstance(data, dict) else None
    if not isinstance(accounts, list):
        notes.append("JSON store has no 'accounts' array: %s" % path)
        return
    for row in accounts:
        if not isinstance(row, dict):
            continue
        token = (row.get("token") or "").strip()
        if not token:
            continue
        label = (row.get("label") or "").strip() or None
        email = (row.get("email") or "").strip() or None
        yield (label, email, token)


def _read_bare_token(path: str, notes: list):
    """Read the first non-empty line of a bare single-token file. Returns the token
    or None. The derived label is the filename stem; email is unknown (partial)."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                tok = line.strip()
                if tok:
                    return tok
    except OSError as e:
        notes.append("could not read token file %s (%s)" % (path, type(e).__name__))
    return None


def _unquote(v: str) -> str:
    """Strip one layer of matching single/double quotes from an env value."""
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        return v[1:-1]
    return v


def _parse_env_file(path: str, notes: list):
    """Parse a shell-style ``KEY=value`` env file into an ordered list of
    ``(key, value)`` pairs. Tolerant of ``export KEY=…``, surrounding quotes,
    comments, and blank lines. Never evaluates or sources the file (no shell)."""
    pairs = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                if s.startswith("export "):
                    s = s[len("export "):].lstrip()
                eq = s.find("=")
                if eq <= 0:
                    continue
                key = s[:eq].strip()
                val = _unquote(s[eq + 1:])
                pairs.append((key, val))
    except OSError as e:
        notes.append("could not read env file %s (%s)" % (path, type(e).__name__))
    return pairs


def _read_secrets_env(path: str, notes: list):
    """Yield ``(label, email, token)`` from a secrets.env store.

    A ``CLAUDE_MAX_SETUP_TOKEN_<LABEL>`` line is a token whose LABEL is the key
    suffix, lower-cased; the paired ``CLAUDE_MAX_EMAIL_<LABEL>`` (optional) is its
    email. An empty value is a not-yet-filled template slot (skipped, noted). A
    non-``sk-ant`` value is refused, never yielded (so a malformed paste can never
    be stored). ``ACCOUNT_FAILOVER_ORDER`` is surfaced as an informational note."""
    pairs = _parse_env_file(path, notes)
    emails = {}
    tokens = []  # (label, value) in file order
    failover = None
    for key, val in pairs:
        if key.startswith(_TOKEN_KEY_PREFIX):
            label = key[len(_TOKEN_KEY_PREFIX):].strip().lower()
            if label:
                tokens.append((label, val))
        elif key.startswith(_EMAIL_KEY_PREFIX):
            label = key[len(_EMAIL_KEY_PREFIX):].strip().lower()
            if label and val:
                emails[label] = val
        elif key == _FAILOVER_KEY and val:
            failover = val
    if failover:
        notes.append("%s failover order: %s" % (os.path.basename(path), failover))
    n_filled = 0
    for label, val in tokens:
        if not val:
            notes.append("secrets.env %s%s is empty (fill via 'claude setup-token'): %s"
                         % (_TOKEN_KEY_PREFIX, label.upper(), path))
            continue
        if not val.startswith("sk-ant"):
            notes.append("secrets.env %s%s is not an sk-ant token (skipped): %s"
                         % (_TOKEN_KEY_PREFIX, label.upper(), path))
            continue
        n_filled += 1
        yield (label, emails.get(label), val)
    if tokens and n_filled == 0:
        notes.append("secrets.env has token slots but none are filled yet: %s" % path)


def _classify_source(path: str) -> str:
    """'dir' | 'json' | 'envfile' | 'token'. A directory ⇒ dir (glob *.token
    inside); a .json extension or JSON-object content ⇒ json; a .env/secrets.env
    name or content carrying CLAUDE_MAX_SETUP_TOKEN_ ⇒ envfile; else a bare token
    file."""
    if os.path.isdir(path):
        return "dir"
    base = os.path.basename(path)
    if path.endswith(".json"):
        return "json"
    if path.endswith(".env") or base == "secrets.env":
        return "envfile"
    try:
        with open(path, "r", encoding="utf-8") as f:
            head = f.read(4096).lstrip()
    except OSError:
        head = ""
    if head.startswith("{"):
        return "json"
    if _TOKEN_KEY_PREFIX in head:
        return "envfile"
    return "token"


def discover_candidates(sources=None):
    """Return ``(full, partial, notes)``.

    * ``full``    — dicts ``{label, email, token, source, fingerprint}`` that carry a
      complete identity and can be auto-registered.
    * ``partial`` — dicts ``{label, email(None), token, source, fingerprint,
      suggest}`` that have a token but no email → reported, never auto-stored.
    * ``notes``   — human-readable warnings (unreadable source, loose perms, …).

    ``sources`` is an explicit list of paths (files/dirs/JSON stores); when None the
    default secrets.env store(s) are probed. Absent paths are silently skipped.
    """
    notes: list = []
    explicit = sources is not None
    if sources is None:
        sources = []
        # The portable secrets.env store is the ONLY default; legacy JSON / token-dir
        # stores are opt-in via --source so no vendor path ships in the skill.
        for se in _secrets_env_search_paths():
            if os.path.exists(se):
                sources.append(se)
    else:
        sources = [os.path.expanduser(s) for s in sources]

    full = []
    partial = []
    seen_fp = set()  # in-batch dedupe (across stores)

    def _add(label, email, token, source, email_optional=False):
        fp = _fingerprint(token)
        if fp in seen_fp:
            return
        seen_fp.add(fp)
        rec = {"label": label, "email": email, "token": token,
               "source": source, "fingerprint": fp}
        # A source where the LABEL is authoritative identity (secrets.env keys)
        # is registerable on the label alone — email is optional annotation.
        if label and (email or email_optional):
            full.append(rec)
        else:
            # Suggest a ready-to-run add-account; keep the source path so the
            # operator can register it with --token-file once they supply the email.
            rec["suggest"] = (
                "accounts.sh add-account --label %s --email <you@example.com> "
                "--token-file %s" % (label or "<label>", source))
            partial.append(rec)

    for src in sources:
        if not os.path.exists(src):
            # Only note a MISSING source the caller named explicitly; a default
            # store that simply isn't on this machine is silently skipped.
            if explicit:
                notes.append("source not found (skipped): %s" % src)
            continue
        kind = _classify_source(src)
        if kind == "envfile":
            _warn_loose_source(src, notes)
            for label, email, token in _read_secrets_env(src, notes):
                _add(label, email, token, src, email_optional=True)
        elif kind == "json":
            _warn_loose_source(src, notes)
            for label, email, token in _read_json_store(src, notes):
                _add(label, email, token, src)
        elif kind == "dir":
            for path in sorted(glob.glob(os.path.join(src, "*.token"))):
                _warn_loose_source(path, notes)
                tok = _read_bare_token(path, notes)
                if tok:
                    stem = os.path.splitext(os.path.basename(path))[0]
                    _add(stem, None, tok, path)
        else:  # bare token file
            _warn_loose_source(src, notes)
            tok = _read_bare_token(src, notes)
            if tok:
                stem = os.path.splitext(os.path.basename(src))[0]
                _add(stem, None, tok, src)

    return full, partial, notes


# ── registry dedupe ───────────────────────────────────────────────────────────
def _registry_fingerprints(path=None):
    """Map fingerprint → existing label, for every token already registered."""
    data = registry.load(path)
    out = {}
    for a in (data.get("accounts") or []):
        tok = a.get("token")
        if tok:
            out[_fingerprint(tok)] = a.get("label")
    return out


# ── scaffold: build a secrets.env for an operator who has none ─────────────────
_SCAFFOLD_TEMPLATE = """\
# Claude Max multi-account tokens for /plan-w-team
# ------------------------------------------------
# One line per Anthropic account you want the fleet (and your interactive `claude`
# sessions) to rotate across. The <LABEL> after the prefix is yours to choose;
# it is the name shown in `accounts.sh status`.
#
# To FILL a slot, run this in a REAL terminal (never inside a Claude Code session),
# logged in as that account in the browser callback:
#
#     claude setup-token
#
# then paste the printed sk-ant-oat… value after the `=` for that label. Keep this
# file mode 0600. Optionally add a CLAUDE_MAX_EMAIL_<LABEL> line to annotate each.
#
# After filling any slots, register them with:
#
#     accounts.sh setup
#
# Example (uncomment + fill; add more accounts by copying the pair):
# CLAUDE_MAX_SETUP_TOKEN_PERSONAL=
# CLAUDE_MAX_EMAIL_PERSONAL=you@example.com

# ACCOUNT_FAILOVER_ORDER is an optional space-separated label preference order.
# ACCOUNT_FAILOVER_ORDER=""
"""


def scaffold_secrets_env(path=None):
    """Create a 0600 secrets.env template if none exists. Returns
    ``(status, path)`` where status is 'exists' | 'created' | 'error'. Never
    overwrites an existing file. The target is ``$PWT_SECRETS_ENV`` (its first
    entry) when set, else the neutral skill default — never an auto-detected
    operator store (we scaffold OUR path, we do not fabricate someone else's)."""
    if path:
        target = os.path.expanduser(path)
    else:
        override = os.environ.get("PWT_SECRETS_ENV")
        if override:
            first = [p for p in override.split(os.pathsep) if p.strip()]
            target = os.path.expanduser(first[0]) if first else os.path.expanduser(_SCAFFOLD_TARGET)
        else:
            target = os.path.expanduser(_SCAFFOLD_TARGET)
    if os.path.exists(target):
        return ("exists", target)
    d = os.path.dirname(os.path.abspath(target))
    try:
        if not os.path.isdir(d):
            os.makedirs(d, mode=0o700, exist_ok=True)
        try:
            os.chmod(d, 0o700)
        except OSError:
            pass
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".secrets-", suffix=".env")
        try:
            os.chmod(tmp, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(_SCAFFOLD_TEMPLATE)
            os.replace(tmp, target)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except OSError as e:
        return ("error", "%s (%s)" % (target, type(e).__name__))
    return ("created", target)


# ── the import operation ──────────────────────────────────────────────────────
def run_import(sources=None, validate=True, enable=True, dry_run=False,
               transport=None, registry_path=None):
    """Discover, validate, and bulk-register saved tokens.

    Returns a structured result dict (all lists carry label/email/source/fp — never
    a token). Raises registry.LoosePermsError / registry.RegistryMalformed straight
    through (the caller decides how to surface a fail-closed store)."""
    full, partial, notes = discover_candidates(sources)
    existing = _registry_fingerprints(registry_path)

    # needs_identity carries NO token — strip it to label/source/fp/suggest so the
    # result structure is safe to serialize/log anywhere (the token stays only in
    # the source file the operator already holds).
    needs_identity = [{"label": p.get("label"), "source": p.get("source"),
                       "fingerprint": p["fingerprint"], "fp": p["fingerprint"][:12],
                       "suggest": p.get("suggest")} for p in partial]

    result = {
        "imported": [], "unchanged": [], "rejected": [], "network_fail": [],
        "would_import": [], "needs_identity": needs_identity, "notes": notes,
        "enabled": False, "validated": validate, "dry_run": dry_run,
    }

    def _display(rec, **extra):
        d = {"label": rec.get("label"), "email": rec.get("email"),
             "source": rec.get("source"), "fp": rec["fingerprint"][:12]}
        d.update(extra)
        return d

    stored_any = False
    for rec in full:
        fp = rec["fingerprint"]
        if fp in existing:
            result["unchanged"].append(_display(rec, as_label=existing[fp]))
            continue
        if dry_run:
            result["would_import"].append(_display(rec))
            continue
        if validate:
            try:
                gauge = probe.probe_usage(rec["token"], transport=transport)
            except probe.MeasurementError as e:
                result["network_fail"].append(_display(rec, reason=str(e)))
                continue
            if gauge.get("stale"):
                result["rejected"].append(_display(rec, reason="no rate-limit headers"))
                continue
            imported = _display(rec, five_hour_pct=gauge.get("five_hour_pct"),
                                seven_day_pct=gauge.get("seven_day_pct"),
                                status=gauge.get("status"))
        else:
            imported = _display(rec, validated=False)
        registry.upsert_account(rec["label"], rec["email"], rec["token"], registry_path)
        existing[fp] = rec["label"]
        stored_any = True
        result["imported"].append(imported)

    # Enable the feature once at least one account is registered (mirrors the add
    # path: multi_account_enabled flips True; the run stays DORMANT until >=2 active,
    # so this is safe). onboarding_answered records that the question is settled.
    if enable and not dry_run and stored_any:
        data = registry.load(registry_path)
        changed = False
        if not data.get("multi_account_enabled"):
            data["multi_account_enabled"] = True
            changed = True
        if not data.get("onboarding_answered"):
            data["onboarding_answered"] = True
            changed = True
        if changed:
            registry.save(data, registry_path)
        result["enabled"] = bool(data.get("multi_account_enabled"))

    # Final active-account count for the summary (drives the dormant/live message).
    data = registry.load(registry_path)
    result["active_count"] = len([a for a in (data.get("accounts") or [])
                                  if a.get("active")])
    result["total_count"] = len(data.get("accounts") or [])
    return result


# ── CLI entry (called by accounts.sh via a tiny heredoc) ──────────────────────
_USAGE = """import — discover + bulk-register pre-existing Claude tokens

Usage: accounts.sh import [--source PATH]... [--dry-run] [--no-validate] [--no-enable]

  --source PATH   an extra store to scan (a JSON account store, a *.token file, or
                  a dir of *.token files). Repeatable. When omitted, the portable
                  secrets.env store is scanned (searched at $PWT_SECRETS_ENV else
                  ~/.config/claude-pwt/secrets.env); legacy JSON / token-dir stores
                  are opt-in via --source, so no vendor path is baked in.
  --dry-run       report what WOULD be imported; probe nothing, store nothing
  --no-validate   store without a validating probe (offline bulk import)
  --no-enable     do not flip multi_account_enabled on after importing
"""


def _print_summary(r) -> None:
    def line(s=""):
        print(s)

    if r["dry_run"]:
        line("import (dry-run) — nothing stored, nothing probed")
        for d in r["would_import"]:
            line("  would import  %-14s %-28s [%s] %s"
                 % (d["label"], d["email"] or "-", d["fp"], d["source"]))
    else:
        for d in r["imported"]:
            extra = ""
            if d.get("validated") is False:
                extra = "(unvalidated)"
            elif d.get("five_hour_pct") is not None or d.get("seven_day_pct") is not None:
                extra = "(5h=%s%% 7d=%s%% status=%s)" % (
                    d.get("five_hour_pct"), d.get("seven_day_pct"), d.get("status"))
            line("  imported      %-14s %-28s [%s] %s"
                 % (d["label"], d["email"] or "-", d["fp"], extra))
    for d in r["unchanged"]:
        line("  already-known %-14s %-28s [%s] (registered as '%s')"
             % (d["label"], d["email"] or "-", d["fp"], d.get("as_label")))
    for d in r["rejected"]:
        line("  REJECTED      %-14s %-28s [%s] %s — NOT stored"
             % (d["label"], d["email"] or "-", d["fp"], d.get("reason")))
    for d in r["network_fail"]:
        line("  unreachable   %-14s %-28s [%s] %s — NOT stored (retry when online)"
             % (d["label"], d["email"] or "-", d["fp"], d.get("reason")))

    for d in r["needs_identity"]:
        line("  needs email   %-14s [%s] %s" % (d["label"], d["fp"], d["source"]))
        line("      → %s" % d["suggest"])

    for n in r["notes"]:
        line("  note: %s" % n)

    if not r["dry_run"]:
        total = r.get("total_count", 0)
        active = r.get("active_count", 0)
        if r.get("enabled") and active >= 2:
            line("multi-account ENABLED — %d active of %d registered; the fleet will "
                 "engage on the next run." % (active, total))
        elif r.get("enabled"):
            line("multi-account enabled — %d active of %d registered; still DORMANT "
                 "until >=2 are active." % (active, total))
        else:
            line("%d account(s) registered." % total)
    if r["needs_identity"]:
        line("To finish a bare token file, re-run its add-account line above with the "
             "account's email.")
    line("To add an account with NO saved token, mint once in a real terminal:")
    line("    claude setup-token | accounts.sh add-account --label L --email E --token-stdin")


def setup_main(argv) -> int:
    """Guided onboarding: ensure a secrets.env exists (scaffold one if not), then
    import every saved token from it and the other known stores. This is the entry
    point ``accounts.sh setup`` / ``authorize`` call and that ``/plan-w-team`` points
    a new operator to. Idempotent: re-running after filling more slots just registers
    the new ones."""
    import sys as _sys
    validate = True
    enable = True
    for a in argv:
        if a == "--no-validate":
            validate = False
        elif a == "--no-enable":
            enable = False
        elif a in ("-h", "--help"):
            print("setup — scaffold a secrets.env if needed, then import saved tokens\n\n"
                  "Usage: accounts.sh setup [--no-validate] [--no-enable]")
            return 0
        else:
            print("setup: unknown flag: %s" % a, file=_sys.stderr)
            return 1

    search = _secrets_env_search_paths()
    existing_env = [p for p in search if os.path.exists(p)]
    # Only scaffold when the operator has NO secrets.env anywhere we look — never
    # fabricate a store on top of existing data.
    created = None
    if not existing_env:
        created = scaffold_secrets_env()

    try:
        r = run_import(None, validate=validate, enable=enable, dry_run=False)
    except registry.LoosePermsError as e:
        print("registry perms too loose — refused: %s" % e, file=_sys.stderr)
        return 2
    except registry.RegistryMalformed as e:
        print("registry malformed: %s" % e, file=_sys.stderr)
        return 7

    # Scaffold header first, then the standard import summary.
    if created is not None:
        status, path = created
        if status == "created":
            print("scaffolded a new secrets.env (0600): %s" % path)
            print("  fill each account by running in a REAL terminal:  claude setup-token")
            print("  paste the sk-ant-oat… value after the matching CLAUDE_MAX_SETUP_TOKEN_<LABEL>=")
            print("  then re-run:  accounts.sh setup")
        elif status == "exists":
            print("secrets.env already present: %s" % path)
        else:
            print("could not scaffold a secrets.env: %s" % path)
    elif existing_env:
        print("secrets.env store(s): %s" % ", ".join(existing_env))

    _print_summary(r)
    return 0


def main(argv) -> int:
    sources = []
    validate = True
    enable = True
    dry_run = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--source":
            if i + 1 >= len(argv):
                print("import: --source needs a PATH", file=__import__("sys").stderr)
                return 1
            sources.append(argv[i + 1]); i += 2; continue
        if a == "--dry-run":
            dry_run = True; i += 1; continue
        if a == "--no-validate":
            validate = False; i += 1; continue
        if a == "--no-enable":
            enable = False; i += 1; continue
        if a in ("-h", "--help"):
            print(_USAGE); return 0
        print("import: unknown flag: %s" % a, file=__import__("sys").stderr)
        print(_USAGE, file=__import__("sys").stderr)
        return 1

    try:
        r = run_import(sources or None, validate=validate, enable=enable,
                       dry_run=dry_run)
    except registry.LoosePermsError as e:
        print("registry perms too loose — refused: %s" % e,
              file=__import__("sys").stderr)
        return 2
    except registry.RegistryMalformed as e:
        print("registry malformed: %s" % e, file=__import__("sys").stderr)
        return 7

    _print_summary(r)
    return 0


if __name__ == "__main__":  # pragma: no cover - exercised via accounts.sh
    import sys
    sys.exit(main(sys.argv[1:]))
