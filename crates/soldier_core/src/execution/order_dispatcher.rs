/// Order dispatch abstraction for emergency close and other execution modules
///
/// This trait defines the interface between execution logic and actual order dispatch.
/// Production implementations integrate with the exchange API layer.
/// Test implementations can use stubs/mocks for deterministic testing.
use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub struct CloseOrderRequest {
    pub instrument_name: String,
    pub qty: f64,
    pub side: OrderSide, // Opposite of current position
    pub order_type: OrderType,
    pub buffer_ticks: i32, // For IOC limit orders
}

#[derive(Debug, Clone, PartialEq)]
pub struct HedgeOrderRequest {
    pub instrument_name: String,
    pub qty: f64,
    pub side: OrderSide,
    pub reduce_only: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderSide {
    Buy,
    Sell,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderType {
    IOC, // Immediate-or-cancel
    Limit,
}

#[derive(Debug, Clone, PartialEq)]
pub struct OrderResult {
    pub requested_qty: f64,
    pub filled_qty: f64,
    pub status: OrderStatus,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderStatus {
    Filled,
    PartiallyFilled,
    Rejected,
    Canceled,
}

#[derive(Debug, Clone)]
pub struct DispatchError {
    pub message: String,
}

impl DispatchError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for DispatchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Dispatch error: {}", self.message)
    }
}

impl std::error::Error for DispatchError {}

/// Trait for order dispatch operations
///
/// Implementations must provide:
/// - Production: Integration with exchange API (REST/WebSocket)
/// - Test: Deterministic stub/mock implementations
pub trait OrderDispatcher: Send + Sync {
    /// Dispatch a close order (emergency flatten)
    ///
    /// Returns filled qty and status. May return partial fill.
    fn dispatch_close(&self, request: &CloseOrderRequest) -> Result<OrderResult, DispatchError>;

    /// Dispatch a hedge order (reduce-only perp hedge)
    ///
    /// Used as fallback when close attempts fail to neutralize exposure.
    fn dispatch_hedge(&self, request: &HedgeOrderRequest) -> Result<OrderResult, DispatchError>;
}

/// Test stub implementation - always returns full fill
///
/// This implementation is suitable for unit tests and development.
/// DO NOT use in production.
#[derive(Debug, Clone)]
pub struct TestStubDispatcher;

impl OrderDispatcher for TestStubDispatcher {
    fn dispatch_close(&self, request: &CloseOrderRequest) -> Result<OrderResult, DispatchError> {
        eprintln!(
            "[TEST STUB] dispatch_close: instrument={} qty={} side={:?} buffer_ticks={}",
            request.instrument_name, request.qty, request.side, request.buffer_ticks
        );

        Ok(OrderResult {
            requested_qty: request.qty,
            filled_qty: request.qty, // Stub: always full fill
            status: OrderStatus::Filled,
        })
    }

    fn dispatch_hedge(&self, request: &HedgeOrderRequest) -> Result<OrderResult, DispatchError> {
        eprintln!(
            "[TEST STUB] dispatch_hedge: instrument={} qty={} side={:?} reduce_only={}",
            request.instrument_name, request.qty, request.side, request.reduce_only
        );

        Ok(OrderResult {
            requested_qty: request.qty,
            filled_qty: request.qty, // Stub: always full fill
            status: OrderStatus::Filled,
        })
    }
}

/// Production dispatcher stub - MUST be replaced before deployment
///
/// This implementation panics with clear error messages directing to integration work.
/// It exists to make the compilation succeed while preventing accidental production use.
#[derive(Debug, Clone)]
pub struct ProductionDispatcher {
    _private: (),
}

impl ProductionDispatcher {
    pub fn new() -> Self {
        eprintln!(
            "[WARN] ProductionDispatcher created - this MUST be replaced with real implementation"
        );
        Self { _private: () }
    }
}

impl OrderDispatcher for ProductionDispatcher {
    fn dispatch_close(&self, _request: &CloseOrderRequest) -> Result<OrderResult, DispatchError> {
        Err(DispatchError::new(
            "ProductionDispatcher::dispatch_close NOT IMPLEMENTED - integrate with exchange API layer",
        ))
    }

    fn dispatch_hedge(&self, _request: &HedgeOrderRequest) -> Result<OrderResult, DispatchError> {
        Err(DispatchError::new(
            "ProductionDispatcher::dispatch_hedge NOT IMPLEMENTED - integrate with exchange API layer",
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_stub_dispatcher_close() {
        let dispatcher = TestStubDispatcher;
        let request = CloseOrderRequest {
            instrument_name: "BTC-PERPETUAL".to_string(),
            qty: 1.0,
            side: OrderSide::Sell,
            order_type: OrderType::IOC,
            buffer_ticks: 5,
        };

        let result = dispatcher.dispatch_close(&request).unwrap();
        assert_eq!(result.filled_qty, 1.0);
        assert_eq!(result.status, OrderStatus::Filled);
    }

    #[test]
    fn test_stub_dispatcher_hedge() {
        let dispatcher = TestStubDispatcher;
        let request = HedgeOrderRequest {
            instrument_name: "BTC-PERPETUAL".to_string(),
            qty: 0.5,
            side: OrderSide::Buy,
            reduce_only: true,
        };

        let result = dispatcher.dispatch_hedge(&request).unwrap();
        assert_eq!(result.filled_qty, 0.5);
        assert_eq!(result.status, OrderStatus::Filled);
    }

    #[test]
    fn test_production_dispatcher_errors() {
        let dispatcher = ProductionDispatcher::new();

        let close_request = CloseOrderRequest {
            instrument_name: "BTC-PERPETUAL".to_string(),
            qty: 1.0,
            side: OrderSide::Sell,
            order_type: OrderType::IOC,
            buffer_ticks: 5,
        };

        let result = dispatcher.dispatch_close(&close_request);
        assert!(result.is_err());
        assert!(result.unwrap_err().message.contains("NOT IMPLEMENTED"));

        let hedge_request = HedgeOrderRequest {
            instrument_name: "BTC-PERPETUAL".to_string(),
            qty: 0.5,
            side: OrderSide::Buy,
            reduce_only: true,
        };

        let result = dispatcher.dispatch_hedge(&hedge_request);
        assert!(result.is_err());
        assert!(result.unwrap_err().message.contains("NOT IMPLEMENTED"));
    }
}
