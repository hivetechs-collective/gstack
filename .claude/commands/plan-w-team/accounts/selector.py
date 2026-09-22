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
  3. Tie-break toward ``pinned_label``, then the lowest Fable bucket, then label.

``need`` (2026-09-18): ``"any"`` (default) is the objective above — the Fable
bucket is a tie-break only, so an Opus/Sonnet lane never shuns an account whose
Fable week is spent. ``"fable"`` ranks by ``max(5h, 7d, Fable)`` and EXCLUDES an
account whose Fable bucket is rejected or at/above HOLD_HARD; an account with no
Fable reading is soft-penalized (its Fable headroom is unknown, not zero).
``need_from_model()`` derives it from a model id / display name.

Classification for the CLI exit code:
  * chosen           → exit 0 (a label was picked).
  * measured-all-hot → exit 3 (fresh readings exist but all are excluded; the
                       caller holds / goes loud and can see the nearest reset).
  * no-fresh-data    → exit 4 (every account is UNKNOWN/stale; caller uses
                       the ambient login — fail-open).

The token NEVER appears on stdout under any flag: gauges carry no token, and the
JSON emitter scrubs any stray ``token`` key defensively.

Reset-aware rules (2.45.0 — forward-looking; agreed with the cleanscale governor
session 2026-09-18). Each is additive, has its own switch, and FAILS OPEN to the
ranking above on any missing/stale field — a rule never invents a cliff from
missing data, and none can admit an account the exclusions in (1) rejected:
  R1 expose   every result carries ``fable_next_open`` ({label, at_epoch}: the
              earliest FUTURE Fable reset among Fable-shut accounts) or None.
  R2 advise   need=fable with nothing eligible: ``fable_wait`` = "hold" when that
              opening is within PWT_ACCT_FABLE_HOLD_MIN (45) minutes, else
              "downgrade" (+ ``recheck_at``). ADVISORY for the interactive lead
              only — it changes no lane behaviour.
  R3 expiry   use-it-or-lose-it: WEEKLY headroom (7d; Fable too under need=fable)
              that expires inside PWT_ACCT_EXPIRY_HORIZON_H (12) hours earns a
              bounded bonus off the rank score (<= PWT_ACCT_EXPIRY_BONUS_MAX, 15).
              The 5h window never earns it (it always resets within the horizon).
              Off: PWT_ACCT_DISABLE_EXPIRY_BONUS=1.
  R5 project  an account whose published ``*_burn_ppm`` projects a window to
              HOLD_HARD within PWT_ACCT_PROJECT_MIN (45) minutes (and before that
              window resets) sorts with the soft-penalized tier — skipped only
              while a calmer account exists. Off: PWT_ACCT_DISABLE_PROJECTION=1.
  R4 reserve  DEFAULT OFF (PWT_ACCT_FABLE_RESERVE=1): under need=any, when exactly
              ONE eligible account has Fable headroom (< HOLD_SOFT, not rejected)
              and its Fable reset is known and beyond the expiry horizon, it sorts
              after the other unpenalized accounts so ordinary lanes do not eat the
              week Fable lanes draw on. Never applies when it is the only
              unpenalized account.

Env knobs: PWT_ACCT_HOLD_SOFT (85), PWT_ACCT_HOLD_HARD (95), plus the rule knobs above.
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
    """The instant this account is benched until (epoch string when derived from
    a rejected 5h/7d window header, ISO8601 from the reactive ``mark_limited``),
    or None. Written straight onto the gauge (merged from the cache), so this is
    a thin, explicit accessor; callers parse either form."""
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


SCOPED_FABLE = "Fable"


def need_from_model(model_id) -> str:
    """``"fable"`` for any model id / display name containing "fable" (case-
    insensitive: the Fable model id, ``Fable 5.1``), else ``"any"``."""
    if model_id and "fable" in str(model_id).lower():
        return "fable"
    return "any"


def _scoped_entry(gauge: dict, name: str):
    """``(pct, status)`` of the gauge's scoped bucket *name* (case-insensitive
    key match), ``(None, None)`` when absent or non-numeric."""
    sc = gauge.get("scoped") or {}
    st = gauge.get("scoped_status") or {}
    if not isinstance(sc, dict):
        return None, None
    for k, v in sc.items():
        if str(k).lower() == name.lower():
            pct = v if (_is_num(v) and not isinstance(v, bool)) else None
            status = st.get(k) if isinstance(st, dict) else None
            return pct, status
    return None, None


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


# ── reset-aware rules (2.45.0) ────────────────────────────────────────────────
def _env_float(name, default):
    try:
        return float(os.environ.get(name, "") or default)
    except (TypeError, ValueError):
        return float(default)


def _env_on(name) -> bool:
    return str(os.environ.get(name, "")).strip().lower() in ("1", "true", "yes", "on")


