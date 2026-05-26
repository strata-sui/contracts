/// Strata vault — the LP-side state machine (supply / redeem / share-price
/// accounting). Mirrors the sim's `PLPVault` semantics
/// (`sim/model/plp.py`) under Pattern A architecture: a single shared
/// `Vault` object owned by the Strata admin holds a single
/// `deepbook_predict::predict_manager::PredictManager`, while LP shares
/// are per-user `Coin<PLP>` tokens.
///
/// Sim invariants this module enforces on-chain (cited inline at each
/// assertion in M2):
///   * S5R3.2 Bug A fix — share_price floored at 0 (depositor-bounded
///     loss). See `sim/model/plp.py::PLPVault::share_price`.
///   * S5R3.3 Bug B fix — total_max_payout <= max_exposure * balance,
///     defensive on the Strata side. See
///     `sim/eval/account.py::step_path` post-S5R3.
///   * NAV-proportional share minting. See
///     `sim/model/plp.py::PLPVault::supply`.
///
/// DeepBook Predict mechanic citations (line numbers from branch
/// `predict-testnet-4-16`, harvested in
/// `docs/move_appendix_protocol.md §12`):
///   * `sources/predict.move::supply:455-459` — NAV-proportional shares
///   * `sources/predict.move::withdraw:479-486` — limiter (THE source
///     of R3 motivation)
///
/// Diction discipline (CLAUDE.md §8 rule B): "truncated tail",
/// "quantified residual", "downside-truncated". Banned: "capped",
/// "loss-proof", "can't lose".
module strata_vault::vault;

// M1 SCAFFOLD STUB — concrete VaultState struct + supply/redeem entries
// land at M2. M1 commit establishes the module shape + dependency graph
// only.
