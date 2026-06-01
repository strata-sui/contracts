/// Strata DN-binary ladder construction + hedge ops — the on-chain
/// analogue of `sim/model/dn_ladder.py::size_ladder` (lines 103-180)
/// and `sim/eval/strategy.py::run_strategy_s4` (the ladder-orchestrated
/// hedge open path).
///
/// Algorithm provenance (anti-cherry-pick discipline locked):
///   * Strike spacing: uniform-in-bps approximation of the sim's
///     uniform-in-log-moneyness over the band
///     `[m_lo_bps, m_hi_bps] = [9595, 9811]` bps of forward. See
///     `sim/model/dn_ladder.py:147-150`. The on-chain approximation
///     is sub-1% off the log-uniform target across the narrow 2.2%
///     band — acceptable for hackathon-scope (Move lacks float / log
///     primitives in stdlib; bps-linear is the principled discrete
///     analogue).
///   * Per-strike sleeve allocation: uniform across the ladder
///     (`budget_per_strike = sleeve_budget / M`). Mirrors
///     `sim/model/dn_ladder.py:167-170` ("Uniform-notional is the
///     simplest defensible default").
///   * Default M = 5; governance-bounded M ∈ [1, 7] (mirrors
///     `gov.move` at M5 — until then, ladder.move enforces the bound
///     directly). M = 1 collapses to the S1 single-strike sim
///     baseline (regression compat).
///   * Band defaults pinned to `sim/model/dn_ladder.py:50-51` — the
///     PLP p0.1 / p1 loss-onset diagnostic (`DEFAULT_MONEYNESS_LO =
///     1 - 0.0405 = 0.9595`, `DEFAULT_MONEYNESS_HI = 1 - 0.0189 =
///     0.9811`). PINNED BEFORE SORTINO was computed in sim S0.
///     Anti-cherry-pick by construction. Hardcoded here in M3; M5
///     gov.move surfaces them as admin-writable with bounds.
///
/// Pattern A architecture per `docs/move_appendix_protocol.md §8`:
/// the Strata vault owns ONE `PredictManager`; hedge ops are
/// admin-only entries; R3 redeem permissionless stays public (M4).
///
/// DeepBook Predict mechanic citations (branch
/// `predict-testnet-4-16`):
///   * `sources/predict.move::create_manager` lines 192-195 — share
///     a new `PredictManager`, returns its `ID`.
///   * `sources/predict.move::mint<Quote>` lines 219-262 — buy a
///     directional binary; asserts `ctx.sender() == manager.owner()`
///     and post-mint `total_exposure ≤ max_total_exposure_pct`.
///   * `sources/market_key/market_key.move::down(oracle_id, expiry,
///     strike)` line 35 — DN-direction MarketKey builder.
///
/// Diction discipline (CLAUDE.md §8 rule B): "tail truncation",
/// "quantified residual", "left-tail reduction". Banned: "capped",
/// "loss-proof", "can't lose".
module strata_vault::ladder;

use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;

use deepbook_predict::predict::{Self, Predict};
use deepbook_predict::predict_manager::{Self, PredictManager};
use deepbook_predict::market_key;
use deepbook_predict::oracle::{Self, OracleSVI};

use strata_vault::vault::{Self, Vault};

// ---- Errors ------------------------------------------------------------

const ELadderSizeOutOfBounds: u64 = 200;
const EManagerAlreadyInitialised: u64 = 201;
const EManagerNotInitialised: u64 = 202;
const EManagerMismatch: u64 = 203;
const EZeroBudget: u64 = 204;
const EBandInvalid: u64 = 205;
/// Caller-supplied `strikes` vector is not strictly ascending (#41 fix).
const EStrikesNotIncreasing: u64 = 206;
/// A caller-supplied strike falls outside the provenance band
/// `[mul_div(forward, m_lo_bps, 10000), mul_div(forward, m_hi_bps, 10000)]`
/// (#41 fix).
const EStrikesOutOfBand: u64 = 207;