def _rule_params(params):
    p = params or {}
    return {
        "expiry_on": bool(p.get("expiry_bonus", not _env_on("PWT_ACCT_DISABLE_EXPIRY_BONUS"))),
        "expiry_horizon_s": float(p.get("expiry_horizon_h", _env_float("PWT_ACCT_EXPIRY_HORIZON_H", 12))) * 3600.0,
        "expiry_max": float(p.get("expiry_bonus_max", _env_float("PWT_ACCT_EXPIRY_BONUS_MAX", 15))),
        "project_on": bool(p.get("projection", not _env_on("PWT_ACCT_DISABLE_PROJECTION"))),
        "project_min": float(p.get("project_min", _env_float("PWT_ACCT_PROJECT_MIN", 45))),
        "reserve_on": bool(p.get("fable_reserve", _env_on("PWT_ACCT_FABLE_RESERVE"))),
        "hold_min": float(p.get("fable_hold_min", _env_float("PWT_ACCT_FABLE_HOLD_MIN", 45))),
    }


def _fable_reset_epoch(gauge: dict):
    sr = gauge.get("scoped_reset") or {}
    if not isinstance(sr, dict):
        return None
    for k, v in sr.items():
        if str(k).lower() == SCOPED_FABLE.lower():
            return _parse_epoch(v)
    return None


def _expiry_bonus(gauge, need, fable_pct, now, rp) -> float:
    """R3: bounded bonus for WEEKLY headroom about to expire unused. 0 on any
    missing field (fail-open)."""
    if not rp["expiry_on"] or rp["expiry_horizon_s"] <= 0 or rp["expiry_max"] <= 0:
        return 0.0
    best = 0.0
    pairs = [(gauge.get("seven_day_pct"), _parse_epoch(gauge.get("seven_day_reset")))]
    if need == "fable":
        pairs.append((fable_pct, _fable_reset_epoch(gauge)))
    for pct, reset in pairs:
        if not _is_num(pct) or isinstance(pct, bool) or reset is None:
            continue
        left = reset - now
        if left <= 0 or left > rp["expiry_horizon_s"]:
            continue
        frac = 1.0 - (left / rp["expiry_horizon_s"])
        best = max(best, max(0.0, 100.0 - pct) * frac * 0.25)
    return round(min(best, rp["expiry_max"]), 3)


def _projected_hot(gauge, hard, now, rp) -> bool:
    """R5: a window's own burn carries it to HOLD_HARD within the lookahead and
    before it resets. False on any missing field (fail-open)."""
    if not rp["project_on"] or rp["project_min"] <= 0:
        return False
    for pk, bk, rk in (("five_hour_pct", "five_hour_burn_ppm", "five_hour_reset"),
                       ("seven_day_pct", "seven_day_burn_ppm", "seven_day_reset")):
        pct, burn = gauge.get(pk), gauge.get(bk)
        if not _is_num(pct) or not _is_num(burn) or isinstance(burn, bool) or burn <= 0:
            continue
        minutes = rp["project_min"]
        reset = _parse_epoch(gauge.get(rk))
        if reset is not None:
            minutes = min(minutes, max(0.0, (reset - now) / 60.0))
        if pct + burn * minutes >= hard:
            return True
    return False


