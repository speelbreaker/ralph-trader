use super::{RejectReason, Side};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PricerIntent {
    pub side: Side,
    pub fair_price: f64,
    pub gross_edge_usd: f64,
    pub fee_estimate_usd: f64,
    pub min_edge_usd: f64,
    pub qty: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PricerOutcome {
    pub limit_price: f64,
    pub net_edge_usd: f64,
    pub max_price_for_min_edge: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PricerReject {
    pub reason: RejectReason,
    pub net_edge_usd: Option<f64>,
}

pub fn price_ioc_limit(intent: &PricerIntent) -> Result<PricerOutcome, PricerReject> {
    let fair_price = parse_positive(intent.fair_price)?;
    let gross_edge = parse_finite(intent.gross_edge_usd)?;
    let fee_estimate = parse_finite(intent.fee_estimate_usd)?;
    let min_edge = parse_finite(intent.min_edge_usd)?;
    let qty = parse_positive(intent.qty)?;

    let net_edge_usd = gross_edge - fee_estimate;
    if !net_edge_usd.is_finite() {
        return Err(reject(None));
    }

    if net_edge_usd < min_edge {
        return Err(reject(Some(net_edge_usd)));
    }

    let net_edge_per_unit = net_edge_usd / qty;
    let fee_per_unit = fee_estimate / qty;
    let min_edge_per_unit = min_edge / qty;

    let max_price_for_min_edge = match intent.side {
        Side::Buy => fair_price - (min_edge_per_unit + fee_per_unit),
        Side::Sell => fair_price + (min_edge_per_unit + fee_per_unit),
    };

    let proposed_limit = match intent.side {
        Side::Buy => fair_price - 0.5 * net_edge_per_unit,
        Side::Sell => fair_price + 0.5 * net_edge_per_unit,
    };

    let limit_price = match intent.side {
        Side::Buy => proposed_limit.min(max_price_for_min_edge),
        Side::Sell => proposed_limit.max(max_price_for_min_edge),
    };

    record_limit_vs_fair_bps(fair_price, limit_price);

    Ok(PricerOutcome {
        limit_price,
        net_edge_usd,
        max_price_for_min_edge,
    })
}

fn parse_finite(value: f64) -> Result<f64, PricerReject> {
    if value.is_finite() {
        Ok(value)
    } else {
        Err(reject(None))
    }
}

fn parse_positive(value: f64) -> Result<f64, PricerReject> {
    if value.is_finite() && value > 0.0 {
        Ok(value)
    } else {
        Err(reject(None))
    }
}

fn reject(net_edge_usd: Option<f64>) -> PricerReject {
    reject_with_metrics(RejectReason::NetEdgeTooLow, net_edge_usd)
}

fn reject_with_metrics(reason: RejectReason, net_edge_usd: Option<f64>) -> PricerReject {
    eprintln!("pricer_reject_total reason={:?}", reason);
    eprintln!(
        "PricerReject reason={:?} net_edge_usd={:?}",
        reason, net_edge_usd
    );
    PricerReject {
        reason,
        net_edge_usd,
    }
}

fn record_limit_vs_fair_bps(fair_price: f64, limit_price: f64) {
    if fair_price == 0.0 {
        return;
    }
    let bps = (limit_price - fair_price) / fair_price * 10_000.0;
    eprintln!("pricer_limit_vs_fair_bps value={}", bps);
}
