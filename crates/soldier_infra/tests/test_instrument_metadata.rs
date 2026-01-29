use soldier_core::venue::{DeribitInstrumentKind, DeribitSettlementPeriod, InstrumentKind};
use soldier_infra::deribit::public::DeribitInstrument;

#[test]
fn test_instrument_metadata_uses_get_instruments() {
    let instrument = DeribitInstrument {
        instrument_name: "BTC-PERP".to_string(),
        kind: DeribitInstrumentKind::Future,
        settlement_period: DeribitSettlementPeriod::Perpetual,
        quote_currency: "USD".to_string(),
        tick_size: 0.5,
        amount_step: 0.1,
        min_amount: 0.2,
        contract_multiplier: Some(10.0),
        expiration_timestamp: None,
        is_active: true,
    };

    let quant = instrument.to_quantization();
    assert_eq!(quant.tick_size, 0.5);
    assert_eq!(quant.amount_step, 0.1);
    assert_eq!(quant.min_amount, 0.2);
    assert_eq!(instrument.contract_multiplier, Some(10.0));
    assert_eq!(
        instrument.derive_instrument_kind(),
        InstrumentKind::Perpetual
    );
}
