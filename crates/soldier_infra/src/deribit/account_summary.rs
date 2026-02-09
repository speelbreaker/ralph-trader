use serde::de::{self, Deserializer, Visitor};
use serde::Deserialize;
use std::fmt;

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct DeribitAccountSummary {
    pub fee_tier: u64,
    pub maker_fee_rate: f64,
    pub taker_fee_rate: f64,
    #[serde(
        default,
        deserialize_with = "deserialize_epoch_ms_opt",
        rename = "fee_model_cached_at_ts_ms",
        alias = "fee_model_cached_at_ts",
        alias = "timestamp"
    )]
    pub fee_model_cached_at_ts_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct DeribitAccountSummaryResponse {
    pub result: DeribitAccountSummary,
}

fn deserialize_epoch_ms_opt<'de, D>(deserializer: D) -> Result<Option<u64>, D::Error>
where
    D: Deserializer<'de>,
{
    struct EpochMsVisitor;

    impl<'de> Visitor<'de> for EpochMsVisitor {
        type Value = Option<u64>;

        fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
            formatter.write_str("epoch milliseconds as int or string")
        }

        fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(Some(value))
        }

        fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            if value < 0 {
                Ok(None)
            } else {
                Ok(Some(value as u64))
            }
        }

        fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(value.parse::<u64>().ok())
        }

        fn visit_string<E>(self, value: String) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(value.parse::<u64>().ok())
        }

        fn visit_none<E>(self) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(None)
        }

        fn visit_unit<E>(self) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(None)
        }

        fn visit_some<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
        where
            D: Deserializer<'de>,
        {
            deserializer.deserialize_any(EpochMsVisitor)
        }
    }

    deserializer.deserialize_any(EpochMsVisitor)
}
