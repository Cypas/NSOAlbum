//! Locally authorized receiver orchestration. SQL remains in database.rs.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::diagnostics::{self, Boundary};
use super::manifest::{Manifest, ManifestCollector, ManifestHeader};
use super::planner::{SyncMode, SyncPlan};
use super::source_names::{SourceDescription, SourceDescriptions};
use super::staging::{Progress, StagingError, StagingOperation};
use crate::database::Database;
use crate::error::{CoreError, CoreResult};
use crate::sync::CancellationToken;

#[derive(Debug, thiserror::Error)]
pub enum ReceiverError {
    #[error("local preview confirmation is required")]
    AuthorizationRequired,
    #[error("local preview confirmation was consumed or does not match")]
    AuthorizationMismatch,
    #[error("the confirmed library or plan changed")]
    PlanChanged,
    #[error("receiver operation is no longer active")]
    InvalidState,
    #[error(transparent)]
    Core(#[from] CoreError),
    #[error(transparent)]
    Staging(#[from] StagingError),
}

pub type ReceiverResult<T> = Result<T, ReceiverError>;

/// Local runtime validity, additional to (never a replacement for) confirmation.
pub trait CommitGuard: Send + Sync {
    fn check(&self) -> CoreResult<()>;
    fn sql_started(&self) {}
    fn sql_progress(&self) {}
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub manifest: Manifest,
    pub sources: SourceDescriptions,
}

pub struct RetainedSourceSnapshot {
    snapshot: Snapshot,
    originals: super::library_guard::SourceSnapshotLease,
}

impl RetainedSourceSnapshot {
    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }
    pub fn originals(&self) -> &[super::library_guard::OriginalIdentity] {
        self.originals.originals()
    }
}

impl Snapshot {
    pub fn read(database: &Database, local_name: &str) -> CoreResult<Self> {
        Self::read_controlled(database, local_name, &super::work::WorkControl::default())
    }
    pub fn read_controlled(
        database: &Database,
        local_name: &str,
        work: &super::work::WorkControl,
    ) -> CoreResult<Self> {
        work.check()?;
        let _lease = database
            .device_sync_exclusive()
            .inspect_err(|error| diagnostics::core(Boundary::SnapshotLease, error))?;
        Self::read_with_header_controlled(
            database,
            database
                .device_sync_header()
                .inspect_err(|error| diagnostics::core(Boundary::SnapshotHeader, error))?,
            Some(local_name),
            work,
        )
    }

    pub fn retain(database: &Database, local_name: &str) -> CoreResult<RetainedSourceSnapshot> {
        Self::retain_controlled(database, local_name, &super::work::WorkControl::default())
    }
    pub fn retain_controlled(
        database: &Database,
        local_name: &str,
        work: &super::work::WorkControl,
    ) -> CoreResult<RetainedSourceSnapshot> {
        let _scope = work.begin(super::work::WorkStage::Scanning)?;
        work.check()?;
        let lease = database.device_sync_exclusive()?;
        let snapshot = Self::read_with_header_controlled(
            database,
            database.device_sync_header()?,
            Some(local_name),
            work,
        )?;
        let (_, root) = database.device_sync_file_roots()?;
        let originals = database.device_sync_retain_source_controlled(&lease, &root, work)?;
        work.check()?;
        Ok(RetainedSourceSnapshot {
            snapshot,
            originals,
        })
    }

    #[allow(dead_code)] // Default-control compatibility entry for recovery callers.
    pub(crate) fn read_with_header(
        database: &Database,
        header: ManifestHeader,
        local_name: Option<&str>,
    ) -> CoreResult<Self> {
        Self::read_with_header_controlled(
            database,
            header,
            local_name,
            &super::work::WorkControl::default(),
        )
    }

