use soldier_core::execution::{
    DispatchRejectReason, OrderSize, contracts_amount_matches, map_order_size_to_deribit_amount,
};
use soldier_core::risk::RiskState;
use soldier_core::venue::InstrumentKind;

#[test]
fn test_order_size_option_linear_future_canonical_amount() {
    let index_price = 100_000.0;

    let option = OrderSize::new(InstrumentKind::Option, None, Some(0.3), None, index_price);
    assert_eq!(option.qty_coin, Some(0.3));
    assert_eq!(option.qty_usd, None);
    assert!((option.notional_usd - 30_000.0).abs() < 1e-9);

    let linear = OrderSize::new(
        InstrumentKind::LinearFuture,
        None,
        Some(1.2),
        None,
        index_price,
    );
    assert_eq!(linear.qty_coin, Some(1.2));
    assert_eq!(linear.qty_usd, None);
    assert!((linear.notional_usd - 120_000.0).abs() < 1e-9);
}

#[test]
fn test_order_size_perp_inverse_canonical_amount() {
    let index_price = 100_000.0;

    let perp = OrderSize::new(
        InstrumentKind::Perpetual,
        None,
        None,
        Some(30_000.0),
        index_price,
    );
    assert_eq!(perp.qty_usd, Some(30_000.0));
    assert_eq!(perp.qty_coin, None);
    assert!((perp.notional_usd - 30_000.0).abs() < 1e-9);

    let inverse = OrderSize::new(
        InstrumentKind::InverseFuture,
        None,
        None,
        Some(12_500.0),
        index_price,
    );
    assert_eq!(inverse.qty_usd, Some(12_500.0));
    assert_eq!(inverse.qty_coin, None);
    assert!((inverse.notional_usd - 12_500.0).abs() < 1e-9);
}

#[test]
fn test_atomic_qty_epsilon_tolerates_float_noise_but_rejects_mismatch() {
    let contracts = 100;
    let multiplier = 10.0;
    let expected = contracts as f64 * multiplier;

    let within_tolerance = expected * 1.0005;
    assert!(contracts_amount_matches(
        within_tolerance,
        contracts,
        multiplier
    ));

    let beyond_tolerance = expected * 1.002;
    assert!(!contracts_amount_matches(
        beyond_tolerance,
        contracts,
        multiplier
    ));
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
    );

    let err =
        map_order_size_to_deribit_amount(InstrumentKind::Option, &option, Some(0.1), index_price)
            .expect_err("mismatch should reject");

    assert_eq!(err.risk_state, RiskState::Degraded);
    assert_eq!(err.reason, DispatchRejectReason::UnitMismatch);
}
