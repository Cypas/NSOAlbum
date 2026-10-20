use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Mutex,
};

#[derive(Default, Clone)]
pub(crate) struct Throughput(Arc<Counters>);

#[derive(Default)]
struct Counters {
    bytes: AtomicU64,
    observed: AtomicU64,
    total: AtomicU64,
    active: AtomicBool,
    published: AtomicU64,
    sample: Mutex<Sample>,
}

#[derive(Default)]
struct Sample {
    at: Option<u64>,
    bytes: u64,
}

impl Throughput {
    pub(super) fn record(&mut self, now: u64, bytes: u64) {
        self.0.observed.fetch_max(now, Ordering::Relaxed);
        if let Ok(mut sample) = self.0.sample.try_lock() {
            sample.at.get_or_insert(now);
        }
        let mut previous = self.0.bytes.load(Ordering::Relaxed);
        loop {
            match self.0.bytes.compare_exchange_weak(
                previous,
                previous.saturating_add(bytes),
                Ordering::Release,
                Ordering::Relaxed,
            ) {
                Ok(_) => break,
                Err(actual) => previous = actual,
            }
        }
    }

    pub(crate) fn rate(&self, now: u64) -> u64 {
        // This lock is independent of the Driver/library owner, never waits,
        // and is held only for this arithmetic (no filesystem or network I/O).
        let Ok(mut sample) = self.0.sample.try_lock() else {
            return self.0.published.load(Ordering::Acquire);
        };
        let now = now.max(self.0.observed.load(Ordering::Relaxed));
        let at = *sample.at.get_or_insert(now);
        let elapsed = now.saturating_sub(at);
        if elapsed < 1000 {
            return self.0.published.load(Ordering::Acquire);
        }
        let bytes = self.0.bytes.load(Ordering::Acquire);
        let delta = bytes.saturating_sub(sample.bytes);
        let rate =
            (u128::from(delta) * 1000 / u128::from(elapsed)).min(u128::from(u64::MAX)) as u64;
        sample.at = Some(now);
        sample.bytes = bytes;
        self.0.published.store(rate, Ordering::Release);
        rate
    }

    pub(super) fn reset(&mut self) {
        self.0.bytes.store(0, Ordering::Release);
        self.0.observed.store(0, Ordering::Release);
        self.0.published.store(0, Ordering::Release);
        *self.0.sample.lock().unwrap_or_else(|e| e.into_inner()) = Sample::default();
    }

    pub(super) fn configure(&self, active: bool, total: u64) {
        self.0.total.store(total, Ordering::Release);
        self.0.active.store(active, Ordering::Release);
    }

    pub(crate) fn project(
        &self,
        now: u64,
        progress: &mut crate::device_sync::read_model::ProgressView,
    ) {
        if self.0.active.load(Ordering::Acquire) {
            progress.transferred_bytes = Some(self.0.bytes.load(Ordering::Acquire));
            progress.transfer_total_bytes = Some(self.0.total.load(Ordering::Acquire));
            progress.transfer_bytes_per_second = Some(self.rate(now));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_second_samples_use_new_bytes_actual_elapsed_and_idle_zero() {
        let mut rate = Throughput::default();
        assert_eq!(rate.rate(0), 0);
        rate.record(100, 4096);
        assert_eq!(
            rate.rate(500),
            0,
            "must not publish at the old 500ms cadence"
        );
        assert_eq!(rate.rate(999), 0);
        assert_eq!(rate.rate(1000), 4096);
        rate.record(1100, 2048);
        assert_eq!(rate.rate(1500), 4096, "same sample must remain stable");
        assert_eq!(rate.rate(2000), 2048, "exclude previously published bytes");
        assert_eq!(rate.rate(3000), 0, "one idle interval must publish zero");
        rate.record(3100, 8192);
        assert_eq!(rate.rate(5000), 4096, "use the actual two-second delay");
        assert_eq!(rate.rate(4500), 4096, "a regressing clock cannot republish");
        rate.reset();
        assert_eq!(rate.rate(9000), 0);
        rate.record(9500, 1024);
        assert_eq!(rate.rate(9999), 0);
        assert_eq!(rate.rate(10000), 1024);
    }

    #[test]
    fn one_idle_sample_drops_stale_rate_and_resets_between_transfers() {
        let mut rate = Throughput::default();
        rate.record(0, 16_384);
        assert_eq!(rate.rate(1000), 16_384);
        assert_eq!(rate.rate(2000), 0);
        rate.record(4_000, 512);
        assert_eq!(rate.rate(4_000), 256);
        rate.reset();
        assert_eq!(rate.rate(9_000), 0);
        rate.record(9_500, 1_536);
        assert_eq!(rate.rate(10_000), 1_536);
    }
}
