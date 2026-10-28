//! Private, bounded device-sync file staging. No SQL application or authorization.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{Read, Seek, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::diagnostics::{self, Boundary};
use super::library_guard::{ExclusiveLease, OriginalIdentity, PublicationPin};
use super::manifest::{Manifest, MediaRecord};
use super::planner::SyncPlan;
use crate::database::Database;
use crate::error::CoreError;
use crate::sync::CancellationToken;
use sha2::{Digest, Sha256};

#[cfg(test)]
mod fix1_tests;
pub(crate) mod paths;
#[cfg(test)]
mod retention_tests;
#[cfg(test)]
mod stream_hash_tests;
mod verified_cache;
use paths::OwnedPart;
use verified_cache::{CacheRoot, VerifiedObject};

pub const MAX_CHUNK_BYTES: usize = super::wire::MEDIA_CHUNK;
const CHECKSUM_BUFFER_BYTES: usize = 65_536;
pub const MAX_RECEIVING_FILES: usize = 4;

/// Only exact UUID-owned private parts are removed; never originals or cache.
pub(crate) fn cleanup_interrupted_operation(
    database: &Database,
    operation: uuid::Uuid,
) -> crate::error::CoreResult<()> {
    let (runtime, _) = database.device_sync_file_roots()?;
    let directory = runtime.join(operation.to_string());
    match std::fs::symlink_metadata(&directory) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
        Ok(_) => {}
    }
    let held = paths::HeldDirectory::open(&directory).map_err(core_cleanup_error)?;
    let mut files = Vec::new();
    for entry in std::fs::read_dir(&directory)? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name
            .to_str()
            .ok_or_else(|| core_cleanup_error(StagingError::UnsafePath))?;
        if files.len() >= MAX_RECEIVING_FILES
            || name.len() < 43
            || name.len() > 128
            || !name.is_ascii()
            || !name.ends_with(".part")
            || name.as_bytes()[36] != b'-'
            || uuid::Uuid::parse_str(&name[..36]).is_err()
        {
            return Err(core_cleanup_error(StagingError::UnsafePath));
        }
        let file = paths::open_regular(&entry.path()).map_err(core_cleanup_error)?;
        paths::require_single_link(&file).map_err(core_cleanup_error)?;
        files.push((
            entry.path(),
            paths::FileIdentity::of(&file).map_err(core_cleanup_error)?,
        ));
    }
    for (path, identity) in files {
        held.inspect().map_err(core_cleanup_error)?;
        let file = paths::open_regular(&path).map_err(core_cleanup_error)?;
        if paths::FileIdentity::of(&file).map_err(core_cleanup_error)? != identity {
            return Err(core_cleanup_error(StagingError::UnsafePath));
        }
        drop(file);
        std::fs::remove_file(path)?;
    }
    held.inspect().map_err(core_cleanup_error)?;
    drop(held);
    std::fs::remove_dir(directory)?;
    Ok(())
}

