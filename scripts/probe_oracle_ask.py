#!/usr/bin/env python3
"""probe_oracle_ask.py - FA2: run every live testnet BTC oracle's REAL SVI
through the FA1 ask calculator, against the FIXED ladder band [9595, 9811].

For each active oracle it asks: would a 5-leg DN ladder at the pinned loss-onset
band clear DeepBook Predict's 1% min-ask floor on THIS oracle's surface? If any
oracle clears, FA2 proceeds to a live open (band untouched -> not a cherry-pick,
just a higher-vol surface). If none clears, that strengthens the environmental
claim: the testnet oracle-set simply doesn't carry the vol/tenor that prices
this band in-bounds.

Reuses the byte-faithful formula in ask_floor_vol_sweep.py (no invented numbers).
Reads SVI + forward live from predict-server. stdlib only (urllib).
"""

import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ask_floor_vol_sweep import dn_ask, MIN_ASK  # noqa: E402
from compute_aligned_strikes import (  # noqa: E402
    aligned_down_strikes,
    DEFAULT_M_LO_BPS,
    DEFAULT_M_HI_BPS,
)

PREDICT_ID = "0xc8736204d12f0a7277c86388a68bf8a194b0a14c5538ad13f22cbd8e2a38028a"
BASE = "https://predict-server.testnet.mystenlabs.com"


def get(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.loads(r.read().decode())


def decode_svi(s):
    """svi/latest returns raw 1e9 ints + sign flags."""
    rho = s["rho"] / 1e9 * (-1 if s.get("rho_negative") else 1)
    m = s["m"] / 1e9 * (-1 if s.get("m_negative") else 1)
    return dict(a=s["a"] / 1e9, b=s["b"] / 1e9, rho=rho, m=m, sigma=s["sigma"] / 1e9)


def main():
    oracles = get(f"{BASE}/predicts/{PREDICT_ID}/oracles")
    oracles = oracles if isinstance(oracles, list) else (oracles.get("oracles") or oracles.get("data") or [])
    active = [o for o in oracles if str(o.get("status", "")).lower() == "active"]
    active.sort(key=lambda o: o.get("expiry", 1 << 62))
    print(f"active BTC oracles: {len(active)}  | band [{DEFAULT_M_LO_BPS},{DEFAULT_M_HI_BPS}] FIXED\n")

    now_ms = None
    print(f"{'oracle_id':>12} {'mins_out':>8} {'sigma':>8} {'b':>10} {'fwd($)':>9} {'min_ask':>9} {'clears1%':>8}")
    print("-" * 76)
    any_clear = False
    results = []
    for o in active:
        oid = o["oracle_id"]
        try:
            svi_raw = get(f"{BASE}/oracles/{oid}/svi/latest")
            px = get(f"{BASE}/oracles/{oid}/prices/latest")
        except Exception as e:  # noqa: BLE001
            print(f"{oid[:10]:>12}  (fetch error: {e})")
            continue
        if now_ms is None:
            now_ms = px.get("checkpoint_timestamp_ms") or px.get("onchain_timestamp")
        svi = decode_svi(svi_raw)
        forward = int(px["forward"])
        mins_out = (o.get("expiry", 0) - (now_ms or 0)) / 60000.0
        try:
            strikes = aligned_down_strikes(forward, DEFAULT_M_LO_BPS, DEFAULT_M_HI_BPS, 5,
                                           o["min_strike"], o["tick_size"], o["min_strike"] + 100000 * o["tick_size"])
        except ValueError as e:  # band too tight / forward too low
            print(f"{oid[:10]:>12} {mins_out:>8.0f}  snap-skip: {e}")
            continue
        asks = [dn_ask(s, forward, svi) for s in strikes]
        min_ask = min(asks)
        clears = all(a >= MIN_ASK for a in asks)
        any_clear = any_clear or clears
        print(f"{oid[:10]:>12} {mins_out:>8.0f} {svi['sigma']:>8.4f} {svi['b']:>10.6f} "
              f"{forward/1e9:>9,.0f} {min_ask*100:>8.3f}% {('YES' if clears else 'no'):>8}")
        results.append(dict(oracle_id=oid, mins_out=round(mins_out, 1), sigma=svi["sigma"],
                            b=svi["b"], forward=forward, min_leg_ask=round(min_ask, 6), clears=clears))

    print("-" * 76)
    print(f"\nany oracle clears the 1% floor for the fixed band? {'YES' if any_clear else 'NO'}")
    if not any_clear:
        print("=> the testnet oracle-set does not carry vol/tenor that prices this band "
              "in-bounds; the residual is environmental, not a design failure.")
    out = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "..", "data", "probe_oracle_ask.json"))
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"any_clear": any_clear, "oracles": results}, f, indent=2)
    print(f"JSON: {out}")


if __name__ == "__main__":
    main()
