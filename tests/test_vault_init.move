/// M2 unit tests — pure-helper invariants on a freshly-initialised
/// Strata vault. Full supply/redeem integration tests (requiring a
/// real `Predict` shared object + `Clock`) land at M6 via
/// `test_scenario::TestScenario`.
///
/// Pins the S5R3.2 + S5R3.3 sim invariants on an empty vault:
///   * share_price floors at 1.0 (= SHARE_PRICE_SCALE) on bootstrap
///     (`sim/model/plp.py::PLPVault::share_price` line 81-84,
///     `if self.shares_outstanding == 0.0: return 1.0`).
///   * available_for_withdraw == 0 when both balance and max_payout
///     are zero
///     (`sim/model/plp.py::PLPVault::available_for_withdraw` lines
///     86-94 — `max(0, balance - total_max_payout)`).
///   * within_max_exposure passes vacuously when no positions are open
///     (mirrors `sim/eval/account.py::step_path` pre-mint state).
///   * Defaults: max_exposure_bps = 8000, f_bps = 500 (per
///     `sim/data/s1_results/s5_gate_b.json::f_star_summary` — f* =
///     0.05 across all w_crash).
#[test_only]
module strata_vault::test_vault_init;

use sui::test_scenario;
use strata_vault::vault::{Self, Vault};

#[test]
fun test_init_publishes_vault_with_defaults() {
    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);
    {
        vault::init_for_testing(scenario.ctx());
    };

    scenario.next_tx(admin);
    {
        let v = scenario.take_shared<Vault>();
        // Defaults from `sim/data/s1_results/s5_gate_b.json::f_star_summary`
        // and CLAUDE.md §4 verified max_exposure mechanic.
        assert!(vault::f_bps(&v) == 500, 1);
        assert!(vault::max_exposure_bps(&v) == 8000, 2);
        assert!(vault::admin(&v) == admin, 3);
        // Empty vault state.
        assert!(vault::plp_value(&v) == 0, 4);
        assert!(vault::dusdc_held_value(&v) == 0, 5);
        assert!(vault::total_max_payout(&v) == 0, 6);
        assert!(vault::total_mtm(&v) == 0, 7);
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
fun test_share_price_bootstraps_at_one() {
    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);
    { vault::init_for_testing(scenario.ctx()); };
    scenario.next_tx(admin);
    {
        let v = scenario.take_shared<Vault>();
        // Mirrors `PLPVault::share_price` bootstrap at line 82-83:
        //   if self.shares_outstanding == 0.0: return 1.0
        // 1_000_000 micro = 1.0 in fixed-point.
        assert!(vault::share_price_micro(&v) == 1_000_000, 1);
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
fun test_available_for_withdraw_zero_on_empty_vault() {
    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);
    { vault::init_for_testing(scenario.ctx()); };
    scenario.next_tx(admin);
    {
        let v = scenario.take_shared<Vault>();
        // Empty vault: balance=0, max_payout=0 ⇒ available=0
        // (`max(0, balance - max_payout) = max(0, 0 - 0) = 0`).
        assert!(vault::available_for_withdraw(&v) == 0, 1);
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
fun test_within_max_exposure_passes_on_empty_vault() {
    let admin = @0xAD;
    let mut scenario = test_scenario::begin(admin);
    { vault::init_for_testing(scenario.ctx()); };
    scenario.next_tx(admin);
    {
        let v = scenario.take_shared<Vault>();
        // 0 max_payout * 10000 <= 8000 * 0 balance ⇒ 0 <= 0 ⇒ true.
        // Vacuous pass; the real assertion bites at M3 when ladder
        // open bumps max_payout against a nonzero balance.
        assert!(vault::within_max_exposure(&v), 1);
        vault::assert_within_max_exposure(&v);  // does not revert
        test_scenario::return_shared(v);
    };
    scenario.end();
}
