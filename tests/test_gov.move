/// M5 unit tests — governance write entries.
///
/// Pins the on-chain mirror of the sim-discovered failure mode at
/// CLAUDE.md §3: setting `f` higher than the §3 self-reference
/// guardrail (MAX_F_BPS = 2000 = 0.20) MUST revert. This is the
/// "anti-rug" assertion the brief calls for at M5.
#[test_only]
module strata_vault::test_gov;

use sui::test_scenario;
use strata_vault::vault::{Self, Vault};
use strata_vault::gov;

const ADMIN: address = @0xAD;
const ATTACKER: address = @0xBAD;

// ---- happy-path admin updates -----------------------------------------

#[test]
fun test_admin_can_set_f_within_bounds() {
    let mut scenario = test_scenario::begin(ADMIN);
    { vault::init_for_testing(scenario.ctx()); };
    scenario.next_tx(ADMIN);
    {
        let mut v = scenario.take_shared<Vault>();
        // 0 -> 750 bps (= 0.075): admin can shift `f` to a different
        // value within the §3 guardrail [0, 2000].
        gov::set_f_bps(&mut v, 750, scenario.ctx());
        assert!(vault::f_bps(&v) == 750, 1);
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
fun test_admin_can_set_max_exposure_within_bounds() {
    let mut scenario = test_scenario::begin(ADMIN);
    { vault::init_for_testing(scenario.ctx()); };
    scenario.next_tx(ADMIN);
    {
        let mut v = scenario.take_shared<Vault>();
        // 8000 -> 7500 bps: defensive tightening allowed within [5000, 9000].
        gov::set_max_exposure_bps(&mut v, 7500, scenario.ctx());
        assert!(vault::max_exposure_bps(&v) == 7500, 1);
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
fun test_admin_can_set_recommended_ladder_size() {
    let mut scenario = test_scenario::begin(ADMIN);
    { vault::init_for_testing(scenario.ctx()); };
    scenario.next_tx(ADMIN);
    {
        let mut v = scenario.take_shared<Vault>();
        // 5 -> 7 (within [3, 7]).
        gov::set_recommended_ladder_size(&mut v, 7, scenario.ctx());
        assert!(vault::recommended_ladder_size(&v) == 7, 1);
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
fun test_admin_can_set_ladder_band() {
    let mut scenario = test_scenario::begin(ADMIN);
    { vault::init_for_testing(scenario.ctx()); };
    scenario.next_tx(ADMIN);
    {
        let mut v = scenario.take_shared<Vault>();
        // 9595/9811 -> 9700/9900 (still within `0 < lo <= hi < 10000`).
        gov::set_ladder_band(&mut v, 9700, 9900, scenario.ctx());
        assert!(vault::ladder_band_lo_bps(&v) == 9700, 1);
        assert!(vault::ladder_band_hi_bps(&v) == 9900, 2);
        test_scenario::return_shared(v);
    };
    scenario.end();
}

// ---- bound violations (§3 self-reference guardrail + sanity) ----------

#[test]
#[expected_failure(abort_code = 400, location = strata_vault::gov)]
fun test_set_f_above_anti_rug_bound_rejected() {
    // f = 2500 bps (0.25) > MAX_F_BPS = 2000 → EFOutOfBounds.
    // THE on-chain mirror of CLAUDE.md §3 anti-rug failure mode.
    let mut scenario = test_scenario::begin(ADMIN);
    { vault::init_for_testing(scenario.ctx()); };
    scenario.next_tx(ADMIN);
    {
        let mut v = scenario.take_shared<Vault>();
        gov::set_f_bps(&mut v, 2500, scenario.ctx());
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 401, location = strata_vault::gov)]
fun test_set_max_exposure_above_predict_bound_rejected() {
    // max_exposure_bps = 9500 > MAX_MAX_EXPOSURE_BPS = 9000.
    // Strata MUST be defensive, not permissive (Predict's bound is
    // 8000; Strata can match or tighten, NOT exceed).
    let mut scenario = test_scenario::begin(ADMIN);
    { vault::init_for_testing(scenario.ctx()); };
    scenario.next_tx(ADMIN);
    {
        let mut v = scenario.take_shared<Vault>();
        gov::set_max_exposure_bps(&mut v, 9500, scenario.ctx());
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 402, location = strata_vault::gov)]
fun test_set_recommended_ladder_size_below_3_rejected() {
    // size = 1: gov layer rejects (operational recommendation only;
    // ladder::open_hedge_ladder still accepts 1 for sim-S1 compat).
    let mut scenario = test_scenario::begin(ADMIN);
    { vault::init_for_testing(scenario.ctx()); };
    scenario.next_tx(ADMIN);
    {
        let mut v = scenario.take_shared<Vault>();
        gov::set_recommended_ladder_size(&mut v, 1, scenario.ctx());
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 403, location = strata_vault::gov)]
fun test_set_ladder_band_inverted_rejected() {
    // lo > hi → ELadderBandOutOfBounds.
    let mut scenario = test_scenario::begin(ADMIN);
    { vault::init_for_testing(scenario.ctx()); };
    scenario.next_tx(ADMIN);
    {
        let mut v = scenario.take_shared<Vault>();
        gov::set_ladder_band(&mut v, 9811, 9595, scenario.ctx());
        test_scenario::return_shared(v);
    };
    scenario.end();
}

// ---- admin-only enforcement -------------------------------------------

#[test]
#[expected_failure(abort_code = 104, location = strata_vault::vault)]
fun test_non_admin_set_f_rejected() {
    // ATTACKER calls set_f_bps → vault::assert_admin reverts with
    // ENotAdmin (104).
    let mut scenario = test_scenario::begin(ADMIN);
    { vault::init_for_testing(scenario.ctx()); };
    scenario.next_tx(ATTACKER);
    {
        let mut v = scenario.take_shared<Vault>();
        gov::set_f_bps(&mut v, 100, scenario.ctx());
        test_scenario::return_shared(v);
    };
    scenario.end();
}

// ---- gov-level bound constants exposed via getters --------------------

#[test]
fun test_bounds_constants_match_sim_anchors() {
    // MAX_F_BPS = 2000 (= 0.20, the §3 anti-rug bound).
    assert!(gov::max_f_bps() == 2000, 1);
    // max_exposure bounds [5000, 9000].
    assert!(gov::min_max_exposure_bps() == 5000, 2);
    assert!(gov::max_max_exposure_bps() == 9000, 3);
    // recommended_ladder_size bounds [3, 7].
    assert!(gov::min_recommended_ladder_size() == 3, 4);
    assert!(gov::max_recommended_ladder_size() == 7, 5);
}