fn core_cleanup_error(_: StagingError) -> crate::error::CoreError {
    crate::error::CoreError::InvalidConfig(
        "interrupted staging cleanup could not be proven safe".into(),
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum StagingError {
    #[error("device-sync file operation is not in the required state")]
    InvalidState,
    #[error("device-sync operation identity does not match")]
    InvalidOperation,
    #[error("media is not part of the prepared device-sync plan")]
    UnknownMedia,
    #[error("device-sync preview or local library changed")]
    PlanChanged,
    #[error("device-sync file declaration is invalid")]
    InvalidPlan,
    #[error("device-sync file path is unsafe")]
    UnsafePath,
    #[error("device-sync staging operation already exists")]
    Conflict,
    #[error("device-sync receiving window is full")]
    ReceivingWindowFull,
    #[error("device-sync file offset is not sequential")]
    Offset,
    #[error("device-sync chunk or file length exceeds its declared boundary")]
    Bounds,
    #[error("device-sync file length does not match")]
    LengthMismatch,
    #[error("device-sync file checksum does not match")]
    ChecksumMismatch,
    #[error("existing local original is not valid")]
    CorruptOriginal,
    #[error("device-sync operation was cancelled")]
    Cancelled,
    #[error("not enough available filesystem space")]
    InsufficientSpace,
    #[error("device-sync byte count overflow")]
    Overflow,
    #[error("local media root belongs to another database")]
    RootOwnership,
    #[error("device-sync publication requires this library's exclusive lease")]
    InvalidLease,
    #[error("local library is busy")]
    LibraryBusy,
    #[error("local original is still referenced")]
    Referenced,
    #[error("device-sync file write failed")]
    Write,
    #[error("device-sync file read failed")]
    Read,
    #[error("device-sync file synchronization failed")]
    Sync,
    #[error("device-sync original publication failed")]
    Publish,
    #[error("device-sync temporary cleanup failed")]
    Cleanup,
    #[error("device-sync original is not committed to the local library")]
    NotCommitted,
    #[error("local library metadata could not be read")]
    Database,
}

pub type StagingResult<T> = Result<T, StagingError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Prepared,
    Receiving,
    Verifying,
    Verified,
    Copying,
    Publishing,
    Published,
    Cancelled,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Progress {
    pub phase: Phase,
    pub completed_bytes: u64,
    pub total_bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpaceRequirements {
    pub staging_bytes: u64,
    pub publication_bytes: u64,
    pub stage_peak_bytes: u64,
    pub media_peak_bytes: u64,
    pub same_volume: bool,
}

impl SpaceRequirements {
    pub fn checked(staging: u64, publication: u64, same_volume: bool) -> StagingResult<Self> {
        Ok(Self {
            staging_bytes: staging,
            publication_bytes: publication,
            stage_peak_bytes: if same_volume {
                staging
                    .checked_add(publication)
                    .ok_or(StagingError::Overflow)?
            } else {
                staging
            },
            media_peak_bytes: publication,
            same_volume,
        })
    }

    pub fn check_available(&self, stage: u64, media: u64) -> StagingResult<()> {
        if stage < self.stage_peak_bytes || media < self.media_peak_bytes {
            Err(StagingError::InsufficientSpace)
        } else {
            Ok(())
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpacePreflight {
    pub requirements: SpaceRequirements,
    pub stage_available_bytes: u64,
    pub media_available_bytes: u64,
    /// A preflight is not a reservation, and omits DB/metadata/allocation overhead.
    pub excludes_metadata_and_filesystem_overhead: bool,
}

pub struct StagingOperation {
    database: Arc<Database>,
    id: uuid::Uuid,
    directory: PathBuf,
    media_root: PathBuf,
    target_uuid: String,
    target_generation: u64,
    entries: BTreeMap<String, Entry>,
    cache: Arc<CacheRoot>,
    progress: Progress,
    space: SpacePreflight,
    state: OperationState,
    receiving: usize,
    validation: super::validation::ValidationMetrics,
}

pub(crate) struct BudgetInputs<'a> {
    pub staging: &'a Path,
    pub originals: &'a Path,
    pub missing: Vec<u64>,
    pub publishing: Vec<u64>,
}

struct Entry {
    record: MediaRecord,
    needs_transfer: bool,
    state: FileState,
    part: Option<OwnedPart>,
    cached: Option<VerifiedObject>,
    written: u64,
    write_stamp: Option<(u64, std::time::SystemTime)>,
}

#[derive(PartialEq, Eq)]
enum FileState {
    Pending,
    Receiving,
    Received,
    Verified,
    Published,
}

#[derive(PartialEq, Eq)]
enum OperationState {
    Active,
    Cancelled,
    Failed,
}

/// An owned publication bound to a live exclusive lease, not an arbitrary path.
/// Drop compensates only originals created by this operation, through reference
/// checking. The caller must retain it until its SQL transaction is resolved.
///
/// ```compile_fail
/// use squid_album_core::device_sync::staging::PublishedOriginal;
/// let value = PublishedOriginal { created: true };
/// ```
///
/// ```compile_fail
/// use std::sync::Arc;
/// use squid_album_core::{database::Database, device_sync::staging::StagingOperation};
/// use squid_album_core::sync::CancellationToken;
/// fn release_too_early(operation: &mut StagingOperation, database: Arc<Database>) {
///     let lease = database.device_sync_exclusive().unwrap();
///     let id = operation.operation_id();
///     let publication = operation.publish(
///         &lease, id, "sha", &CancellationToken::default(), &mut |_| {}
///     ).unwrap();
///     drop(lease);
///     drop(publication);
/// }
/// ```
pub struct PublishedOriginal<'lease> {
    database: Arc<Database>,
    lease: &'lease ExclusiveLease,
    identity: OriginalIdentity,
    pin: PublicationPin,
    created: bool,
}

impl PublishedOriginal<'_> {
    pub fn identity(&self) -> &OriginalIdentity {
        &self.identity
    }

    pub fn created_by_operation(&self) -> bool {
        self.created
    }

    /// True means this operation's unreferenced new original was removed.
    /// False includes reused originals and originals retained by another owner.
    pub fn rollback(mut self) -> StagingResult<bool> {
        let removed = if self.created {
            self.database
                .device_sync_cleanup_published(
                    self.lease,
                    &self.identity.root,
                    &self.identity.path(),
                    self.identity.sha256(),
                    &self.pin,
                )
                .map_err(core_error)?
        } else {
            false
        };
        self.created = false;
        Ok(removed)
    }

    /// Release compensation ownership only after the matching actual DB row
    /// exists. This does not perform or authorize SQL application.
    pub fn commit(mut self) -> StagingResult<()> {
        self.database
            .device_sync_validate_exclusive(self.lease)
            .map_err(|_| StagingError::InvalidLease)?;
        let (path, length) = self
            .database
            .device_sync_original_path(self.identity.sha256())
            .map_err(core_error)?
            .ok_or(StagingError::NotCommitted)?;
        let actual = OriginalIdentity::controlled(
            &self.identity.root,
            &path,
            self.identity.sha256(),
            length,
        )
        .map_err(|_| StagingError::NotCommitted)?;
        if actual != self.identity {
            return Err(StagingError::NotCommitted);
        }
        self.created = false;
        Ok(())
    }
}

impl Drop for PublishedOriginal<'_> {
    fn drop(&mut self) {
        if self.created {
            let _ = self.database.device_sync_cleanup_published(
                self.lease,
                &self.identity.root,
                &self.identity.path(),
                self.identity.sha256(),
                &self.pin,
            );
        }
    }
}

impl StagingOperation {
    pub(crate) fn check_handoff_complete(&self, cancel: &CancellationToken) -> StagingResult<()> {
        if self.state != OperationState::Active || self.receiving != 0 {
            return Err(StagingError::InvalidState);
        }
        self.database
            .validate_existing_original_root(&self.media_root)
            .map_err(core_error)?;
        for (sha, entry) in &self.entries {
            check_cancel(cancel)?;
            let file = if entry.needs_transfer {
                if entry.state != FileState::Verified {
                    return Err(StagingError::InvalidState);
                }
                entry
                    .cached
                    .as_ref()
                    .ok_or(StagingError::InvalidState)?
                    .open()?
            } else {
                // DB-controlled CAS reuse is not a fresh incoming-byte claim.
                // All existing bytes are still fully SHA-checked by the local
                // receiver_prepare backup before any formal SQL mutation.
                let (path, length) = self
                    .database
                    .device_sync_original_path(sha)
                    .map_err(core_error)?
                    .ok_or(StagingError::CorruptOriginal)?;
                if length != entry.record.length {
                    return Err(StagingError::CorruptOriginal);
                }
                let identity = OriginalIdentity::controlled(&self.media_root, &path, sha, length)
                    .map_err(core_error)?;
                let file = paths::open_regular(&identity.path())?;
                paths::require_single_link(&file)?;
                file
            };
            if file.metadata().map_err(|_| StagingError::Read)?.len() != entry.record.length {
                return Err(StagingError::CorruptOriginal);
            }
        }
        Ok(())
    }
    pub(crate) fn budget_inputs(
        &self,
        work: &super::work::WorkControl,
    ) -> StagingResult<BudgetInputs<'_>> {
        paths::inspect(&self.directory)?;
        paths::inspect(&self.media_root)?;
        let mut missing = Vec::new();
        let mut publishing = Vec::new();
        for entry in self.entries.values() {
            work.check().map_err(core_error)?;
            if entry.needs_transfer {
                publishing.push(entry.record.length);
                if entry.cached.is_none() {
                    missing.push(entry.record.length);
                }
            }
        }
        Ok(BudgetInputs {
            staging: &self.directory,
            originals: &self.media_root,
            missing,
            publishing,
        })
    }
    pub fn operation_id(&self) -> uuid::Uuid {
        self.id
    }

    pub fn progress(&self) -> &Progress {
        &self.progress
    }

    pub fn space_preflight(&self) -> &SpacePreflight {
        &self.space
    }

    pub fn prepare(
        database: Arc<Database>,
        source: &Manifest,
        target: &Manifest,
        plan: &SyncPlan,
    ) -> StagingResult<Self> {
        Self::prepare_controlled(
            database,
            source,
            target,
            plan,
            &super::work::WorkControl::default(),
        )
    }
    pub fn prepare_controlled(
        database: Arc<Database>,
        source: &Manifest,
        target: &Manifest,
        plan: &SyncPlan,
        work: &super::work::WorkControl,
    ) -> StagingResult<Self> {
        plan.verify_controlled(source, target, work)
            .map_err(|error| {
                if matches!(error, CoreError::Cancelled) {
                    StagingError::Cancelled
                } else {
                    StagingError::InvalidPlan
                }
            })?;
        work.check().map_err(core_error)?;
        let _writing = database.write_lease().map_err(core_error)?;
        let header = database.device_sync_header().map_err(core_error)?;
        if header.library_uuid != target.header.library_uuid
            || header.generation != target.header.generation
        {
            return Err(StagingError::PlanChanged);
        }
        let (runtime, media_root) = database.device_sync_file_roots().map_err(core_error)?;
        paths::ensure_directory(&runtime).inspect_err(|error| {
            diagnostics::receiver(
                Boundary::StageRuntimeEnsure,
                &super::receiver::ReceiverError::Staging(*error),
            )
        })?;
        paths::ensure_directory(&media_root).inspect_err(|error| {
            diagnostics::receiver(
                Boundary::StageMediaEnsure,
                &super::receiver::ReceiverError::Staging(*error),
            )
        })?;
        let runtime = runtime.canonicalize().map_err(|error| {
            diagnostics::core(Boundary::StageRuntimeCanonical, &CoreError::Io(error));
            StagingError::UnsafePath
        })?;
        let media_root = database
            .ensure_original_root(&media_root)
            .map_err(core_error)?;
        let cache = CacheRoot::open(&runtime, work.validation.clone()).inspect_err(|error| {
            diagnostics::receiver(
                Boundary::StageCacheOpen,
                &super::receiver::ReceiverError::Staging(*error),
            )
        })?;
        let mut entries = BTreeMap::new();
        let mut cached_bytes = 0_u64;
        for entry in &plan.media {
            work.check().map_err(core_error)?;
            if let Some(record) = &entry.final_record {
                let cached = if entry.reuse_original {
                    None
                } else {
                    cache.lookup(record, work).inspect_err(|error| {
                        diagnostics::receiver(
                            Boundary::StageCacheLookup,
                            &super::receiver::ReceiverError::Staging(*error),
                        )
                    })?
                };
                if cached.is_some() {
                    cached_bytes = cached_bytes
                        .checked_add(record.length)
                        .ok_or(StagingError::Overflow)?;
                }
                entries.insert(
                    entry.sha256.clone(),
                    Entry {
                        record: record.clone(),
                        needs_transfer: !entry.reuse_original,
                        state: if cached.is_some() {
                            FileState::Verified
                        } else {
                            FileState::Pending
                        },
                        part: None,
                        cached,
                        written: 0,
                        write_stamp: None,
                    },
                );
            }
        }
        let requirements = SpaceRequirements::checked(
            plan.space
                .new_staging_bytes
                .checked_sub(cached_bytes)
                .ok_or(StagingError::Overflow)?,
            plan.space.new_staging_bytes,
            paths::same_volume(&runtime, &media_root)?,
        )?;
        let stage_available_bytes =
            fs2::available_space(&runtime).map_err(|_| StagingError::Read)?;
        let media_available_bytes =
            fs2::available_space(&media_root).map_err(|_| StagingError::Read)?;
        requirements.check_available(stage_available_bytes, media_available_bytes)?;
        let id = uuid::Uuid::new_v4();
        let directory = runtime.join(id.to_string());
        work.check().map_err(core_error)?;
        // Persist ownership before creating any private directory or part.
        if let Some(session) = work.sync_session {
            database
                .device_sync_bind_session_staging(session, id)
                .map_err(core_error)?;
        }
        paths::create_operation(&directory).inspect_err(|error| {
            diagnostics::receiver(
                Boundary::StageOperationCreate,
                &super::receiver::ReceiverError::Staging(*error),
            )
        })?;
        drop(_writing);
        Ok(Self {
            database,
            id,
            directory,
            media_root,
            target_uuid: header.library_uuid,
            target_generation: header.generation,
            entries,
            cache,
            progress: Progress {
                phase: Phase::Prepared,
                completed_bytes: 0,
                total_bytes: None,
            },
            space: SpacePreflight {
                requirements,
                stage_available_bytes,
                media_available_bytes,
                excludes_metadata_and_filesystem_overhead: true,
            },
            state: OperationState::Active,
            receiving: 0,
            validation: work.validation.clone(),
        })
    }

    fn check(&self, operation: uuid::Uuid, sha: &str) -> StagingResult<()> {
        if operation != self.id {
            return Err(StagingError::InvalidOperation);
        }
        match self.state {
            OperationState::Cancelled => return Err(StagingError::Cancelled),
            OperationState::Failed => return Err(StagingError::InvalidState),
            OperationState::Active => {}
        }
        if !self.entries.contains_key(sha) {
            return Err(StagingError::UnknownMedia);
        }
        Ok(())
    }

    /// Current-operation transfer scheduling only; this grants no publication authority.
    pub fn requires_transfer(&self, sha: &str) -> StagingResult<bool> {
        self.check(self.id, sha)?;
        let entry = self.entries.get(sha).expect("checked SHA");
        Ok(entry.needs_transfer && entry.state == FileState::Pending)
    }

    /// ReceivingWindowFull leaves the operation unchanged. Retry that pending
    /// file after an in-flight file finishes; other errors are not this signal.
    pub fn begin_file(&mut self, operation: uuid::Uuid, sha: &str) -> StagingResult<()> {
        self.check(operation, sha)?;
        let entry = self.entries.get_mut(sha).expect("checked SHA");
        if !entry.needs_transfer || entry.state != FileState::Pending {
            return Err(StagingError::InvalidState);
        }
        if self.receiving >= MAX_RECEIVING_FILES {
            return Err(StagingError::ReceivingWindowFull);
        }
        entry.part = Some(OwnedPart::create(&self.directory)?);
        entry.state = FileState::Receiving;
        self.receiving += 1;
        self.progress = progress(Phase::Receiving, 0, Some(entry.record.length));
        Ok(())
    }

    pub fn write_chunk(
        &mut self,
        operation: uuid::Uuid,
        sha: &str,
        offset: u64,
        bytes: &[u8],
    ) -> StagingResult<Progress> {
        self.check(operation, sha)?;
        let entry = self.entries.get_mut(sha).expect("checked SHA");
        if entry.state != FileState::Receiving {
            return Err(StagingError::InvalidState);
        }
        if offset != entry.written {
            return Err(StagingError::Offset);
        }
        if bytes.is_empty()
            || bytes.len() > MAX_CHUNK_BYTES
            || offset
                .checked_add(bytes.len() as u64)
                .is_none_or(|end| end > entry.record.length)
        {
            return Err(StagingError::Bounds);
        }
        let part = entry.part.as_mut().expect("receiving owns part");
        part.inspect()?;
        let result = write_counted(
            part.file_mut(),
            bytes,
            &mut entry.written,
            &mut self.progress,
            entry.record.length,
        );
        if let Err(error) = result {
            self.fail(error);
            return Err(error);
        }
        match file_stamp(part.file_mut()) {
            Ok(stamp) => entry.write_stamp = Some(stamp),
            Err(error) => {
                self.fail(error);
                return Err(error);
            }
        }
        Ok(self.progress.clone())
    }

    pub fn finish_file(
        &mut self,
        operation: uuid::Uuid,
        sha: &str,
        cancel: &CancellationToken,
        observer: &mut impl FnMut(Progress),
    ) -> StagingResult<()> {
        self.seal_file(operation, sha, cancel)?;
        self.verify_sealed_file(sha, cancel, observer)
    }

    /// Complete only the bounded receive. This does not verify content or
    /// grant cache/publication authority; the driver validates the whole batch.
    pub(crate) fn seal_file(
        &mut self,
        operation: uuid::Uuid,
        sha: &str,
        cancel: &CancellationToken,
    ) -> StagingResult<()> {
        self.check(operation, sha)?;
        let entry = self.entries.get_mut(sha).expect("checked SHA");
        if entry.state != FileState::Receiving {
            return Err(StagingError::InvalidState);
        }
        let result = (|| {
            check_cancel(cancel)?;
            if entry.written != entry.record.length {
                return Err(StagingError::LengthMismatch);
            }
            let part = entry.part.as_mut().expect("receiving owns part");
            part.inspect()?;
            if entry.write_stamp != Some(file_stamp(part.file_mut())?) {
                return Err(StagingError::ChecksumMismatch);
            }
            sync_file(part.file_mut())?;
            check_cancel(cancel)?;
            if file_stamp(part.file_mut())?.0 != entry.record.length {
                return Err(StagingError::LengthMismatch);
            }
            part.suspend()?;
            entry.state = FileState::Received;
            self.receiving -= 1;
            self.progress = progress(Phase::Receiving, entry.written, Some(entry.record.length));
            Ok(())
        })();
        if let Err(error) = result {
            self.fail(error);
        }
        result
    }

    fn verify_sealed_file(
        &mut self,
        sha: &str,
        cancel: &CancellationToken,
        observer: &mut impl FnMut(Progress),
    ) -> StagingResult<()> {
        self.check(self.id, sha)?;
        let entry = self.entries.get_mut(sha).expect("checked SHA");
        if entry.state != FileState::Received {
            return Err(StagingError::InvalidState);
        }
        let result = (|| {
            check_cancel(cancel)?;
            let part = entry.part.as_mut().ok_or(StagingError::InvalidState)?;
            part.inspect()?;
            part.resume()?;
            part.file_mut().rewind().map_err(|_| StagingError::Read)?;
            verify_open_file(
                part.file_mut(),
                &entry.record,
                cancel,
                observer,
                &self.validation,
            )?;
            check_cancel(cancel)?;
            part.inspect()?;
            let part = entry.part.take().expect("received owns part");
            entry.cached = Some(self.cache.retain(part, &entry.record, cancel)?);
            entry.state = FileState::Verified;
            self.progress = progress(Phase::Verified, entry.written, Some(entry.record.length));
            observer(self.progress.clone());
            Ok(())
        })();
        if let Err(error) = result {
            self.fail(error);
        }
        result
    }

    /// No content is examined until every required incoming file is sealed.
    /// Validated entries alone enter the reusable cache, including on failure.
    pub(crate) fn verify_received(
        &mut self,
        cancel: &CancellationToken,
        observer: &mut impl FnMut(Progress),
    ) -> StagingResult<()> {
        check_cancel(cancel)?;
        if self.state != OperationState::Active
            || self.receiving != 0
            || self.entries.values().any(|entry| {
                entry.needs_transfer
                    && !matches!(entry.state, FileState::Received | FileState::Verified)
            })
        {
            return Err(StagingError::InvalidState);
        }
        let pending: Vec<_> = self
            .entries
            .iter()
            .filter(|(_, entry)| entry.state == FileState::Received)
            .map(|(sha, entry)| (sha.clone(), entry.record.length))
            .collect();
        let total = pending.iter().try_fold(0_u64, |sum, (_, length)| {
            sum.checked_add(*length).ok_or(StagingError::Overflow)
        })?;
        let mut completed = 0_u64;
        for (sha, length) in pending {
            self.verify_sealed_file(&sha, cancel, &mut |event| {
                observer(progress(
                    Phase::Verifying,
                    completed + event.completed_bytes,
                    Some(total),
                ));
            })?;
            completed += length;
        }
        self.check_handoff_complete(cancel)
    }

    pub fn publish<'lease>(
        &mut self,
        lease: &'lease ExclusiveLease,
        operation: uuid::Uuid,
        sha: &str,
        cancel: &CancellationToken,
        observer: &mut impl FnMut(Progress),
    ) -> StagingResult<PublishedOriginal<'lease>> {
        self.check(operation, sha)?;
        self.database
            .device_sync_validate_exclusive(lease)
            .map_err(|_| StagingError::InvalidLease)?;
        let entry = self.entries.get(sha).expect("checked SHA");
        if entry.state == FileState::Published
            || (entry.needs_transfer && entry.state != FileState::Verified)
        {
            return Err(StagingError::InvalidState);
        }
        self.validate_target()?;
        let result = self.publish_inner(lease, sha, cancel, observer);
        if let Err(error) = &result {
            self.fail(*error);
        }
        result
    }

    pub fn cancel(&mut self) -> StagingResult<()> {
        if self.state != OperationState::Active {
            return Err(if self.state == OperationState::Cancelled {
                StagingError::Cancelled
            } else {
                StagingError::InvalidState
            });
        }
        self.state = OperationState::Cancelled;
        self.progress = progress(Phase::Cancelled, self.progress.completed_bytes, None);
        self.cleanup_private()
    }

    fn validate_target(&self) -> StagingResult<()> {
        let header = self.database.device_sync_header().map_err(core_error)?;
        if header.library_uuid != self.target_uuid || header.generation != self.target_generation {
            return Err(StagingError::PlanChanged);
        }
        let (_, root) = self.database.device_sync_file_roots().map_err(core_error)?;
        paths::inspect(&root)?;
        if super::library_guard::path_key(
            &root.canonicalize().map_err(|_| StagingError::UnsafePath)?,
        ) != super::library_guard::path_key(&self.media_root)
        {
            return Err(StagingError::PlanChanged);
        }
        self.database
            .ensure_original_root(&root)
            .map_err(core_error)?;
        Ok(())
    }

    fn publish_inner<'lease>(
        &mut self,
        lease: &'lease ExclusiveLease,
        sha: &str,
        cancel: &CancellationToken,
        observer: &mut impl FnMut(Progress),
    ) -> StagingResult<PublishedOriginal<'lease>> {
        check_cancel(cancel)?;
        let entry = self.entries.get_mut(sha).expect("checked SHA");
        let record = &entry.record;
        let parent = self
            .media_root
            .join("originals")
            .join(&sha[..2])
            .join(&sha[2..4]);
        paths::ensure_directory(&parent)?;
        let mut emit = |event: Progress| {
            self.progress = event.clone();
            observer(event);
        };
        let existing = self
            .database
            .device_sync_original_path(sha)
            .map_err(core_error)?;
        let destination = if let Some((path, length)) = existing {
            if length != record.length {
                return Err(StagingError::CorruptOriginal);
            }
            Some(path)
        } else {
            find_existing(&parent, record, cancel, &mut emit, &self.validation)?
        };
        let destination =
            destination.unwrap_or_else(|| parent.join(format!("{sha}.{}", record.extension)));
        let identity =
            OriginalIdentity::controlled(&self.media_root, &destination, sha, record.length)
                .map_err(|_| StagingError::UnsafePath)?;
        let pin = self
            .database
            .device_sync_pin_original_exclusive(
                lease,
                &self.media_root,
                &destination,
                sha,
                record.length,
            )
            .map_err(core_error)?;
        let exists = match std::fs::symlink_metadata(&destination) {
            Ok(_) => true,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
            Err(error) => return Err(io_error(&error, StagingError::Read)),
        };
        let created = if exists {
            verify_original(&destination, record, cancel, &mut emit, &self.validation)?;
            false
        } else {
            // A planned reuse is not permission to silently replace a lost original.
            if !entry.needs_transfer {
                return Err(StagingError::CorruptOriginal);
            }
            let available = fs2::available_space(&parent).map_err(|_| StagingError::Read)?;
            if available < record.length {
                return Err(StagingError::InsufficientSpace);
            }
            let source = entry
                .cached
                .as_ref()
                .ok_or(StagingError::InvalidState)?
                .open()?;
            let mut temporary = OwnedPart::create(&parent)?;
            copy_file(
                source,
                &mut temporary,
                record,
                cancel,
                &mut emit,
                &self.validation,
            )?;
            sync_file(temporary.file_mut())?;
            emit(progress(Phase::Publishing, 0, None));
            check_cancel(cancel)?;
            paths::inspect(&parent)?;
            match temporary.publish_to(&destination) {
                Ok(()) => true,
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    verify_original(&destination, record, cancel, &mut emit, &self.validation)?;
                    false
                }
                Err(error) => return Err(io_error(&error, StagingError::Publish)),
            }
        };
        let published = PublishedOriginal {
            database: self.database.clone(),
            lease,
            identity,
            pin,
            created,
        };
        entry.state = FileState::Published;
        entry.part.take();
        emit(progress(
            Phase::Published,
            record.length,
            Some(record.length),
        ));
        Ok(published)
    }

    fn fail(&mut self, error: StagingError) {
        self.state = if error == StagingError::Cancelled {
            OperationState::Cancelled
        } else {
            OperationState::Failed
        };
        self.progress.phase = if error == StagingError::Cancelled {
            Phase::Cancelled
        } else {
            Phase::Failed
        };
        let _ = self.cleanup_private();
    }

    fn cleanup_private(&mut self) -> StagingResult<()> {
        self.receiving = 0;
        for entry in self.entries.values_mut() {
            entry.part.take();
        }
        if !self.directory.exists() {
            return Ok(());
        }
        paths::inspect(&self.directory)?;
        std::fs::remove_dir(&self.directory).map_err(|_| StagingError::Cleanup)
    }
}

