//! Cooperative work boundaries shared by scanning, validation and planning.
use std::sync::{
    atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering},
    Arc, Mutex,
};
use std::time::Instant;

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PreparationStage {
    ReadingLibrary,
    ComparingRecords,
    CheckingCache,
    CheckingSpace,
    PreparingPreview,
    WaitingForPeer,
}

struct PreparationProgress {
    phase: PreparationStage,
    processed: u64,
    total: Option<u64>,
    started: Instant,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkObservation {
    pub stage: WorkStage,
    pub preparation_phase: Option<PreparationStage>,
    pub preparation_processed_items: u64,
    pub preparation_total_items: Option<u64>,
    pub preparation_rate: Option<u64>,
    pub preparation_eta_ms: Option<u64>,
    pub scanned_items: u64,
    pub work_items: u64,
    pub active: bool,
    pub mapped_items: u64,
    pub compared_items: u64,
    pub phase_scanned_items: u64,
    pub phase_mapped_items: u64,
    pub phase_compared_items: u64,
    pub total_scanned_items: Option<u64>,
    pub total_mapped_items: Option<u64>,
    pub total_compared_items: Option<u64>,
    pub verified_bytes: u64,
    pub total_verified_bytes: Option<u64>,
    pub verified_files: u64,
    pub total_verified_files: Option<u64>,
    pub current_verify_file: Option<u64>,
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
    preparation: Mutex<Option<PreparationProgress>>,
    stage: AtomicU8,
    scanned: AtomicU64,
    phase_scanned: AtomicU64,
    items: AtomicU64,
    active: AtomicU64,
    mapped: AtomicU64,
    phase_mapped: AtomicU64,
    compared: AtomicU64,
    phase_compared: AtomicU64,
    total_scanned: AtomicU64,
    total_mapped: AtomicU64,
    total_compared: AtomicU64,
    total_scanned_known: AtomicBool,
    total_mapped_known: AtomicBool,
    total_compared_known: AtomicBool,
    scan_started: Mutex<Option<Instant>>,
    compare_started: Mutex<Option<Instant>>,
    verified_bytes: AtomicU64,
    total_verified_bytes: AtomicU64,
    total_verified_bytes_known: AtomicBool,
    verified_files: AtomicU64,
    total_verified_files: AtomicU64,
    total_verified_files_known: AtomicBool,
    current_verify_file: AtomicU64,
    verify_started: Mutex<Option<Instant>>,
    backup_phase: AtomicU8,
    backup_completed: AtomicU64,
    #[cfg(test)]
    backup_observer: std::sync::Mutex<Option<test_observer::Observer>>,
}

pub(crate) struct WorkScope(Arc<Counters>);
impl Drop for WorkScope {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::Release);
    }
}

pub(crate) struct PreparationBytes {
    completed: AtomicU64,
    #[cfg(test)]
    limit: u64,
}

impl PreparationBytes {
    pub(crate) fn new(_limit: u64) -> Arc<Self> {
        Arc::new(Self {
            completed: AtomicU64::new(0),
            #[cfg(test)]
            limit: _limit,
        })
    }

    pub(crate) fn completed(&self) -> u64 {
        self.completed.load(Ordering::Acquire)
    }

    #[cfg(test)]
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
    pub(crate) sync_session: Option<uuid::Uuid>,
    pub(crate) validation: super::validation::ValidationMetrics,
}

