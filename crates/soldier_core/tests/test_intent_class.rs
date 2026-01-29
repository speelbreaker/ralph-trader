use soldier_core::execution::{IntentAction, IntentClass};
use soldier_core::risk::TradingMode;

#[test]
fn test_intent_class_fail_closed_on_unknown_action() {
    let class = IntentClass::from_action(IntentAction::Unknown, None);
    assert_eq!(class, IntentClass::Open);
}

#[test]
fn test_intent_class_reduce_only_maps_to_close() {
    let class = IntentClass::from_action(IntentAction::Place, Some(true));
    assert_eq!(class, IntentClass::Close);
}

#[test]
fn test_intent_class_cancel_stays_cancel() {
    let class = IntentClass::from_action(IntentAction::Cancel, Some(false));
    assert_eq!(class, IntentClass::Cancel);
}

#[test]
fn test_trading_mode_allows_open_only_in_active() {
    assert!(IntentClass::Open.allowed_in_mode(TradingMode::Active));
    assert!(!IntentClass::Open.allowed_in_mode(TradingMode::ReduceOnly));
    assert!(!IntentClass::Open.allowed_in_mode(TradingMode::Kill));
}

#[test]
fn test_trading_mode_allows_close_in_reduceonly() {
    assert!(IntentClass::Close.allowed_in_mode(TradingMode::ReduceOnly));
    assert!(!IntentClass::Close.allowed_in_mode(TradingMode::Kill));
}