impl Drop for StagingOperation {
    fn drop(&mut self) {
        let _ = self.cleanup_private();
    }
}

fn progress(phase: Phase, completed_bytes: u64, total_bytes: Option<u64>) -> Progress {
    Progress {
        phase,
        completed_bytes,
        total_bytes,
    }
}

fn check_cancel(cancel: &CancellationToken) -> StagingResult<()> {
    cancel.check().map_err(|_| StagingError::Cancelled)
}

fn write_counted(
    file: &mut impl Write,
    mut bytes: &[u8],
    written: &mut u64,
    status: &mut Progress,
    total: u64,
) -> StagingResult<()> {
    while !bytes.is_empty() {
        #[cfg(test)]
        tests::io_fault(tests::IoPoint::Write)
            .map_err(|error| io_error(&error, StagingError::Write))?;
        let count = file
            .write(bytes)
            .map_err(|error| io_error(&error, StagingError::Write))?;
        if count == 0 {
            return Err(StagingError::Write);
        }
        *written = written
            .checked_add(count as u64)
            .ok_or(StagingError::Overflow)?;
        *status = progress(Phase::Receiving, *written, Some(total));
        bytes = &bytes[count..];
    }
    Ok(())
}

fn file_stamp(file: &File) -> StagingResult<(u64, std::time::SystemTime)> {
    let metadata = file.metadata().map_err(|_| StagingError::Read)?;
    Ok((
        metadata.len(),
        metadata.modified().map_err(|_| StagingError::Read)?,
    ))
}