    pub(crate) fn read_with_header_controlled(
        database: &Database,
        header: ManifestHeader,
        local_name: Option<&str>,
        work: &super::work::WorkControl,
    ) -> CoreResult<Self> {
        let _scope = work.begin(super::work::WorkStage::Scanning)?;
        work.checkpoint(super::work::WorkStage::Scanning, 0)?;
        let mut collector = ManifestCollector::with_control(header.clone(), work.clone())
            .inspect_err(|error| diagnostics::core(Boundary::SnapshotCollector, error))?;
        let mut cursor = None;
        loop {
            let page = database
                .device_sync_manifest_page_controlled(&header, cursor.as_ref(), 128, work)
                .inspect_err(|error| diagnostics::core(Boundary::SnapshotPage, error))?;
            work.checkpoint(super::work::WorkStage::Scanning, page.records.len())?;
            cursor = page.next.clone();
            collector
                .push(page)
                .inspect_err(|error| diagnostics::core(Boundary::SnapshotCollector, error))?;
            if cursor.is_none() {
                break;
            }
        }
        let manifest = collector
            .finish()
            .inspect_err(|error| diagnostics::core(Boundary::SnapshotCollector, error))?;
        let mut known = database
            .device_sync_source_names_controlled(work)
            .inspect_err(|error| diagnostics::core(Boundary::SnapshotSources, error))?;
        if let Some(name) = local_name {
            known.retain(|e| e.library_uuid != header.library_uuid);
            known.push(
                SourceDescription::new(header.library_uuid, name.into())
                    .inspect_err(|error| diagnostics::core(Boundary::SnapshotSources, error))?,
            );
        }
        let sources = SourceDescriptions::filtered_controlled(&manifest, known, work)
            .inspect_err(|error| diagnostics::core(Boundary::SnapshotFilter, error))?;
        work.checkpoint(super::work::WorkStage::FinalCheck, 0)?;
        let current = database
            .device_sync_header()
            .inspect_err(|error| diagnostics::core(Boundary::SnapshotFinalHeader, error))?;
        if current.library_uuid != manifest.header.library_uuid
            || current.generation != manifest.header.generation
        {
            let error = CoreError::InvalidConfig("device-sync snapshot changed".into());
            diagnostics::core(Boundary::SnapshotGenerationChanged, &error);
            return Err(error);
        }
        work.check()?;
        Ok(Self { manifest, sources })
    }

    pub fn validate(&self) -> CoreResult<()> {
        self.validate_controlled(&super::work::WorkControl::default())
    }

    pub fn validate_controlled(&self, work: &super::work::WorkControl) -> CoreResult<()> {
        self.sources.validate_controlled(&self.manifest, work)
    }

