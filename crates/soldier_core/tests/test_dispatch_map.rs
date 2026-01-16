use soldier_core::execution::{
    DispatchRejectReason, OrderSize, map_order_size_to_deribit_amount,
    order_intent_reject_unit_mismatch_total,
};
use soldier_core::risk::RiskState;
use soldier_core::venue::InstrumentKind;
use std::sync::Mutex;

static UNIT_MISMATCH_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn acceptance_option_and_perp_mapping() {
    let index_price = 100_000.0;
    // Option: 0.3 coin. Multiplier 1.0 (standard option). Contracts = 0.3 / 1.0 = 0 (rounded? No, options are usually 1 contract = 1 coin).
    // Actually, Deribit Options: 1 contract = 1 instrument. Multiplier = 1.
    // If qty_coin is 0.3, and multiplier is 1, contracts would be 0 (0.3 rounds to 0).
    // Wait, Options usually have size in contracts (e.g. 1 contract).
    // If I send 0.3 BTC, that's 0.3 contracts?
    // Deribit: "amount": "Amount in contract units". For options, 1 contract = 1 coin?
    // Let's assume multiplier = 1.0 for options for this test.

    let option = OrderSize::new(InstrumentKind::Option, None, Some(0.3), None, index_price);
    // Passing multiplier 1.0
    let option_amount =
        map_order_size_to_deribit_amount(InstrumentKind::Option, &option, Some(1.0), index_price)
            .unwrap();
    assert!((option_amount.amount - 0.3).abs() < 1e-9);
    // 0.3 contracts rounds to 0? Or is it fractional?
    // Rounding: 0.3 -> 0.
    // OrderSize contracts is i64.
    // So if I send 0.3, derived contracts is 0.
    assert_eq!(option_amount.contracts, Some(0));

    let option_qty_coin = option_amount.derived_qty_coin.expect("derived qty coin");
    assert!((option_qty_coin - 0.3).abs() < 1e-9);

    // Perp: 30,000 USD. Multiplier 10.0 (e.g. 10 USD per contract).
    // Contracts = 30000 / 10 = 3000.
    let perp = OrderSize::new(
        InstrumentKind::Perpetual,
        None,
        None,
        Some(30_000.0),
        index_price,
    );
    let perp_amount =
        map_order_size_to_deribit_amount(InstrumentKind::Perpetual, &perp, Some(10.0), index_price)
            .unwrap();
    assert!((perp_amount.amount - 30_000.0).abs() < 1e-9);
    assert_eq!(perp_amount.contracts, Some(3000));

    let perp_qty_coin = perp_amount.derived_qty_coin.expect("derived qty coin");
    assert!((perp_qty_coin - 0.3).abs() < 1e-9);
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
    let _guard = UNIT_MISMATCH_LOCK.lock().expect("unit mismatch lock");
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
    assert_eq!(err.reason, DispatchRejectReason::UnitMismatch);
}

#[test]
fn reject_zero_index_price_for_usd_instruments() {
    let _guard = UNIT_MISMATCH_LOCK.lock().expect("unit mismatch lock");
    let perp = OrderSize::new(
        InstrumentKind::Perpetual,
        None,
        None,
        Some(100.0),
        0.0, // Invalid
    );
    let err = map_order_size_to_deribit_amount(InstrumentKind::Perpetual, &perp, Some(10.0), 0.0)
        .unwrap_err();
    assert_eq!(err.reason, DispatchRejectReason::UnitMismatch); // "invalid_index_price" maps to UnitMismatch
}

#[test]
fn rejects_contract_mismatch_and_increments_counter() {
    let _guard = UNIT_MISMATCH_LOCK.lock().expect("unit mismatch lock");
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