// ---- Constants — anchored to sim, NOT outcome-tuned --------------------

/// Lower bound (deeper OTM-DN side): `1 + p_PLP_0.1 = 1 - 0.0405`.
/// Source: `sim/model/dn_ladder.py:50` (post-S0 diagnostic, pinned
/// BEFORE Sortino computation).
const DEFAULT_M_LO_BPS: u64 = 9595;
/// Upper bound (shallower OTM-DN side): `1 + p_PLP_1 = 1 - 0.0189`.
/// Source: `sim/model/dn_ladder.py:51`.
const DEFAULT_M_HI_BPS: u64 = 9811;

/// Default ladder size, mirrors `sim/model/dn_ladder.py:52`
/// (`DEFAULT_LADDER_SIZE = 5`). Governance bound M ∈ [1, 7].
const DEFAULT_LADDER_SIZE: u64 = 5;
const MIN_LADDER_SIZE: u64 = 1;
const MAX_LADDER_SIZE: u64 = 7;

// ---- Events ------------------------------------------------------------

public struct PredictManagerLinked has copy, drop, store {
    vault_id: ID,
    manager_id: ID,
    admin: address,
}

public struct ManagerFunded has copy, drop, store {
    vault_id: ID,
    manager_id: ID,
    amount: u64,
    new_dusdc_in_manager: u64,
}

public struct LadderLegOpened has copy, drop, store {
    vault_id: ID,
    manager_id: ID,
    oracle_id: ID,
    expiry: u64,
    strike: u64,
    leg_index: u64,
    quantity: u64,
}

public struct LadderOpened has copy, drop, store {
    vault_id: ID,
    manager_id: ID,
    oracle_id: ID,
    expiry: u64,
    ladder_size: u64,
    m_lo_bps: u64,
    m_hi_bps: u64,
    forward: u64,
    sleeve_budget: u64,
    legs_minted: u64,
}

// ---- Predict manager bootstrap (one-time admin entry) -----------------

/// Admin-only: creates a fresh `PredictManager` (owner = admin) and
/// records its `ID` in the Strata `Vault`. Must run AFTER the vault
/// `init` and BEFORE any hedge-open call. Pattern A: ONE manager per
/// vault, lifetime-shared.
public fun init_predict_manager(
    self: &mut Vault,
    ctx: &mut TxContext,
) {
    vault::assert_admin(self, ctx);
    assert!(!vault::has_predict_manager(self), EManagerAlreadyInitialised);
    let manager_id = predict::create_manager(ctx);
    vault::set_predict_manager_id(self, manager_id);
    event::emit(PredictManagerLinked {
        vault_id: object::id(self),
        manager_id,
        admin: vault::admin(self),
    });
}

/// Admin-only: deposit dUSDC into the Strata-owned `PredictManager`
/// (the hedge-side bank). Strata-side tracker `dusdc_in_manager`
/// bumps by the deposited amount. The provided `manager` reference
/// MUST be the one whose `ID` is recorded in `self.predict_manager_id`
/// — checked here.
///
/// Mirrors sim's `state.hedge_sleeve` capital flow when
/// `run_strategy_s4` opens a hedge sleeve before the per-cycle
/// ladder build (`sim/eval/strategy.py:404-450`-ish).
public fun fund_manager<Quote>(
    self: &mut Vault,
    manager: &mut PredictManager,
    dusdc_in: Coin<Quote>,
    ctx: &mut TxContext,
) {
    vault::assert_admin(self, ctx);
    assert!(vault::has_predict_manager(self), EManagerNotInitialised);
    let recorded = *option::borrow(vault::predict_manager_id(self));
    assert!(object::id(manager) == recorded, EManagerMismatch);
    let amount = coin::value(&dusdc_in);
    assert!(amount > 0, EZeroBudget);
    predict_manager::deposit<Quote>(manager, dusdc_in, ctx);
    vault::bump_dusdc_in_manager(self, amount);
    event::emit(ManagerFunded {
        vault_id: object::id(self),
        manager_id: recorded,
        amount,
        new_dusdc_in_manager: vault::dusdc_in_manager(self),
    });
}

