/// Strata governance — admin write surface for the four
/// vault-resident parameters:
///   * `f_bps` (LP-share fraction recommendation; surfaced on-chain
///     for the frontend "safe deposit size" calculator)
///   * `max_exposure_bps` (defensive guard against Predict rotation)
///   * `recommended_ladder_size` (ladder size recommendation)
///   * `ladder_band_lo_bps` / `ladder_band_hi_bps` (PLP loss-onset
///     band)
///
/// All writes require the caller to be `vault.admin` (Pattern A
/// `docs/move_appendix_protocol.md §8` — single-admin model). The
/// `assert_admin` check lives in `vault.move`; this module is
/// purely the entry-function surface + per-write event emission.
///
/// AdminCap note (deviation from M5 brief — flagged for masterplanner):
/// the brief calls for a separate `AdminCap` capability object.
/// Pattern A's "single admin address" model in appendix §8 makes the
/// vault.admin address check equivalent in security and simpler in
/// surface area (no cap-transfer entry to maintain). Keeping the
/// address check avoids dual-admin state inconsistency. Admin
/// rotation, if needed, can be added as a `transfer_admin` entry in
/// a follow-up commit (out of scope at M5).
///
/// §3 self-reference disclosure (LOCKED — see CLAUDE.md §3):
///
///   The §3 mathematics show that hedge protection scales with the
///   strike-local `(u(k) − f)`, not the naive `(1 − f)`. As `f`
///   approaches `u(k)`, hedge protection degrades to zero regardless
///   of notional. The admin guardrail `f_bps <= MAX_F_BPS = 2000`
///   (= 0.20) at the gov layer prevents an admin from setting `f`
///   high enough to grief the hedge. This is the sim-discovered
///   failure mode formalised as an on-chain invariant.
///
/// Sim provenance for default values (all data-anchored, NOT
/// outcome-tuned — same anti-cherry-pick discipline as the sim S0
/// diagnostic):
///   * Defaults in `vault.move`:
///       f_bps                   = 500   (sim s5_gate_b.json
///                                          f_star_low_weight = 0.05)
///       max_exposure_bps        = 8000  (sim post-S5R3.3 + Predict
///                                          max_total_exposure_pct)
///       recommended_ladder_size = 5     (sim/model/dn_ladder.py:52)
///       ladder_band_lo_bps      = 9595  (sim/model/dn_ladder.py:50 -
///                                         PLP p0.1 loss-onset)
///       ladder_band_hi_bps      = 9811  (sim/model/dn_ladder.py:51 -
///                                         PLP p1   loss-onset)
///
/// Diction discipline (CLAUDE.md §8 rule B): "tail truncation",
/// "quantified residual", "left-tail reduction", "downside-truncated".
/// Banned: "capped", "loss-proof", "can't lose".
module strata_vault::gov;

use sui::event;

use strata_vault::vault::{Self, Vault};

// ---- Errors ------------------------------------------------------------

const EFOutOfBounds: u64 = 400;
const EMaxExposureOutOfBounds: u64 = 401;
const ELadderSizeOutOfBounds: u64 = 402;
const ELadderBandOutOfBounds: u64 = 403;

// ---- Bounds — anchored to sim, NOT outcome-tuned -----------------------

/// `f` upper bound at the gov layer. The §3 self-reference math shows
/// that hedge protection collapses as `f` approaches `u(k)`; under
/// the conservative trader-flow anchor `u(k) ≈ 0.20–0.30`. The
/// MAX_F_BPS = 2000 (= 0.20) bound prevents an admin from setting `f`
/// high enough to drive `(u(k) − f)` to zero — the on-chain mirror
/// of the sim-discovered failure mode. Source: CLAUDE.md §3.
const MAX_F_BPS: u64 = 2000;

/// `max_exposure_bps` lower bound — Predict's own `max_total_exposure_pct`
/// is 8000 bps; allowing Strata to set its own bound BELOW that is
/// fine (Strata's bound becomes the effective constraint). Lower
/// bound 5000 prevents an admin from setting it absurdly small and
/// griefing the ladder open. Upper bound 9000 prevents an admin
/// from setting it above Predict's bound — Strata MUST be defensive,
/// not permissive.
const MIN_MAX_EXPOSURE_BPS: u64 = 5000;
const MAX_MAX_EXPOSURE_BPS: u64 = 9000;

/// Recommended ladder size — gov layer bounds. The OPERATIONAL
/// recommendation lives in [3, 7]; `ladder::open_hedge_ladder`
/// still accepts [1, 7] for sim-S1 backwards-compat tests, but the
/// gov recommendation never goes below 3 (single-strike is
/// regression-only, not operational).
const MIN_RECOMMENDED_LADDER_SIZE: u64 = 3;
const MAX_RECOMMENDED_LADDER_SIZE: u64 = 7;

