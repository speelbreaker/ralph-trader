use soldier_core::execution::{
    DispatchRejectReason, OrderSize, map_order_size_to_deribit_amount,
    order_intent_reject_unit_mismatch_total,
};
use soldier_core::risk::RiskState;
use soldier_core::venue::InstrumentKind;

#[test]
fn acceptance_option_and_perp_mapping() {
    let index_price = 100_000.0;

    let option = OrderSize::new(InstrumentKind::Option, None, Some(0.3), None, index_price);
    let option_amount =
        map_order_size_to_deribit_amount(InstrumentKind::Option, &option, None, index_price)
            .unwrap();
    assert!((option_amount.amount - 0.3).abs() < 1e-9);
    let option_qty_coin = option_amount.derived_qty_coin.expect("derived qty coin");
    assert!((option_qty_coin - 0.3).abs() < 1e-9);
    assert!((option.notional_usd - 30_000.0).abs() < 1e-9);

    let perp = OrderSize::new(
        InstrumentKind::Perpetual,
        None,
        None,
        Some(30_000.0),
        index_price,
    );
    let perp_amount =
        map_order_size_to_deribit_amount(InstrumentKind::Perpetual, &perp, None, index_price)
            .unwrap();
    assert!((perp_amount.amount - 30_000.0).abs() < 1e-9);
    let perp_qty_coin = perp_amount.derived_qty_coin.expect("derived qty coin");
    assert!((perp_qty_coin - 0.3).abs() < 1e-9);
    assert!((perp.notional_usd - 30_000.0).abs() < 1e-9);
}

#[test]
fn maps_coin_amount_for_option_and_linear_future() {
    let index_price = 100_000.0;

    let option = OrderSize::new(InstrumentKind::Option, None, Some(0.3), None, index_price);
    let option_amount =
        map_order_size_to_deribit_amount(InstrumentKind::Option, &option, None, index_price)
            .unwrap();
    assert!((option_amount.amount - 0.3).abs() < 1e-9);
    let option_qty_coin = option_amount.derived_qty_coin.expect("derived qty coin");
    assert!((option_qty_coin - 0.3).abs() < 1e-9);

    let linear = OrderSize::new(
        InstrumentKind::LinearFuture,
        None,
        Some(1.5),
        None,
        index_price,
    );
    let linear_amount =
        map_order_size_to_deribit_amount(InstrumentKind::LinearFuture, &linear, None, index_price)
            .unwrap();
    assert!((linear_amount.amount - 1.5).abs() < 1e-9);
    let linear_qty_coin = linear_amount.derived_qty_coin.expect("derived qty coin");
    assert!((linear_qty_coin - 1.5).abs() < 1e-9);
}

#[test]
fn maps_usd_amount_for_perp_and_inverse_future() {
    let index_price = 100_000.0;

    let perp = OrderSize::new(
        InstrumentKind::Perpetual,
        None,
        None,
        Some(30_000.0),
        index_price,
    );
    let perp_amount =
        map_order_size_to_deribit_amount(InstrumentKind::Perpetual, &perp, None, index_price)
            .unwrap();
    assert!((perp_amount.amount - 30_000.0).abs() < 1e-9);
    let perp_qty_coin = perp_amount.derived_qty_coin.expect("derived qty coin");
    assert!((perp_qty_coin - 0.3).abs() < 1e-9);

    let inverse = OrderSize::new(
        InstrumentKind::InverseFuture,
        None,
        None,
        Some(12_000.0),
        index_price,
    );
    let inverse_amount = map_order_size_to_deribit_amount(
        InstrumentKind::InverseFuture,
        &inverse,
        None,
        index_price,
    )
    .unwrap();
    assert!((inverse_amount.amount - 12_000.0).abs() < 1e-9);
    let inverse_qty_coin = inverse_amount.derived_qty_coin.expect("derived qty coin");
    assert!((inverse_qty_coin - 0.12).abs() < 1e-9);
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

    let before = order_intent_reject_unit_mismatch_total();
    let err =
        map_order_size_to_deribit_amount(InstrumentKind::Option, &option, Some(0.1), index_price)
            .expect_err("mismatch should reject");
    let after = order_intent_reject_unit_mismatch_total();

    assert_eq!(err.risk_state, RiskState::Degraded);
    assert_eq!(err.reason, DispatchRejectReason::UnitMismatch);
    assert_eq!(after, before + 1);
}
