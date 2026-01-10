use soldier_core::execution::OrderSize;
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
