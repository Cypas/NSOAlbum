//! Cooperative work boundaries shared by scanning, validation and planning.
use std::sync::{
    atomic::{AtomicU64, AtomicU8, Ordering},
    Arc,
};

use crate::{error::CoreResult, sync::CancellationToken};

#[cfg(test)]
pub(crate) mod test_observer;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum WorkStage {
    #[default]
    Idle,
    Scanning,
    Validating,
    Mapping,
    Comparing,
    Pinning,
    FinalCheck,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkObservation {
    pub stage: WorkStage,
    pub scanned_items: u64,
    pub work_items: u64,
    pub active: bool,
    pub mapped_items: u64,
    pub compared_items: u64,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum BackupWork {
    #[default]
    Idle,
    Copying,
    Hashing,
    Decoding,
    Manifest,
    Rows,
}

#[derive(Debug, Clone, Copy)]
pub struct BackupObservation {
    pub phase: BackupWork,
    pub completed: u64,
}

#[derive(Default)]
struct Counters {
    stage: AtomicU8,
    scanned: AtomicU64,
    items: AtomicU64,
    active: AtomicU64,
    mapped: AtomicU64,
    compared: AtomicU64,
    backup_phase: AtomicU8,
    backup_completed: AtomicU64,
    #[cfg(test)]
    backup_observer: std::sync::Mutex<Option<test_observer::Observer>>,
    #[cfg(test)]
    cache_read_observer: std::sync::Mutex<Option<test_observer::CacheReadObserver>>,
}

pub(crate) struct WorkScope(Arc<Counters>);
impl Drop for WorkScope {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::Release);
    }
}

pub(crate) struct PreparationBytes {
    completed: AtomicU64,
    limit: u64,
}

impl PreparationBytes {
    pub(crate) fn new(limit: u64) -> Arc<Self> {
        Arc::new(Self {
            completed: AtomicU64::new(0),
            limit,
        })
    }

    pub(crate) fn completed(&self) -> u64 {
        self.completed.load(Ordering::Acquire)
    }

    fn add(&self, bytes: u64) -> CoreResult<()> {
        let mut previous = self.completed.load(Ordering::Acquire);
        loop {
            let next = previous
                .checked_add(bytes)
                .filter(|sum| *sum <= self.limit)
                .ok_or_else(|| {
                    crate::error::CoreError::InvalidConfig("preparation byte limit exceeded".into())
                })?;
            match self.completed.compare_exchange_weak(
                previous,
                next,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return Ok(()),
                Err(actual) => previous = actual,
            }
        }
    }
}

#[derive(Clone, Default)]
pub struct WorkControl {
    cancel: CancellationToken,
    counters: Arc<Counters>,
    preparation: Option<Arc<PreparationBytes>>,
    pub(crate) validation: super::validation::ValidationMetrics,
}

