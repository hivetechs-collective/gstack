#!/usr/bin/env python3
"""Launch an interactive `claude` (or any command) on the optimal rotation account.

This is the INTERACTIVE-session sibling of ``lane_cred.py``. Where lane_cred writes
a per-lane ``settings.local.json`` at fleet spawn, this resolves the SAME account
(identical registry + probe + selector path, so foreground sessions ride the exact
rotation the fleet does) and hands the token to a freshly-``exec``'d process through
the child ENVIRONMENT only.

SECURITY (INV-4, identical posture to lane_cred / registry):
  * The token is read from the 0600 registry straight into the child's ``environ``
    for ``os.execvpe`` — it is NEVER printed, logged, placed on argv, or stored in a
    shell variable. Only the chosen LABEL (non-secret) and a reason reach stderr.
  * ``os.execvpe`` resolves the command via PATH at the syscall level, which BYPASSES
    shell functions/aliases — so a ``claude`` shell wrapper that calls this can shadow
    the binary without recursing (the exec still finds the real executable).

Behavior when the registry is DORMANT / absent / loose-perms / all-accounts-hot:
  the command is exec'd UNCHANGED (ambient login), byte-identical to today. Choosing
  to route is opt-in; refusing to route is always safe and never blocks foreground work.
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import registry
import probe
import selector

ENV_TOKEN = "CLAUDE_CODE_OAUTH_TOKEN"
ENV_LABEL = "PWT_ACCOUNT_LABEL"


def _warn(msg: str) -> None:
    print("session_cred: %s" % msg, file=sys.stderr)


def _token_for(reg: dict, label):
    for a in (reg.get("accounts") or []):
        if a.get("label") == label:
            return a.get("token") or ""
    return ""


def resolve(registry_path=None, pinned=None):
    """Resolve the account a foreground session SHOULD run as.

    Returns ``(label, token, reason)``. ``label``/``token`` are None/"" whenever the
    session should use the ambient login (dormant, unusable registry, all-hot, or a
    chosen label whose token is missing) — the ``reason`` says which. The token is
    returned in-process only for the immediate ``execvpe``; callers must never print it.
    """
    try:
        reg = registry.load(registry_path)
    except registry.LoosePermsError as e:
        _warn("registry perms refused (%s) — ambient login" % e)
        return None, "", "loose-perms"
    except registry.RegistryMalformed as e:
        _warn("registry malformed (%s) — ambient login" % e)
        return None, "", "registry-malformed"

    active = [a for a in (reg.get("accounts") or []) if a.get("active")]
    if not reg.get("multi_account_enabled") or len(active) < 2:
        return None, "", "dormant"

    gauges = probe.resolve_usage(reg)
    decision = selector.classify(gauges, pinned_label=pinned)
    cls = decision.get("classification")
    if cls != "chosen":
        # measured-all-hot / no-fresh-data → do NOT block foreground work; the
        # ambient login is as good as any cooling account right now.
        return None, "", decision.get("reason") or cls

    label = (decision.get("chosen") or {}).get("label")
    token = _token_for(reg, label)
    if not token:
        _warn("no token for chosen label %r — ambient login" % label)
        return None, "", "missing-token"
    return label, token, decision.get("reason") or "chosen"


def which_label(registry_path=None, pinned=None) -> int:
    """Print ONLY the label a foreground session would run as (or ``(ambient)``).
    Never touches or prints the token — safe for scripting/status."""
    label, _token, reason = resolve(registry_path, pinned)
    print(label if label else "(ambient)")
    print("reason=%s" % reason, file=sys.stderr)
    return 0


def launch(cmd, registry_path=None, pinned=None) -> int:
    """Select the optimal account and ``exec`` *cmd* with the token in its env.

    On success this process is REPLACED by *cmd* and does not return. Returns 127
    only if the exec itself fails (command not found / not executable)."""
    if not cmd:
        _warn("no command to launch")
        return 2
    label, token, reason = resolve(registry_path, pinned)
    env = dict(os.environ)
    if label and token:
        env[ENV_TOKEN] = token
        env[ENV_LABEL] = label
        print("launching '%s' on account '%s' (%s)" % (cmd[0], label, reason),
              file=sys.stderr)
    else:
        # Ambient: do not carry a stale PWT_ACCOUNT_LABEL from our own environment
        # into the child (it would mislabel the session).
        env.pop(ENV_LABEL, None)
        print("launching '%s' on ambient login (%s)" % (cmd[0], reason),
              file=sys.stderr)
    try:
        os.execvpe(cmd[0], list(cmd), env)
    except OSError as e:
        _warn("could not exec %r (%s)" % (cmd[0], type(e).__name__))
        return 127
    return 127  # pragma: no cover - execvpe only returns on failure


def _current_login_email() -> str:
    """Email of the keychain / ``~/.claude.json`` login this machine runs as.

    This is the account INTERACTIVE Claude Code actually authenticates as — the one a
    rotated ``CLAUDE_CODE_OAUTH_TOKEN`` env token does NOT change (status line, /usage,
    Remote Control all follow the keychain /login) — so ``advise`` compares its
    recommendation against IT, never against an injected token. Fail-open to ``""``."""
    try:
        with open(os.path.expanduser("~/.claude.json"), encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return ""
    return ((d.get("oauthAccount") or {}).get("emailAddress") or "").strip()


def _pcts(gauge):
    if not gauge:
        return None, None
    return gauge.get("five_hour_pct"), gauge.get("seven_day_pct")


def advise(registry_path=None, pinned=None) -> int:
    """Print a one-line JSON advisory (NEVER a token) for the status line and
    ``claude-account``: which registered account has the most headroom, which account
    this machine is logged in as, and whether/why to move. Prints ``{}`` whenever
    there is nothing to advise — dormant registry, unusable perms, or every account
    hot / no fresh data — so the status line simply shows no advice segment (fail-open).

    Keys: ``best``/``best_email``/``best_5h``/``best_7d`` (the pick),
    ``current``/``current_email``/``current_5h``/``current_7d`` (this login, mapped to
    a label by email), ``switch`` (best differs from current login), ``current_hot``
    (current's binding window ≥ ``PWT_ACCT_SWITCH_HINT_PCT``, default 80).

    Reads the shared usage cache (probing only stale accounts), so front it with the
    caller's own short cache when calling on every status-line render."""
    try:
        reg = registry.load(registry_path)
    except (registry.LoosePermsError, registry.RegistryMalformed):
        print("{}")
        return 0

    active = [a for a in (reg.get("accounts") or []) if a.get("active")]
    if not reg.get("multi_account_enabled") or len(active) < 2:
        print("{}")
        return 0

    gauges = probe.resolve_usage(reg)
    decision = selector.classify(gauges, pinned_label=pinned)
    best = decision.get("chosen")
    if not best:
        # measured-all-hot / no-fresh-data → nothing actionable to recommend.
        print("{}")
        return 0

    cur_email = _current_login_email()
    by_email = {(a.get("email") or "").strip().lower(): a.get("label")
                for a in active if (a.get("email") or "").strip()}
    cur_label = by_email.get(cur_email.lower()) if cur_email else None

    gmap = {g.get("label"): g for g in gauges}
    b5, b7 = _pcts(best)
    c5, c7 = _pcts(gmap.get(cur_label) if cur_label else None)

    hint = float(os.environ.get("PWT_ACCT_SWITCH_HINT_PCT", "80"))
    cur_binding = max((v for v in (c5, c7) if isinstance(v, (int, float))),
                      default=None)
    best_label = best.get("label")
    out = {
        "best": best_label,
        "best_email": best.get("email") or "",
        "best_5h": b5, "best_7d": b7,
        "current": cur_label,
        "current_email": cur_email,
        "current_5h": c5, "current_7d": c7,
        "switch": bool(best_label and best_label != cur_label),
        "current_hot": cur_binding is not None and cur_binding >= hint,
    }
    print(json.dumps(out, separators=(",", ":")))
    return 0


def main(argv) -> int:
    pinned = None
    which = False
    advise_flag = False
    rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--pinned":
            if i + 1 >= len(argv):
                _warn("--pinned needs a LABEL")
                return 2
            pinned = argv[i + 1]
            i += 2
            continue
        if a == "--which":
            which = True
            i += 1
            continue
        if a == "--advise":
            advise_flag = True
            i += 1
            continue
        if a == "--":
            rest = argv[i + 1:]
            break
        # first non-flag token starts the command
        rest = argv[i:]
        break
    if advise_flag:
        return advise(pinned=pinned)
    if which:
        return which_label(pinned=pinned)
    if not rest:
        rest = ["claude"]
    return launch(rest, pinned=pinned)


if __name__ == "__main__":  # pragma: no cover - exercised via accounts.sh
    sys.exit(main(sys.argv[1:]))
