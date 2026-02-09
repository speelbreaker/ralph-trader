use soldier_core::execution::{
    DispatchMetrics, IntentClassification, OrderSize, RejectReason,
    map_order_size_to_deribit_amount, map_order_size_to_deribit_amount_with_metrics,
    reduce_only_from_intent_classification,
};
use soldier_core::risk::RiskState;
use soldier_core::venue::InstrumentKind;

#[test]
fn test_dispatch_amount_field_coin_vs_usd() {
    let index_price = 100_000.0;

    let option = OrderSize::new(InstrumentKind::Option, None, Some(0.3), None, index_price);
    assert_eq!(option.qty_coin, Some(0.3));
    assert_eq!(option.qty_usd, None);
    let option_amount =
        map_order_size_to_deribit_amount(InstrumentKind::Option, &option, Some(1.0), index_price)
            .unwrap();
    assert!((option_amount.amount - 0.3).abs() < 1e-9);
    assert_eq!(option_amount.derived_qty_coin, Some(0.3));

    let linear = OrderSize::new(
        InstrumentKind::LinearFuture,
        None,
        Some(1.2),
        None,
        index_price,
    );
    assert_eq!(linear.qty_coin, Some(1.2));
    assert_eq!(linear.qty_usd, None);
    let linear_amount = map_order_size_to_deribit_amount(
        InstrumentKind::LinearFuture,
        &linear,
        Some(1.0),
        index_price,
    )
    .unwrap();
    assert!((linear_amount.amount - 1.2).abs() < 1e-9);
    assert_eq!(linear_amount.derived_qty_coin, Some(1.2));

    let perp = OrderSize::new(
        InstrumentKind::Perpetual,
        None,
        None,
        Some(30_000.0),
        index_price,
    );
    assert_eq!(perp.qty_usd, Some(30_000.0));
    assert_eq!(perp.qty_coin, None);
    let perp_amount =
        map_order_size_to_deribit_amount(InstrumentKind::Perpetual, &perp, Some(10.0), index_price)
            .unwrap();
    assert!((perp_amount.amount - 30_000.0).abs() < 1e-9);
    assert_eq!(perp_amount.derived_qty_coin, Some(0.3));

    let inverse = OrderSize::new(
        InstrumentKind::InverseFuture,
        None,
        None,
        Some(12_500.0),
        index_price,
    );
    assert_eq!(inverse.qty_usd, Some(12_500.0));
    assert_eq!(inverse.qty_coin, None);
    let inverse_amount = map_order_size_to_deribit_amount(
        InstrumentKind::InverseFuture,
        &inverse,
        Some(10.0),
        index_price,
    )
    .unwrap();
    assert!((inverse_amount.amount - 12_500.0).abs() < 1e-9);
    assert_eq!(inverse_amount.derived_qty_coin, Some(0.125));
}

#[test]
fn test_dispatch_rejects_both_canonical_amounts() {
    let index_price = 100_000.0;
    let invalid = OrderSize {
        contracts: None,
        qty_coin: Some(0.1),
        qty_usd: Some(10_000.0),
        notional_usd: 10_000.0,
    };

    let err =
        map_order_size_to_deribit_amount(InstrumentKind::Option, &invalid, Some(1.0), index_price)
            .unwrap_err();
    assert_eq!(err.risk_state, RiskState::Degraded);
    assert_eq!(err.reason, RejectReason::UnitMismatch);
}

#[test]
fn test_dispatch_rejects_missing_canonical_amount() {
    let index_price = 100_000.0;
    let invalid = OrderSize {
        contracts: None,
        qty_coin: None,
        qty_usd: None,
        notional_usd: 0.0,
    };

    let err =
        map_order_size_to_deribit_amount(InstrumentKind::Option, &invalid, Some(1.0), index_price)
            .unwrap_err();
    assert_eq!(err.risk_state, RiskState::Degraded);
    assert_eq!(err.reason, RejectReason::UnitMismatch);
}

#[test]
fn test_dispatch_rejects_wrong_canonical_field_for_kind() {
    let index_price = 100_000.0;
    let option_wrong = OrderSize {
        contracts: None,
        qty_coin: None,
        qty_usd: Some(10_000.0),
        notional_usd: 10_000.0,
    };
    let err = map_order_size_to_deribit_amount(
        InstrumentKind::Option,
        &option_wrong,
        Some(1.0),
        index_price,
    )
    .unwrap_err();
    assert_eq!(err.risk_state, RiskState::Degraded);
    assert_eq!(err.reason, RejectReason::UnitMismatch);

    let perp_wrong = OrderSize {
        contracts: None,
        qty_coin: Some(0.2),
        qty_usd: None,
        notional_usd: 20_000.0,
    };
    let err = map_order_size_to_deribit_amount(
        InstrumentKind::Perpetual,
        &perp_wrong,
        Some(10.0),
        index_price,
    )
    .unwrap_err();
    assert_eq!(err.risk_state, RiskState::Degraded);
    assert_eq!(err.reason, RejectReason::UnitMismatch);
}

