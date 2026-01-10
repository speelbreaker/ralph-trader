use soldier_core::execution::{OrderSize, map_order_size_to_deribit_amount};
use soldier_core::venue::InstrumentKind;

#[test]
fn maps_coin_amount_for_option_and_linear_future() {
    let index_price = 100_000.0;

    let option = OrderSize::new(InstrumentKind::Option, None, Some(0.3), None, index_price);
    let option_amount =
        map_order_size_to_deribit_amount(InstrumentKind::Option, &option, None).unwrap();
    assert!((option_amount.amount - 0.3).abs() < 1e-9);

    let linear = OrderSize::new(
        InstrumentKind::LinearFuture,
        None,
        Some(1.5),
        None,
        index_price,
    );
    let linear_amount =
        map_order_size_to_deribit_amount(InstrumentKind::LinearFuture, &linear, None).unwrap();
    assert!((linear_amount.amount - 1.5).abs() < 1e-9);
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
        map_order_size_to_deribit_amount(InstrumentKind::Perpetual, &perp, None).unwrap();
    assert!((perp_amount.amount - 30_000.0).abs() < 1e-9);

    let inverse = OrderSize::new(
        InstrumentKind::InverseFuture,
        None,
        None,
        Some(12_000.0),
        index_price,
    );
    let inverse_amount =
        map_order_size_to_deribit_amount(InstrumentKind::InverseFuture, &inverse, None).unwrap();
    assert!((inverse_amount.amount - 12_000.0).abs() < 1e-9);
}
