/// M3 unit tests — pure-helper ladder algorithms (no Predict state
/// needed). Integration tests for `open_hedge_ladder` against a
/// staged `Predict` + `OracleSVI` land at M6 via `TestScenario`.
///
/// Pins the S4.1 algorithm provenance — strikes uniform-in-bps
/// (on-chain approximation of sim's uniform-in-log-moneyness), per-leg
/// budget uniform across the ladder
/// (`sim/model/dn_ladder.py:167-170`).
#[test_only]
module strata_vault::test_ladder_helpers;

use strata_vault::ladder;

const FORWARD: u64 = 60_000_000_000;  // $60,000 at 6 decimals (matches dUSDC).

// #41: live BTC oracle scale is 1e9-per-USD. $100,000 = 1e14.
const FORWARD_1E9: u64 = 100_000_000_000_000;

// ---- compute_strikes: shape + monotonicity + bounds --------------------

#[test]
fun test_strikes_single_strike_is_band_midpoint() {
    // n=1 collapses to (m_lo + m_hi) / 2. Mirrors sim
    // `dn_ladder.py:145-147` single-strike branch.
    let strikes = ladder::compute_strikes(FORWARD, 9595, 9811, 1);
    assert!(vector::length(&strikes) == 1, 1);
    let mid = *vector::borrow(&strikes, 0);
    // Expected mid bps = (9595 + 9811) / 2 = 9703.
    // Expected strike  = 60_000_000_000 * 9703 / 10000 = 58_218_000_000.
    assert!(mid == 58_218_000_000, 2);
}

#[test]
fun test_strikes_default_5_strike_band() {
    // n=5 over [9595, 9811] in bps-linear. Spans 216 bps, step 54.
    // m_k_bps = 9595, 9649, 9703, 9757, 9811.
    let strikes = ladder::compute_strikes(FORWARD, 9595, 9811, 5);
    assert!(vector::length(&strikes) == 5, 1);
    // Strike[0] = 60_000_000_000 * 9595 / 10000 = 57_570_000_000.
    assert!(*vector::borrow(&strikes, 0) == 57_570_000_000, 2);
    // Strike[4] = 60_000_000_000 * 9811 / 10000 = 58_866_000_000.
    assert!(*vector::borrow(&strikes, 4) == 58_866_000_000, 3);
    // Monotonic increasing across the band.
    let mut k: u64 = 1;
    while (k < 5) {
        let prev = *vector::borrow(&strikes, k - 1);
        let cur = *vector::borrow(&strikes, k);
        assert!(cur > prev, 100 + k);
        k = k + 1;
    };
}

#[test]
fun test_strikes_3_leg_ladder_within_bounds() {
    let strikes = ladder::compute_strikes(FORWARD, 9595, 9811, 3);
    assert!(vector::length(&strikes) == 3, 1);
    // All strikes in [forward * 9595/10000, forward * 9811/10000].
    let lo_bound = FORWARD * 9595 / 10000;
    let hi_bound = FORWARD * 9811 / 10000;
    let mut k: u64 = 0;
    while (k < 3) {
        let s = *vector::borrow(&strikes, k);
        assert!(s >= lo_bound, 100 + k);
        assert!(s <= hi_bound, 200 + k);
        k = k + 1;
    };
}

#[test]
fun test_strikes_7_leg_ladder_max_size_boundary() {
    // M=7 is the gov upper bound (MAX_LADDER_SIZE). Must succeed.
    let strikes = ladder::compute_strikes(FORWARD, 9595, 9811, 7);
    assert!(vector::length(&strikes) == 7, 1);
}

#[test]
#[expected_failure(abort_code = 200, location = strata_vault::ladder)]
fun test_strikes_zero_size_rejected() {
    let _ = ladder::compute_strikes(FORWARD, 9595, 9811, 0);
}

#[test]
#[expected_failure(abort_code = 200, location = strata_vault::ladder)]
fun test_strikes_oversize_rejected() {
    // M=8 > MAX_LADDER_SIZE → ELadderSizeOutOfBounds.
    let _ = ladder::compute_strikes(FORWARD, 9595, 9811, 8);
}

#[test]
#[expected_failure(abort_code = 205, location = strata_vault::ladder)]
fun test_strikes_inverted_band_rejected() {
    // m_lo > m_hi is invalid.
    let _ = ladder::compute_strikes(FORWARD, 9811, 9595, 3);
}

// ---- validate_strikes: #41 grid-snap caller-supplied path --------------
// band @ FORWARD_1E9 = [95_950_000_000_000, 98_110_000_000_000].
// Sample legs are tick-aligned (multiples of 1e9) and strictly ascending.

