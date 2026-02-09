use crate::venue::InstrumentKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderType {
    Limit,
    Market,
    StopMarket,
    StopLimit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkedOrderType {
    Oco,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderTypeRejectReason {
    OrderTypeMarketForbidden,
    OrderTypeStopForbidden,
    LinkedOrderTypeForbidden,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OrderTypeGuardConfig {
    pub linked_orders_supported: bool,
    pub enable_linked_orders_for_bot: bool,
}

impl Default for OrderTypeGuardConfig {
    fn default() -> Self {
        Self {
            linked_orders_supported: false,
            enable_linked_orders_for_bot: false,
        }
    }
}

impl OrderTypeGuardConfig {
    fn linked_orders_allowed(self) -> bool {
        self.linked_orders_supported && self.enable_linked_orders_for_bot
    }
}

pub fn validate_order_type(
    instrument_kind: InstrumentKind,
    order_type: OrderType,
    has_trigger_fields: bool,
    linked_order_type: Option<LinkedOrderType>,
    config: OrderTypeGuardConfig,
) -> Result<(), OrderTypeRejectReason> {
    if linked_order_type.is_some() {
        let allow_linked = match instrument_kind {
            InstrumentKind::Option => false,
            InstrumentKind::LinearFuture
            | InstrumentKind::InverseFuture
            | InstrumentKind::Perpetual => config.linked_orders_allowed(),
        };
        if !allow_linked {
            return Err(OrderTypeRejectReason::LinkedOrderTypeForbidden);
        }
    }

    match instrument_kind {
        InstrumentKind::Option => {
            if order_type == OrderType::Market {
                return Err(OrderTypeRejectReason::OrderTypeMarketForbidden);
            }
            if matches!(order_type, OrderType::StopMarket | OrderType::StopLimit) {
                return Err(OrderTypeRejectReason::OrderTypeStopForbidden);
            }
            if has_trigger_fields {
                return Err(OrderTypeRejectReason::OrderTypeStopForbidden);
            }
        }
        InstrumentKind::LinearFuture
        | InstrumentKind::InverseFuture
        | InstrumentKind::Perpetual => {
            if order_type == OrderType::Market {
                return Err(OrderTypeRejectReason::OrderTypeMarketForbidden);
            }
            if matches!(order_type, OrderType::StopMarket | OrderType::StopLimit) {
                return Err(OrderTypeRejectReason::OrderTypeStopForbidden);
            }
        }
    }

    Ok(())
}