fn sync_file(file: &mut File) -> StagingResult<()> {
    #[cfg(test)]
    tests::io_fault(tests::IoPoint::Sync).map_err(|error| io_error(&error, StagingError::Sync))?;
    file.sync_all()
        .map_err(|error| io_error(&error, StagingError::Sync))
}

fn verify_file(
    path: &Path,
    record: &MediaRecord,
    cancel: &CancellationToken,
    observer: &mut impl FnMut(Progress),
    validation: &super::validation::ValidationMetrics,
) -> StagingResult<()> {
    paths::inspect(path)?;
    if !std::fs::symlink_metadata(path)
        .map_err(|_| StagingError::Read)?
        .is_file()
    {
        return Err(StagingError::LengthMismatch);
    }
    let mut file = paths::open_regular(path)?;
    verify_open_file(&mut file, record, cancel, observer, validation)
}

fn verify_open_file(
    file: &mut File,
    record: &MediaRecord,
    cancel: &CancellationToken,
    observer: &mut impl FnMut(Progress),
    validation: &super::validation::ValidationMetrics,
) -> StagingResult<()> {
    if !file.metadata().map_err(|_| StagingError::Read)?.is_file()
        || file.metadata().map_err(|_| StagingError::Read)?.len() != record.length
    {
        return Err(StagingError::LengthMismatch);
    }
    observer(progress(Phase::Verifying, 0, Some(record.length)));
    let mut buffer = [0_u8; CHECKSUM_BUFFER_BYTES];
    let mut written = 0_u64;
    let mut digest = Sha256::new();
    loop {
        check_cancel(cancel)?;
        let count = file
            .read(&mut buffer)
            .map_err(|error| io_error(&error, StagingError::Read))?;
        if count == 0 {
            break;
        }
        validation.checksum_read(count as u64);
        written = written
            .checked_add(count as u64)
            .ok_or(StagingError::Overflow)?;
        if written > record.length {
            return Err(StagingError::LengthMismatch);
        }
        digest.update(&buffer[..count]);
        observer(progress(Phase::Verifying, written, Some(record.length)));
    }
    if written != record.length {
        return Err(StagingError::LengthMismatch);
    }
    if hex::encode(digest.finalize()) != record.sha256 {
        return Err(StagingError::ChecksumMismatch);
    }
    Ok(())
}

fn verify_original(
    path: &Path,
    record: &MediaRecord,
    cancel: &CancellationToken,
    observer: &mut impl FnMut(Progress),
    validation: &super::validation::ValidationMetrics,
) -> StagingResult<()> {
    verify_file(path, record, cancel, observer, validation).map_err(|error| match error {
        StagingError::LengthMismatch | StagingError::ChecksumMismatch | StagingError::Read => {
            StagingError::CorruptOriginal
        }
        _ => error,
    })
}

