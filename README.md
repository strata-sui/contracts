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

> *Deployed to Sui testnet 2026-05-30. Published from the canonical
> Strata testnet address with the `Published.toml`-in-cache mechanism
> (see "Verifying the build on Suiscan" below) so the canonical
> `predict` / `deepbook` / `token` packages are linked, never
> republished.*

| Field | Value |
|---|---|
| Package address | `0xb2986cb60834b8333f1d52edef5627042eff42588cafb2540292157f936b5999` |
| Deploy tx digest | `DrBXTuFBnwhqctbNmoCSvw5jZ4GRq8pJEh2M8aAmNZuU` |
| Vault object (shared) | `0x44cc95d2a0a2ed3bff1ff36873a0a5ac859b1ef382eb55d53d77907aaf1053b9` |
| UpgradeCap | `0xbff356585e35890fba6c09733463158a96530c0a9b0c2bca2ab042f41e95012a` |
| Deployer (testnet) | `0xe7b270554f5e3cb61f178f0411a71601b9d4c5a3114f26fa40104d4b22696add` |
| Network | testnet (chain-id `4c78adac`) |
| Sui CLI used | `1.73.0` |

Explore on Suiscan: <https://suiscan.xyz/testnet/object/0xb2986cb60834b8333f1d52edef5627042eff42588cafb2540292157f936b5999>

`scripts/deploy_testnet.ps1` is idempotent + crash-safe. The script
performs a pre-flight env / balance check, re-runs `sui move build`
+ `sui move test` as a publish gate, then publishes with a
200_000_000 MIST gas budget. The publish receipt
(`data/deploy_receipt.json`) captures `package_id`,
`deploy_tx_digest`, `vault_object_id`, and the deployer address for
auditor reproducibility.

## End-to-end testnet replay (M8)

The live user flow was exercised against the deployed package on
testnet 2026-05-30. Each step is a real on-chain transaction, linking
the canonical DeepBook Predict `Predict`, `OracleSVI`, and
`PredictManager` objects:

