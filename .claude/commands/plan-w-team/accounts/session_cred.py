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


def main(argv) -> int:
    pinned = None
    which = False
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
        if a == "--":
            rest = argv[i + 1:]
            break
        # first non-flag token starts the command
        rest = argv[i:]
        break
    if which:
        return which_label(pinned=pinned)
    if not rest:
        rest = ["claude"]
    return launch(rest, pinned=pinned)


if __name__ == "__main__":  # pragma: no cover - exercised via accounts.sh
    sys.exit(main(sys.argv[1:]))