impl WorkControl {
    pub fn new(cancel: CancellationToken) -> Self {
        Self {
            cancel,
            counters: Arc::default(),
            preparation: None,
            sync_session: None,
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
            sync_session: self.sync_session,
            validation: self.validation.clone(),
        }
    }
    pub(crate) fn with_preparation(&self, progress: Arc<PreparationBytes>) -> Self {
        Self {
            preparation: Some(progress),
            ..self.clone()
        }
    }
    #[cfg(test)]
    pub(crate) fn preparation_read(&self, bytes: u64) -> CoreResult<()> {
        self.check()?;
        if let Some(progress) = &self.preparation {
            progress.add(bytes)?;
        }
        Ok(())
    }
    pub(crate) fn with_sync_session(&self, session: uuid::Uuid) -> Self {
        Self {
            sync_session: Some(session),
            ..self.clone()
        }
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
    pub(crate) fn set_preparation_phase(&self, phase: PreparationStage, total: Option<u64>) {
        let mut progress = self
            .counters
            .preparation
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        *progress = Some(PreparationProgress {
            phase,
            processed: 0,
            total,
            started: Instant::now(),
        });
        drop(progress);
        super::diagnostics::measurement(&format!(
            "preparation_phase={phase:?} total_items={}",
            total.map_or_else(|| "unknown".into(), |total| total.to_string())
        ));
    }
    pub(crate) fn preparation_item_completed(&self) {
        let mut progress = self
            .counters
            .preparation
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if let Some(progress) = progress.as_mut() {
            progress.processed = progress.processed.saturating_add(1);
        }
    }
    pub(crate) fn set_total(&self, stage: WorkStage, total: u64) {
        let (target, known) = match stage {
            WorkStage::Scanning => (
                &self.counters.total_scanned,
                &self.counters.total_scanned_known,
            ),
            WorkStage::Mapping => (
                &self.counters.total_mapped,
                &self.counters.total_mapped_known,
            ),
            WorkStage::Comparing => (
                &self.counters.total_compared,
                &self.counters.total_compared_known,
            ),
            _ => return,
        };
        target.store(total, Ordering::Release);
        known.store(true, Ordering::Release);
        {
            let mut progress = self
                .counters
                .preparation
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            if let Some(progress) = progress.as_mut() {
                if matches!(
                    (stage, progress.phase),
                    (WorkStage::Scanning, PreparationStage::ReadingLibrary)
                        | (WorkStage::Comparing, PreparationStage::ComparingRecords)
                ) {
                    progress.processed = 0;
                    progress.total = Some(total);
                    progress.started = Instant::now();
                }
            }
        }
        match stage {
            WorkStage::Scanning => self.counters.phase_scanned.store(0, Ordering::Release),
            WorkStage::Mapping => self.counters.phase_mapped.store(0, Ordering::Release),
            WorkStage::Comparing => self.counters.phase_compared.store(0, Ordering::Release),
            _ => {}
        }
        let started = match stage {
            WorkStage::Scanning => &self.counters.scan_started,
            WorkStage::Comparing => &self.counters.compare_started,
            _ => return,
        };
        let mut started = started.lock().unwrap_or_else(|error| error.into_inner());
        *started = Some(Instant::now());
    }
    pub(crate) fn estimate_progress(
        &self,
        stage: WorkStage,
        completed: u64,
        total: u64,
    ) -> Option<(u64, u64)> {
        let started = match stage {
            WorkStage::Scanning => &self.counters.scan_started,
            WorkStage::Comparing => &self.counters.compare_started,
            _ => return None,
        };
        let started = started.lock().unwrap_or_else(|error| error.into_inner());
        let started = started.as_ref().copied()?;
        let elapsed_ms = started.elapsed().as_millis().try_into().ok()?;
        estimate_rate_and_remaining(completed, total, elapsed_ms)
    }
    pub(crate) fn begin_verification(&self, total_bytes: u64, total_files: u64) {
        self.counters.verified_bytes.store(0, Ordering::Release);
        self.counters.verified_files.store(0, Ordering::Release);
        self.counters
            .current_verify_file
            .store(0, Ordering::Release);
        self.counters
            .total_verified_bytes
            .store(total_bytes, Ordering::Release);
        self.counters
            .total_verified_files
            .store(total_files, Ordering::Release);
        self.counters
            .total_verified_bytes_known
            .store(true, Ordering::Release);
        self.counters
            .total_verified_files_known
            .store(true, Ordering::Release);
        *self
            .counters
            .verify_started
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = Some(Instant::now());
    }
    pub(crate) fn verification_progress(
        &self,
        completed_bytes: u64,
        completed_files: u64,
        current_file: Option<u64>,
    ) {
        self.counters
            .verified_bytes
            .store(completed_bytes, Ordering::Release);
        self.counters
            .verified_files
            .store(completed_files, Ordering::Release);
        self.counters
            .current_verify_file
            .store(current_file.unwrap_or(0), Ordering::Release);
    }
    pub(crate) fn estimate_verification(&self) -> Option<(u64, u64)> {
        let started = self
            .counters
            .verify_started
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let elapsed_ms = started.as_ref()?.elapsed().as_millis().try_into().ok()?;
        estimate_rate_and_remaining(
            self.counters.verified_bytes.load(Ordering::Acquire),
            self.counters.total_verified_bytes.load(Ordering::Acquire),
            elapsed_ms,
        )
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
            self.counters
                .phase_scanned
                .fetch_add(completed as u64, Ordering::Relaxed);
        }
        if stage == WorkStage::Mapping {
            self.counters
                .mapped
                .fetch_add(completed as u64, Ordering::Relaxed);
            self.counters
                .phase_mapped
                .fetch_add(completed as u64, Ordering::Relaxed);
        }
        if stage == WorkStage::Comparing {
            self.counters
                .compared
                .fetch_add(completed as u64, Ordering::Relaxed);
            self.counters
                .phase_compared
                .fetch_add(completed as u64, Ordering::Relaxed);
        }
        {
            let mut progress = self
                .counters
                .preparation
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            if let Some(progress) = progress.as_mut() {
                if matches!(
                    (stage, progress.phase),
                    (WorkStage::Scanning, PreparationStage::ReadingLibrary)
                        | (WorkStage::Comparing, PreparationStage::ComparingRecords)
                ) {
                    progress.processed = progress.processed.saturating_add(completed as u64);
                }
            }
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
        let progress = self
            .counters
            .preparation
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let estimate = progress.as_ref().and_then(|progress| {
            let total = progress.total?;
            if progress.processed >= total {
                return None;
            }
            estimate_rate_and_remaining(
                progress.processed,
                total,
                progress.started.elapsed().as_millis().try_into().ok()?,
            )
        });
        WorkObservation {
            preparation_phase: progress.as_ref().map(|progress| progress.phase),
            preparation_processed_items: progress.as_ref().map_or(0, |progress| progress.processed),
            preparation_total_items: progress.as_ref().and_then(|progress| progress.total),
            preparation_rate: estimate.map(|(rate, _)| rate),
            preparation_eta_ms: estimate.map(|(_, eta)| eta),
            stage: if active { stage } else { WorkStage::Idle },
            scanned_items: self.counters.scanned.load(Ordering::Relaxed),
            work_items: self.counters.items.load(Ordering::Relaxed),
            active,
            mapped_items: self.counters.mapped.load(Ordering::Relaxed),
            compared_items: self.counters.compared.load(Ordering::Relaxed),
            phase_scanned_items: self.counters.phase_scanned.load(Ordering::Relaxed),
            phase_mapped_items: self.counters.phase_mapped.load(Ordering::Relaxed),
            phase_compared_items: self.counters.phase_compared.load(Ordering::Relaxed),
            total_scanned_items: known(
                self.counters.total_scanned_known.load(Ordering::Acquire),
                self.counters.total_scanned.load(Ordering::Acquire),
            ),
            total_mapped_items: known(
                self.counters.total_mapped_known.load(Ordering::Acquire),
                self.counters.total_mapped.load(Ordering::Acquire),
            ),
            total_compared_items: known(
                self.counters.total_compared_known.load(Ordering::Acquire),
                self.counters.total_compared.load(Ordering::Acquire),
            ),
            verified_bytes: self.counters.verified_bytes.load(Ordering::Acquire),
            total_verified_bytes: known(
                self.counters
                    .total_verified_bytes_known
                    .load(Ordering::Acquire),
                self.counters.total_verified_bytes.load(Ordering::Acquire),
            ),
            verified_files: self.counters.verified_files.load(Ordering::Acquire),
            total_verified_files: known(
                self.counters
                    .total_verified_files_known
                    .load(Ordering::Acquire),
                self.counters.total_verified_files.load(Ordering::Acquire),
            ),
            current_verify_file: match self.counters.current_verify_file.load(Ordering::Acquire) {
                0 => None,
                index => Some(index),
            },
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

fn known(is_known: bool, value: u64) -> Option<u64> {
    is_known.then_some(value)
}

fn estimate_rate_and_remaining(completed: u64, total: u64, elapsed_ms: u64) -> Option<(u64, u64)> {
    if elapsed_ms == 0 {
        return None;
    }
    if total == 0 {
        return Some((0, 0));
    }
    if completed == 0 {
        return None;
    }
    let rate = u64::try_from(u128::from(completed) * 1000 / u128::from(elapsed_ms)).ok()?;
    if rate == 0 {
        return None;
    }
    let remaining = total.saturating_sub(completed);
    let eta_ms = u64::try_from(u128::from(remaining) * 1000 / u128::from(rate)).ok()?;
    Some((rate, eta_ms))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preparation_phase_changes_reset_counts_and_do_not_reuse_an_old_eta() {
        let work = WorkControl::default();
        work.set_preparation_phase(PreparationStage::ComparingRecords, Some(897));
        work.checkpoint(WorkStage::Comparing, 897).unwrap();
        work.set_preparation_phase(PreparationStage::CheckingCache, Some(10));
        work.preparation_item_completed();
        let checking = work.observe();
        assert_eq!(checking.preparation_processed_items, 1);
        assert_eq!(checking.preparation_total_items, Some(10));
        work.set_preparation_phase(PreparationStage::CheckingSpace, None);
        let space = work.observe();
        assert_eq!(
            space.preparation_phase,
            Some(PreparationStage::CheckingSpace)
        );
        assert_eq!(space.preparation_processed_items, 0);
        assert_eq!(space.preparation_total_items, None);
        assert_eq!(space.preparation_rate, None);
        assert_eq!(space.preparation_eta_ms, None);
    }

    #[test]
    fn repeated_phase_totals_reset_counters_and_preserve_empty_totals() {
        let work = WorkControl::default();
        work.set_total(WorkStage::Scanning, 10);
        work.checkpoint(WorkStage::Scanning, 7).unwrap();
        work.set_total(WorkStage::Scanning, 5);
        work.checkpoint(WorkStage::Scanning, 2).unwrap();
        work.set_total(WorkStage::Comparing, 8);
        work.checkpoint(WorkStage::Comparing, 6).unwrap();
        work.set_total(WorkStage::Comparing, 3);
        work.checkpoint(WorkStage::Comparing, 1).unwrap();
        work.set_total(WorkStage::Comparing, 0);

        let observed = work.observe();
        assert_eq!(observed.scanned_items, 9);
        assert_eq!(observed.phase_scanned_items, 2);
        assert_eq!(observed.total_scanned_items, Some(5));
        assert_eq!(observed.compared_items, 7);
        assert_eq!(observed.phase_compared_items, 0);
        assert_eq!(observed.total_compared_items, Some(0));
        assert_eq!(observed.total_mapped_items, None);
    }

    #[test]
    fn progress_estimate_uses_observed_work_and_never_divides_by_zero() {
        assert_eq!(
            estimate_rate_and_remaining(20, 100, 5000),
            Some((4, 20_000))
        );
        assert_eq!(estimate_rate_and_remaining(0, 100, 5000), None);
        assert_eq!(estimate_rate_and_remaining(1, 100, 0), None);
        assert_eq!(estimate_rate_and_remaining(0, 0, 5000), Some((0, 0)));
    }

    #[test]
    fn verification_progress_keeps_only_bounded_ordinals_and_real_totals() {
        let work = WorkControl::default();
        work.begin_verification(4096, 3);
        work.verification_progress(1024, 0, Some(1));
        let observation = work.observe();
        assert_eq!(observation.verified_bytes, 1024);
        assert_eq!(observation.total_verified_bytes, Some(4096));
        assert_eq!(observation.verified_files, 0);
        assert_eq!(observation.total_verified_files, Some(3));
        assert_eq!(observation.current_verify_file, Some(1));
    }
}