// ---- Pure helpers (no side effects; auditor-checkable) -----------------

/// Compute the M strike prices uniform-in-bps across the band
/// `[m_lo_bps, m_hi_bps]` of forward, expressed in the forward's
/// integer base units.
///
/// SCALE (Bug-2 fix, #41): the live BTC oracle uses a **1e9-per-USD**
/// scale, NOT the 1e6-per-USD this comment previously assumed. So
/// `$100,000 = 100_000_000_000_000` (1e14) and the grid floor
/// `min_strike = 50_000_000_000_000` (5e13 = $50,000), tick
/// `1_000_000_000` (1e9). `forward` MUST be read from
/// `oracle::forward_price()` in those native units.
///
/// NOTE (#41): this helper is now a REFERENCE only. `open_hedge_ladder`
/// no longer calls it — the raw `forward * m_k_bps / 10000` output is
/// NOT tick-aligned to the Predict grid (`strike % 1e9 == 0`) and so
/// reverts inside `predict::mint::assert_valid_strike`. The aligned
/// strikes are computed off-chain (`scripts/compute_aligned_strikes.py`)
/// and passed in as a pre-snapped `strikes` vector. This helper is kept
/// for provenance + M6 spacing tests.
///
/// On-chain APPROXIMATION of the sim's uniform-in-log-moneyness
/// (`np.linspace(np.log(m_lo), np.log(m_hi), M)`). For the narrow
/// 2.2% loss-onset band, the difference is sub-1% per strike —
/// acceptable hackathon-scope tradeoff. (Move stdlib lacks log /
/// exp; bps-linear is the principled discrete analogue.)
///
/// M = 1 emits the band midpoint (mirrors sim's
/// `n_strikes == 1` branch in `dn_ladder.py:145-147`).
public fun compute_strikes(
    forward: u64,
    m_lo_bps: u64,
    m_hi_bps: u64,
    n: u64,
): vector<u64> {
    assert!(n >= MIN_LADDER_SIZE && n <= MAX_LADDER_SIZE, ELadderSizeOutOfBounds);
    assert!(m_lo_bps > 0 && m_lo_bps <= m_hi_bps && m_hi_bps < 10000, EBandInvalid);
    let mut out: vector<u64> = vector[];
    if (n == 1) {
        // Midpoint — matches sim `dn_ladder.py:145-147`.
        let mid_bps = (m_lo_bps + m_hi_bps) / 2;
        vector::push_back(&mut out, mul_div(forward, mid_bps, 10000));
        return out
    };
    // n >= 2: linear interpolation across the band.
    // m_k_bps = m_lo_bps + (m_hi_bps - m_lo_bps) * k / (n - 1)
    let span = m_hi_bps - m_lo_bps;
    let mut k: u64 = 0;
    while (k < n) {
        let m_k_bps = m_lo_bps + (span * k) / (n - 1);
        let strike = mul_div(forward, m_k_bps, 10000);
        vector::push_back(&mut out, strike);
        k = k + 1;
    };
    out
}