#[test]
fn test_reduce_only_flag_set_by_intent_classification() {
    assert_eq!(
        reduce_only_from_intent_classification(IntentClassification::Close),
        Some(true)
    );
    assert_eq!(
        reduce_only_from_intent_classification(IntentClassification::Hedge),
        Some(true)
    );
    assert_eq!(
        reduce_only_from_intent_classification(IntentClassification::Open),
        None
    );
    assert_eq!(
        reduce_only_from_intent_classification(IntentClassification::Cancel),
        None
    );
}

#[test]
fn derives_contracts_when_missing_in_order_size() {
    let index_price = 50_000.0;
    // Inverse Future: 1000 USD. Multiplier 10 USD.
    let inverse = OrderSize::new(
        InstrumentKind::InverseFuture,
        None, // contracts missing
        None,
        Some(1000.0),
        index_price,
    );
    let result = map_order_size_to_deribit_amount(
        InstrumentKind::InverseFuture,
        &inverse,
        Some(10.0),
        index_price,
    )
    .unwrap();

    assert_eq!(result.amount, 1000.0);
    assert_eq!(result.contracts, Some(100)); // 1000 / 10 = 100
}

#[test]
fn validates_contracts_if_present() {
    let index_price = 50_000.0;
    // Linear Future: 1.5 Coin. Multiplier 1.0. Contracts should be 1. (1.5 rounds to 2).
    // Wait, round() is to nearest integer.
    // If inputs are consistent:
    // If I say contracts=2, and coin=2.0, multiplier=1.0 -> OK.

    let valid = OrderSize::new(
        InstrumentKind::LinearFuture,
        Some(2),
        Some(2.0),
        None,
        index_price,
    );
    let result = map_order_size_to_deribit_amount(
        InstrumentKind::LinearFuture,
        &valid,
        Some(1.0),
        index_price,
    )
    .unwrap();
    assert_eq!(result.contracts, Some(2));

    // Mismatch
    let invalid = OrderSize::new(
        InstrumentKind::LinearFuture,
        Some(5),   // Claims 5 contracts
        Some(2.0), // But provides 2.0 coin (implies 2 contracts if mult=1)
        None,
        index_price,
    );
    let err = map_order_size_to_deribit_amount(
        InstrumentKind::LinearFuture,
        &invalid,
        Some(1.0),
        index_price,
    )
    .unwrap_err();
    assert_eq!(err.reason, RejectReason::UnitMismatch);
    assert_eq!(err.mismatch_delta, Some(3.0));
}

#[test]
fn reject_zero_index_price_for_usd_instruments() {
    let perp = OrderSize::new(
        InstrumentKind::Perpetual,
        None,
        None,
        Some(100.0),
        0.0, // Invalid
    );
    let err = map_order_size_to_deribit_amount(InstrumentKind::Perpetual, &perp, Some(10.0), 0.0)
        .unwrap_err();
    assert_eq!(err.reason, RejectReason::UnitMismatch); // "invalid_index_price" maps to UnitMismatch
}

#[test]
fn rejects_contract_mismatch_and_increments_counter() {
    let index_price = 100_000.0;
    let option = OrderSize::new(
        InstrumentKind::Option,
        Some(2),
        Some(0.3),
        None,
        index_price,
    );

    let metrics = DispatchMetrics::new();
    let before = metrics.unit_mismatch_total();
    let err = map_order_size_to_deribit_amount_with_metrics(
        &metrics,
        InstrumentKind::Option,
        &option,
        Some(0.1),
        index_price,
    )
    .expect_err("mismatch should reject");
    let after = metrics.unit_mismatch_total();

    assert_eq!(err.risk_state, RiskState::Degraded);
    assert_eq!(err.reason, RejectReason::UnitMismatch);
    let mismatch_delta = err.mismatch_delta.expect("mismatch delta missing");
    assert!((mismatch_delta - 0.1).abs() < 1e-9);
    assert_eq!(after, before + 1);
}
