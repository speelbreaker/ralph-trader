use crate::venue::InstrumentKind;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OrderSize {
    pub contracts: Option<i64>,
    pub qty_coin: Option<f64>,
    pub qty_usd: Option<f64>,
    pub notional_usd: f64,
}

impl OrderSize {
    pub fn new(
        instrument_kind: InstrumentKind,
        contracts: Option<i64>,
        qty_coin: Option<f64>,
        qty_usd: Option<f64>,
        index_price: f64,
    ) -> Self {
        let (qty_coin, qty_usd, notional_usd) = match instrument_kind {
            InstrumentKind::Option | InstrumentKind::LinearFuture => {
                let qty_coin = qty_coin.expect("qty_coin required for coin-sized instruments");
                let notional_usd = qty_coin * index_price;
                (Some(qty_coin), None, notional_usd)
            }
            InstrumentKind::Perpetual | InstrumentKind::InverseFuture => {
                let qty_usd = qty_usd.expect("qty_usd required for USD-sized instruments");
                let notional_usd = qty_usd;
                (None, Some(qty_usd), notional_usd)
            }
        };

        eprintln!(
            "OrderSizeComputed instrument_kind={:?} notional_usd={}",
            instrument_kind, notional_usd
        );

        Self {
            contracts,
            qty_coin,
            qty_usd,
            notional_usd,
        }
    }
}