fn find_existing(
    parent: &Path,
    record: &MediaRecord,
    cancel: &CancellationToken,
    observer: &mut impl FnMut(Progress),
    validation: &super::validation::ValidationMetrics,
) -> StagingResult<Option<PathBuf>> {
    let mut found = None;
    for extension in ["jpg", "jpeg", "png", "webp", "mp4", "mov"] {
        let path = parent.join(format!("{}.{extension}", record.sha256));
        match std::fs::symlink_metadata(&path) {
            Ok(_) => {
                verify_original(&path, record, cancel, observer, validation)?;
                if found.is_none() {
                    found = Some(path);
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(io_error(&error, StagingError::Read)),
        }
    }
    Ok(found)
}

fn copy_file(
    mut source: File,
    target: &mut OwnedPart,
    record: &MediaRecord,
    cancel: &CancellationToken,
    observer: &mut impl FnMut(Progress),
    validation: &super::validation::ValidationMetrics,
) -> StagingResult<()> {
    let mut buffer = [0_u8; CHECKSUM_BUFFER_BYTES];
    let mut copied = 0_u64;
    let mut digest = Sha256::new();
    observer(progress(Phase::Copying, 0, Some(record.length)));
    loop {
        check_cancel(cancel)?;
        let count = source
            .read(&mut buffer)
            .map_err(|error| io_error(&error, StagingError::Read))?;
        if count == 0 {
            break;
        }
        let next = copied
            .checked_add(count as u64)
            .ok_or(StagingError::Overflow)?;
        if next > record.length {
            return Err(StagingError::LengthMismatch);
        }
        #[cfg(test)]
        tests::io_fault(tests::IoPoint::Copy)
            .map_err(|error| io_error(&error, StagingError::Write))?;
        let mut remaining = &buffer[..count];
        while !remaining.is_empty() {
            let written = target
                .file_mut()
                .write(remaining)
                .map_err(|error| io_error(&error, StagingError::Write))?;
            if written == 0 {
                return Err(StagingError::Write);
            }
            digest.update(&remaining[..written]);
            validation.copied(written as u64);
            remaining = &remaining[written..];
        }
        copied = next;
        observer(progress(Phase::Copying, copied, Some(record.length)));
    }
    if copied != record.length {
        return Err(StagingError::LengthMismatch);
    }
    if hex::encode(digest.finalize()) != record.sha256 {
        return Err(StagingError::ChecksumMismatch);
    }
    observer(progress(
        Phase::Verifying,
        record.length,
        Some(record.length),
    ));
    Ok(())
}

fn core_error(error: CoreError) -> StagingError {
    match error {
        CoreError::LibraryBusy => StagingError::LibraryBusy,
        CoreError::LibraryReferenced => StagingError::Referenced,
        CoreError::LibraryRootOwnership => StagingError::RootOwnership,
        CoreError::Cancelled => StagingError::Cancelled,
        CoreError::Io(error) => io_error(&error, StagingError::Read),
        _ => StagingError::Database,
    }
}

fn io_error(error: &std::io::Error, fallback: StagingError) -> StagingError {
    if error.kind() == std::io::ErrorKind::StorageFull {
        StagingError::InsufficientSpace
    } else {
        fallback
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_sync::manifest::{
        ManifestCollector, ManifestHeader, ManifestRecord, MediaRecord, VERSION,
    };
    use crate::device_sync::planner::{build_plan, SyncMode};
    use crate::models::MediaKind;

    pub(super) const ABC_SHA: &str =
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    #[derive(Clone, Copy, PartialEq, Eq)]
    pub(super) enum IoPoint {
        Write,
        Copy,
        Sync,
        Publish,
    }

    thread_local! {
        static FAULT: std::cell::Cell<Option<(IoPoint, std::io::ErrorKind)>> = const { std::cell::Cell::new(None) };
    }

    pub(super) fn io_fault(point: IoPoint) -> std::io::Result<()> {
        if let Some((selected, kind)) = FAULT.get() {
            if selected == point {
                FAULT.set(None);
                return Err(std::io::Error::from(kind));
            }
        }
        Ok(())
    }

    pub(super) fn fixture() -> (
        tempfile::TempDir,
        Arc<Database>,
        Manifest,
        Manifest,
        SyncPlan,
    ) {
        let root = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
        let database =
            Arc::new(Database::open(root.path().join("database/library.sqlite3")).unwrap());
        let target = local_manifest(&database);
        let mut source = Manifest {
            header: ManifestHeader {
                version: VERSION,
                library_uuid: uuid::Uuid::new_v4().to_string(),
                generation: 0,
                observed_at: target.header.observed_at,
            },
            records: vec![ManifestRecord::Media(MediaRecord {
                sha256: ABC_SHA.into(),
                length: 3,
                kind: MediaKind::Image,
                extension: "jpg".into(),
                original_display_name: "capture.jpg".into(),
                captured_at: None,
                imported_at: None,
                game_title_id: None,
                source_game_name: "Synthetic".into(),
                game_name: "Synthetic".into(),
                tags: vec![],
                note: String::new(),
                favorite: false,
                revision: None,
            })],
        };
        source.records.extend(target.records.iter().cloned());
        let plan = build_plan(&source, &target, SyncMode::Merge).unwrap();
        (root, database, source, target, plan)
    }

    fn local_manifest(database: &Database) -> Manifest {
        let header = database.device_sync_header().unwrap();
        let mut collector = ManifestCollector::new(header.clone()).unwrap();
        let mut cursor = None;
        loop {
            let page = database
                .device_sync_manifest_page(&header, cursor.as_ref(), 128)
                .unwrap();
            cursor = page.next.clone();
            collector.push(page).unwrap();
            if cursor.is_none() {
                break;
            }
        }
        collector.finish().unwrap()
    }

    #[test]
    fn staging_prepares_real_private_operation_without_mutating_media() {
        let (root, database, source, target, plan) = fixture();
        let _operation =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        assert!(root.path().join("temporary/device-sync").is_dir());
        assert!(!root.path().join("originals").exists());
        assert_eq!(
            database.device_sync_header().unwrap().generation,
            target.header.generation
        );
    }

    pub(super) fn receive(operation: &mut StagingOperation) {
        let id = operation.operation_id();
        operation.begin_file(id, ABC_SHA).unwrap();
        operation.write_chunk(id, ABC_SHA, 0, b"a").unwrap();
        operation.write_chunk(id, ABC_SHA, 1, b"bc").unwrap();
        operation
            .finish_file(id, ABC_SHA, &CancellationToken::default(), &mut |_| {})
            .unwrap();
    }

    #[test]
    fn staging_streams_hand_checked_sha_and_publishes_only_with_exclusive() {
        let (root, database, source, target, plan) = fixture();
        let mut operation =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        receive(&mut operation);
        assert_eq!(operation.progress().phase, Phase::Verified);
        assert!(!root.path().join("originals").exists());
        // No ordinary write lease may remain attached to transfer or publication.
        let exclusive = database.device_sync_exclusive().unwrap();
        let mut events = Vec::new();
        let published = operation
            .publish(
                &exclusive,
                operation.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |event| events.push(event),
            )
            .unwrap();
        assert!(published.created_by_operation());
        assert_eq!(std::fs::read(published.identity().path()).unwrap(), b"abc");
        assert_eq!(events.last().unwrap().phase, Phase::Published);
        assert!(events.iter().any(|event| event.phase == Phase::Verifying));
        assert!(events
            .iter()
            .any(|event| event.phase == Phase::Publishing && event.total_bytes.is_none()));
        let path = published.identity().path();
        assert!(published.rollback().unwrap());
        assert!(!path.exists());
        assert!(database
            .device_sync_original_path(ABC_SHA)
            .unwrap()
            .is_none());
    }

    #[test]
    fn staging_rejects_wrong_identity_offsets_bounds_and_repeated_finish() {
        let (_root, database, source, target, plan) = fixture();
        let mut operation = StagingOperation::prepare(database, &source, &target, &plan).unwrap();
        let id = operation.operation_id();
        assert_eq!(
            operation.begin_file(uuid::Uuid::new_v4(), ABC_SHA),
            Err(StagingError::InvalidOperation)
        );
        assert_eq!(
            operation.begin_file(id, &"0".repeat(64)),
            Err(StagingError::UnknownMedia)
        );
        operation.begin_file(id, ABC_SHA).unwrap();
        assert_eq!(
            operation.write_chunk(id, ABC_SHA, 1, b"a"),
            Err(StagingError::Offset)
        );
        assert_eq!(
            operation.write_chunk(id, ABC_SHA, 0, b"abcd"),
            Err(StagingError::Bounds)
        );
        assert_eq!(
            operation.write_chunk(id, ABC_SHA, 0, &vec![0; 65_537]),
            Err(StagingError::Bounds)
        );
        assert_eq!(operation.progress().completed_bytes, 0);
        operation.write_chunk(id, ABC_SHA, 0, b"abc").unwrap();
        operation
            .finish_file(id, ABC_SHA, &CancellationToken::default(), &mut |_| {})
            .unwrap();
        assert_eq!(
            operation.finish_file(id, ABC_SHA, &CancellationToken::default(), &mut |_| {}),
            Err(StagingError::InvalidState)
        );
        operation.cancel().unwrap();
        assert_eq!(
            operation.write_chunk(id, ABC_SHA, 3, b"x"),
            Err(StagingError::Cancelled)
        );
    }

    #[test]
    fn staging_short_or_wrong_checksum_never_becomes_verified() {
        for bytes in [b"a".as_slice(), b"abd".as_slice()] {
            let (_root, database, source, target, plan) = fixture();
            let mut operation =
                StagingOperation::prepare(database, &source, &target, &plan).unwrap();
            let id = operation.operation_id();
            operation.begin_file(id, ABC_SHA).unwrap();
            operation.write_chunk(id, ABC_SHA, 0, bytes).unwrap();
            let mut events = Vec::new();
            let error = operation
                .finish_file(id, ABC_SHA, &CancellationToken::default(), &mut |event| {
                    events.push(event)
                })
                .unwrap_err();
            assert_eq!(
                error,
                if bytes.len() == 1 {
                    StagingError::LengthMismatch
                } else {
                    StagingError::ChecksumMismatch
                }
            );
            assert!(!events.iter().any(|event| event.phase == Phase::Verified));
            assert_eq!(operation.progress().phase, Phase::Failed);
        }
    }

    #[test]
    fn staging_drop_and_cancel_clean_only_their_private_operation() {
        let (_root, database, source, target, plan) = fixture();
        let mut first =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        let mut second = StagingOperation::prepare(database, &source, &target, &plan).unwrap();
        let first_path = first.directory.clone();
        let second_path = second.directory.clone();
        first.begin_file(first.operation_id(), ABC_SHA).unwrap();
        second.begin_file(second.operation_id(), ABC_SHA).unwrap();
        first
            .write_chunk(first.operation_id(), ABC_SHA, 0, b"a")
            .unwrap();
        second
            .write_chunk(second.operation_id(), ABC_SHA, 0, b"abc")
            .unwrap();
        first.cancel().unwrap();
        assert!(!first_path.exists());
        assert!(second_path.is_dir());
        second
            .finish_file(
                second.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        drop(second);
        assert!(!second_path.exists());
    }

    #[test]
    fn staging_wrong_database_exclusive_cannot_publish_or_delete() {
        let (_root, database, source, target, plan) = fixture();
        let (_foreign_root, foreign, _, _, _) = fixture();
        let mut operation =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        receive(&mut operation);
        let foreign_lease = foreign.device_sync_exclusive().unwrap();
        assert!(matches!(
            operation.publish(
                &foreign_lease,
                operation.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {}
            ),
            Err(StagingError::InvalidLease)
        ));
        let lease = database.device_sync_exclusive().unwrap();
        let published = operation
            .publish(
                &lease,
                operation.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        let path = published.identity().path();
        drop(published);
        assert!(!path.exists());
    }

    #[test]
    fn staging_space_accounts_for_two_copies_and_refuses_checked_overflow() {
        let shared = SpaceRequirements::checked(3, 3, true).unwrap();
        assert_eq!(shared.stage_peak_bytes, 6);
        assert_eq!(
            shared.check_available(5, 100),
            Err(StagingError::InsufficientSpace)
        );
        let independent = SpaceRequirements::checked(3, 3, false).unwrap();
        assert!(independent.check_available(3, 3).is_ok());
        assert_eq!(
            independent.check_available(3, 2),
            Err(StagingError::InsufficientSpace)
        );
        assert_eq!(
            SpaceRequirements::checked(u64::MAX, 1, true),
            Err(StagingError::Overflow)
        );
    }

    fn update_plan(source: &Manifest, target: &Manifest) -> SyncPlan {
        build_plan(source, target, SyncMode::Merge).unwrap()
    }

    fn target_path(root: &Path, extension: &str) -> PathBuf {
        root.join("originals/ba/78")
            .join(format!("{ABC_SHA}.{extension}"))
    }

    #[test]
    fn staging_reuses_actual_different_extension_and_never_deletes_reused_original() {
        let (root, database, mut source, target, _) = fixture();
        if let ManifestRecord::Media(record) = &mut source.records[0] {
            record.extension = "jpeg".into();
        }
        let mut operation = StagingOperation::prepare(
            database.clone(),
            &source,
            &target,
            &update_plan(&source, &target),
        )
        .unwrap();
        receive(&mut operation);
        let actual = target_path(root.path(), "jpg");
        std::fs::create_dir_all(actual.parent().unwrap()).unwrap();
        std::fs::write(&actual, b"abc").unwrap();
        let lease = database.device_sync_exclusive().unwrap();
        let published = operation
            .publish(
                &lease,
                operation.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        assert!(!published.created_by_operation());
        assert_eq!(published.identity().path(), actual.canonicalize().unwrap());
        assert!(!published.rollback().unwrap());
        assert_eq!(std::fs::read(actual).unwrap(), b"abc");
        assert!(!target_path(root.path(), "jpeg").exists());
        assert_eq!(
            walkdir::WalkDir::new(root.path().join("originals"))
                .into_iter()
                .filter_map(Result::ok)
                .filter(|entry| entry.file_type().is_file())
                .count(),
            1
        );
    }

    #[test]
    fn staging_database_reuse_selects_real_jpg_path_without_a_transfer() {
        let (root, database, mut source, target, plan) = fixture();
        let mut first =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        receive(&mut first);
        let lease = database.device_sync_exclusive().unwrap();
        let published = first
            .publish(
                &lease,
                first.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        let actual = published.identity().path();
        crate::database::staging_test_support::row(&database, &lease, &actual, ABC_SHA, true)
            .unwrap();
        published.commit().unwrap();
        drop(lease);
        let target = local_manifest(&database);
        if let ManifestRecord::Media(record) = &mut source.records[0] {
            record.extension = "jpeg".into();
        }
        source.header.observed_at = target.header.observed_at;
        let plan = update_plan(&source, &target);
        let mut second =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        assert_eq!(second.space_preflight().requirements.staging_bytes, 0);
        assert_eq!(
            second.begin_file(second.operation_id(), ABC_SHA),
            Err(StagingError::InvalidState)
        );
        let lease = database.device_sync_exclusive().unwrap();
        let reused = second
            .publish(
                &lease,
                second.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        assert!(!reused.created_by_operation());
        assert_eq!(reused.identity().path(), actual);
        reused.commit().unwrap();
        assert_eq!(std::fs::read(&actual).unwrap(), b"abc");
        assert!(!target_path(root.path(), "jpeg").exists());
        assert!(matches!(
            second.publish(
                &lease,
                second.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {}
            ),
            Err(StagingError::InvalidState)
        ));
    }

    #[test]
    fn staging_ordinary_writes_during_transfer_invalidate_the_preview_at_publication() {
        let (root, database, source, target, plan) = fixture();
        let mut operation =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        receive(&mut operation);
        database
            .create_tag("ordinary write stays available")
            .unwrap();
        let lease = database.device_sync_exclusive().unwrap();
        assert!(matches!(
            operation.publish(
                &lease,
                operation.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {}
            ),
            Err(StagingError::PlanChanged)
        ));
        assert!(!target_path(root.path(), "jpg").exists());
    }

    #[test]
    fn staging_existing_damage_and_no_clobber_race_keep_the_original_bytes() {
        for inject_at_publication in [false, true] {
            let (root, database, source, target, plan) = fixture();
            let mut operation =
                StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
            receive(&mut operation);
            let destination = target_path(root.path(), "jpg");
            std::fs::create_dir_all(destination.parent().unwrap()).unwrap();
            if !inject_at_publication {
                std::fs::write(&destination, b"xyz").unwrap();
            }
            let lease = database.device_sync_exclusive().unwrap();
            let result = operation.publish(
                &lease,
                operation.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |event| {
                    if inject_at_publication && event.phase == Phase::Publishing {
                        std::fs::write(&destination, b"xyz").unwrap();
                    }
                },
            );
            assert!(matches!(result, Err(StagingError::CorruptOriginal)));
            assert_eq!(std::fs::read(destination).unwrap(), b"xyz");
            assert!(database
                .device_sync_original_path(ABC_SHA)
                .unwrap()
                .is_none());
        }
    }

    #[test]
    fn staging_new_publications_hold_pins_across_sql_failure_and_commit() {
        for commit in [false, true] {
            let (_root, database, source, target, plan) = fixture();
            let mut operation =
                StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
            receive(&mut operation);
            let lease = database.device_sync_exclusive().unwrap();
            // Existing backups are valid apply state, not a relocation veto.
            let backup = database
                .device_sync_retain_backup(&lease, &operation.media_root)
                .unwrap();
            let published = operation
                .publish(
                    &lease,
                    operation.operation_id(),
                    ABC_SHA,
                    &CancellationToken::default(),
                    &mut |_| {},
                )
                .unwrap();
            let path = published.identity().path();
            assert!(!database
                .cleanup_original_exclusive(&lease, &operation.media_root, &path, ABC_SHA)
                .unwrap());
            let result = crate::database::staging_test_support::row(
                &database, &lease, &path, ABC_SHA, commit,
            );
            if commit {
                result.unwrap();
                published.commit().unwrap();
                assert_eq!(std::fs::read(&path).unwrap(), b"abc");
                assert!(!database
                    .cleanup_original_exclusive(&lease, &operation.media_root, &path, ABC_SHA)
                    .unwrap());
            } else {
                assert!(result.is_err());
                assert!(database
                    .device_sync_original_path(ABC_SHA)
                    .unwrap()
                    .is_none());
                assert!(published.rollback().unwrap());
                assert!(!path.exists());
            }
            database.device_sync_release_backup(&lease, backup).unwrap();
        }
    }

    #[test]
    fn staging_compensation_honors_other_pins_snapshots_and_durable_backups() {
        let (_root, database, source, target, plan) = fixture();
        let mut operation =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        receive(&mut operation);
        let lease = database.device_sync_exclusive().unwrap();
        let published = operation
            .publish(
                &lease,
                operation.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        let path = published.identity().path();
        let second_pin = database
            .device_sync_pin_original_exclusive(&lease, &operation.media_root, &path, ABC_SHA, 3)
            .unwrap();
        assert!(!published.rollback().unwrap());
        assert!(path.exists());
        drop(second_pin);
        crate::database::staging_test_support::row(&database, &lease, &path, ABC_SHA, true)
            .unwrap();
        let snapshot = database
            .device_sync_retain_source(&lease, &operation.media_root)
            .unwrap();
        let backup = database
            .device_sync_retain_backup(&lease, &operation.media_root)
            .unwrap();
        crate::database::staging_test_support::remove_row(&database, &lease, ABC_SHA);
        assert!(!database
            .cleanup_original_exclusive(&lease, &operation.media_root, &path, ABC_SHA)
            .unwrap());
        drop(snapshot);
        assert!(!database
            .cleanup_original_exclusive(&lease, &operation.media_root, &path, ABC_SHA)
            .unwrap());
        database.device_sync_release_backup(&lease, backup).unwrap();
        assert!(database
            .cleanup_original_exclusive(&lease, &operation.media_root, &path, ABC_SHA)
            .unwrap());
    }

    #[test]
    fn staging_commit_without_sql_row_rejects_and_compensates_its_new_original() {
        let (_root, database, source, target, plan) = fixture();
        let mut operation =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        receive(&mut operation);
        let lease = database.device_sync_exclusive().unwrap();
        let published = operation
            .publish(
                &lease,
                operation.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        let path = published.identity().path();
        assert_eq!(published.commit(), Err(StagingError::NotCommitted));
        assert!(!path.exists());
    }

    #[test]
    fn staging_rejects_links_escape_conflicts_and_non_regular_targets() {
        let (root, database, source, target, plan) = fixture();
        let mut operation =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        assert_eq!(
            operation.begin_file(operation.operation_id(), "../outside.jpg"),
            Err(StagingError::UnknownMedia)
        );
        assert_eq!(
            paths::create_operation(&operation.directory),
            Err(StagingError::Conflict)
        );
        receive(&mut operation);
        let destination = target_path(root.path(), "jpg");
        std::fs::create_dir_all(&destination).unwrap();
        let lease = database.device_sync_exclusive().unwrap();
        assert!(matches!(
            operation.publish(
                &lease,
                operation.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {}
            ),
            Err(StagingError::CorruptOriginal)
        ));
        assert!(destination.is_dir());
    }

    #[cfg(any(windows, unix))]
    fn link_directory(target: &Path, link: &Path) {
        #[cfg(windows)]
        std::os::windows::fs::symlink_dir(target, link).unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(target, link).unwrap();
    }

    #[cfg(any(windows, unix))]
    fn configure_alias(
        database: &Database,
        target: &Path,
    ) -> (tempfile::TempDir, std::path::PathBuf) {
        let holder = tempfile::tempdir_in(std::env::temp_dir().canonicalize().unwrap()).unwrap();
        let alias = holder.path().join("configured-root");
        link_directory(target, &alias);
        let settings = crate::settings::AppSettings {
            proxy_url: None,
            doh_enabled: false,
            library_path: alias.to_string_lossy().into_owned(),
            theme: "ocean".into(),
            language: "en".into(),
            gallery_columns: 4,
            gallery_rows: 3,
            show_note_preview: true,
            show_game_tag: true,
            compact_tag_display: true,
            auto_play_video: false,
            auto_sync_on_launch: false,
            notify_on_auto_sync: true,
            show_splatoon_schedule: true,
            show_splatoon_friend_activity: false,
            close_behavior: "ask".into(),
            custom_font_paths: vec![],
            sync_policy: Default::default(),
        };
        crate::database::staging_test_support::persisted_settings(database, &settings);
        (holder, alias)
    }

    #[cfg(any(windows, unix))]
    #[test]
    fn staging_owned_root_alias_prepares_without_rewriting_settings() {
        let (root, database, source, target, plan) = fixture();
        database.ensure_original_root(root.path()).unwrap();
        let (_holder, alias) = configure_alias(&database, root.path());
        let operation = StagingOperation::prepare(database.clone(), &source, &target, &plan)
            .expect("an already-owned configured root has a canonical effective identity");
        assert_eq!(operation.media_root, root.path().canonicalize().unwrap());
        assert_eq!(
            database
                .get_setting::<crate::settings::AppSettings>("app.settings")
                .unwrap()
                .unwrap()
                .library_path,
            alias.to_string_lossy()
        );
        assert_eq!(
            database.device_sync_header().unwrap().generation,
            target.header.generation
        );
        assert!(!root.path().join("originals").exists());
    }

    #[cfg(any(windows, unix))]
    #[test]
    fn staging_ordinary_configured_root_keeps_existing_admission() {
        for exists in [false, true] {
            let (root, database, source, target, plan) = fixture();
            let (_holder, configured) = configure_alias(&database, root.path());
            #[cfg(windows)]
            std::fs::remove_dir(&configured).unwrap();
            #[cfg(unix)]
            std::fs::remove_file(&configured).unwrap();
            if exists {
                std::fs::create_dir(&configured).unwrap();
            }
            let marker =
                configured.join(crate::device_sync::library_guard::ORIGINAL_ROOT_OWNER_FILE);
            assert!(!marker.exists());
            let operation = StagingOperation::prepare(database, &source, &target, &plan).unwrap();
            assert_eq!(operation.media_root, configured.canonicalize().unwrap());
            assert!(marker.is_file());
            assert!(!configured.join("originals").exists());
        }
    }

    #[cfg(any(windows, unix))]
    #[test]
    fn staging_owned_root_alias_never_adopts_unowned_or_foreign_targets() {
        for foreign in [false, true] {
            let (_root, database, source, target, plan) = fixture();
            let outside = tempfile::tempdir().unwrap();
            let marker = outside
                .path()
                .join(crate::device_sync::library_guard::ORIGINAL_ROOT_OWNER_FILE);
            let _foreign = if foreign {
                let other =
                    Database::open(outside.path().join("database/library.sqlite3")).unwrap();
                other.ensure_original_root(outside.path()).unwrap();
                Some(other)
            } else {
                None
            };
            let before = std::fs::read(&marker).ok();
            let sentinel = outside.path().join("unchanged");
            std::fs::write(&sentinel, b"private-synthetic-fixture").unwrap();
            let (_holder, _alias) = configure_alias(&database, outside.path());
            assert!(StagingOperation::prepare(database, &source, &target, &plan).is_err());
            assert_eq!(std::fs::read(&marker).ok(), before);
            assert_eq!(
                std::fs::read(sentinel).unwrap(),
                b"private-synthetic-fixture"
            );
            assert!(!outside.path().join("originals").exists());
            assert!(!outside.path().join("temporary").exists());
        }
    }

    #[cfg(any(windows, unix))]
    #[test]
    fn staging_owned_root_alias_retarget_cannot_publish_into_another_library() {
        let (root, database, source, target, plan) = fixture();
        database.ensure_original_root(root.path()).unwrap();
        let (_holder, alias) = configure_alias(&database, root.path());
        let mut operation =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        receive(&mut operation);
        let outside = tempfile::tempdir().unwrap();
        let other = Database::open(outside.path().join("database/library.sqlite3")).unwrap();
        other.ensure_original_root(outside.path()).unwrap();
        #[cfg(windows)]
        std::fs::remove_dir(&alias).unwrap();
        #[cfg(unix)]
        std::fs::remove_file(&alias).unwrap();
        link_directory(outside.path(), &alias);
        let lease = database.device_sync_exclusive().unwrap();
        assert!(matches!(
            operation.publish(
                &lease,
                operation.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {}
            ),
            Err(StagingError::RootOwnership | StagingError::PlanChanged)
        ));
        assert!(!outside.path().join("originals").exists());
        assert!(!root.path().join("originals").exists());
    }

    #[cfg(any(windows, unix))]
    #[test]
    fn staging_owned_root_alias_rechecks_current_root_and_marker_before_publish() {
        for retarget in [false, true] {
            let (root, database, source, target, plan) = fixture();
            database.ensure_original_root(root.path()).unwrap();
            let (_holder, alias) = configure_alias(&database, root.path());
            let mut operation =
                StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
            receive(&mut operation);
            let alternate = tempfile::tempdir().unwrap();
            if retarget {
                database.ensure_original_root(alternate.path()).unwrap();
                #[cfg(windows)]
                std::fs::remove_dir(&alias).unwrap();
                #[cfg(unix)]
                std::fs::remove_file(&alias).unwrap();
                link_directory(alternate.path(), &alias);
            } else {
                std::fs::write(
                    root.path()
                        .join(crate::device_sync::library_guard::ORIGINAL_ROOT_OWNER_FILE),
                    b"invalid-owner",
                )
                .unwrap();
            }
            let lease = database.device_sync_exclusive().unwrap();
            assert!(matches!(
                operation.publish(
                    &lease,
                    operation.operation_id(),
                    ABC_SHA,
                    &CancellationToken::default(),
                    &mut |_| {}
                ),
                Err(StagingError::RootOwnership | StagingError::PlanChanged)
            ));
            assert!(!root.path().join("originals").exists());
            assert!(!alternate.path().join("originals").exists());
        }
    }

    #[cfg(any(windows, unix))]
    #[test]
    fn staging_rejects_linked_runtime_and_cas_components_without_touching_outside() {
        for runtime in [true, false] {
            let (root, database, source, target, plan) = fixture();
            let outside = tempfile::tempdir().unwrap();
            let sentinel = outside.path().join("unchanged");
            std::fs::write(&sentinel, b"outside").unwrap();
            if runtime {
                link_directory(outside.path(), &root.path().join("temporary"));
                assert!(matches!(
                    StagingOperation::prepare(database, &source, &target, &plan),
                    Err(StagingError::UnsafePath)
                ));
            } else {
                let mut operation =
                    StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
                receive(&mut operation);
                link_directory(outside.path(), &root.path().join("originals"));
                let lease = database.device_sync_exclusive().unwrap();
                assert!(matches!(
                    operation.publish(
                        &lease,
                        operation.operation_id(),
                        ABC_SHA,
                        &CancellationToken::default(),
                        &mut |_| {}
                    ),
                    Err(StagingError::UnsafePath)
                ));
            }
            assert_eq!(std::fs::read(sentinel).unwrap(), b"outside");
            assert_eq!(std::fs::read_dir(outside.path()).unwrap().count(), 1);
        }
    }

    #[test]
    fn staging_changed_plan_and_foreign_root_ownership_are_rejected() {
        let (root, database, source, target, plan) = fixture();
        let mut operation =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        receive(&mut operation);
        let foreign_root = tempfile::tempdir().unwrap();
        let foreign = Database::open(foreign_root.path().join("database/library.sqlite3")).unwrap();
        foreign.ensure_original_root(foreign_root.path()).unwrap();
        std::fs::copy(
            foreign_root
                .path()
                .join(super::super::library_guard::ORIGINAL_ROOT_OWNER_FILE),
            root.path()
                .join(super::super::library_guard::ORIGINAL_ROOT_OWNER_FILE),
        )
        .unwrap();
        let lease = database.device_sync_exclusive().unwrap();
        assert!(matches!(
            operation.publish(
                &lease,
                operation.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {}
            ),
            Err(StagingError::RootOwnership)
        ));
        assert!(!root.path().join("originals").exists());
    }

    #[test]
    fn staging_cancellation_during_copy_never_reports_publication() {
        let (_root, database, source, target, plan) = fixture();
        let mut operation =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        receive(&mut operation);
        let lease = database.device_sync_exclusive().unwrap();
        let cancel = CancellationToken::default();
        let mut events = Vec::new();
        let result = operation.publish(
            &lease,
            operation.operation_id(),
            ABC_SHA,
            &cancel,
            &mut |event| {
                if event.phase == Phase::Copying && event.completed_bytes == 3 {
                    cancel.cancel();
                }
                events.push(event);
            },
        );
        assert!(matches!(result, Err(StagingError::Cancelled)));
        assert!(!events.iter().any(|event| event.phase == Phase::Published));
        assert_eq!(operation.progress().phase, Phase::Cancelled);
        assert!(!target_path(&operation.media_root, "jpg").exists());
        assert_eq!(
            operation.write_chunk(operation.operation_id(), ABC_SHA, 3, b"x"),
            Err(StagingError::Cancelled)
        );
    }

    #[test]
    fn staging_injected_io_failures_keep_old_files_and_other_operations() {
        for point in [
            IoPoint::Write,
            IoPoint::Copy,
            IoPoint::Sync,
            IoPoint::Publish,
        ] {
            let (root, database, source, target, plan) = fixture();
            let mut operation =
                StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
            let mut other =
                StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
            receive(&mut other);
            let sentinel = root.path().join("old-file");
            std::fs::write(&sentinel, b"old original").unwrap();
            if point == IoPoint::Write {
                operation
                    .begin_file(operation.operation_id(), ABC_SHA)
                    .unwrap();
                set_fault(point, std::io::ErrorKind::StorageFull);
                assert_eq!(
                    operation.write_chunk(operation.operation_id(), ABC_SHA, 0, b"abc"),
                    Err(StagingError::InsufficientSpace)
                );
            } else {
                receive(&mut operation);
                set_fault(point, std::io::ErrorKind::Other);
                let lease = database.device_sync_exclusive().unwrap();
                let result = operation.publish(
                    &lease,
                    operation.operation_id(),
                    ABC_SHA,
                    &CancellationToken::default(),
                    &mut |_| {},
                );
                assert!(matches!(
                    result,
                    Err(StagingError::Write | StagingError::Sync | StagingError::Publish)
                ));
            }
            assert_eq!(std::fs::read(sentinel).unwrap(), b"old original");
            assert_eq!(other.progress().phase, Phase::Verified);
            assert!(other.directory.is_dir());
            assert!(!target_path(root.path(), "jpg").exists());
            assert!(!operation.directory.exists());
        }
    }

    fn set_fault(point: IoPoint, kind: std::io::ErrorKind) {
        FAULT.set(Some((point, kind)));
    }

    #[test]
    fn staging_short_write_reports_only_confirmed_bytes() {
        struct ShortWriter(Vec<u8>);
        impl Write for ShortWriter {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                if self.0.is_empty() {
                    self.0.push(bytes[0]);
                    Ok(1)
                } else {
                    Ok(0)
                }
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let mut writer = ShortWriter(Vec::new());
        let mut status = progress(Phase::Receiving, 0, Some(3));
        let mut written = 0;
        assert_eq!(
            write_counted(&mut writer, b"abc", &mut written, &mut status, 3,),
            Err(StagingError::Write)
        );
        assert_eq!(writer.0, b"a");
        assert_eq!(written, 1);
        assert_eq!(status.completed_bytes, 1);
    }

    #[test]
    fn staging_finish_sync_failure_and_hash_cancellation_remove_only_own_parts() {
        for sync_failure in [false, true] {
            let (_root, database, source, target, plan) = fixture();
            let mut operation =
                StagingOperation::prepare(database, &source, &target, &plan).unwrap();
            let id = operation.operation_id();
            operation.begin_file(id, ABC_SHA).unwrap();
            operation.write_chunk(id, ABC_SHA, 0, b"abc").unwrap();
            let cancel = CancellationToken::default();
            if sync_failure {
                set_fault(IoPoint::Sync, std::io::ErrorKind::Other);
            }
            let result = operation.finish_file(id, ABC_SHA, &cancel, &mut |event| {
                if !sync_failure && event.phase == Phase::Verifying {
                    cancel.cancel();
                }
            });
            assert_eq!(
                result,
                Err(if sync_failure {
                    StagingError::Sync
                } else {
                    StagingError::Cancelled
                })
            );
            assert!(!operation.directory.exists());
        }
    }

    #[test]
    fn staging_real_257_mib_is_streamed_verified_and_published_without_nso_limit() {
        let (root, database, mut source, target, _) = fixture();
        let sha = "aeabb8952ff1b1e5165c8d60ae8c2876cf8d20b78884f3945b9c53b97c5051a0";
        let length = 257_u64 * 1024 * 1024;
        if let ManifestRecord::Media(record) = &mut source.records[0] {
            record.sha256 = sha.into();
            record.length = length;
            record.kind = MediaKind::Video;
            record.extension = "mp4".into();
        }
        let mut operation = StagingOperation::prepare(
            database.clone(),
            &source,
            &target,
            &update_plan(&source, &target),
        )
        .unwrap();
        let id = operation.operation_id();
        operation.begin_file(id, sha).unwrap();
        let chunk = [0x5a_u8; MAX_CHUNK_BYTES];
        for index in 0..length / MAX_CHUNK_BYTES as u64 {
            let actual = operation
                .write_chunk(id, sha, index * MAX_CHUNK_BYTES as u64, &chunk)
                .unwrap();
            assert_eq!(actual.completed_bytes, (index + 1) * MAX_CHUNK_BYTES as u64);
        }
        assert_eq!(
            std::fs::metadata(operation.entries[sha].part.as_ref().unwrap().path())
                .unwrap()
                .len(),
            length
        );
        operation
            .finish_file(id, sha, &CancellationToken::default(), &mut |_| {})
            .unwrap();
        let lease = database.device_sync_exclusive().unwrap();
        let published = operation
            .publish(&lease, id, sha, &CancellationToken::default(), &mut |_| {})
            .unwrap();
        let mut file = File::open(published.identity().path()).unwrap();
        assert_eq!(file.metadata().unwrap().len(), length);
        let mut digest = Sha256::new();
        let mut buffer = [0_u8; MAX_CHUNK_BYTES];
        loop {
            let count = file.read(&mut buffer).unwrap();
            if count == 0 {
                break;
            }
            digest.update(&buffer[..count]);
        }
        assert_eq!(hex::encode(digest.finalize()), sha);
        drop(file);
        eprintln!(
            "257 MiB fixture: root={}, bytes={}, sha={}",
            root.path().display(),
            length,
            sha
        );
        assert!(published.rollback().unwrap());
    }

    #[test]
    #[ignore = "requires explicit NSOALBUM_DEVICE_SYNC_CROSS_VOLUME_ROOT on another real volume"]
    fn staging_cross_volume_real_opt_in_copy() {
        let opt_in = std::env::var_os("NSOALBUM_DEVICE_SYNC_CROSS_VOLUME_ROOT")
            .expect("explicit cross-volume root is required; no skipped early return");
        let other = tempfile::tempdir_in(PathBuf::from(opt_in)).unwrap();
        let (root, database, source, target, plan) = fixture();
        let settings = crate::settings::AppSettings {
            proxy_url: None,
            doh_enabled: false,
            library_path: other.path().to_string_lossy().into_owned(),
            theme: "ocean".into(),
            language: "en".into(),
            gallery_columns: 4,
            gallery_rows: 3,
            show_note_preview: true,
            show_game_tag: true,
            compact_tag_display: true,
            auto_play_video: false,
            auto_sync_on_launch: false,
            notify_on_auto_sync: true,
            show_splatoon_schedule: true,
            show_splatoon_friend_activity: false,
            close_behavior: "ask".into(),
            custom_font_paths: vec![],
            sync_policy: Default::default(),
        };
        database.set_setting("app.settings", &settings).unwrap();
        let mut operation =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        assert!(!operation.space_preflight().requirements.same_volume);
        receive(&mut operation);
        operation.cancel().unwrap();
        drop(operation);
        let mut operation =
            StagingOperation::prepare(database.clone(), &source, &target, &plan).unwrap();
        let requirements = &operation.space_preflight().requirements;
        assert!(!requirements.same_volume);
        assert_eq!(requirements.staging_bytes, 0);
        assert_eq!(requirements.publication_bytes, 3);
        assert_eq!(requirements.stage_peak_bytes, 0);
        assert_eq!(requirements.media_peak_bytes, 3);
        assert!(!operation.requires_transfer(ABC_SHA).unwrap());
        let lease = database.device_sync_exclusive().unwrap();
        let published = operation
            .publish(
                &lease,
                operation.operation_id(),
                ABC_SHA,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        assert_eq!(std::fs::read(published.identity().path()).unwrap(), b"abc");
        assert!(published.created_by_operation());
        eprintln!(
            "cross-volume: private={}, target={}, bytes=3",
            root.path().display(),
            other.path().display()
        );
        assert!(published.rollback().unwrap());
    }
}
