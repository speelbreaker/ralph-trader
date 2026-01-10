use soldier_core::venue::{DeribitInstrumentKind, DeribitSettlementPeriod, InstrumentKind};

#[test]
fn derives_linear_future_from_usdc_perpetual() {
    let kind = InstrumentKind::from_deribit(
        DeribitInstrumentKind::Future,
        DeribitSettlementPeriod::Perpetual,
        "USDC",
    );

    assert_eq!(kind, InstrumentKind::LinearFuture);
}

#[test]
fn maps_option_and_futures_kinds() {
    let option_kind = InstrumentKind::from_deribit(
        DeribitInstrumentKind::Option,
        DeribitSettlementPeriod::Other,
        "USD",
    );
    assert_eq!(option_kind, InstrumentKind::Option);

    let perpetual_kind = InstrumentKind::from_deribit(
        DeribitInstrumentKind::Future,
        DeribitSettlementPeriod::Perpetual,
        "USD",
    );
    assert_eq!(perpetual_kind, InstrumentKind::Perpetual);

    let inverse_future_kind = InstrumentKind::from_deribit(
        DeribitInstrumentKind::Future,
        DeribitSettlementPeriod::Month,
        "USD",
    );
    assert_eq!(inverse_future_kind, InstrumentKind::InverseFuture);

    let linear_future_kind = InstrumentKind::from_deribit(
        DeribitInstrumentKind::Future,
        DeribitSettlementPeriod::Month,
        "USDC",
    );
    assert_eq!(linear_future_kind, InstrumentKind::LinearFuture);
}
