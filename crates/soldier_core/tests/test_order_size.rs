use soldier_core::execution::{DispatchRejectReason, OrderSize, map_order_size_to_deribit_amount};
use soldier_core::risk::RiskState;
use soldier_core::venue::InstrumentKind;

#[test]
fn test_order_size_option_perp_canonical_amount() {
    let index_price = 100_000.0;

    let option = OrderSize::new(InstrumentKind::Option, None, Some(0.3), None, index_price);
    assert_eq!(option.qty_coin, Some(0.3));
    assert_eq!(option.qty_usd, None);
    assert!((option.notional_usd - 30_000.0).abs() < 1e-9);

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