#[test]
fun test_validate_strikes_accepts_valid_ladder() {
    let strikes = vector[
        96_000_000_000_000,
        96_500_000_000_000,
        97_000_000_000_000,
        97_500_000_000_000,
        98_000_000_000_000,
    ];
    let n = ladder::validate_strikes(FORWARD_1E9, 9595, 9811, &strikes);
    assert!(n == 5, 1);
}

#[test]
#[expected_failure(abort_code = 207, location = strata_vault::ladder)]
fun test_validate_strikes_rejects_below_band() {
    // First strike below band_lo (95_950_000_000_000) → EStrikesOutOfBand.
    let strikes = vector[
        95_000_000_000_000,
        96_500_000_000_000,
        97_000_000_000_000,
        97_500_000_000_000,
        98_000_000_000_000,
    ];
    let _ = ladder::validate_strikes(FORWARD_1E9, 9595, 9811, &strikes);
}

#[test]
#[expected_failure(abort_code = 207, location = strata_vault::ladder)]
fun test_validate_strikes_rejects_above_band() {
    // Last strike above band_hi (98_110_000_000_000) → EStrikesOutOfBand.
    let strikes = vector[
        96_000_000_000_000,
        96_500_000_000_000,
        97_000_000_000_000,
        97_500_000_000_000,
        99_000_000_000_000,
    ];
    let _ = ladder::validate_strikes(FORWARD_1E9, 9595, 9811, &strikes);
}

#[test]
#[expected_failure(abort_code = 206, location = strata_vault::ladder)]
fun test_validate_strikes_rejects_non_increasing() {
    // Equal adjacent strikes are not strictly ascending → EStrikesNotIncreasing.
    let strikes = vector[
        96_000_000_000_000,
        96_500_000_000_000,
        96_500_000_000_000,
        97_500_000_000_000,
        98_000_000_000_000,
    ];
    let _ = ladder::validate_strikes(FORWARD_1E9, 9595, 9811, &strikes);
}

#[test]
#[expected_failure(abort_code = 200, location = strata_vault::ladder)]
fun test_validate_strikes_rejects_empty() {
    let strikes = vector<u64>[];
    let _ = ladder::validate_strikes(FORWARD_1E9, 9595, 9811, &strikes);
}

#[test]
#[expected_failure(abort_code = 200, location = strata_vault::ladder)]
fun test_validate_strikes_rejects_oversize() {
    // 8 legs > MAX_LADDER_SIZE → ELadderSizeOutOfBounds.
    let strikes = vector[
        96_000_000_000_000,
        96_200_000_000_000,
        96_400_000_000_000,
        96_600_000_000_000,
        96_800_000_000_000,
        97_000_000_000_000,
        97_200_000_000_000,
        97_400_000_000_000,
    ];
    let _ = ladder::validate_strikes(FORWARD_1E9, 9595, 9811, &strikes);
}

#[test]
#[expected_failure(abort_code = 205, location = strata_vault::ladder)]
fun test_validate_strikes_rejects_inverted_band() {
    let strikes = vector[96_000_000_000_000, 97_000_000_000_000, 98_000_000_000_000];
    let _ = ladder::validate_strikes(FORWARD_1E9, 9811, 9595, &strikes);
}

// ---- compute_per_leg_budget --------------------------------------------

#[test]
fun test_per_leg_budget_uniform_5_legs() {
    // Mirrors `sim/model/dn_ladder.py:167-170` uniform allocation.
    let per_leg = ladder::compute_per_leg_budget(50_000_000, 5);
    assert!(per_leg == 10_000_000, 1);  // exact divisor
}

#[test]
fun test_per_leg_budget_remainder_drops_as_dust() {
    // 51_234_567 / 5 = 10_246_913 (rem 2 — dust drops, per sim semantics).
    let per_leg = ladder::compute_per_leg_budget(51_234_567, 5);
    assert!(per_leg == 10_246_913, 1);
}

// ---- default config getters --------------------------------------------

#[test]
fun test_defaults_match_sim_diagnostic() {
    // Sim S0 diagnostic constants pinned BEFORE Sortino computation:
    // `sim/model/dn_ladder.py:50-51` (loss-onset band).
    assert!(ladder::default_m_lo_bps() == 9595, 1);
    assert!(ladder::default_m_hi_bps() == 9811, 2);
    // `sim/model/dn_ladder.py:52` (default ladder size).
    assert!(ladder::default_ladder_size() == 5, 3);
    assert!(ladder::min_ladder_size() == 1, 4);
    assert!(ladder::max_ladder_size() == 7, 5);
}
