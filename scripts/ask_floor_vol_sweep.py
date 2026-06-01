#!/usr/bin/env python3
"""ask_floor_vol_sweep.py - FA1: demonstrate the ask-bound mechanism (#41).

Reproduces DeepBook Predict's binary ask formula EXACTLY as in the pinned
contract source, then sweeps implied total variance to show:
  * at the near-degenerate low-vol surfaces seen on testnet, the deep-OTM DOWN
    legs price BELOW the 1% min-ask floor -> predict::mint reverts
    (EAskPriceOutOfBounds) -- the residual the v2 grid-snap upgrade surfaced;
  * at realistic / mainnet-like implied vol, those same legs clear the floor;
  * the ladder band [9595, 9811] bps is held FIXED in every single row -- the
    lever is the volatility surface, NOT the band (moving the band would be the
    cherry-pick the anti-overfit discipline forbids).

Formula provenance -- byte-verified against deepbookv3 @ predict-testnet-4-16
(local dep rev 1159d79a), so these are the real on-chain numbers, not invented:
  oracle.move::compute_nd2          (lines 396-429)
      k    = ln(strike / forward)
      w(k) = a + b * (rho*(k - m) + sqrt((k - m)^2 + sigma^2))      # total variance
      d2   = -((k + w/2) / sqrt(w));   UP = N(d2);   DN = 1 - UP
  predict.move::trade_prices        (lines 819-854)
      dn_ask = 1 - up_bid = (1 - UP) + spread
  pricing_config.move::quote_spread_from_fair_price (lines 91-107)
      spread = max(base_spread * sqrt(p*(1-p)), min_spread) + util_term
  constants.move (FLOAT_SCALING = 1e9):
      base_spread = 20_000_000 (2%), min_spread = 5_000_000 (0.5%),
      min_ask_price = 10_000_000 (1%), max_ask_price = 990_000_000 (99%).

All on-chain SVI params + prices are 1e9 fixed-point; we work in decimals
(raw_int / 1e9). The Move `ln`/`sqrt`/`normal_cdf` are fixed-point
approximations; here we use IEEE-754 `math.erf` (exact normal CDF). The
difference is < 1e-3 and does not move the qualitative floor-crossing threshold.
"""

import csv
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compute_aligned_strikes import (  # noqa: E402
    aligned_down_strikes,
    DEFAULT_MIN_STRIKE,
    DEFAULT_TICK_SIZE,
    DEFAULT_MAX_STRIKE,
    DEFAULT_M_LO_BPS,
    DEFAULT_M_HI_BPS,
)

# --- Predict pricing constants (constants.move, decoded from FLOAT_SCALING) ---
BASE_SPREAD = 0.02   # 20_000_000 / 1e9
MIN_SPREAD = 0.005   # 5_000_000  / 1e9
MIN_ASK = 0.01       # 10_000_000 / 1e9  (assert_mintable_ask floor)
MAX_ASK = 0.99       # 990_000_000 / 1e9

# --- §4 live testnet SVI sample (CLAUDE.md §4 / verified live API) ------------
# a, b are raw 1e9 ints -> /1e9; rho, m, sigma already decoded decimals.
BASE_SVI = dict(a=165787 / 1e9, b=7321280 / 1e9, rho=-0.3188, m=-0.00275, sigma=0.01426)

# Representative live BTC forward (native 1e9-per-USD units; ~ $72,871).
FORWARD = 72_871_250_000_000


def norm_cdf(x):
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def total_variance(k, svi):
    km = k - svi["m"]
    inner = svi["rho"] * km + math.sqrt(km * km + svi["sigma"] ** 2)
    return svi["a"] + svi["b"] * inner


def up_price(strike, forward, svi):
    k = math.log(strike / forward)
    w = total_variance(k, svi)
    if w <= 0:  # degenerate surface -> step function (settled-like)
        return 1.0 if k < 0 else 0.0
    d2 = -((k + w / 2.0) / math.sqrt(w))
    return norm_cdf(d2)


