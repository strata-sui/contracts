# Strata Contracts

> *On-chain implementation of the Strata vault on DeepBook Predict —
> a tail-truncated liquidity vault that earns yield AND hedges its
> own downside via a verified `redeem_permissionless` escape-hatch.*

Sui Overflow 2026 — DeepBook track. The Move package mirrors the
simulator's discovered invariants on-chain; the discovery, the
quantified pillars, and the methodology live in the sibling
[`strata-sui/sim`](https://github.com/strata-sui/sim) repository,
frozen at tag [`v0.1.0-simulator-closed`](https://github.com/strata-sui/sim/releases/tag/v0.1.0-simulator-closed).

## What this Move package does

The vault is a single shared `Vault` object holding the Strata
admin's `PredictManager` (Pattern A architecture — one manager per
vault, owned by Strata admin). User flow:

1. **Supply.** User calls `vault::supply<DUSDC>` to deposit dUSDC.
   The vault forwards the deposit to DeepBook Predict's PLP pool
   via `predict::supply<DUSDC>`; the user receives a Strata vault
   share token `Coin<VAULT>` minted NAV-proportional to the PLP
   token-supply received.
2. **Hedge.** Admin calls `ladder::open_hedge_ladder<DUSDC>` to
   construct an M-leg DN-binary ladder against an active oracle.
   Each leg's strike is set via the `compute_strikes` helper that
   spaces strikes uniformly across the empirical PLP loss-onset
   band (S0 diagnostic; anti-cherry-pick by construction).
3. **R3 escape-hatch.** After oracle settlement, **anyone** can call
   `r3::redeem_permissionless<DUSDC>` to realise the ladder's ITM
   payout via the verified
   [`predict::redeem_permissionless`](https://github.com/MystenLabs/deepbookv3/blob/predict-testnet-4-16/packages/predict/sources/predict.move)
   path that **bypasses** the standard PLP withdraw limiter. This
   is the on-chain analogue of the sim's $383,063 liquid-cash
   delta (`sim/data/s1_results/s5_r3_verification.json`).
4. **Redeem.** User calls `vault::redeem<DUSDC>` to burn the Strata
   share and receive dUSDC back. Subject to the standard PLP
   withdraw limiter when no R3 cash has been realised.

## Mapping to the sim's discovered invariants

The Move package enforces the four S5R3 invariants the simulator
phase pinned:

| Sim discovery | Move enforcement |
|---|---|
| **S5R3.2 Bug A** — share_price floored at 0 (depositor's loss bounded by deposit) | `vault::share_price_micro` reads `max(0, NAV / total_shares)` (`sources/vault.move::share_price_micro`) |
| **S5R3.3 Bug B** — `total_max_payout / balance <= max_exposure` | `vault::assert_within_max_exposure` invoked post-mint at every `ladder::open_hedge_ladder` call |
| **S4.1** — DN ladder shaped to PLP loss-onset band, uniform-in-log-moneyness | `ladder::compute_strikes` (uniform-in-bps on-chain approximation, sub-1% off log-uniform over the narrow 2.2% band) |
| **§3 anti-rug** — `f` upper bound 0.20 prevents griefing the hedge | `gov::set_f_bps` rejects values > `MAX_F_BPS = 2000` |

Every Move assertion that mirrors a sim invariant cites the sim file
+ line range in its module doc comment (auditor trail).

## Public testnet deploy

> *Pending the M7 deploy step. Worker's reproducible deploy script:
> `scripts/deploy_testnet.ps1`. When the deployer address has been
> funded with ≥ 2 SUI testnet gas, deploy completes in ~30 s; this
> section gets the live testnet `package_id` + deploy `tx_digest` +
> bytecode hash.*

| Field | Value |
|---|---|
| Package address | `<PENDING M7 publish>` |
| Deploy tx digest | `<PENDING M7 publish>` |
| Deployer (testnet) | `0x67606efb71792fdb505e123f020cfaaf19d9c54d3b07bf399b5fa08072f72eac` |
| Network | testnet |
| Sui CLI used | `1.72.2-85b460a63fd7-dirty` |

`scripts/deploy_testnet.ps1` is idempotent + crash-safe. The script
performs a pre-flight env / balance check, re-runs `sui move build`
+ `sui move test` as a publish gate, then publishes with a
200_000_000 MIST gas budget. The publish receipt
(`data/deploy_receipt.json`) captures `package_id`,
`deploy_tx_digest`, `vault_object_id`, and the deployer address for
auditor reproducibility.

## Build + test reproduction

```powershell
# 1. Build the Move package (pulls Sui framework + deepbook + predict
#    transitively; ~3-5 min first time).
sui move build

# 2. Run the Move unit test suite (33 tests at v0.1.0-contracts-testnet).
sui move test

# 3. Deploy to testnet (once the active address has SUI gas).
pwsh -File scripts/deploy_testnet.ps1
```

Build determinism: `Move.lock` is committed so the resolver state is
auditor-checkable. `Move.toml` pins `deepbook_predict` at git revision
`predict-testnet-4-16` (verified live at M0 pre-flight 2026-05-26 —
all 3 protocol addresses confirmed on-chain via `sui client object`).

## Honest disclosures

- **MARGINAL Gate-B verdict from sim is preserved.** The Move package
  is the execution credibility layer; it does NOT re-litigate the
  verdict. Sim's `gate_b.verdict_gate_b = "MARGINAL"` stands at tag
  [`v0.1.0-simulator-closed`](https://github.com/strata-sui/sim/releases/tag/v0.1.0-simulator-closed).
- **Two pillars hold under the corrected synthesis** (per
  `sim/SUBMISSION.md §4`):
    - **Tail truncation** — `best p01_reduction = +0.0473`
      monotonic-increasing in `f`; the hedge ladder truncates the
      left tail by design.
    - **R3 liquidity escape-hatch** — `$383,063` delta empirically
      quantified at sim time; this Move package implements the
      on-chain mechanic that produces this delta.
- **Sample size below the optimistic target.** The sim's 10k benign
  Monte-Carlo paths × 5,900 historical crash windows is below the
  brief's optimistic 1M target. Documented honestly in
  `sim/SUBMISSION.md §9`; the Move package inherits this disclosure
  by reference.
- **Move test count: 33** (M6 acceptance floor was ≥ 12). Integration
  tests against staged `Predict` + `OracleSVI` deferred to M8
  end-to-end testnet replay.

## Architectural decisions

- **Pattern A** (single shared `Vault` holds a single
  `PredictManager`; hedge ops are admin-only; the R3 path stays
  public by Predict design). Pattern B (per-user manager) was
  explicitly NOT taken — too complex for the 10-day phase budget.
- **No `AdminCap` capability object.** `vault.admin: address` is the
  single auth gate, reused across `vault.move` (M2),
  `ladder.move` (M3), and `gov.move` (M5). Admin rotation, if needed
  for production, is a follow-up `transfer_admin` entry.
- **Sui framework auto-resolution.** `Move.toml` declares only the
  `deepbook_predict` dependency; the Sui framework is brought in
  transitively at the revision `deepbook_predict` pins, avoiding the
  multi-version Sui conflict the dual-explicit pinning produced at
  M1.

## Related repositories

- [`strata-sui/sim`](https://github.com/strata-sui/sim) — NumPy Monte
  Carlo simulator (frozen at `v0.1.0-simulator-closed`).
- [`strata-sui/frontend`](https://github.com/strata-sui/frontend) —
  Next.js dashboard (frontend phase, separate brief).

## License

MIT. See [LICENSE](./LICENSE).

## Citations

- DeepBook Predict source, branch
  [`predict-testnet-4-16`](https://github.com/MystenLabs/deepbookv3/tree/predict-testnet-4-16/packages/predict).
- All Strata Move assertions that mirror a Predict mechanic cite the
  Predict source file + line range in their module doc comment
  (auditor trail).
- Strata simulator phase frozen at
  [`strata-sui/sim@v0.1.0-simulator-closed`](https://github.com/strata-sui/sim/releases/tag/v0.1.0-simulator-closed)
  (357 unit tests, Gate-B MARGINAL).
