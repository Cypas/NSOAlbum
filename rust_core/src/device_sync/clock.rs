//! Authenticated connection-time sampling, independent of library scan duration.

use serde::{Deserialize, Serialize};
use std::time::Instant;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClockTrust {
    WithinLimit,
    OutsideLimit,
    Uncertain,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectionSample {
    pub lower_offset_ms: i64,
    pub upper_offset_ms: i64,
}

impl ConnectionSample {
    pub fn from_round_trip(start: i64, end: i64, peer: i64) -> Option<Self> {
        if end < start {
            return None;
        }
        Some(Self {
            lower_offset_ms: peer.checked_sub(end)?,
            upper_offset_ms: peer.checked_sub(start)?,
        })
    }

    pub fn trust(self) -> ClockTrust {
        if self.lower_offset_ms > self.upper_offset_ms {
            ClockTrust::Uncertain
        } else if self.lower_offset_ms >= -120_000 && self.upper_offset_ms <= 120_000 {
            ClockTrust::WithinLimit
        } else if self.lower_offset_ms > 120_000 || self.upper_offset_ms < -120_000 {
            ClockTrust::OutsideLimit
        } else {
            ClockTrust::Uncertain
        }
    }
}

pub trait Clock: Send + Sync {
    fn monotonic_ms(&self) -> u64;
    fn unix_ms(&self) -> i64;
}

pub struct SystemClock {
    origin: Instant,
}

impl Default for SystemClock {
    fn default() -> Self {
        Self {
            origin: Instant::now(),
        }
    }
}

impl Clock for SystemClock {
    fn monotonic_ms(&self) -> u64 {
        self.origin.elapsed().as_millis().min(u64::MAX as u128) as u64
    }
    fn unix_ms(&self) -> i64 {
        chrono::Utc::now().timestamp_millis()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connection_interval_does_not_treat_long_scanning_as_clock_skew() {
        let sample = ConnectionSample::from_round_trip(1_000_000, 1_000_020, 1_000_010).unwrap();
        assert_eq!(sample.trust(), ClockTrust::WithinLimit);
        let uncertain = ConnectionSample::from_round_trip(1_000_000, 1_300_000, 1_150_000).unwrap();
        assert_eq!(uncertain.trust(), ClockTrust::Uncertain);
        let skewed = ConnectionSample::from_round_trip(1_000_000, 1_000_020, 1_130_000).unwrap();
        assert_eq!(skewed.trust(), ClockTrust::OutsideLimit);
    }
}
