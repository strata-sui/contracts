/// Strata vault — event types emitted by the vault, ladder, R3, and gov
/// modules. Centralised here so off-chain indexers (frontend, REPLAY.md
/// audit table) have a single event schema to consume.
///
/// Sim cross-references:
///   * Three pillars table in `sim/SUBMISSION.md §4` — Strata's claim
///     surface that these events make on-chain-observable.
///   * R3 verification scenario in
///     `sim/data/s1_results/s5_r3_verification.json` — the `liquid_cash_delta`
///     emitted by `R3LiquidityRealized` is the on-chain analogue of the
///     `$383,063` sim-side empirical figure.
///
/// Approved diction (CLAUDE.md §8 rule B): only "tail truncation",
/// "quantified residual", "downside-truncated", "left-tail reduction"
/// appear in event field names or doc comments. Banned: "capped",
/// "loss-proof", "can't lose".
module strata_vault::events;

// Empty stub at M1 — concrete event structs land alongside their
// emitter modules (M2: Supply/Redeem; M3: LadderOpened; M4:
// R3LiquidityRealized; M5: GovParamUpdated). Centralised module here
// reserves the namespace and gives auditors a single import path.
