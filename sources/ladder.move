/// Strata DN-binary ladder construction — the on-chain analogue of
/// the sim's S4.1 prefix-matched ladder algorithm
/// (`sim/model/dn_ladder.py::size_ladder`, lines 103-180).
///
/// Algorithm provenance (anti-cherry-pick discipline preserved from
/// sim):
///   * Strikes uniform in log-moneyness across
///     `[1 + p_PLP_0_1, 1 + p_PLP_1]` OTM-DN band — the empirical PLP
///     loss-onset diagnostic from `sim/model/dn_ladder.py:50-51`
///     (`DEFAULT_MONEYNESS_LO = 0.9595`, `DEFAULT_MONEYNESS_HI =
///     0.9811`). Pinned BEFORE any Sortino was computed in sim S0
///     diagnostic — anti-cherry-pick by construction.
///   * Per-strike notional: uniform across the ladder
///     (`notional_k = sleeve_budget / M / ask_k`). Cite
///     `sim/model/dn_ladder.py:167-170`.
///   * Default `M = 5`. Governance bounds `M ∈ [3, 7]` enforced in
///     `gov.move`. Backwards-compat path `M = 1` produces the S1
///     single-strike hedge (sim regression equivalence).
///
/// DeepBook Predict integration:
///   * One `predict::mint<DUSDC>` call per ladder leg, all chained in
///     a single PTB at M3 implementation. See appendix §3.3
///     `mint<Quote>` signature in `docs/move_appendix_protocol.md`.
///   * Each leg's `MarketKey` built via
///     `predict::market_key::down(oracle_id, expiry, strike)` (DN
///     direction). Appendix §5.
///
/// NO Sortino-tuning of ladder spacing in code (anti-cherry-pick
/// discipline locked through every phase — same as
/// `sim/model/dn_ladder.py:6-15` module docstring).
///
/// Diction discipline: "truncated tail" / "quantified residual" /
/// "left-tail reduction" only. Banned per CLAUDE.md §8 rule B.
module strata_vault::ladder;

// M1 SCAFFOLD STUB — concrete construct_ladder + open_hedge_ladder
// entries land at M3. M1 commit establishes the module shape only.
