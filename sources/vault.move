/// Strata vault — the LP-side state machine.
///
/// Pattern A architecture (per `docs/move_appendix_protocol.md §8`):
/// a single shared `Vault` object owned by the Strata admin holds:
///   * the underlying `Balance<PLP>` (LP shares from Predict),
///   * Strata-side share accounting (StrataShareSupply),
///   * a `PredictManager` ID (recorded at init; used by ladder.move at
///     M3 for hedge mint),
///   * governance parameters (defaulted at M2; admin-writable via M5).
///
/// Sim invariants enforced on-chain (cited inline below):
///   * S5R3.2 Bug A fix — share_price floored at 0 (depositor's loss
///     bounded by deposit). See
///     `sim/model/plp.py::PLPVault::share_price` lines 80-84
///     (post-fix: `max(0.0, nav / shares_outstanding)`).
///   * S5R3.3 Bug B fix — total_max_payout <= max_exposure * balance.
///     See `sim/eval/account.py::step_path` post-S5R3 (M3 ladder will
///     enforce this directly on Strata-side hedge mints).
///   * NAV-proportional share minting. See
///     `sim/model/plp.py::PLPVault::supply` lines 98-116.
///
/// DeepBook Predict mechanic citations (branch
/// `predict-testnet-4-16`):
///   * `sources/predict.move::supply` lines 437-470 — NAV-proportional
///     PLP share minting.
///   * `sources/predict.move::withdraw` lines 474-498 — limiter
///     `available = max(balance - total_max_payout, 0)`. This is the
///     PATH that goes to zero in the R3 verification scenario; the
///     bypass is implemented at `r3.move` (M4).
///
/// Diction discipline (CLAUDE.md §8 rule B): "truncated tail",
/// "quantified residual", "downside-truncated". Banned: "capped",
/// "loss-proof", "can't lose".
#[allow(deprecated_usage)]
module strata_vault::vault;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;

use deepbook_predict::predict::{Self, Predict};
use deepbook_predict::plp::PLP;

// ---- Constants ----------------------------------------------------------

/// Strata error codes — start at 100 per appendix §7 (avoid collision
/// with Predict's `EZeroAmount=4`, `EWithdrawExceedsAvailable=2`, etc).
const EZeroAmount: u64 = 100;
const EZeroShares: u64 = 101;
const EMaxExposureViolated: u64 = 102;
const ENotAdmin: u64 = 104;

/// `share_price` is reported in `SHARE_PRICE_SCALE` fixed-point so it
/// fits cleanly in u64 readouts (e.g., for the frontend "safe deposit
/// size" calculator). 1.0 = 1_000_000 (6 decimals — same as DeepBook
/// Predict's `quote_scaling` per CLAUDE.md §4 verified mechanics).
const SHARE_PRICE_SCALE: u64 = 1_000_000;

/// Default `max_exposure_bps`. Mirrors `sim` defaults and Predict's
/// own `MAX_TOTAL_EXPOSURE_PCT` from
/// `predict.move::mint` line 243 — 80% of balance.
const DEFAULT_MAX_EXPOSURE_BPS: u64 = 8000;

/// Default `f` (LP-share fraction recommendation) surfaced on-chain
/// for the frontend calculator. Post-S5R3 sweep result:
/// `f_star_low_weight = 0.05` across all crash-weight tail-aversions
/// at the 10k+5,900 sample resolution; surfaced as 500 bps.
/// Source: `sim/data/s1_results/s5_gate_b.json::f_star_summary`.
const DEFAULT_F_BPS: u64 = 500;

// ---- Strata share token (witness pattern) -------------------------------

/// One-time witness for the Strata vault share `Coin<VAULT>`.
/// 1 share = pro-rata claim on Strata vault's `Balance<PLP>` + any
/// Strata-side hedge realisation.
public struct VAULT has drop {}

// ---- Vault state --------------------------------------------------------

