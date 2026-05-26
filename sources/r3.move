/// Strata R3 — liquidity escape-hatch wrapper around
/// `deepbook_predict::predict::redeem_permissionless<DUSDC>`. THE
/// submission's R3 pillar empirical claim
/// (`sim/SUBMISSION.md §5`) depends on this entry function existing
/// on-chain.
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
/// DeepBook Predict mechanic citation (line numbers from branch
/// `predict-testnet-4-16`):
///   * `sources/predict.move::redeem_permissionless:309` — the
///     `oracle.is_settled()` gate (NOT just expiry — settlement = first
///     post-expiry price update).
///   * `sources/predict_manager.move::deposit_permissionless` —
///     bypasses owner check; THE structural reason this path realizes
///     cash even when standard `withdraw` is limiter-bound.
///
/// Architectural note (appendix §8 Pattern A — LOCKED):
///   * `redeem_permissionless` on the Predict side has NO owner check
///     (it is the public bypass by Predict design).
///   * The Strata wrapper exposes a public entry function so ANY
///     keeper can trigger settlement realisation — Strata admin not
///     required. This matches the appendix Pattern A intent: "R3
///     redeem permissionless tetap public (by Predict design)."
///
/// Diction discipline: "tail truncation" / "quantified residual" /
/// "left-tail reduction". Banned per CLAUDE.md §8 rule B.
module strata_vault::r3;

// M1 SCAFFOLD STUB — concrete redeem_permissionless<DUSDC> wrapper
// entry function lands at M4. M1 commit establishes the module shape
// only.