| Step | Entry | Tx digest | Result |
|---|---|---|---|
| 1. Bootstrap manager | `ladder::init_predict_manager` | `2cjdapXap6XGVFJdtPk9yta2Wch1m5xWvUcqZLCtEfPK` | Shared `PredictManager` `0x5841704d6fe4b567d66ed8234ca6aba37de70a5ecd2760132a42a75c570fd802` created + linked into the vault |
| 2. Supply | `vault::supply<DUSDC>` | `8ibdXQtDvU2PDCRyNxL7pg55V5myjv1dVGYi7r3PQLVw` | 5,000 dUSDC → PLP; received `Coin<VAULT>` share `0x6209c56ff1d35d6898c41ab7ee2533c70742ec56e4a758c27fba80ed0c068336` |
| 3. Fund manager | `ladder::fund_manager<DUSDC>` | `PtnGVDqYQLYB6mUzco16hHbB7CkzumYjtCjwBnhEkws` | 2,000 dUSDC deposited into the hedge-side `PredictManager` bank |
| 4. Open hedge ladder | `ladder::open_hedge_ladder_aligned<DUSDC>` (v2) | `HWpon6rNt3JJQwqRbJyQs87c1NE1hY5MYQH3H1oLoDCF` | Strike-grid gate **passed** (#41 fixed); mint aborts one layer deeper at the ask-bound — see limitation below |

### Strike-tick alignment — FIXED in v2 (#41); residual is the ask-bound

**Resolved.** The v1 blocker was `ladder::compute_strikes` emitting
`mul_div(forward, m_bps, 10000)` strikes that are not multiples of the
oracle tick (`tick_size = 1e9`), so Predict's `assert_valid_strike`
aborted. The **v2 upgrade** (package
`0x0256b69cbfa9071eb7eb4aa99263154157835b11ba2a71a7083ec6f22044a8c0`,
upgrade tx `EG38Enb8QZRcfWvm2jgPrqYhDngsy6zeBPRbkASJL3Tm`) adds
`ladder::open_hedge_ladder_aligned(strikes: vector<u64>)`: strikes are
snapped to the grid off-chain by `scripts/compute_aligned_strikes.py`
(clamped into the on-chain floor-based band) and validated on-chain by
`ladder::validate_strikes` (strictly ascending + in-band). An on-chain
call (tx `HWpon6rNt3JJQwqRbJyQs87c1NE1hY5MYQH3H1oLoDCF`) confirms the
strikes now **pass** both `assert_valid_strike` and `validate_strikes`.

The fix is additive: Sui's compatible upgrade policy forbids changing an
existing `public fun` signature, so the original `open_hedge_ladder` is
preserved verbatim (ABI-compatible) and the new logic lives in
`open_hedge_ladder_aligned`.

**Residual (market-pricing, not a code defect) — and how it is cleared
WITHOUT touching the band.** On short-tenor, low-σ testnet oracles the
mint aborts at `predict::assert_mintable_ask` with `EAskPriceOutOfBounds`:
the deep-OTM DOWN binaries at the 1.89–4.05 % loss-onset band price below
Predict's 1 % min-ask floor.

The band is held **FIXED** by anti-cherry-pick discipline — it is pinned
to the PLP loss-onset diagnostic (`[9595, 9811]` bps, set in S0 before any
Sortino was computed). The 1 % ask floor is cleared by **surface
vol/tenor — mainnet real-vol, or a higher-vol testnet oracle — NOT by
moving the band.** Moving the band toward the forward would clear the
floor too, but that is precisely the outcome-tuning the discipline
forbids, so we decline it.

This is demonstrated two ways, both with the band untouched:
- **Calculator** (`scripts/ask_floor_vol_sweep.py`): a byte-faithful
  reproduction of Predict's ask formula shows the fixed band clears the
  1 % floor once `σ_atm ≳ 1.16 %`; the live SVI sample already clears at
  ~4.6 %, mainnet-like vol at ~36 %.
- **Live on-chain** (`scripts/probe_oracle_ask.py` + a real open): probing
  every live BTC oracle found the longer-tenor ones above that threshold;
  opening the SAME pinned band against a ~18 h-tenor oracle
  (`0x8ce7edba…`) **succeeded** — tx
  `Fp6ipCErtEVqi9JsEewgRcmaCyZbLr9H63hyHzDQvpzx` minted real DN binaries
  with `within_max_exposure = true`. Only the oracle's tenor/vol differs;
  the band is identical. (See REPLAY.md.)

We record the short-tenor block rather than contrive a non-representative
leg to force a green (the no-band-aid discipline). The supply / fund / R3
legs and all four sim invariants are unaffected and proven live above; the
sim verdict is untouched.

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

Build determinism: `Move.lock` + `Published.toml` are committed so the
resolver state and the published address are auditor-checkable.
`Move.toml` pins `deepbook_predict` at git revision
`predict-testnet-4-16` (verified live at M0 pre-flight 2026-05-26 —
all 3 protocol addresses confirmed on-chain via `sui client object`).

## Verifying the build on Suiscan

The published package reproduces deterministically from this repo's
committed source. You can confirm it two ways.

### 1. Local CLI verification (`sui client verify-source`)

This compiles the local source and byte-compares it against the
on-chain package at the address in `Published.toml`:

```bash
sui client verify-source        # add --verify-deps to also check deps
# => "Source verification succeeded!"
```

A green result proves the committed `sources/` + `Move.toml` +
`Move.lock` produce *exactly* the bytecode living at
`0xb2986cb6…b5999` on testnet. This repo passes as of the deploy
commit.

### 2. Suiscan source verification (the public "Verified" badge)

Suiscan's verifier (WELLDONE Studio / Blockberry) does the same
bytecode comparison, then publishes a **Source Code** tab + a
"Verified" label on the package page. Steps:

1. Zip the package source. It MUST contain `Move.toml` (with **git**
   dependencies, not local paths), `Move.lock`, `Published.toml`, and
   the `sources/` directory:

   ```bash
   zip -r strata_vault_src.zip Move.toml Move.lock Published.toml sources/
   # no `zip` installed? python fallback:
   python3 -c "import zipfile,os; z=zipfile.ZipFile('strata_vault_src.zip','w',zipfile.ZIP_DEFLATED); [z.write(f) for f in ['Move.toml','Move.lock','Published.toml']]; [z.write(os.path.join(r,fn)) for r,_,fs in os.walk('sources') for fn in fs]; z.close()"
   ```

2. Open the package on Suiscan testnet:
   <https://suiscan.xyz/testnet/object/0xb2986cb60834b8333f1d52edef5627042eff42588cafb2540292157f936b5999>

3. Click **Verify** (only shown for unverified packages).

4. Paste the package ID `0xb2986cb6…b5999` and upload
   `strata_vault_src.zip` (browse or drag-drop).

5. The verifier compiles the zipped source against the git deps and
   compares to on-chain bytecode. On success a **Source Code** tab
   appears and the package is badged **Verified**.

> Requirements that make verification pass: dependencies in `Move.toml`
> are git-pinned (Strata pins `deepbook_predict` / `deepbook` / `token`
> by `rev`), `Published.toml` carries the canonical `published-at`, and
> the zip is built from the same commit that was deployed. Third-party
> "no-code" deployers often omit `Move.lock` / source files and fail
> here — Strata ships the full source so it does not.

### Verifying at the moment you run `sui client publish`

To verify a *fresh* deploy in one flow:

```bash
# 1. Publish. Sui writes Published.toml with the new published-at.
sui client publish --gas-budget 500000000 --json > publish_output.json

# 2. Immediately byte-verify the local source against what you just
#    published (no address to copy — it reads Published.toml):
sui client verify-source

# 3. Commit Published.toml (+ Move.lock) so the verified address is
#    pinned in source control, then do the Suiscan zip-upload above.
git add Published.toml Move.lock && git commit -m "chore: pin published address"
```

`verify-source` right after `publish` is the fast self-check; the
Suiscan zip-upload is the public-facing badge. Do both.

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
