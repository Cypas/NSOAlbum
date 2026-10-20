//! Operation-owned numeric work counters. No identifiers, paths or payloads.
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};

#[derive(Default)]
struct Counters {
    snapshot_digests: AtomicU64,
    binding_digests: AtomicU64,
    checksum_read_bytes: AtomicU64,
    receive_hashed_bytes: AtomicU64,
    copy_bytes: AtomicU64,
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
        }
    }
}

impl std::fmt::Display for ValidationObservation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "snapshot_digests={} binding_digests={} staging_checksum_read_bytes={} receive_hashed_bytes={} copy_bytes={}",
            self.snapshot_digests, self.binding_digests, self.checksum_read_bytes,
            self.receive_hashed_bytes, self.copy_bytes)
    }
}