    pub(crate) fn digest(&self) -> CoreResult<String> {
        self.digest_controlled(&super::work::WorkControl::default())
    }
    pub(crate) fn digest_controlled(&self, work: &super::work::WorkControl) -> CoreResult<String> {
        Ok(hex::encode(Sha256::digest(
            format!(
                "{}:{}",
                self.manifest.validate_controlled(work)?.digest,
                self.sources.digest_controlled(&self.manifest, work)?,
            )
            .as_bytes(),
        )))
    }
}

/// Deliberately neither Clone nor serializable, and has no public constructor.
pub struct LocalAuthorization {
    operation: Uuid,
    binding: String,
    used: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyState {
    LibraryAppliedPending,
    Finalized,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApplyReceipt {
    pub operation_uuid: Uuid,
    pub backup_uuid: Uuid,
    pub state: ApplyState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyBoundary {
    Prepared,
    LibraryApplied,
    Finalized,
}

pub struct ReceiveOperation {
    database: Arc<Database>,
    source: Snapshot,
    target: Snapshot,
    local_name: String,
    plan: SyncPlan,
    staging: StagingOperation,
    authorization_issued: bool,
    finished: bool,
    work: super::work::WorkControl,
    receiver_budget: super::space_budget::ReceiverBudgetView,
}

impl ReceiveOperation {
    pub fn prepare(
        database: Arc<Database>,
        source: Snapshot,
        local_name: &str,
        mode: SyncMode,
    ) -> ReceiverResult<Self> {
        Self::prepare_with_clock(database, source, local_name, mode, None)
    }

    pub fn prepare_with_clock(
        database: Arc<Database>,
        source: Snapshot,
        local_name: &str,
        mode: SyncMode,
        clock: Option<super::clock::ClockTrust>,
    ) -> ReceiverResult<Self> {
        Self::prepare_controlled(
            database,
            source,
            local_name,
            mode,
            clock,
            &super::work::WorkControl::default(),
        )
    }
    pub fn prepare_controlled(
        database: Arc<Database>,
        source: Snapshot,
        local_name: &str,
        mode: SyncMode,
        clock: Option<super::clock::ClockTrust>,
        work: &super::work::WorkControl,
    ) -> ReceiverResult<Self> {
        source
            .sources
            .validate_controlled(&source.manifest, work)
            .inspect_err(|error| diagnostics::core(Boundary::ReceiverSourceValidation, error))?;
        let target = Snapshot::read_controlled(&database, local_name, work)
            .inspect_err(|error| diagnostics::core(Boundary::TargetSnapshot, error))?;
        let plan = super::planner::build_plan_controlled(
            &source.manifest,
            &target.manifest,
            mode,
            clock,
            work,
        )
        .inspect_err(|error| diagnostics::core(Boundary::ReceiverPlan, error))?;
        let staging = StagingOperation::prepare_controlled(
            database.clone(),
            &source.manifest,
            &target.manifest,
            &plan,
            work,
        )
        .inspect_err(|error| {
            diagnostics::receiver(Boundary::ReceiverStaging, &ReceiverError::Staging(*error))
        })?;
        let metadata = database
            .device_sync_metadata_cost(&target, &plan, work)
            .inspect_err(|error| diagnostics::core(Boundary::ReceiverMetadataCost, error))?;
        let receiver_budget =
            super::space_budget::measure(&staging, metadata, work).inspect_err(|error| {
                diagnostics::receiver(Boundary::ReceiverBudget, &ReceiverError::Staging(*error))
            })?;
        work.check()
            .inspect_err(|error| diagnostics::core(Boundary::ReceiverFinalCheck, error))?;
        Ok(Self {
            database,
            source,
            target,
            local_name: local_name.into(),
            plan,
            staging,
            authorization_issued: false,
            finished: false,
            work: work.clone(),
            receiver_budget,
        })
    }

    pub fn operation_id(&self) -> Uuid {
        self.staging.operation_id()
    }
    pub fn plan(&self) -> &SyncPlan {
        &self.plan
    }
    pub fn target(&self) -> &Snapshot {
        &self.target
    }
    pub fn receiver_budget(&self) -> &super::space_budget::ReceiverBudgetView {
        &self.receiver_budget
    }
    pub fn staging_mut(&mut self) -> &mut StagingOperation {
        &mut self.staging
    }

    fn binding(&self) -> CoreResult<String> {
        self.work.digest_json(&(
            1_u32,
            self.operation_id(),
            self.source.digest_controlled(&self.work)?,
            self.target.digest_controlled(&self.work)?,
            &self.plan,
        ))
    }

    pub fn authorize(&mut self) -> ReceiverResult<LocalAuthorization> {
        if self.authorization_issued || self.finished {
            return Err(ReceiverError::InvalidState);
        }
        self.authorization_issued = true;
        Ok(LocalAuthorization {
            operation: self.operation_id(),
            binding: self.binding()?,
            used: false,
        })
    }

    pub fn apply(
        &mut self,
        authorization: Option<&mut LocalAuthorization>,
        external_reference: Option<Uuid>,
        cancel: &CancellationToken,
        observer: &mut impl FnMut(ApplyBoundary),
    ) -> ReceiverResult<ApplyReceipt> {
        self.apply_with_file_progress(
            authorization,
            external_reference,
            cancel,
            observer,
            &mut |_| {},
        )
    }

    pub fn apply_with_file_progress(
        &mut self,
        authorization: Option<&mut LocalAuthorization>,
        external_reference: Option<Uuid>,
        cancel: &CancellationToken,
        observer: &mut impl FnMut(ApplyBoundary),
        file_observer: &mut impl FnMut(Progress),
    ) -> ReceiverResult<ApplyReceipt> {
        self.apply_guarded(
            authorization,
            external_reference,
            cancel,
            observer,
            file_observer,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn apply_guarded(
        &mut self,
        authorization: Option<&mut LocalAuthorization>,
        external_reference: Option<Uuid>,
        cancel: &CancellationToken,
        observer: &mut impl FnMut(ApplyBoundary),
        file_observer: &mut impl FnMut(Progress),
        guard: Option<Arc<dyn CommitGuard>>,
    ) -> ReceiverResult<ApplyReceipt> {
        let authorization = authorization.ok_or(ReceiverError::AuthorizationRequired)?;
        if authorization.used || authorization.operation != self.operation_id() {
            return Err(ReceiverError::AuthorizationMismatch);
        }
        authorization.used = true;
        if self.finished || authorization.binding != self.binding()? {
            return Err(ReceiverError::AuthorizationMismatch);
        }
        cancel.check()?;
        if let Some(guard) = &guard {
            guard.check()?;
        }
        let database = self.database.clone();
        let work = self.work.with_cancellation(cancel.clone());
        let lease = database.device_sync_exclusive()?;
        // Preserve the approved clock sample; only persistent contents are reread.
        let current = Snapshot::read_with_header_controlled(
            &database,
            self.target.manifest.header.clone(),
            Some(&self.local_name),
            &work,
        )
        .map_err(|error| {
            if matches!(error, CoreError::Cancelled) {
                ReceiverError::Core(error)
            } else {
                ReceiverError::PlanChanged
            }
        })?;
        work.checkpoint(super::work::WorkStage::FinalCheck, 0)?;
        if current.digest_controlled(&work)? != self.target.digest_controlled(&work)? {
            return Err(ReceiverError::PlanChanged);
        }
        self.plan
            .verify_controlled(&self.source.manifest, &current.manifest, &work)
            .map_err(|error| {
                if matches!(error, CoreError::Cancelled) {
                    ReceiverError::Core(error)
                } else {
                    ReceiverError::PlanChanged
                }
            })?;
        self.receiver_budget = super::space_budget::measure(
            &self.staging,
            database.device_sync_metadata_cost(&current, &self.plan, &work)?,
            &work,
        )?;
        let operation = self.operation_id();
        let backup = database.receiver_prepare(
            &lease,
            operation,
            &authorization.binding,
            &current,
            external_reference,
            cancel,
        )?;
        self.finished = true;
        observer(ApplyBoundary::Prepared);
        let mut publications = Vec::new();
        let result = (|| -> ReceiverResult<()> {
            cancel.check()?;
            for decision in &self.plan.media {
                if decision.final_record.is_some() && !decision.reuse_original {
                    publications.push(self.staging.publish(
                        &lease,
                        operation,
                        &decision.sha256,
                        cancel,
                        file_observer,
                    )?);
                }
            }
            cancel.check()?;
            database.receiver_apply(
                &lease,
                operation,
                &self.plan,
                &self.source,
                &current,
                &publications,
                cancel,
                guard.clone(),
            )?;
            Ok(())
        })();
        if let Err(error) = result {
            for publication in publications {
                publication.rollback()?;
            }
            database.receiver_finish_prepared(&lease, operation)?;
            return Err(error);
        }
        for publication in publications {
            publication.commit()?;
        }
        observer(ApplyBoundary::LibraryApplied);
        // A cancellation here is an unresolved journal, never a false success.
        cancel.check()?;
        if let Some(guard) = &guard {
            guard.check()?;
        }
        let state = if external_reference.is_some() {
            ApplyState::LibraryAppliedPending
        } else {
            database.receiver_finalize(&lease, operation)?;
            observer(ApplyBoundary::Finalized);
            ApplyState::Finalized
        };
        Ok(ApplyReceipt {
            operation_uuid: operation,
            backup_uuid: backup,
            state,
        })
    }
}

#[cfg(test)]
#[path = "../../tests/fixtures/receiver_process.rs"]
mod process_tests;
#[cfg(test)]
mod tests;

#[cfg(test)]
#[path = "receiver/fix1_tests.rs"]
mod fix1_tests;