/// Validate a caller-supplied, pre-aligned `strikes` vector (#41 fix).
/// Returns the ladder size `n`. Pure (no chain state) — auditor- and
/// unit-test-checkable. Aborts with:
///   * `EBandInvalid` if the provenance band is malformed,
///   * `ELadderSizeOutOfBounds` if `n` is outside `[MIN, MAX]`,
///   * `EStrikesOutOfBand` if any strike is outside the band
///     `[mul_div(forward, m_lo_bps, 10000), mul_div(forward, m_hi_bps, 10000)]`,
///   * `EStrikesNotIncreasing` if the vector is not strictly ascending.
///
/// NOTE: this does NOT verify grid-tick alignment (`strike % tick == 0`)
/// — that is owned by Predict's `mint` (`grid_params` is module-private
/// there). The off-chain snapper guarantees alignment; `mint` is the
/// backstop.
public fun validate_strikes(
    forward: u64,
    m_lo_bps: u64,
    m_hi_bps: u64,
    strikes: &vector<u64>,
): u64 {
    assert!(m_lo_bps > 0 && m_lo_bps <= m_hi_bps && m_hi_bps < 10000, EBandInvalid);
    let n = vector::length(strikes);
    assert!(n >= MIN_LADDER_SIZE && n <= MAX_LADDER_SIZE, ELadderSizeOutOfBounds);
    let band_lo = mul_div(forward, m_lo_bps, 10000);
    let band_hi = mul_div(forward, m_hi_bps, 10000);
    let mut v: u64 = 0;
    while (v < n) {
        let s = *vector::borrow(strikes, v);
        assert!(s >= band_lo && s <= band_hi, EStrikesOutOfBand);
        if (v + 1 < n) {
            let s_next = *vector::borrow(strikes, v + 1);
            assert!(s < s_next, EStrikesNotIncreasing);
        };
        v = v + 1;
    };
    n
}

/// Per-leg sleeve allocation: `budget_per_strike = sleeve_budget / n`.
/// Mirrors `sim/model/dn_ladder.py:167-170` ("Uniform sleeve
/// allocation across the ladder"). Returns the per-leg integer
/// budget; remainder dust (< n) stays unallocated.
public fun compute_per_leg_budget(sleeve_budget: u64, n: u64): u64 {
    assert!(n >= MIN_LADDER_SIZE && n <= MAX_LADDER_SIZE, ELadderSizeOutOfBounds);
    sleeve_budget / n
}

/// `(a * b) / c` with u128 overflow guard.
fun mul_div(a: u64, b: u64, c: u64): u64 {
    let prod = (a as u128) * (b as u128);
    let q = prod / (c as u128);
    q as u64
}

/// Default ladder-config getters — surfaced for the frontend "safe
/// deposit size" calculator AND for assertions in M6 tests.
public fun default_m_lo_bps(): u64 { DEFAULT_M_LO_BPS }
public fun default_m_hi_bps(): u64 { DEFAULT_M_HI_BPS }
public fun default_ladder_size(): u64 { DEFAULT_LADDER_SIZE }
public fun min_ladder_size(): u64 { MIN_LADDER_SIZE }
public fun max_ladder_size(): u64 { MAX_LADDER_SIZE }

// ---- Hedge-open orchestration -----------------------------------------