// ---- Events ------------------------------------------------------------

public struct FBpsUpdated has copy, drop, store {
    vault_id: ID,
    old_value: u64,
    new_value: u64,
}

public struct MaxExposureBpsUpdated has copy, drop, store {
    vault_id: ID,
    old_value: u64,
    new_value: u64,
}

public struct RecommendedLadderSizeUpdated has copy, drop, store {
    vault_id: ID,
    old_value: u64,
    new_value: u64,
}

public struct LadderBandUpdated has copy, drop, store {
    vault_id: ID,
    old_lo_bps: u64,
    new_lo_bps: u64,
    old_hi_bps: u64,
    new_hi_bps: u64,
}

// ---- Admin write entries ----------------------------------------------

/// Admin-only: update the `f_bps` LP-share recommendation surface.
/// Bounded at `MAX_F_BPS = 2000` (= 0.20) — the on-chain mirror of
/// CLAUDE.md §3 self-reference guardrail. Setting `f` higher would
/// re-introduce the `(u(k) − f)` degradation.
public fun set_f_bps(
    self: &mut Vault,
    new_f: u64,
    ctx: &TxContext,
) {
    vault::assert_admin(self, ctx);
    assert!(new_f <= MAX_F_BPS, EFOutOfBounds);
    let old = vault::f_bps(self);
    vault::set_f_bps(self, new_f);
    event::emit(FBpsUpdated {
        vault_id: object::id(self),
        old_value: old,
        new_value: new_f,
    });
}

/// Admin-only: update the `max_exposure_bps` defensive bound.
/// Bounded [5000, 9000].
public fun set_max_exposure_bps(
    self: &mut Vault,
    new_cap: u64,
    ctx: &TxContext,
) {
    vault::assert_admin(self, ctx);
    assert!(
        new_cap >= MIN_MAX_EXPOSURE_BPS && new_cap <= MAX_MAX_EXPOSURE_BPS,
        EMaxExposureOutOfBounds,
    );
    let old = vault::max_exposure_bps(self);
    vault::set_max_exposure_bps(self, new_cap);
    event::emit(MaxExposureBpsUpdated {
        vault_id: object::id(self),
        old_value: old,
        new_value: new_cap,
    });
}

/// Admin-only: update the operational ladder-size recommendation.
/// Bounded [3, 7]. The `ladder::open_hedge_ladder` entry still
/// accepts [1, 7] (sim-S1 single-strike backwards-compat) — this
/// gov setter is for the OPERATIONAL recommendation, not a hard floor.
public fun set_recommended_ladder_size(
    self: &mut Vault,
    new_size: u64,
    ctx: &TxContext,
) {
    vault::assert_admin(self, ctx);
    assert!(
        new_size >= MIN_RECOMMENDED_LADDER_SIZE
            && new_size <= MAX_RECOMMENDED_LADDER_SIZE,
        ELadderSizeOutOfBounds,
    );
    let old = vault::recommended_ladder_size(self);
    vault::set_recommended_ladder_size(self, new_size);
    event::emit(RecommendedLadderSizeUpdated {
        vault_id: object::id(self),
        old_value: old,
        new_value: new_size,
    });
}

/// Admin-only: update the ladder band `[lo_bps, hi_bps]`. Bound:
/// `0 < lo <= hi < 10000`. The defaults (`9595, 9811`) come from
/// the sim S0 diagnostic; re-pinning requires admin tx + emits
/// `LadderBandUpdated` (auditor trail).
public fun set_ladder_band(
    self: &mut Vault,
    new_lo_bps: u64,
    new_hi_bps: u64,
    ctx: &TxContext,
) {
    vault::assert_admin(self, ctx);
    assert!(
        new_lo_bps > 0 && new_lo_bps <= new_hi_bps && new_hi_bps < 10000,
        ELadderBandOutOfBounds,
    );
    let old_lo = vault::ladder_band_lo_bps(self);
    let old_hi = vault::ladder_band_hi_bps(self);
    vault::set_ladder_band(self, new_lo_bps, new_hi_bps);
    event::emit(LadderBandUpdated {
        vault_id: object::id(self),
        old_lo_bps: old_lo,
        new_lo_bps,
        old_hi_bps: old_hi,
        new_hi_bps,
    });
}

// ---- Public bound getters (auditor + test introspection) --------------

public fun max_f_bps(): u64 { MAX_F_BPS }
public fun min_max_exposure_bps(): u64 { MIN_MAX_EXPOSURE_BPS }
public fun max_max_exposure_bps(): u64 { MAX_MAX_EXPOSURE_BPS }
public fun min_recommended_ladder_size(): u64 { MIN_RECOMMENDED_LADDER_SIZE }
public fun max_recommended_ladder_size(): u64 { MAX_RECOMMENDED_LADDER_SIZE }
