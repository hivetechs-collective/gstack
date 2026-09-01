#!/usr/bin/env python3
"""Neutral account selector for /plan-w-team multi-account routing.

Pure core (``select_account`` / ``classify``) over usage gauges + a thin CLI.
This is a business-agnostic "most headroom" objective — no billing classes,
roles, per-account reserves, or emergency legs; every account is ranked purely
by remaining usage headroom.

Objective (spec §Selector objective):
  1. Exclude a gauge whose ``status == "rejected"``, whose ``binding_pct`` or
     EITHER window pct is ``>= HOLD_HARD`` (95), whose ``limited_until`` is still
     in the future, or that is UNKNOWN / stale past the ceiling.
  2. Rank the rest by LOWEST ``max(five_hour_pct, seven_day_pct)`` (most total
     headroom). Any account at/above ``HOLD_SOFT`` (85) on either window sorts
     strictly AFTER every below-soft account (a fixed penalty).
  3. Tie-break toward ``pinned_label``, then by label name.

Classification for the CLI exit code:
  * chosen           → exit 0 (a label was picked).
  * measured-all-hot → exit 3 (fresh readings exist but all are excluded; the
                       caller holds / goes loud and can see the nearest reset).
  * no-fresh-data    → exit 4 (every account is UNKNOWN/stale; caller uses
                       the ambient login — fail-open).

The token NEVER appears on stdout under any flag: gauges carry no token, and the
JSON emitter scrubs any stray ``token`` key defensively.

Env knobs: PWT_ACCT_HOLD_SOFT (85), PWT_ACCT_HOLD_HARD (95).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone


# ── ported utilities (clean, business-agnostic) ───────────────────────────────
def _parse_ts(s):
    """Parse an ISO8601 stamp (fractional seconds + Z tolerated) → epoch float.

    A parse failure returns None, which callers treat as NOT limited (fail-open
    on the cooldown — the HOLD gauges are the real protection)."""
    if not s:
        return None
    t = re.sub(r"\.\d+", "", str(s).strip()).replace("Z", "+00:00")
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S"):
        try:
            dt = datetime.strptime(t, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.timestamp()
        except ValueError:
            continue
    try:
        dt = datetime.fromisoformat(t)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.timestamp()
    except ValueError:
        return None


def _parse_epoch(s):
    """Parse a unix-epoch string ("1788199800") → float, or None."""
    if s is None:
        return None
    try:
        return float(str(s).strip())
    except (TypeError, ValueError):
        return None


def cooldown_until(gauge: dict):
    """The ISO8601 instant this account is benched until, or None. In this schema
    the reactive backstop writes ``limited_until`` straight onto the gauge (merged
    from the cache), so this is a thin, explicit accessor."""
    return (gauge or {}).get("limited_until")


def _safe_label(label):
    """Leak-boundary guard: redact anything from an '@' onward so a mis-entered
    email-shaped label can never write a raw address into the ledger."""
    if isinstance(label, str) and "@" in label:
        return label.split("@", 1)[0]
    return label


# ── params ─────────────────────────────────────────────────────────────────────
def _thresholds(params):
    soft = float(os.environ.get("PWT_ACCT_HOLD_SOFT", "85"))
    hard = float(os.environ.get("PWT_ACCT_HOLD_HARD", "95"))
    if params:
        soft = float(params.get("hold_soft", soft))
        hard = float(params.get("hold_hard", hard))
    return soft, hard


def _is_num(v):
    return isinstance(v, (int, float))


def _max_pct(fh, sd):
    vals = [v for v in (fh, sd) if _is_num(v)]
    return max(vals) if vals else None


def _is_unknown(gauge: dict) -> bool:
    if gauge.get("status") == "UNKNOWN":
        return True
    return gauge.get("five_hour_pct") is None and gauge.get("seven_day_pct") is None


def _binding_reset_epoch(gauge: dict):
    """The reset epoch of the binding window (fallback: the nearer of the two)."""
    bw = gauge.get("binding_window")
    if bw == "five_hour":
        return _parse_epoch(gauge.get("five_hour_reset"))
    if bw == "seven_day":
        return _parse_epoch(gauge.get("seven_day_reset"))
    resets = [e for e in (_parse_epoch(gauge.get("five_hour_reset")),
                          _parse_epoch(gauge.get("seven_day_reset"))) if e is not None]
    return min(resets) if resets else None


# ── the pure core ──────────────────────────────────────────────────────────────
def classify(gauges, pinned_label=None, params=None, now=None) -> dict:
    """Full decision: which account (if any) + WHY, with the CLI exit code.

    Returns ``{classification, chosen, reason, nearest_reset, exit_code}`` where
    ``chosen`` is the winning gauge (with a ``reason`` key added) or None."""
    soft, hard = _thresholds(params)
    now = time.time() if now is None else now

    eligible = []
    any_fresh = False
    excluded_resets = []

    for g in gauges or []:
        fh = g.get("five_hour_pct")
        sd = g.get("seven_day_pct")
        status = g.get("status")
        unknown = _is_unknown(g)
        if not unknown:
            any_fresh = True

        lu_ts = _parse_ts(cooldown_until(g))
        limited = lu_ts is not None and now < lu_ts

        bpct = g.get("binding_pct")
        mx = _max_pct(fh, sd)
        hard_excluded = (
            status == "rejected"
            or (_is_num(bpct) and bpct >= hard)
            or (mx is not None and mx >= hard)
        )

        if unknown or limited or hard_excluded:
            if not unknown:
                r = _binding_reset_epoch(g)
                if r is not None:
                    excluded_resets.append(r)
            continue

        soft_penalty = 1 if ((_is_num(fh) and fh >= soft)
                             or (_is_num(sd) and sd >= soft)) else 0
        pin_rank = 0 if (pinned_label and g.get("label") == pinned_label) else 1
        eligible.append((soft_penalty, mx if mx is not None else 0.0,
                         pin_rank, g.get("label") or "", g))

    if eligible:
        eligible.sort(key=lambda t: (t[0], t[1], t[2], t[3]))
        soft_penalty, mx, _pin, _lbl, g = eligible[0]
        reason = "lowest max(5h,7d)=%.1f%%%s" % (
            mx, " [soft-penalized]" if soft_penalty else "")
        chosen = dict(g)
        chosen["reason"] = reason
        return {"classification": "chosen", "chosen": chosen, "reason": reason,
                "nearest_reset": None, "exit_code": 0}

    if any_fresh:
        nearest = min(excluded_resets) if excluded_resets else None
        return {"classification": "measured-all-hot", "chosen": None,
                "reason": "measured-all-hot: every account excluded by HOLD/limit",
                "nearest_reset": nearest, "exit_code": 3}

    return {"classification": "no-fresh-data", "chosen": None,
            "reason": "no-fresh-data: all readings UNKNOWN/stale — use ambient",
            "nearest_reset": None, "exit_code": 4}


def select_account(gauges, pinned_label=None, params=None, now=None):
    """PURE: return the chosen gauge dict (with a ``reason`` key) or None."""
    return classify(gauges, pinned_label=pinned_label, params=params, now=now)["chosen"]


# ── fail-open ledger ───────────────────────────────────────────────────────────
def _default_ledger_path() -> str:
    home = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(home, "claude-pwt", "selection-log.jsonl")


def append_ledger(entry: dict, path: str = None) -> bool:
    """Append one token-free decision row (label + reason only) to the JSONL
    selection log. FAIL-OPEN: any filesystem error is swallowed so telemetry can
    never block a selection."""
    path = path or _default_ledger_path()
    row = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": "account-selection",
        "selected_label": _safe_label(entry.get("selected_label")),
        "classification": entry.get("classification"),
        "reason": entry.get("reason"),
    }
    try:
        d = os.path.dirname(path)
        if d and not os.path.isdir(d):
            os.makedirs(d, mode=0o700, exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(row, separators=(",", ":")) + "\n")
        return True
    except OSError as e:
        print("selector: ledger append skipped (%s)" % e, file=sys.stderr)
        return False


# ── CLI ─────────────────────────────────────────────────────────────────────────
def _scrub_tokens(obj):
    """Defense in depth: strip any ``token`` key before emitting JSON."""
    if isinstance(obj, dict):
        obj.pop("token", None)
        for v in obj.values():
            _scrub_tokens(v)
    elif isinstance(obj, list):
        for v in obj:
            _scrub_tokens(v)
    return obj


def _load_gauges(args):
    if args.from_json:
        with open(args.from_json, encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and "gauges" in data:
            return data["gauges"]
        return data
    # --registry: resolve live usage (probes/caches as needed).
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import registry
    import probe
    reg = registry.load(args.registry)
    return probe.resolve_usage(reg)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Select the account with the most headroom.")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--from-json", default=None,
                     help="fixture: a gauge list, or {\"gauges\": [...]}")
    src.add_argument("--registry", default=None,
                     help="registry path (resolve live usage via probe.py)")
    ap.add_argument("--label-only", action="store_true",
                    help="print just the chosen label (empty when none)")
    ap.add_argument("--pinned", default=None, help="tie-break toward this label")
    ap.add_argument("--no-ledger", action="store_true", help="do not append to the selection log")
    args = ap.parse_args(argv)

    gauges = _load_gauges(args)
    result = classify(gauges, pinned_label=args.pinned)

    chosen_label = (result["chosen"] or {}).get("label") if result["chosen"] else None
    if not args.no_ledger:
        append_ledger({
            "selected_label": chosen_label,
            "classification": result["classification"],
            "reason": result["reason"],
        })

    if args.label_only:
        if chosen_label:
            print(chosen_label)
    else:
        print(json.dumps(_scrub_tokens(result), indent=2))
    return result["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