/// Strata vault — Pattern A single shared object.
public struct Vault has key {
    id: UID,
    /// Strata admin address. Writes to gov params (M5) + hedge open
    /// (M3) gated by this. R3 path is permissionless (M4 — by Predict
    /// design).
    admin: address,
    /// `Balance<PLP>` held on behalf of all Strata depositors. Strata
    /// LP-share value is pro-rata against this balance + the
    /// `dusdc_held` reserve below.
    plp_held: Balance<PLP>,
    /// dUSDC the vault holds OUTSIDE Predict's PLP pool — i.e. the
    /// reserve sleeve + unspent hedge sleeve. M2 lands the reserve
    /// pathway; M3 ladder consumes from this for premium payment.
    dusdc_held_value: u64,
    /// Treasury cap for the Strata share token. Mints on supply, burns
    /// on redeem. NAV-proportional.
    share_treasury: TreasuryCap<VAULT>,
    /// Strata-side mirror of total_max_payout. Bumped by `ladder.move`
    /// when a ladder leg opens; cleared on settlement. M2 keeps this
    /// at 0; M3 wires the increment path.
    total_max_payout: u64,
    /// Strata-side mirror of total_mtm. Same wiring pattern as
    /// `total_max_payout`. At M2 stays 0; M3 wires increments.
    total_mtm: u64,
    /// Recommendation surface for `f` in basis points. Default 500 (=
    /// 0.05) per the S5R3 final sweep result. Admin-writable via M5
    /// `gov.move::set_f`; bounded at 2000 bps (= 0.20) — anti-rug.
    f_bps: u64,
    /// Per the protocol's verified `max_total_exposure_pct` (= 8000
    /// bps = 0.80). Strata enforces this on its OWN side as a
    /// defensive guard against Predict's value rotating up; see
    /// `sim/eval/account.py` post-S5R3.3 fix.
    max_exposure_bps: u64,
}

// ---- Events -------------------------------------------------------------

public struct VaultInitialised has copy, drop, store {
    vault_id: ID,
    admin: address,
    f_bps: u64,
    max_exposure_bps: u64,
}

public struct Supply has copy, drop, store {
    vault_id: ID,
    actor: address,
    dusdc_amount: u64,
    plp_minted: u64,
    strata_shares_minted: u64,
    share_price_micro: u64,
}

public struct Redeem has copy, drop, store {
    vault_id: ID,
    actor: address,
    strata_shares_burned: u64,
    plp_burned: u64,
    dusdc_paid_out: u64,
    share_price_micro: u64,
}

// ---- Init / share-price ------------------------------------------------

