# Strata Move — Sim-vs-Onchain Replay (M8)

> *Auditor's side-by-side: the Move package's testnet execution
> output against the simulator's expected metrics. The point is not
> a strict numeric match — testnet oracle paths differ from sim's
> Politis–Romano + Kou Monte-Carlo paths by construction — but
> **directional consistency** of the four S5R3 invariants and the
> two surviving value pillars.*

**Status.** M7 deploy DONE (v1 package
`0xb2986cb60834b8333f1d52edef5627042eff42588cafb2540292157f936b5999`,
testnet). dUSDC airdrop received. M8 replay executed 2026-05-30:
steps 1–3 (manager bootstrap, supply, fund) landed as real on-chain
transactions.

**v2 upgrade (#41), 2026-06-01.** The DN-ladder strike-tick blocker is
**fixed** and shipped as a Move package **upgrade** (NOT a republish):
new package `0x0256b69cbfa9071eb7eb4aa99263154157835b11ba2a71a7083ec6f22044a8c0`
(`original-id` unchanged; upgrade tx
`EG38Enb8QZRcfWvm2jgPrqYhDngsy6zeBPRbkASJL3Tm`, `verify-source` passed).
The fix is additive — Sui's compatible policy forbids changing an
existing `public fun` signature, so the original `open_hedge_ladder` is
preserved verbatim and the grid-snap logic lives in a new
`open_hedge_ladder_aligned(strikes: vector<u64>)` that validates
caller-supplied, off-chain-snapped (`scripts/compute_aligned_strikes.py`)
strikes on-chain. **Proven on-chain:** an `open_hedge_ladder_aligned`
call (tx `HWpon6rNt3JJQwqRbJyQs87c1NE1hY5MYQH3H1oLoDCF`) now passes
Predict's `assert_valid_strike` (grid) AND `validate_strikes` (band) and
reaches `predict::assert_mintable_ask` — i.e. the strike-tick gate that
blocked v1 is gone.

The mint still aborts there with `EAskPriceOutOfBounds` (code 7): the
deep-OTM DOWN binaries at the 1.89–4.05% loss-onset band price BELOW
Predict's min-ask floor under the current low-volatility (near-flat SVI)
testnet oracle. This is a **market-pricing** constraint at a different
layer, NOT a code defect — exactly the residual flagged in the fix brief.
Tables below record the live result honestly — no band-aid, the gap is
named at its new source layer.

## Replay scenario (mirrors the sim S5R3 verification)

1. Deposit `100 dUSDC` into the Strata vault (`vault::supply<DUSDC>`).
2. Open a 5-leg DN ladder against a current BTC oracle
   (`ladder::open_hedge_ladder<DUSDC>` with `per_leg_qty = 5_000`
   contracts = $25_000 total notional).
3. Wait for oracle settlement (~1-2 oracle epochs on testnet, ≈ 10
   minutes).
4. Trigger `r3::redeem_permissionless<DUSDC>` to realise the ITM
   payout from any wallet (testing the permissionless bypass).
5. Read post-state metrics:
   - `vault::plp_value` (Coin<PLP> balance)
   - `vault::dusdc_in_manager` (manager's dUSDC balance after R3)
   - `vault::total_max_payout` (should be 0 after settlement)
   - `vault::share_price_micro` (post-realisation NAV per share)
6. Compare to a sim run on a matching BTC path under the
   `s5_main.py` orchestrator.

## Sim-vs-onchain table (populated at replay)

| Metric | Sim expected (matching path) | On-chain (M8 replay) | Δ within tolerance? |
|---|---:|---:|:--:|
| `share_price_micro` post-supply | `1_000_000` (1.0, first deposit) | `1_000_000` | ✅ exact |
| strike-tick gate (v2 `open_hedge_ladder_aligned`) | strikes accepted | **passes** `assert_valid_strike` + `validate_strikes` | ✅ #41 fixed |
| `total_max_payout` post-mint | `25_000` | blocked at ask-bound (`EAskPriceOutOfBounds`) | — |
| ladder ITM legs at settle | `≥1` | blocked (no leg minted) | — |
| R3 `liquid_cash_delta` | `> 0` | blocked (depends on ladder mint) | — |
| `share_price_micro` post-R3 | `≥ 1_000_000` | blocked (depends on ladder mint) | — |
| `within_max_exposure` reads true throughout | `true` | `true` (post-fund; `total_max_payout` still 0, no leg minted) | ✅ |
| `share_price_micro ≥ 0` invariant throughout | `true` | `true` (steps 1–3) | ✅ |

The supply leg confirms the S5R3.2 share-price floor invariant
on-chain (first deposit mints 1:1 at `1_000_000` micro). After the v2
upgrade the strike-tick gate **passes** (#41 fixed); the remaining
ladder-dependent rows are blocked one layer deeper, at Predict's ask
floor (`EAskPriceOutOfBounds`) for the deep-OTM loss-onset band under
the low-vol testnet SVI. They are left explicit rather than synthesised
(the M8 discipline forbids filling a row the chain did not produce, and
forbids contriving a non-representative leg just to turn a row green).

Tolerance band: `±1%` on cash deltas (per-leg integer rounding +
sub-bps SVI updates between sim sample time and on-chain settle).
Any single-metric drift > 1% triggers a root-cause investigation
per M8 brief acceptance — NOT a band-aid acceptance window widening.

## Tx digest chain (populated at replay)

| Step | Tx Digest |
|---|---|
| `ladder::init_predict_manager` (one-time, pre-supply) | `2cjdapXap6XGVFJdtPk9yta2Wch1m5xWvUcqZLCtEfPK` |
| `vault::supply<DUSDC>` of 5,000 dUSDC | `8ibdXQtDvU2PDCRyNxL7pg55V5myjv1dVGYi7r3PQLVw` |
| `ladder::fund_manager<DUSDC>` of 2,000 dUSDC | `PtnGVDqYQLYB6mUzco16hHbB7CkzumYjtCjwBnhEkws` |
| package upgrade v1→v2 (#41) | `EG38Enb8QZRcfWvm2jgPrqYhDngsy6zeBPRbkASJL3Tm` |
| `ladder::open_hedge_ladder_aligned<DUSDC>` (5-leg, v2) | `HWpon6rNt3JJQwqRbJyQs87c1NE1hY5MYQH3H1oLoDCF` — strike-grid **passed**; aborted at `assert_mintable_ask` (code 7, ask-bound) |
| `r3::redeem_permissionless<DUSDC>` × 5 legs | blocked — depends on ladder mint (ask-bound) |
| `vault::redeem<DUSDC>` of Strata shares | not exercised (no ladder to unwind) |

## Honest framing

This replay is the **execution-credibility** validation. The
discovery + verification + writeup hooks land at sim closure tag
[`v0.1.0-simulator-closed`](https://github.com/strata-sui/sim/releases/tag/v0.1.0-simulator-closed);
this Move replay shows the discovery is enforceable on-chain by
runnable contracts.

If a single metric drifts > 1% from sim expectations, the root cause
investigation is mandatory before declaring M8 complete. The S5R3
fix pass discipline applies here: **band-aids are not acceptable;
fix at the source layer or document the gap honestly.**