def dn_ask(strike, forward, svi):
    """DOWN-binary ask = 1 - up_bid, with up_bid = max(UP - spread, 0).
    util term = 0 (fresh vault, total_mtm ~ 0); this is the conservative case
    for clearing the MIN floor (utilization only widens the spread upward)."""
    up = up_price(strike, forward, svi)
    spread = max(BASE_SPREAD * math.sqrt(up * (1.0 - up)), MIN_SPREAD)
    up_bid = max(up - spread, 0.0)
    return 1.0 - up_bid


def scaled_svi(svi, var_mult):
    """Scale TOTAL VARIANCE by var_mult (w = a + b*inner scales linearly in a,b;
    `inner` depends only on rho/m/sigma, so this is an exact variance scaling).
    vol multiplier = sqrt(var_mult)."""
    return dict(a=svi["a"] * var_mult, b=svi["b"] * var_mult,
                rho=svi["rho"], m=svi["m"], sigma=svi["sigma"])


def atm_sigma(svi):
    """Effective ATM total vol = sqrt(w(k=m)) = sqrt(a + b*sigma)."""
    return math.sqrt(max(total_variance(svi["m"], svi), 0.0))


def main():
    strikes = aligned_down_strikes(
        FORWARD, DEFAULT_M_LO_BPS, DEFAULT_M_HI_BPS, 5,
        DEFAULT_MIN_STRIKE, DEFAULT_TICK_SIZE, DEFAULT_MAX_STRIKE,
    )
    print(f"forward = {FORWARD}  (~${FORWARD/1e9:,.0f})")
    print(f"band    = [{DEFAULT_M_LO_BPS}, {DEFAULT_M_HI_BPS}] bps  (FIXED in every row)")
    print("strikes = " + ", ".join(f"${s/1e9:,.0f}" for s in strikes))
    print(f"min-ask floor = {MIN_ASK*100:.1f}%   (assert_mintable_ask)\n")

    # Variance multipliers spanning degenerate-testnet -> mainnet-like.
    mults = [0.003, 0.01, 0.03, 0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0]
    label = {
        0.003: "~ degenerate testnet oracle (observed; near-zero vol)",
        1.0: "~ live testnet SVI sample (CLAUDE.md sec 4)",
        16.0: "~ mainnet-like real vol (stressed BTC)",
    }

    rows = []
    threshold = None
    print(f"{'var_mult':>9} {'sigma_atm':>10} {'min_leg_ask':>12} {'all>=1%?':>9}  note")
    print("-" * 78)
    for mult in mults:
        svi = scaled_svi(BASE_SVI, mult)
        asks = [dn_ask(s, FORWARD, svi) for s in strikes]
        min_ask = min(asks)
        clears = all(a >= MIN_ASK for a in asks)
        if clears and threshold is None:
            threshold = mult
        note = label.get(mult, "")
        print(f"{mult:>9.3f} {atm_sigma(svi)*100:>9.3f}% {min_ask*100:>11.3f}% "
              f"{('YES' if clears else 'no'):>9}  {note}")
        rows.append(dict(var_mult=mult, sigma_atm=round(atm_sigma(svi), 6),
                         min_leg_ask=round(min_ask, 6),
                         all_legs_clear_1pct=clears, note=note))

    print("-" * 78)
    if threshold is not None:
        print(f"\nThreshold: all 5 band legs clear the 1% floor at var_mult >= {threshold} "
              f"(sigma_atm >= {atm_sigma(scaled_svi(BASE_SVI, threshold))*100:.3f}%).")
    print("Band identical in every row -> the lever is surface vol/tenor, not the band.")

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data",
                       "ask_floor_vol_sweep.csv")
    out = os.path.normpath(out)
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["var_mult", "sigma_atm", "min_leg_ask",
                                          "all_legs_clear_1pct", "note"])
        w.writeheader()
        w.writerows(rows)
    print(f"\nCSV: {out}")


if __name__ == "__main__":
    main()
