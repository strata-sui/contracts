/// Strata governance — `AdminCap` + read/write parameter surface for
/// `f` (LP-share fraction recommendation), `max_exposure_bps`,
/// `ladder_size`, and the ladder loss-onset band.
///
/// The `f` parameter is exposed as an ON-CHAIN VIEW — the frontend
/// "safe deposit size" calculator reads it from protocol state, not
/// from a static README. The f*(w_crash) methodology stays actionable
/// on-chain because the current recommendation is queryable in real
/// time.
///
/// §3 self-reference disclosure (LOCKED per CLAUDE.md §3):
///
///   The §3 mathematics show that hedge protection scales with
///   strike-local `(u(k) − f)`, not the naive `(1 − f)`. As `f`
///   approaches `u(k)`, hedge protection degrades to zero regardless
///   of notional. The admin guardrail `f <= 0.20` upper bound at the
///   gov layer prevents an admin from "setting f to 1 and griefing
///   the hedge" — sim-discovered failure mode formalised as on-chain
///   invariant.
///
/// Sim provenance for default values (all data-anchored, NOT
/// outcome-tuned):
///   * `max_exposure_bps = 8000` (= 0.80). Defensive on Strata side;
///     Predict already enforces 80% in
///     `predict.move::mint:243`. See
///     `sim/eval/account.py::step_path` post-S5R3.3 fix.
///   * `ladder_size = 5`. Sim S4.1 default
///     (`sim/model/dn_ladder.py::DEFAULT_LADDER_SIZE`).
///   * `ladder_band_p0_1 = 9595, ladder_band_p1 = 9811` (bps of
///     forward, so 0.9595 / 0.9811). Sim S0 diagnostic:
///     `sim/model/dn_ladder.py:50-51` — pinned BEFORE any Sortino was
///     computed.
///   * `f` (LP-share recommendation): post-S5R3 sweep result.
///     `sim/data/s1_results/s5_gate_b.json::f_star_summary::f_star_low_weight`
///     = 0.05 across all crash-weight tail-aversions at the 10k+5,900
///     resolution. Default surfaces 500 bps (= 0.05) on-chain.
///
/// Diction discipline: "tail truncation" / "quantified residual" /
/// "left-tail reduction". Banned per CLAUDE.md §8 rule B.
module strata_vault::gov;

// M1 SCAFFOLD STUB — concrete AdminCap + GovConfig struct + parameter
// entry/view functions land at M5. M1 commit establishes the module
// shape only.
