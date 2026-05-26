# Strata Move — Sim-vs-Onchain Replay (M8)

> *Auditor's side-by-side: the Move package's testnet execution
> output against the simulator's expected metrics. The point is not
> a strict numeric match — testnet oracle paths differ from sim's
> Politis–Romano + Kou Monte-Carlo paths by construction — but
> **directional consistency** of the four S5R3 invariants and the
> two surviving value pillars.*

**Status.** Pending M7 deploy + dUSDC faucet receipt. This file is
the template the replay run fills in.

**When this lands.** Worker fills the table below once
`scripts/deploy_testnet.ps1` completes (M7) and Albary's dUSDC Tally
form receipt clears (M7 prerequisite for M8 supply/redeem). The
testnet replay is a single PowerShell session — see
`docs/move_m8_notes.md` (LOCAL) for the exact procedure.

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
| `total_max_payout` post-mint | `<PENDING>` | `<PENDING>` | `<PENDING>` |
| `share_price_micro` pre-settlement | `<PENDING>` | `<PENDING>` | `<PENDING>` |
| ladder ITM legs at settle | `<PENDING>` | `<PENDING>` | `<PENDING>` |
| R3 `liquid_cash_delta` | `<PENDING>` | `<PENDING>` | `<PENDING>` |
| `share_price_micro` post-R3 | `<PENDING>` | `<PENDING>` | `<PENDING>` |
| `within_max_exposure` reads true throughout | `true` | `<PENDING>` | `<PENDING>` |
| `share_price_micro ≥ 0` invariant throughout | `true` | `<PENDING>` | `<PENDING>` |

Tolerance band: `±1%` on cash deltas (per-leg integer rounding +
sub-bps SVI updates between sim sample time and on-chain settle).
Any single-metric drift > 1% triggers a root-cause investigation
per M8 brief acceptance — NOT a band-aid acceptance window widening.

## Tx digest chain (populated at replay)

| Step | Tx Digest |
|---|---|
| `vault::supply<DUSDC>` of 100 dUSDC | `<PENDING>` |
| `ladder::init_predict_manager` | `<PENDING>` (one-time, pre-supply) |
| `ladder::fund_manager<DUSDC>` of ~10 dUSDC | `<PENDING>` |
| `ladder::open_hedge_ladder<DUSDC>` (5-leg) | `<PENDING>` |
| `r3::redeem_permissionless<DUSDC>` × 5 legs | `<PENDING>` |
| `vault::redeem<DUSDC>` of 100 Strata shares | `<PENDING>` |

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
