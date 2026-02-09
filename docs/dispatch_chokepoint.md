# Dispatch Chokepoint (P1-A)

Chokepoint module: `soldier_core::execution::build_order_intent`
(`crates/soldier_core/src/execution/build_order_intent.rs`).

Dispatch function: `build_order_intent` (records dispatch attempt via
`record_dispatch_step(DispatchStep::DispatchAttempt)`).

Exchange client type (current proxy):
`soldier_core::execution::build_order_intent::DispatchStep`
(dispatch marker `DispatchStep::DispatchAttempt`). Until a concrete exchange
client exists, `DispatchStep::DispatchAttempt` is treated as the dispatch hook
and must appear only in this module and function.

Normative: "No other module may call the exchange client directly."
