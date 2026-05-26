/// Strata R3 — liquidity escape-hatch wrapper around
/// `deepbook_predict::predict::redeem_permissionless<Quote>`. THE
/// submission's pillar-2 empirical claim
/// (`sim/SUBMISSION.md §5`, `README.md` three-pillars table)
/// depends on this entry function existing on-chain.
///
/// Sim cross-references:
///   * Empirical $383,063 liquid-cash delta:
///     `sim/data/s1_results/s5_r3_verification.json::r3_delta::liquid_cash_delta_R3`.
///   * R3 verification scenario (rigged 8% crash + heavy trader-DN
///     mints driving `available_for_withdraw -> 0`):
///     `sim/s5_r3_verification.py`.
///   * Stress test confirming model RESPONSIVE to bypass (disable
///     bypass → Strata collapses to raw_plp $0):
///     `s5_r3_verification.json::r3_delta::stress_strata_if_no_bypass`.
///
/// DeepBook Predict mechanic citations (branch
/// `predict-testnet-4-16`):
///   * `sources/predict.move::redeem_permissionless` lines 300-313 —
///     `oracle.is_settled()` gate (NOT just expired — settlement =
///     first post-expiry price update). NO `sender == manager.owner`
///     check (THE bypass — permissionless by Predict design).
///   * `sources/predict_manager.move::deposit_permissionless` —
///     bypasses owner check on the deposit side; THE structural
///     reason this path realizes cash even when standard `withdraw`
///     is limiter-bound.
///
/// Pattern A architecture decision (`docs/move_appendix_protocol.md
/// §8` — LOCKED): R3 redeem permissionless STAYS public (by Predict
/// design), even though hedge open/owner-redeem is admin-only.
/// Anyone — including a keeper bot or another LP — can trigger
/// settlement realization on Strata's hedge legs. The pillar-2 claim
/// is THIS exact property.
///
/// Diction discipline (CLAUDE.md §8 rule B): "tail truncation",
/// "quantified residual", "left-tail reduction", "downside-truncated".
/// Banned: "capped", "loss-proof", "can't lose".
module strata_vault::r3;

use sui::clock::Clock;
use sui::event;

use deepbook_predict::predict::{Self, Predict};
use deepbook_predict::predict_manager::{Self, PredictManager};
use deepbook_predict::market_key::{Self, MarketKey};
use deepbook_predict::oracle::{Self, OracleSVI};

use strata_vault::vault::{Self, Vault};

// ---- Errors ------------------------------------------------------------

const EManagerNotInitialised: u64 = 300;
const EManagerMismatch: u64 = 301;
const EZeroQuantity: u64 = 302;

// ---- Events ------------------------------------------------------------

/// Emitted on every successful R3 redeem. The `liquid_cash_delta`
/// IS the on-chain analogue of the sim's $383,063 figure
/// (`sim/data/s1_results/s5_r3_verification.json`). Off-chain
/// indexers + the REPLAY.md audit table consume this directly.
public struct R3LiquidityRealized has copy, drop, store {
    vault_id: ID,
    manager_id: ID,
    oracle_id: ID,
    strike: u64,
    is_up: bool,
    quantity_redeemed: u64,
    liquid_cash_delta: u64,
    executor: address,
}

// ---- Entry function (PUBLIC — permissionless by design) ----------------

/// Public R3 entry — anyone can call after the oracle settles. The
/// realized payout enters the Strata `PredictManager`'s balance via
/// `manager.deposit_permissionless` (bypasses the owner check on
/// both sides — that's the structural bypass the submission's
/// pillar-2 claim is anchored on).
///
/// Strata-side updates AFTER `predict::redeem_permissionless`:
///   * `total_max_payout` reduces by `quantity` (the redeemed leg
///     closes; the Strata-side max-exposure denominator regains
///     the freed headroom).
///   * `dusdc_in_manager` bumps by the measured liquid delta
///     (`post_balance - pre_balance`). The cash now lives inside
///     `manager.balance<Quote>`, accessible by admin-only
///     `manager.withdraw` OR to be redeployed in the next cycle's
///     hedge open.
///
/// Reverts cleanly when:
///   * `manager` ID mismatches the one Strata recorded at
///     `init_predict_manager` (EManagerMismatch).
///   * Quantity is zero (EZeroQuantity).
///   * Oracle is NOT yet settled (propagated from
///     `predict::redeem_permissionless` as `EOracleNotSettled`).
///   * Manager has no matching position to redeem (propagated as
///     Predict's internal redeem-side errors).
public fun redeem_permissionless<Quote>(
    self: &mut Vault,
    predict_obj: &mut Predict,
    manager: &mut PredictManager,
    oracle_svi: &OracleSVI,
    key: MarketKey,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Strata-side manager-binding check (avoids cross-vault
    // griefing — only the manager Strata recorded at init is
    // accepted).
    assert!(vault::has_predict_manager(self), EManagerNotInitialised);
    let recorded = *option::borrow(vault::predict_manager_id(self));
    assert!(object::id(manager) == recorded, EManagerMismatch);
    assert!(quantity > 0, EZeroQuantity);

    // 2. Snapshot manager.balance<Quote> pre-call so we can measure
    // the realized liquid delta empirically (the sim's
    // `liquid_cash_delta_R3` field is the same pre/post comparison
    // — see `sim/s5_r3_verification.py`).
    let pre_balance = predict_manager::balance<Quote>(manager);

    // 3. THE bypass path. `predict::redeem_permissionless` enforces
    // `oracle.is_settled()` internally (line 309 of predict.move at
    // `predict-testnet-4-16`); no owner check anywhere. Payout
    // lands directly in `manager.balance<Quote>` via
    // `deposit_permissionless`.
    predict::redeem_permissionless<Quote>(
        predict_obj,
        manager,
        oracle_svi,
        key,
        quantity,
        clock,
        ctx,
    );

    let post_balance = predict_manager::balance<Quote>(manager);
    let liquid_delta = if (post_balance > pre_balance) {
        post_balance - pre_balance
    } else {
        0
    };

    // 4. Strata-side mirror updates:
    //   * total_max_payout reduces by quantity (the leg is now
    //     settled; the Strata exposure denominator regains headroom
    //     for `within_max_exposure` to relax post-redeem).
    //   * dusdc_in_manager bumps by liquid_delta (the realized cash
    //     now sitting inside manager.balance).
    vault::reduce_max_payout(self, quantity);
    vault::bump_dusdc_in_manager(self, liquid_delta);

    event::emit(R3LiquidityRealized {
        vault_id: object::id(self),
        manager_id: recorded,
        oracle_id: oracle::id(oracle_svi),
        strike: market_key::strike(&key),
        is_up: market_key::is_up(&key),
        quantity_redeemed: quantity,
        liquid_cash_delta: liquid_delta,
        executor: ctx.sender(),
    });
}
