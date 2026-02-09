# Dispatch Chokepoint (P1-A)

Chokepoint module: `soldier_core::execution::build_order_intent`
(`crates/soldier_core/src/execution/build_order_intent.rs`).

Dispatch function: `build_order_intent` (records dispatch attempt via
`record_dispatch_step(DispatchStep::DispatchAttempt)`).

Exchange client type: not yet implemented in this repo. Current dispatch hook
is `soldier_core::execution::BuildOrderIntentObservers`, which records the
`DispatchStep::DispatchAttempt` marker inside the chokepoint. When a concrete
exchange client is introduced, it must be invoked only from this module and
function.

Normative: "No other module may call the exchange client directly."