/// Admin-only: open a DN-binary ladder against `oracle` + `expiry`
/// from a caller-supplied, pre-aligned `strikes` vector. Each leg
/// pulls its premium (= per-leg quantity × per-contract ask) from the
/// manager's balance via `predict::mint`. Strata-side
/// `total_max_payout` bumps by the aggregate notional (= Σ
/// leg_quantity). The S5R3.3 Bug B invariant — `(max_payout * 10000)
/// <= max_exposure_bps * balance_total` — is asserted post-mint via
/// `vault::assert_within_max_exposure(self)`.
///
/// #41 GRID-SNAP FIX: the previous version derived strikes on-chain via
/// `compute_strikes(forward, ...)`, emitting arbitrary
/// `mul_div(forward, m_k_bps, 10000)` values that are NOT multiples of
/// the live grid tick (`strike % 1e9 == 0`) — so `predict::mint`'s
/// internal `assert_valid_strike` reverted. We now take a
/// `strikes: vector<u64>` snapped off-chain to the grid
/// (`scripts/compute_aligned_strikes.py`), and verify on-chain that it
/// is strictly ascending (`EStrikesNotIncreasing`) and every strike
/// lies within the provenance band
/// `[mul_div(forward, m_lo_bps, 10000), mul_div(forward, m_hi_bps, 10000)]`
/// (`EStrikesOutOfBand`). `forward` / `m_lo_bps` / `m_hi_bps` remain as
/// provenance + band-sanity inputs only; `compute_strikes` is kept as a
/// reference helper but is no longer called here. The grid tick itself
/// is enforced by Predict's `mint` (it owns `grid_params`); we do not
/// re-implement `assert_valid_strike`.
///
/// SCALE (Bug-2 fix): `forward` is the BTC oracle's current price on the
/// live **1e9-per-USD** scale (read from `oracle::forward_price()`;
/// e.g. $100,000 = 100_000_000_000_000). NOT the 1e6-per-USD an earlier
/// comment assumed.
///
/// Per-leg quantity is the per-leg budget directly (1 contract = $1
/// max payout in Predict's notional convention — `quantity` IS the
/// notional in base units). Premium = quantity × ask, withdrawn from
/// the manager's deposited balance by `predict::mint` internally.
///
/// IMPORTANT: this entry function does NOT pre-quote the ask from
/// the oracle (Predict's `mint` quotes against the POST-trade state
/// internally; the price quoted to the user is the price actually
/// paid). The admin should monitor `dusdc_in_manager` and call
/// `fund_manager` if the manager balance is insufficient — `mint`
/// reverts with `EWithdrawExceedsAvailable` otherwise.
public fun open_hedge_ladder<Quote>(
    self: &mut Vault,
    predict_obj: &mut Predict,
    manager: &mut PredictManager,
    oracle_svi: &OracleSVI,
    expiry: u64,
    forward: u64,
    m_lo_bps: u64,
    m_hi_bps: u64,
    strikes: vector<u64>,
    per_leg_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    vault::assert_admin(self, ctx);
    assert!(vault::has_predict_manager(self), EManagerNotInitialised);
    let recorded = *option::borrow(vault::predict_manager_id(self));
    assert!(object::id(manager) == recorded, EManagerMismatch);
    assert!(per_leg_quantity > 0, EZeroBudget);

    // Validate the caller-supplied, pre-aligned strikes (#41): size in
    // bounds, strictly ascending, every strike inside the provenance band.
    let n = validate_strikes(forward, m_lo_bps, m_hi_bps, &strikes);

    let oracle_id = oracle::id(oracle_svi);

    let mut k: u64 = 0;
    while (k < n) {
        let strike_k = *vector::borrow(&strikes, k);
        let key = market_key::down(oracle_id, expiry, strike_k);
        // Predict::mint pulls from manager.balance internally; reverts
        // if the manager is under-funded OR if `strike_k` is not a valid
        // grid tick (its internal `assert_valid_strike` is the grid
        // backstop — we pre-snap off-chain so this passes). Strata-side
        // `total_max_payout` bumps by the quantity (the notional, 1:1).
        predict::mint<Quote>(
            predict_obj,
            manager,
            oracle_svi,
            key,
            per_leg_quantity,
            clock,
            ctx,
        );
        // Strata-side mirror: total_max_payout bumps by quantity
        // (1 contract = $1 max payout, base unit).
        vault::bump_max_payout(self, per_leg_quantity);
        event::emit(LadderLegOpened {
            vault_id: object::id(self),
            manager_id: recorded,
            oracle_id,
            expiry,
            strike: strike_k,
            leg_index: k,
            quantity: per_leg_quantity,
        });
        k = k + 1;
    };

    // S5R3.3 Bug B invariant assertion on-chain. Mirrors
    // `sim/eval/account.py::step_path` post-S5R3 fix.
    vault::assert_within_max_exposure(self);

    event::emit(LadderOpened {
        vault_id: object::id(self),
        manager_id: recorded,
        oracle_id,
        expiry,
        ladder_size: n,
        m_lo_bps,
        m_hi_bps,
        forward,
        sleeve_budget: per_leg_quantity * n,
        legs_minted: n,
    });
}
