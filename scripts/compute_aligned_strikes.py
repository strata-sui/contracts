#!/usr/bin/env python3
"""compute_aligned_strikes.py — #41 grid-snap helper.

Strata's DN-ladder strikes must be multiples of the live Predict grid tick
(`strike % tick_size == 0`, with `tick_size = 1e9` on the BTC oracle's
1e9-per-USD scale). The on-chain `ladder::compute_strikes` emits raw
`forward * m_k_bps / 10000` values that are NOT tick-aligned, so
`predict::mint::assert_valid_strike` reverts. This snapper computes the band
strikes off-chain and rounds each to the nearest grid tick, producing a
strictly-ascending vector the upgraded `open_hedge_ladder_aligned(strikes=...)` accepts.

Grid params come from the predict-server oracles endpoint; `forward` MUST be the
oracle's `forward_price()` in native (1e9-per-USD) units — NOT a REST field
(`o.get("forward")` is a latent bug: the endpoint does not return forward).

Usage:
    python compute_aligned_strikes.py --forward 100000000000000 \\
        [--n 5] [--m-lo-bps 9595] [--m-hi-bps 9811] \\
        [--min-strike 50000000000000] [--tick 1000000000] \\
        [--max-strike 150000000000000]
"""

import argparse
import sys

# Live BTC oracle grid (predict-server, 2026-05-31). 1e9-per-USD scale.
DEFAULT_MIN_STRIKE = 50_000_000_000_000   # 5e13  = $50,000 (grid floor)
DEFAULT_TICK_SIZE = 1_000_000_000         # 1e9   = $1 step
DEFAULT_MAX_STRIKE = 150_000_000_000_000  # 1.5e14 = $150,000
DEFAULT_M_LO_BPS = 9595
DEFAULT_M_HI_BPS = 9811
DEFAULT_N = 5

# Floor caveat: every leg must clear min_strike. The lowest leg is
# forward * m_lo_bps / 10000, so forward must satisfy
#   forward * 9595 / 10000 >= 50_000_000_000_000  ->  forward >= 5.211e13
# (BTC roughly >~4% above the $50k floor). RAISE if violated — never clamp.
MIN_FORWARD_FOR_BAND = 52_110_000_000_000  # ~5.211e13


def aligned_down_strikes(
    forward, m_lo_bps, m_hi_bps, n, min_strike, tick_size, max_strike
):
    # On-chain band bounds: ladder::validate_strikes uses the SAME floor-based
    # formula (mul_div(forward, m_*_bps, 10000)) and rejects any strike outside
    # [band_lo, band_hi]. Nearest-tick rounding can push the end legs just past
    # those bounds, so we clamp into the tick-aligned sub-band
    # [ceil(band_lo/tick), floor(band_hi/tick)] which is guaranteed to satisfy
    # the on-chain check. Also respect the grid floor/ceiling [min, max].
    band_lo = forward * m_lo_bps // 10000
    band_hi = forward * m_hi_bps // 10000
    lo_aligned = -(-band_lo // tick_size) * tick_size            # ceil to tick
    hi_aligned = (band_hi // tick_size) * tick_size              # floor to tick
    lo_aligned = max(lo_aligned, min_strike)
    hi_aligned = min(hi_aligned, (max_strike // tick_size) * tick_size)

    if n == 1:
        raws = [forward * ((m_lo_bps + m_hi_bps) // 2) // 10000]
    else:
        span = m_hi_bps - m_lo_bps
        raws = [
            forward * (m_lo_bps + span * k // (n - 1)) // 10000 for k in range(n)
        ]
    out = []
    for r in raws:
        s = round(r / tick_size) * tick_size                     # nearest tick
        s = min(max(s, lo_aligned), hi_aligned)                  # clamp into band
        out.append(s)
    if len(set(out)) != n or any(out[i] >= out[i + 1] for i in range(n - 1)):
        raise ValueError(
            "band too tight / forward too low — raise (m_hi-m_lo) span or lower n"
        )
    assert all(s % tick_size == 0 for s in out)
    # The on-chain validate_strikes invariant: every strike within the band.
    assert all(band_lo <= s <= band_hi for s in out)
    assert all(min_strike <= s <= max_strike for s in out)
    return out


def main():
    ap = argparse.ArgumentParser(description="Grid-snap DN ladder strikes (#41).")
    ap.add_argument("--forward", type=int, required=True,
                    help="oracle forward_price() in native 1e9-per-USD units")
    ap.add_argument("--n", type=int, default=DEFAULT_N)
    ap.add_argument("--m-lo-bps", type=int, default=DEFAULT_M_LO_BPS)
    ap.add_argument("--m-hi-bps", type=int, default=DEFAULT_M_HI_BPS)
    ap.add_argument("--min-strike", type=int, default=DEFAULT_MIN_STRIKE)
    ap.add_argument("--tick", type=int, default=DEFAULT_TICK_SIZE)
    ap.add_argument("--max-strike", type=int, default=DEFAULT_MAX_STRIKE)
    args = ap.parse_args()

    if args.forward < MIN_FORWARD_FOR_BAND:
        sys.exit(
            f"ERROR: forward {args.forward} < floor {MIN_FORWARD_FOR_BAND} "
            f"(~5.211e13). The lowest leg would fall below the grid floor "
            f"(${args.min_strike // 1_000_000_000:,}). RAISE forward (BTC must "
            f"be >~4% above the floor) -- refusing to silently clamp to the floor."
        )

    strikes = aligned_down_strikes(
        args.forward, args.m_lo_bps, args.m_hi_bps, args.n,
        args.min_strike, args.tick, args.max_strike,
    )

    # Move vector literal for the open PTB.
    print("vector[" + ",".join(str(s) for s in strikes) + "]")
    # Per-leg list for the redeem PTB (must use the SAME strikes).
    print("# per-leg strikes (redeem PTB, keep in sync):")
    for i, s in enumerate(strikes):
        print(f"#   leg {i}: {s}  (${s / 1_000_000_000:,.0f})")


if __name__ == "__main__":
    main()
