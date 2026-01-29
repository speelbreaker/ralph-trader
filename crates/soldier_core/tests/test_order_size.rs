use soldier_core::execution::{
    DispatchRejectReason, OrderSize, OrderSizeError, map_order_size_to_deribit_amount,
};
use soldier_core::risk::RiskState;
use soldier_core::venue::InstrumentKind;

#[test]
fn test_order_size_option_perp_canonical_amount() {
    let index_price = 100_000.0;

    let option = OrderSize::new(InstrumentKind::Option, None, Some(0.3), None, index_price)
        .expect("valid option order size");
    assert_eq!(option.qty_coin, Some(0.3));
    assert_eq!(option.qty_usd, None);
    assert!((option.notional_usd - 30_000.0).abs() < 1e-9);

    let perp = OrderSize::new(
        InstrumentKind::Perpetual,
        None,
        None,
        Some(30_000.0),
        index_price,
    )
    .expect("valid perp order size");
    assert_eq!(perp.qty_usd, Some(30_000.0));
    assert_eq!(perp.qty_coin, None);
    assert!((perp.notional_usd - 30_000.0).abs() < 1e-9);
}

#[test]
fn rejects_contract_mismatch_in_dispatch_map() {
    let index_price = 100_000.0;
    let option = OrderSize::new(
        InstrumentKind::Option,
        Some(2),
        Some(0.3),
        None,
        index_price,
    )
    .expect("valid option order size");

    let err =
        map_order_size_to_deribit_amount(InstrumentKind::Option, &option, Some(0.1), index_price)
            .expect_err("mismatch should reject");

    assert_eq!(err.risk_state, RiskState::Degraded);
    assert_eq!(err.reason, DispatchRejectReason::ContractsAmountMismatch);
}

#[test]
fn test_order_size_rejects_missing_qty_coin() {
    let err =
        OrderSize::new(InstrumentKind::Option, None, None, None, 100.0).expect_err("missing qty");
    assert_eq!(err, OrderSizeError::MissingQtyCoin);
}

#[test]
fn test_order_size_rejects_both_qtys() {
    let err = OrderSize::new(
        InstrumentKind::Perpetual,
        None,
        Some(1.0),
        Some(2.0),
        100.0,
    )
    .expect_err("both qtys should reject");
    assert_eq!(err, OrderSizeError::BothQtyProvided);
}

#[test]
fn test_order_size_rejects_non_positive_qty() {
    let err = OrderSize::new(
        InstrumentKind::LinearFuture,
        None,
        Some(0.0),
        None,
        100.0,
    )
    .expect_err("zero qty should reject");
    assert_eq!(err, OrderSizeError::NonPositiveQty);
}

#[test]
fn test_contracts_amount_match_tolerance_rejects_mismatches_above_0_001() {
    let index_price = 1.0;
    let order_size = OrderSize::new(
        InstrumentKind::Option,
        Some(1000),
        Some(1002.0),
        None,
        index_price,
    )
    .expect("valid order size");

    let err = map_order_size_to_deribit_amount(
        InstrumentKind::Option,
        &order_size,
        Some(1.0),
        index_price,
    )
    .expect_err("mismatch beyond tolerance should reject");

    assert_eq!(err.reason, DispatchRejectReason::ContractsAmountMismatch);
}
