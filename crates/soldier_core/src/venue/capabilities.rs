use std::env;

use crate::venue::InstrumentKind;

pub const ENABLE_LINKED_ORDERS_FOR_BOT: &str = "ENABLE_LINKED_ORDERS_FOR_BOT";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VenueCapabilities {
    pub linked_orders_supported: bool,
}

impl Default for VenueCapabilities {
    fn default() -> Self {
        Self {
            linked_orders_supported: false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FeatureFlags {
    pub enable_linked_orders_for_bot: bool,
}

impl Default for FeatureFlags {
    fn default() -> Self {
        Self {
            enable_linked_orders_for_bot: false,
        }
    }
}

impl FeatureFlags {
    pub fn from_env() -> Self {
        Self {
            enable_linked_orders_for_bot: env_flag_enabled(ENABLE_LINKED_ORDERS_FOR_BOT),
        }
    }
}

impl VenueCapabilities {
    pub fn linked_orders_supported_for(
        self,
        instrument_kind: InstrumentKind,
        feature_flags: FeatureFlags,
    ) -> bool {
        match instrument_kind {
            InstrumentKind::Option => false,
            InstrumentKind::LinearFuture
            | InstrumentKind::InverseFuture
            | InstrumentKind::Perpetual => {
                self.linked_orders_supported && feature_flags.enable_linked_orders_for_bot
            }
        }
    }
}

fn env_flag_enabled(key: &str) -> bool {
    match env::var(key) {
        Ok(value) => {
            let value = value.trim();
            value == "1" || value.eq_ignore_ascii_case("true")
        }
        Err(_) => false,
    }
}