# ── the pure core ──────────────────────────────────────────────────────────────
def classify(gauges, pinned_label=None, params=None, now=None, need="any") -> dict:
    """Full decision: which account (if any) + WHY, with the CLI exit code.

    Returns ``{classification, chosen, reason, nearest_reset, exit_code,
    fable_next_open, fable_wait, recheck_at}`` where ``chosen`` is the winning
    gauge (with a ``reason`` key added) or None (R1/R2: module docstring).
    ``need`` is ``"any"`` or ``"fable"`` (see the module docstring)."""
    soft, hard = _thresholds(params)
    now = time.time() if now is None else now
    need = "fable" if str(need or "any").lower() == "fable" else "any"
    rp = _rule_params(params)
    fable_open = None  # R1: (at_epoch, label) — earliest future reset of a shut Fable bucket

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

        lu_ts = cooldown_until(g)
        lu_ts = _parse_epoch(lu_ts) if _parse_epoch(lu_ts) is not None else _parse_ts(lu_ts)
        limited = lu_ts is not None and now < lu_ts

        bpct = g.get("binding_pct")
        mx = _max_pct(fh, sd)
        fable_pct, fable_status = _scoped_entry(g, SCOPED_FABLE)
        hard_excluded = (
            status == "rejected"
            or (_is_num(bpct) and bpct >= hard)
            or (mx is not None and mx >= hard)
        )
        if not unknown and (fable_status == "rejected"
                            or (fable_pct is not None and fable_pct >= hard)):
            fr_open = _fable_reset_epoch(g)
            if fr_open is not None and fr_open > now and (fable_open is None or fr_open < fable_open[0]):
                fable_open = (fr_open, g.get("label") or "")
        fable_unknown = False
        if need == "fable":
            if fable_status == "rejected" or (fable_pct is not None and fable_pct >= hard):
                hard_excluded = True
            elif fable_pct is None:
                fable_unknown = True
            else:
                mx = max(mx, fable_pct) if mx is not None else fable_pct

        if unknown or limited or hard_excluded:
            if not unknown:
                r = _binding_reset_epoch(g)
                if need == "fable":
                    fr = _parse_epoch((g.get("scoped_reset") or {}).get(SCOPED_FABLE))
                    if fr is not None and (fable_status == "rejected" or r is None):
                        r = fr
                if r is not None:
                    excluded_resets.append(r)
            continue

        soft_penalty = 1 if ((_is_num(fh) and fh >= soft)
                             or (_is_num(sd) and sd >= soft)
                             or (need == "fable" and (fable_unknown or fable_pct >= soft))) else 0
        pin_rank = 0 if (pinned_label and g.get("label") == pinned_label) else 1
        projected = _projected_hot(g, hard, now, rp)
        bonus = _expiry_bonus(g, need, fable_pct, now, rp)
        raw = mx if mx is not None else 0.0
        eligible.append({
            "penalty": 1 if (soft_penalty or projected) else 0,
            "soft": soft_penalty, "projected": projected, "reserve": 0,
            "score": max(0.0, raw - bonus), "raw": raw, "bonus": bonus,
            "pin": pin_rank, "fable": fable_pct if fable_pct is not None else 0.0,
            "fable_known": fable_pct is not None and fable_status != "rejected",
            "label": g.get("label") or "", "g": g})

    # R4 (default OFF): keep the ONE account with Fable headroom for Fable work.
    if rp["reserve_on"] and need == "any" and len(eligible) >= 2:
        holders = [e for e in eligible if e["fable_known"] and e["fable"] < soft]
        if len(holders) == 1:
            h = holders[0]
            fr = _fable_reset_epoch(h["g"])
            others_calm = any(e is not h and e["penalty"] == 0 for e in eligible)
            if (fr is not None and fr - now > rp["expiry_horizon_s"]
                    and h["penalty"] == 0 and others_calm):
                h["reserve"] = 1

    open_out = ({"label": fable_open[1], "at_epoch": int(fable_open[0])}
                if fable_open else None)

    if eligible:
        eligible.sort(key=lambda e: (e["penalty"], e["reserve"], e["score"],
                                     e["pin"], e["fable"], e["label"]))
        e = eligible[0]
        tags = ""
        if e["soft"]:
            tags += " [soft-penalized]"
        if e["projected"]:
            tags += " [projected-hot]"
        if e["bonus"] > 0:
            tags += " [expiry-bonus %.1f]" % e["bonus"]
        if e["reserve"]:
            tags += " [fable-reserve]"
        reason = "lowest max(%s)=%.1f%%%s" % (
            "5h,7d,Fable" if need == "fable" else "5h,7d", e["raw"], tags)
        chosen = dict(e["g"])
        chosen["reason"] = reason
        return {"classification": "chosen", "chosen": chosen, "reason": reason,
                "nearest_reset": None, "exit_code": 0,
                "fable_next_open": open_out, "fable_wait": None, "recheck_at": None}

    # R2 (advisory): need=fable with nothing eligible — wait for the opening, or
    # downgrade and re-check AT the opening rather than on a blind tick.
    wait, recheck = None, None
    if need == "fable" and open_out:
        wait = "hold" if (open_out["at_epoch"] - now) <= rp["hold_min"] * 60.0 else "downgrade"
        recheck = open_out["at_epoch"]

    if any_fresh:
        nearest = min(excluded_resets) if excluded_resets else None
        return {"classification": "measured-all-hot", "chosen": None,
                "reason": "measured-all-hot: every account excluded by HOLD/limit",
                "nearest_reset": nearest, "exit_code": 3,
                "fable_next_open": open_out, "fable_wait": wait, "recheck_at": recheck}

    return {"classification": "no-fresh-data", "chosen": None,
            "reason": "no-fresh-data: all readings UNKNOWN/stale — use ambient",
            "nearest_reset": None, "exit_code": 4,
            "fable_next_open": None, "fable_wait": None, "recheck_at": None}


def select_account(gauges, pinned_label=None, params=None, now=None, need="any"):
    """PURE: return the chosen gauge dict (with a ``reason`` key) or None."""
    return classify(gauges, pinned_label=pinned_label, params=params, now=now,
                    need=need)["chosen"]


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
    ap.add_argument("--need", choices=("any", "fable"), default=None,
                    help="'fable' ranks by max(5h,7d,Fable) and excludes Fable-rejected accounts")
    ap.add_argument("--model", default=None,
                    help="derive --need from a model id (claude-fable-* → fable)")
    args = ap.parse_args(argv)

    need = args.need or need_from_model(args.model)
    gauges = _load_gauges(args)
    result = classify(gauges, pinned_label=args.pinned, need=need)

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
