#!/usr/bin/env python3
"""The ONLY spawn-time token writer for /plan-w-team multi-account routing.

At each lane spawn (when >=2 accounts are active) this resolves the best account,
reads THAT account's token from the 0600 registry, and drops a lane
``settings.local.json`` env block so the worker authenticates as its assigned
account from its first API call. The token is read from the 0600 file straight
into a ``json.dump`` and written to a 0600 file — it NEVER appears on argv,
stdout, or in a shell variable (INV-4). Only the chosen LABEL (non-secret) and a
reason reach stderr.

Modes:
  * default    — write a private 0600 temp under ``<wt>/.claude/`` and print ONLY
                 its path on stdout. The bash caller (``__pwt_inject_lane_settings``)
                 copies it to the lane's ``settings.local.json`` and OWNS the
                 unlink-on-success; on any failure BEFORE the path is printed this
                 process unlinks the temp itself.
  * --self-place — write ``<wt>/.claude/settings.local.json`` directly (atomic
                 os.replace) for callers that want no intermediate temp.

Exit codes (the spawn caller branches on these):
  0  wrote a lane cred — path on stdout.
  3  selector pause (measured-all-hot): no eligible account with FRESH readings →
     caller HOLDS or falls back to ambient. Nothing on stdout.
  4  no fresh data / dormant / registry absent / loose perms / <2 accounts /
     missing token for the chosen label → caller uses the AMBIENT login. Nothing
     on stdout. (Loose perms and a missing token also emit a loud stderr warning.)
  5  HARD ERROR (fail-closed): an account WAS selected and its token read, but the
     atomic lane-cred WRITE/validate failed → the caller MUST abort the spawn and
     NOT fall back to ambient (never run the wrong routing decision silently).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import registry
import probe
import selector

EXIT_WROTE = 0
EXIT_PAUSE_HOT = 3
EXIT_AMBIENT = 4
EXIT_FAILCLOSED = 5

ENV_TOKEN = "CLAUDE_CODE_OAUTH_TOKEN"
ENV_LABEL = "PWT_ACCOUNT_LABEL"


def _warn(msg: str) -> None:
    print("lane_cred: %s" % msg, file=sys.stderr)


def _emit_reason(label, reason) -> None:
    # Label + reason ONLY — never a token.
    print("label=%s reason=%s" % (label, reason), file=sys.stderr)


def _select_label(registry_path, pinned):
    """Resolve the chosen label. Returns ``(label, reg, reason)`` on success, or
    ``(None, exit_code, reason)`` when no lane cred should be written.

    Loose perms / malformed / absent / dormant all resolve to the AMBIENT exit
    (4) — the registry is an opt-in, and refusing to route is safer than reading
    a possibly-tampered store or idling the fleet."""
    try:
        reg = registry.load(registry_path)
    except registry.LoosePermsError as e:
        _warn("registry perms refused (%s) — using ambient login" % e)
        return None, EXIT_AMBIENT, "loose-perms"
    except registry.RegistryMalformed as e:
        _warn("registry malformed (%s) — using ambient login" % e)
        return None, EXIT_AMBIENT, "registry-malformed"

    active = [a for a in (reg.get("accounts") or []) if a.get("active")]
    if not reg.get("multi_account_enabled") or len(active) < 2:
        return None, EXIT_AMBIENT, "dormant"

    gauges = probe.resolve_usage(reg)
    decision = selector.classify(gauges, pinned_label=pinned)
    cls = decision["classification"]
    if cls == "chosen":
        return decision["chosen"].get("label"), reg, decision["reason"]
    if cls == "measured-all-hot":
        return None, EXIT_PAUSE_HOT, decision["reason"]
    return None, EXIT_AMBIENT, decision["reason"]


def _token_for(reg: dict, label):
    for a in (reg.get("accounts") or []):
        if a.get("label") == label:
            return a.get("token") or ""
    return ""


def _build_env_block(token, label) -> dict:
    # Built by json.dump downstream — NEVER string-interpolated (INV-4).
    return {"env": {ENV_TOKEN: token, ENV_LABEL: label}}


def write(wt: str, registry_path, pinned=None, self_place=False) -> int:
    claude_dir = os.path.join(wt, ".claude")

    label, reg_or_code, reason = _select_label(registry_path, pinned)
    if label is None:
        # reg_or_code is an exit code (ambient/pause). Print nothing to stdout.
        _emit_reason(None, reason)
        return reg_or_code

    reg = reg_or_code
    token = _token_for(reg, label)
    if not token:
        # We chose a label but the store has no token for it — do NOT block the
        # fleet on a corrupt row; fall back to ambient loudly.
        _warn("no token for chosen label %r — using ambient login" % label)
        _emit_reason(label, "missing-token")
        return EXIT_AMBIENT

    block = _build_env_block(token, label)

    # Everything past here is fail-CLOSED: we committed to routing to `label`, so
    # a write failure must abort the spawn rather than silently run on ambient.
    try:
        os.makedirs(claude_dir, mode=0o700, exist_ok=True)
    except OSError as e:
        _warn("could not create %s (%s) — aborting lane (fail-closed)" % (claude_dir, e))
        _emit_reason(label, "mkdir-failed")
        return EXIT_FAILCLOSED

    # mkstemp itself can fail (unwritable <wt>/.claude) — that is the fail-closed
    # case, so keep it inside the guarded region rather than letting it escape.
    try:
        fd, tmp = tempfile.mkstemp(dir=claude_dir, prefix=".lanecred-", suffix=".json")
    except OSError as e:
        _warn("could not create lane cred temp (%s) — aborting lane (fail-closed)" % type(e).__name__)
        _emit_reason(label, "mkstemp-failed")
        return EXIT_FAILCLOSED
    try:
        # os.fdopen takes ownership of fd and closes it even on exception, so the
        # descriptor never leaks. mkstemp already creates the file 0600; fchmod is
        # belt-and-braces before any bytes are written.
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            os.fchmod(f.fileno(), 0o600)
            json.dump(block, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
    except BaseException as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        _warn("could not write lane cred (%s) — aborting lane (fail-closed)" % type(e).__name__)
        _emit_reason(label, "write-failed")
        return EXIT_FAILCLOSED

    if self_place:
        # Place directly at settings.local.json (atomic); no surviving temp.
        dst = os.path.join(claude_dir, "settings.local.json")
        try:
            os.replace(tmp, dst)
            os.chmod(dst, 0o600)
        except OSError as e:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            _warn("could not place settings.local.json (%s) — aborting (fail-closed)" % e)
            _emit_reason(label, "place-failed")
            return EXIT_FAILCLOSED
        _emit_reason(label, reason)
        print(dst)
        return EXIT_WROTE

    # Default: the temp SURVIVES on success (the caller copies it into
    # settings.local.json and owns the unlink). Print ONLY the path.
    _emit_reason(label, reason)
    print(tmp)
    return EXIT_WROTE


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Write a per-lane credential for the chosen account.")
    sub = ap.add_subparsers(dest="cmd")
    w = sub.add_parser("write", help="select an account and write its lane cred")
    w.add_argument("--wt", required=True, help="lane worktree directory (must exist)")
    w.add_argument("--registry", default=None, help="registry path (default: XDG)")
    w.add_argument("--pinned", default=None, help="tie-break toward this label")
    w.add_argument("--self-place", action="store_true",
                   help="write <wt>/.claude/settings.local.json directly (no temp)")
    args = ap.parse_args(argv)

    if args.cmd != "write":
        ap.print_help(sys.stderr)
        return 2
    if not os.path.isdir(args.wt):
        _warn("worktree not a directory: %s — aborting (fail-closed)" % args.wt)
        return EXIT_FAILCLOSED
    return write(args.wt, args.registry, pinned=args.pinned, self_place=args.self_place)


if __name__ == "__main__":
    sys.exit(main())