/// One-time init: publishes the Strata share token treasury and shares
/// a `Vault` object owned by the publisher (= the Strata admin
/// keypair for the testnet deploy).
fun init(otw: VAULT, ctx: &mut TxContext) {
    let (treasury, metadata) = coin::create_currency<VAULT>(
        otw,
        6,                              // decimals — match dUSDC
        b"sSTRATA",                     // symbol
        b"Strata Vault Share",          // name
        b"LP claim on the Strata tail-truncated PLP vault on DeepBook Predict",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    let vault = Vault {
        id: object::new(ctx),
        admin: ctx.sender(),
        plp_held: balance::zero(),
        dusdc_held_value: 0,
        share_treasury: treasury,
        total_max_payout: 0,
        total_mtm: 0,
        f_bps: DEFAULT_F_BPS,
        max_exposure_bps: DEFAULT_MAX_EXPOSURE_BPS,
    };
    event::emit(VaultInitialised {
        vault_id: object::id(&vault),
        admin: vault.admin,
        f_bps: vault.f_bps,
        max_exposure_bps: vault.max_exposure_bps,
    });
    transfer::share_object(vault);
}

/// Strata-side share price in `SHARE_PRICE_SCALE` micro-units.
///
/// Floor at 0 (NOT at 1.0) is the S5R3.2 Bug A fix:
/// `sim/model/plp.py::PLPVault::share_price` lines 80-84.
/// A vault token is a CLAIM, never a liability — depositor's loss is
/// bounded by their deposit.
public fun share_price_micro(self: &Vault): u64 {
    let total_shares = coin::total_supply(&self.share_treasury);
    if (total_shares == 0) {
        // Bootstrap: 1:1 first deposit (mirrors sim's
        // `PLPVault::supply` lines 106-107).
        return SHARE_PRICE_SCALE
    };
    let plp_value = balance::value(&self.plp_held);
    let nav_raw = (plp_value + self.dusdc_held_value);
    // The floor: subtract MTM only up to the gross value, never below 0.
    // (Sim's `max(0.0, nav / shares_outstanding)` mapped to u64.)
    let nav = if (nav_raw > self.total_mtm) {
        nav_raw - self.total_mtm
    } else {
        0
    };
    mul_div(nav, SHARE_PRICE_SCALE, total_shares)
}

/// Strata-side `available_for_withdraw` mirror, per
/// `sim/model/plp.py::PLPVault::available_for_withdraw` lines 86-94.
/// Returned as USD-equivalent in dUSDC base units.
public fun available_for_withdraw(self: &Vault): u64 {
    let balance_total = balance::value(&self.plp_held) + self.dusdc_held_value;
    if (balance_total > self.total_max_payout) {
        balance_total - self.total_max_payout
    } else {
        0
    }
}

// ---- Supply / Redeem ---------------------------------------------------

/// User supplies dUSDC to the Strata vault and receives Strata shares.
///
/// Mirrors `sim/eval/account.py::AccountConfig` initialisation +
/// `PLPVault::supply` semantics. NAV-proportional minting; first
/// deposit is 1:1. Vault internally forwards the user's dUSDC to
/// Predict's PLP pool via `predict::supply<Quote>` (verified at
/// `sources/predict.move` lines 437-470).
public fun supply<Quote>(
    self: &mut Vault,
    predict: &mut Predict,
    dusdc_in: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<VAULT> {
    let amount = coin::value(&dusdc_in);
    assert!(amount > 0, EZeroAmount);

    let plp_value_before = balance::value(&self.plp_held);
    let plp_coin: Coin<PLP> = predict::supply<Quote>(predict, dusdc_in, clock, ctx);
    let plp_minted = coin::value(&plp_coin);
    balance::join(&mut self.plp_held, coin::into_balance(plp_coin));

    let total_strata_shares = coin::total_supply(&self.share_treasury);
    let strata_shares = if (total_strata_shares == 0) {
        // Bootstrap: mirror sim's `PLPVault::supply` line 107
        // (1:1 first deposit).
        plp_minted
    } else {
        // NAV-proportional: shares = plp_minted * total_strata_shares
        //                            / plp_value_before
        // matches sim's `PLPVault::supply` lines 109-113 with the
        // Strata-side denomination.
        let plp_pre_supply = plp_value_before;
        assert!(plp_pre_supply > 0, EZeroShares);
        mul_div(plp_minted, total_strata_shares, plp_pre_supply)
    };
    assert!(strata_shares > 0, EZeroShares);

    let out = coin::mint(&mut self.share_treasury, strata_shares, ctx);
    let sp = share_price_micro(self);

    event::emit(Supply {
        vault_id: object::id(self),
        actor: ctx.sender(),
        dusdc_amount: amount,
        plp_minted,
        strata_shares_minted: strata_shares,
        share_price_micro: sp,
    });
    out
}

/// User burns Strata shares and receives dUSDC back. Calls
/// `predict::withdraw<Quote>` under the hood, which enforces the
/// limiter `available = max(balance - total_max_payout, 0)` per
/// `sources/predict.move` lines 478-487. If the limiter binds on the
/// Predict side, this call reverts with Predict's
/// `EWithdrawExceedsAvailable` — Strata users must then either wait
/// or rely on the R3 path (`r3.move::redeem_permissionless`, M4)
/// for hedge cash that BYPASSES the limiter.
public fun redeem<Quote>(
    self: &mut Vault,
    predict: &mut Predict,
    shares_in: Coin<VAULT>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    let strata_shares = coin::value(&shares_in);
    assert!(strata_shares > 0, EZeroShares);

    let total_strata_shares = coin::total_supply(&self.share_treasury);
    let plp_value = balance::value(&self.plp_held);
    // Pro-rata PLP shares to burn for this user's claim.
    let plp_burn = mul_div(plp_value, strata_shares, total_strata_shares);
    assert!(plp_burn > 0, EZeroShares);

    // Burn Strata-side share first (effects-before-interactions).
    coin::burn(&mut self.share_treasury, shares_in);

    // Pull the user's pro-rata PLP from internal balance, then
    // forward into Predict::withdraw.
    let plp_to_withdraw = coin::from_balance(
        balance::split(&mut self.plp_held, plp_burn),
        ctx,
    );
    let dusdc_out: Coin<Quote> = predict::withdraw<Quote>(predict, plp_to_withdraw, clock, ctx);
    let dusdc_paid = coin::value(&dusdc_out);

    let sp = share_price_micro(self);

    event::emit(Redeem {
        vault_id: object::id(self),
        actor: ctx.sender(),
        strata_shares_burned: strata_shares,
        plp_burned: plp_burn,
        dusdc_paid_out: dusdc_paid,
        share_price_micro: sp,
    });
    dusdc_out
}

// ---- Invariant assertions (public — exercised by M6 tests) -------------

/// Returns true iff the Strata-side `total_max_payout` is within the
/// `max_exposure_bps` envelope of the vault's gross value. This is
/// the on-chain mirror of the S5R3.3 Bug B fix
/// (`sim/eval/account.py::step_path` post-S5R3 — cap on per-step
/// trader notional). M3 ladder open MUST assert this passes before
/// emitting the mint.
public fun within_max_exposure(self: &Vault): bool {
    let balance_total = balance::value(&self.plp_held) + self.dusdc_held_value;
    // total_max_payout <= max_exposure_bps/10000 * balance
    // ⇒ total_max_payout * 10000 <= max_exposure_bps * balance
    let lhs = (self.total_max_payout as u128) * 10000u128;
    let rhs = (self.max_exposure_bps as u128) * (balance_total as u128);
    lhs <= rhs
}

public fun assert_within_max_exposure(self: &Vault) {
    assert!(within_max_exposure(self), EMaxExposureViolated);
}

public fun admin(self: &Vault): address { self.admin }
public fun f_bps(self: &Vault): u64 { self.f_bps }
public fun max_exposure_bps(self: &Vault): u64 { self.max_exposure_bps }
public fun total_max_payout(self: &Vault): u64 { self.total_max_payout }
public fun total_mtm(self: &Vault): u64 { self.total_mtm }
public fun plp_value(self: &Vault): u64 { balance::value(&self.plp_held) }
public fun dusdc_held_value(self: &Vault): u64 { self.dusdc_held_value }

// ---- Package-private mutators (used by ladder.move M3, r3.move M4,
// ----                          gov.move M5)
public(package) fun bump_max_payout(self: &mut Vault, delta: u64) {
    self.total_max_payout = self.total_max_payout + delta;
}
public(package) fun reduce_max_payout(self: &mut Vault, delta: u64) {
    self.total_max_payout = if (self.total_max_payout > delta) {
        self.total_max_payout - delta
    } else { 0 };
}
public(package) fun bump_mtm(self: &mut Vault, delta: u64) {
    self.total_mtm = self.total_mtm + delta;
}
public(package) fun reduce_mtm(self: &mut Vault, delta: u64) {
    self.total_mtm = if (self.total_mtm > delta) { self.total_mtm - delta } else { 0 };
}
public(package) fun set_f_bps(self: &mut Vault, new_f: u64) {
    self.f_bps = new_f;
}
public(package) fun set_max_exposure_bps(self: &mut Vault, new_cap: u64) {
    self.max_exposure_bps = new_cap;
}
public(package) fun assert_admin(self: &Vault, ctx: &TxContext) {
    assert!(tx_context::sender(ctx) == self.admin, ENotAdmin);
}

// ---- Internal helpers --------------------------------------------------

/// `(a * b) / c` with overflow protection via u128 intermediate.
fun mul_div(a: u64, b: u64, c: u64): u64 {
    let prod = (a as u128) * (b as u128);
    let q = prod / (c as u128);
    q as u64
}

// ---- Test-only init for M6 tests ---------------------------------------
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(VAULT {}, ctx)
}
