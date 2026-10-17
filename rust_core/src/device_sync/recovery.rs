//! Explicit interrupted-operation compensation and user-selected backup restore.
use std::sync::Arc;

use uuid::Uuid;

use super::library_guard::{ExclusiveLease, RecoveryLease};
use super::receiver::{CommitGuard, ReceiverError, ReceiverResult, Snapshot};
use super::work::WorkControl;
use crate::database::Database;
use crate::sync::CancellationToken;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JournalStage {
    Prepared,
    LibraryApplied,
    RolledBack,
    Finalized,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JournalEntry {
    pub operation_uuid: Uuid,
    pub library_uuid: String,
    pub stage: JournalStage,
    pub backup_uuid: Uuid,
    pub preview_digest: String,
    pub external_reference: Option<Uuid>,
}

pub(crate) enum RecoveryAccess {
    New(ExclusiveLease),
    Pending(RecoveryLease, Uuid),
}

pub struct RecoveryAuthorization {
    operation: Uuid,
    binding: String,
    used: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreReceipt {
    pub operation_uuid: Uuid,
    /// The state before this restore, available for another explicit restore.
    pub backup_uuid: Uuid,
    pub compensated_operation: Option<Uuid>,
}

pub struct RecoveryOperation {
    database: Arc<Database>,
    operation: Uuid,
    backup: Uuid,
    pending: Option<JournalEntry>,
    current: Snapshot,
    restored: Snapshot,
    ownership: Option<(JournalEntry, String)>,
    local_name: String,
    issued: bool,
    finished: bool,
    work: WorkControl,
}

impl RecoveryOperation {
    pub fn preview_backup(
        database: Arc<Database>,
        backup: Uuid,
        local_name: &str,
    ) -> ReceiverResult<Self> {
        Self::preview_backup_controlled(database, backup, local_name, &WorkControl::default())
    }

    pub fn preview_backup_controlled(
        database: Arc<Database>,
        backup: Uuid,
        local_name: &str,
        work: &WorkControl,
    ) -> ReceiverResult<Self> {
        work.check()?;
        let lease = database.device_sync_exclusive()?;
        let ownership = database.device_sync_restore_proof(backup, work)?;
        let current = Snapshot::read_with_header_controlled(
            &database,
            database.device_sync_header()?,
            Some(local_name),
            work,
        )?;
        let restored = database.receiver_backup_snapshot_controlled(backup, work)?;
        work.check()?;
        drop(lease);
        Ok(Self {
            database,
            operation: Uuid::new_v4(),
            backup,
            pending: None,
            current,
            restored,
            ownership: Some(ownership),
            local_name: local_name.into(),
            issued: false,
            finished: false,
            work: work.clone(),
        })
    }

    pub fn preview_pending(
        database: Arc<Database>,
        operation: Uuid,
        local_name: &str,
    ) -> ReceiverResult<Self> {
        Self::preview_pending_controlled(database, operation, local_name, &WorkControl::default())
    }

    pub fn preview_pending_controlled(
        database: Arc<Database>,
        operation: Uuid,
        local_name: &str,
        work: &WorkControl,
    ) -> ReceiverResult<Self> {
        work.check()?;
        let lease = database.receiver_recovery_lease_controlled(operation, work)?;
        work.check()?;
        let entry = database
            .device_sync_journal(operation)?
            .ok_or(ReceiverError::InvalidState)?;
        let current = Snapshot::read_with_header_controlled(
            &database,
            database.device_sync_header()?,
            Some(local_name),
            work,
        )?;
        work.check()?;
        let restored = database.receiver_backup_snapshot_controlled(entry.backup_uuid, work)?;
        work.check()?;
        drop(lease);
        Ok(Self {
            database,
            operation,
            backup: entry.backup_uuid,
            pending: Some(entry),
            current,
            restored,
            ownership: None,
            local_name: local_name.into(),
            issued: false,
            finished: false,
            work: work.clone(),
        })
    }

    pub fn current(&self) -> &Snapshot {
        &self.current
    }
    pub fn restored(&self) -> &Snapshot {
        &self.restored
    }
    pub fn pending(&self) -> Option<&JournalEntry> {
        self.pending.as_ref()
    }
    pub fn operation_id(&self) -> Uuid {
        self.operation
    }

    pub fn preview_binding(&self) -> crate::error::CoreResult<String> {
        self.binding()
    }

    pub fn validate_preview(&self) -> ReceiverResult<()> {
        if self.finished || self.issued {
            return Err(ReceiverError::AuthorizationMismatch);
        }
        let _access = self.access(&self.work.cancellation())?;
        Ok(())
    }

    fn binding(&self) -> crate::error::CoreResult<String> {
        self.work.digest_json(&(
            1_u32,
            self.operation,
            self.backup,
            self.current.digest_controlled(&self.work)?,
            self.restored.digest_controlled(&self.work)?,
            self.ownership.as_ref().map(|(_, proof)| proof),
        ))
    }

    pub fn authorize(&mut self) -> ReceiverResult<RecoveryAuthorization> {
        if self.issued || self.finished {
            return Err(ReceiverError::InvalidState);
        }
        self.issued = true;
        Ok(RecoveryAuthorization {
            operation: self.operation,
            binding: self.binding()?,
            used: false,
        })
    }

    fn consume(&mut self, authorization: Option<&mut RecoveryAuthorization>) -> ReceiverResult<()> {
        let authorization = authorization.ok_or(ReceiverError::AuthorizationRequired)?;
        if self.finished || authorization.used || authorization.operation != self.operation {
            return Err(ReceiverError::AuthorizationMismatch);
        }
        authorization.used = true;
        if authorization.binding != self.binding()? {
            return Err(ReceiverError::AuthorizationMismatch);
        }
        self.finished = true;
        Ok(())
    }

    fn access(&self, cancel: &CancellationToken) -> ReceiverResult<RecoveryAccess> {
        let work = self.work.with_cancellation(cancel.clone());
        work.check()?;
        let access = if self.pending.is_some() {
            RecoveryAccess::Pending(
                self.database
                    .receiver_recovery_lease_controlled(self.operation, &work)?,
                self.operation,
            )
        } else {
            RecoveryAccess::New(self.database.device_sync_exclusive()?)
        };
        if let Some(expected) = &self.ownership {
            let actual = self
                .database
                .device_sync_restore_proof(self.backup, &work)
                .map_err(|error| match error {
                    crate::error::CoreError::Cancelled => ReceiverError::Core(error),
                    _ => ReceiverError::PlanChanged,
                })?;
            if &actual != expected {
                return Err(ReceiverError::PlanChanged);
            }
        }
        work.check()?;
        let current = Snapshot::read_with_header_controlled(
            &self.database,
            self.current.manifest.header.clone(),
            Some(&self.local_name),
            &work,
        )
        .map_err(|error| match error {
            crate::error::CoreError::Cancelled => ReceiverError::Core(error),
            _ => ReceiverError::PlanChanged,
        })?;
        if current.digest_controlled(&work)? != self.current.digest_controlled(&work)? {
            return Err(ReceiverError::PlanChanged);
        }
        work.check()?;
        if self
            .database
            .receiver_backup_snapshot_controlled(self.backup, &work)?
            != self.restored
        {
            return Err(ReceiverError::PlanChanged);
        }
        work.check()?;
        Ok(access)
    }

    pub fn restore(
        &mut self,
        authorization: Option<&mut RecoveryAuthorization>,
        cancel: &CancellationToken,
    ) -> ReceiverResult<RestoreReceipt> {
        self.restore_with_external(authorization, None, cancel)
    }

    /// User-selected account backups remain pending until their secure-store
    /// coordinator finishes; interrupted-operation compensation stays offline.
    pub fn restore_with_external(
        &mut self,
        authorization: Option<&mut RecoveryAuthorization>,
        external: Option<Uuid>,
        cancel: &CancellationToken,
    ) -> ReceiverResult<RestoreReceipt> {
        if external.is_some_and(|id| id.is_nil()) || (external.is_some() && self.pending.is_some())
        {
            return Err(ReceiverError::InvalidState);
        }
        if self.ownership.as_ref().is_some_and(|(ownership, _)| {
            ownership.external_reference.is_some() != external.is_some()
        }) {
            return Err(ReceiverError::AuthorizationMismatch);
        }
        self.consume(authorization)?;
        cancel.check()?;
        let access = self.access(cancel)?;
        let work = self.work.with_cancellation(cancel.clone());
        let backup = self.database.receiver_restore(
            &access,
            self.operation,
            self.backup,
            &self.current,
            &self.binding()?,
            &work,
            external,
        )?;
        Ok(RestoreReceipt {
            operation_uuid: self.operation,
            backup_uuid: backup,
            compensated_operation: self.pending.as_ref().map(|e| e.operation_uuid),
        })
    }

    /// The supplied reference acknowledges that the external coordinator has
    /// completed. This API does not perform or claim secure-storage work.
    pub fn finalize(
        &mut self,
        authorization: Option<&mut RecoveryAuthorization>,
        external: Option<Uuid>,
    ) -> ReceiverResult<()> {
        self.finalize_guarded(authorization, external, &CancellationToken::default(), None)
    }

    pub fn finalize_guarded(
        &mut self,
        authorization: Option<&mut RecoveryAuthorization>,
        external: Option<Uuid>,
        cancel: &CancellationToken,
        guard: Option<Arc<dyn CommitGuard>>,
    ) -> ReceiverResult<()> {
        cancel.check()?;
        if let Some(guard) = &guard {
            guard.check()?;
        }
        self.consume(authorization)?;
        cancel.check()?;
        if let Some(guard) = &guard {
            guard.check()?;
        }
        let entry = self.pending.as_ref().ok_or(ReceiverError::InvalidState)?;
        if entry.stage != JournalStage::LibraryApplied || entry.external_reference != external {
            return Err(ReceiverError::AuthorizationMismatch);
        }
        let access = self.access(cancel)?;
        cancel.check()?;
        if let Some(guard) = &guard {
            guard.check()?;
        }
        self.database.receiver_finalize_recovery(
            &access,
            self.operation,
            external,
            cancel,
            guard,
        )?;
        Ok(())
    }
}