impl WorkControl {
    pub fn new(cancel: CancellationToken) -> Self {
        Self {
            cancel,
            counters: Arc::default(),
            preparation: None,
            validation: Default::default(),
        }
    }
    pub fn cancellation(&self) -> CancellationToken {
        self.cancel.clone()
    }
    pub(crate) fn validation_metrics(&self) -> super::validation::ValidationObservation {
        self.validation.observe()
    }
    pub fn with_cancellation(&self, cancel: CancellationToken) -> Self {
        Self {
            cancel,
            counters: self.counters.clone(),
            preparation: self.preparation.clone(),
            validation: self.validation.clone(),
        }
    }
    pub(crate) fn with_preparation(&self, progress: Arc<PreparationBytes>) -> Self {
        Self {
            preparation: Some(progress),
            ..self.clone()
        }
    }
    pub(crate) fn preparation_read(&self, bytes: u64) -> CoreResult<()> {
        self.check()?;
        if let Some(progress) = &self.preparation {
            progress.add(bytes)?;
        }
        Ok(())
    }
    pub fn check(&self) -> CoreResult<()> {
        self.cancel.check()
    }
    pub(crate) fn begin(&self, stage: WorkStage) -> CoreResult<WorkScope> {
        self.check()?;
        self.counters.active.fetch_add(1, Ordering::AcqRel);
        self.counters.stage.store(stage as u8, Ordering::Release);
        Ok(WorkScope(self.counters.clone()))
    }
    /// Records only work that actually ran, never a timer-based estimate.
    pub fn checkpoint(&self, stage: WorkStage, completed: usize) -> CoreResult<()> {
        self.check()?;
        self.counters.stage.store(stage as u8, Ordering::Release);
        self.counters
            .items
            .fetch_add(completed as u64, Ordering::Relaxed);
        if stage == WorkStage::Scanning {
            self.counters
                .scanned
                .fetch_add(completed as u64, Ordering::Relaxed);
        }
        if stage == WorkStage::Mapping {
            self.counters
                .mapped
                .fetch_add(completed as u64, Ordering::Relaxed);
        }
        if stage == WorkStage::Comparing {
            self.counters
                .compared
                .fetch_add(completed as u64, Ordering::Relaxed);
        }
        if stage == WorkStage::Validating
            && self.counters.backup_phase.load(Ordering::Acquire) == BackupWork::Manifest as u8
        {
            self.backup_processed(completed);
        }
        Ok(())
    }
    pub(crate) fn backup_begin(&self, phase: BackupWork) -> CoreResult<()> {
        self.check()?;
        self.counters.backup_completed.store(0, Ordering::Relaxed);
        self.counters
            .backup_phase
            .store(phase as u8, Ordering::Release);
        Ok(())
    }
    /// Observes only actual local backup bytes or validated rows. Keeping this
    /// separate from network/media progress avoids manufacturing a percentage.
    pub(crate) fn backup_processed(&self, completed: usize) {
        self.counters
            .backup_completed
            .fetch_add(completed as u64, Ordering::Relaxed);
        #[cfg(test)]
        {
            let observer = self.counters.backup_observer.lock().unwrap().clone();
            if let Some(observer) = observer {
                observer(self.observe_backup());
            }
        }
    }
    pub fn observe_backup(&self) -> BackupObservation {
        let phase = match self.counters.backup_phase.load(Ordering::Acquire) {
            1 => BackupWork::Copying,
            2 => BackupWork::Hashing,
            3 => BackupWork::Decoding,
            4 => BackupWork::Manifest,
            5 => BackupWork::Rows,
            _ => BackupWork::Idle,
        };
        BackupObservation {
            phase,
            completed: self.counters.backup_completed.load(Ordering::Relaxed),
        }
    }
    pub fn observe(&self) -> WorkObservation {
        let active = self.counters.active.load(Ordering::Acquire) != 0;
        let stage = match self.counters.stage.load(Ordering::Acquire) {
            1 => WorkStage::Scanning,
            2 => WorkStage::Validating,
            3 => WorkStage::Mapping,
            4 => WorkStage::Comparing,
            5 => WorkStage::Pinning,
            6 => WorkStage::FinalCheck,
            _ => WorkStage::Idle,
        };
        WorkObservation {
            stage: if active { stage } else { WorkStage::Idle },
            scanned_items: self.counters.scanned.load(Ordering::Relaxed),
            work_items: self.counters.items.load(Ordering::Relaxed),
            active,
            mapped_items: self.counters.mapped.load(Ordering::Relaxed),
            compared_items: self.counters.compared.load(Ordering::Relaxed),
        }
    }
    pub fn digest_json(&self, value: &impl serde::Serialize) -> CoreResult<String> {
        let _scope = self.begin(WorkStage::Validating)?;
        use sha2::{Digest, Sha256};
        struct Output<'a> {
            work: &'a WorkControl,
            hash: Sha256,
        }
        impl std::io::Write for Output<'_> {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                self.work
                    .check()
                    .map_err(|_| std::io::Error::other("cancelled"))?;
                self.hash.update(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        self.check()?;
        let mut output = Output {
            work: self,
            hash: Sha256::new(),
        };
        let encoded = serde_json::to_writer(&mut output, value);
        self.check()?;
        encoded?;
        Ok(hex::encode(output.hash.finalize()))
    }
}
