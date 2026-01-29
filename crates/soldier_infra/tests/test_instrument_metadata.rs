use soldier_core::venue::InstrumentKind;
use soldier_infra::deribit::public::DeribitInstrumentRaw;

#[test]
fn test_instrument_metadata_uses_get_instruments() {
    let json = r#"
    {
        "instrument_name": "BTC-PERP",
        "kind": "future",
        "settlement_period": "perpetual",
        "quote_currency": "USD",
        "tick_size": 0.5,
        "min_trade_amount": 0.1,
        "contract_size": 10.0,
        "expiration_timestamp": null,
        "is_active": true
    }
    "#;

    let raw: DeribitInstrumentRaw = serde_json::from_str(json).expect("deserialize instrument");
    let instrument = raw.into_domain().expect("map to domain");

    let quant = instrument.to_quantization();
    assert_eq!(quant.tick_size, 0.5);
    assert_eq!(quant.amount_step, 0.1);
    assert_eq!(quant.min_amount, 0.1);
    assert_eq!(instrument.contract_multiplier, Some(10.0));
    assert_eq!(
        instrument.derive_instrument_kind(),
        InstrumentKind::Perpetual
    );
}
