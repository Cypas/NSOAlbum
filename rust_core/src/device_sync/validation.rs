//! Operation-owned numeric work counters. No identifiers, paths or payloads.
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};
use std::time::{Duration, Instant};

#[derive(Clone, Copy)]
pub(crate) enum ApplyTimingPhase {
    Binding,
    Snapshot,
    Plan,
    Originals,
    Space,
    Backup,
    Sql,
    Postcheck,
    Journal,
}

#[derive(Default)]
struct Counters {
    snapshot_digests: AtomicU64,
    binding_digests: AtomicU64,
    checksum_read_bytes: AtomicU64,
    receive_hashed_bytes: AtomicU64,
    copy_bytes: AtomicU64,
    apply_us: [AtomicU64; 9],
    apply_count: [AtomicU64; 9],
    strict_noop_applied: AtomicU64,
}

#[derive(Clone, Default)]
pub(crate) struct ValidationMetrics(Arc<Counters>);

#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct ValidationObservation {
    pub snapshot_digests: u64,
    pub binding_digests: u64,
    pub checksum_read_bytes: u64,
    pub receive_hashed_bytes: u64,
    pub copy_bytes: u64,
    apply_us: [u64; 9],
    apply_count: [u64; 9],
    strict_noop_applied: u64,
}

pub(crate) struct ApplyTimingScope {
    metrics: ValidationMetrics,
    phase: ApplyTimingPhase,
    started: Instant,
}
impl Drop for ApplyTimingScope {
    fn drop(&mut self) {
        self.metrics
            .record_apply(self.phase, self.started.elapsed());
    }
}

fn add(counter: &AtomicU64, count: u64) {
    let mut previous = counter.load(Ordering::Relaxed);
    loop {
        match counter.compare_exchange_weak(
            previous,
            previous.saturating_add(count),
            Ordering::Relaxed,
            Ordering::Relaxed,
        ) {
            Ok(_) => break,
            Err(actual) => previous = actual,
        }
    }
}

impl ValidationMetrics {
    pub(crate) fn time_apply(&self, phase: ApplyTimingPhase) -> ApplyTimingScope {
        ApplyTimingScope {
            metrics: self.clone(),
            phase,
            started: Instant::now(),
        }
    }
    pub(crate) fn record_apply(&self, phase: ApplyTimingPhase, elapsed: Duration) {
        add(
            &self.0.apply_us[phase as usize],
            elapsed.as_micros().min(u128::from(u64::MAX)) as u64,
        );
        add(&self.0.apply_count[phase as usize], 1);
    }
    pub(crate) fn strict_noop_applied(&self) {
        self.0.strict_noop_applied.store(1, Ordering::Relaxed);
    }
    pub(crate) fn snapshot_digest(&self) {
        add(&self.0.snapshot_digests, 1);
    }
    pub(crate) fn binding_digest(&self) {
        add(&self.0.binding_digests, 1);
    }
    pub(crate) fn checksum_read(&self, bytes: u64) {
        add(&self.0.checksum_read_bytes, bytes);
    }
    pub(crate) fn copied(&self, bytes: u64) {
        add(&self.0.copy_bytes, bytes);
    }
    pub(crate) fn observe(&self) -> ValidationObservation {
        ValidationObservation {
            snapshot_digests: self.0.snapshot_digests.load(Ordering::Relaxed),
            binding_digests: self.0.binding_digests.load(Ordering::Relaxed),
            checksum_read_bytes: self.0.checksum_read_bytes.load(Ordering::Relaxed),
            receive_hashed_bytes: self.0.receive_hashed_bytes.load(Ordering::Relaxed),
            copy_bytes: self.0.copy_bytes.load(Ordering::Relaxed),
            apply_us: std::array::from_fn(|i| self.0.apply_us[i].load(Ordering::Relaxed)),
            apply_count: std::array::from_fn(|i| self.0.apply_count[i].load(Ordering::Relaxed)),
            strict_noop_applied: self.0.strict_noop_applied.load(Ordering::Relaxed),
        }
    }
}

impl std::fmt::Display for ValidationObservation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "snapshot_digests={} binding_digests={} staging_checksum_read_bytes={} receive_hashed_bytes={} copy_bytes={}",
            self.snapshot_digests, self.binding_digests, self.checksum_read_bytes,
            self.receive_hashed_bytes, self.copy_bytes)?;
        write!(
            f,
            " strict_noop_applied={} apply_timings_nested=1",
            self.strict_noop_applied
        )?;
        for (index, name) in [
            "binding",
            "snapshot",
            "plan",
            "originals",
            "space",
            "backup",
            "sql",
            "postcheck",
            "journal",
        ]
        .into_iter()
        .enumerate()
        {
            write!(
                f,
                " apply_{name}_us={} apply_{name}_count={}",
                self.apply_us[index], self.apply_count[index]
            )?;
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "validation_tests.rs"]
mod tests;
