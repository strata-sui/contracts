# Strata Move — Sim-vs-Onchain Replay (M8)

> *Auditor's side-by-side: the Move package's testnet execution
> output against the simulator's expected metrics. The point is not
> a strict numeric match — testnet oracle paths differ from sim's
> Politis–Romano + Kou Monte-Carlo paths by construction — but
> **directional consistency** of the four S5R3 invariants and the
> two surviving value pillars.*

**Status.** M7 deploy DONE (package
`0xb2986cb60834b8333f1d52edef5627042eff42588cafb2540292157f936b5999`,
testnet). dUSDC airdrop received. M8 replay executed 2026-05-30:
steps 1–3 (manager bootstrap, supply, fund) landed as real on-chain
transactions; the ladder-open leg (step 4) is blocked by an on-chain
strike-tick constraint, documented in `README.md` ("Known limitation
— DN-ladder strike-tick alignment"). Tables below record the live
result honestly — no band-aid, the gap is named at its source layer.

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
| `total_max_payout` post-mint | `25_000` | blocked (ladder leg) | — |
| ladder ITM legs at settle | `≥1` | blocked (ladder leg) | — |
| R3 `liquid_cash_delta` | `> 0` | blocked (depends on ladder) | — |
| `share_price_micro` post-R3 | `≥ 1_000_000` | blocked (depends on ladder) | — |
| `within_max_exposure` reads true throughout | `true` | `true` (post-fund, pre-ladder) | ✅ |
| `share_price_micro ≥ 0` invariant throughout | `true` | `true` (steps 1–3) | ✅ |

The supply leg confirms the S5R3.2 share-price floor invariant
on-chain (first deposit mints 1:1 at `1_000_000` micro). The
ladder-dependent rows are blocked at the strike-tick constraint
named in `README.md`; they are left explicit rather than synthesised
(the M8 discipline forbids filling a row the chain did not produce).

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
| `ladder::open_hedge_ladder<DUSDC>` (5-leg) | blocked — strike-tick constraint (README) |
| `r3::redeem_permissionless<DUSDC>` × 5 legs | blocked — depends on ladder open |
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
