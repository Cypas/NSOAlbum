//! Safe projections of the existing session, plan and durable backup owners.
//! No account material, invitations, paths or business-usable SQL identifiers.
//! Cursors are opaque, authenticated positions, not confidential content.
use std::sync::OnceLock;

use serde::Serialize;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

use super::{
    driver::{DriverError, State},
    manifest::{MAX_PAGE_BYTES, MAX_PAGE_ITEMS},
    planner::{Action, Conflict, ConflictReason, SpaceEstimate, SyncMode, SyncPlan},
    receiver::ReceiverError,
    source_names::SourceDescription,
    staging::StagingError,
    work::{WorkControl, WorkStage},
    SessionError,
};
use crate::error::CoreError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum ReadError {
    Busy,
    PreviewChanged,
    RecoveryRequired,
    PermissionDenied,
    WindowFull,
    Unavailable,
    Disconnected,
    Timeout,
    InvalidInput,
    VersionMismatch,
    Internal,
    Cancelled,
    InsufficientSpace,
}

impl ReadError {
    pub fn core(error: &CoreError) -> Self {
        match error {
            CoreError::LibraryBusy | CoreError::LibraryReferenced => Self::Busy,
            CoreError::LibraryLockUnavailable => Self::Unavailable,
            CoreError::LibraryRootOwnership => Self::PermissionDenied,
            CoreError::DeviceSyncRecoveryRequired => Self::RecoveryRequired,
            CoreError::Cancelled => Self::Cancelled,
            CoreError::InvalidConfig(_) | CoreError::Json(_) | CoreError::Url(_) => {
                Self::InvalidInput
            }
            CoreError::Io(error) => match error.kind() {
                std::io::ErrorKind::PermissionDenied => Self::PermissionDenied,
                std::io::ErrorKind::TimedOut => Self::Timeout,
                std::io::ErrorKind::NotFound => Self::Unavailable,
                std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::ConnectionReset => {
                    Self::Disconnected
                }
                _ => Self::Internal,
            },
            CoreError::Database(rusqlite::Error::SqliteFailure(error, _))
                if matches!(
                    error.code,
                    rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
                ) =>
            {
                Self::Busy
            }
            CoreError::Database(rusqlite::Error::SqliteFailure(error, _))
                if error.code == rusqlite::ErrorCode::OperationInterrupted =>
            {
                Self::Unavailable
            }
            _ => Self::Internal,
        }
    }
    pub fn session(error: &SessionError) -> Self {
        match error {
            SessionError::VersionMismatch => Self::VersionMismatch,
            SessionError::Expired => Self::Timeout,
            SessionError::Terminal | SessionError::Io => Self::Disconnected,
            SessionError::NotConfirmed | SessionError::Authentication => Self::PermissionDenied,
            SessionError::Consumed => Self::PreviewChanged,
            SessionError::InvalidQr | SessionError::Protocol | SessionError::Bounds => {
                Self::InvalidInput
            }
            SessionError::Tls => Self::Unavailable,
        }
    }
    pub fn driver(error: &DriverError) -> Self {
        match error {
            DriverError::Channel(error) => Self::session(error),
            DriverError::Library => Self::PreviewChanged,
            DriverError::Timeout => Self::Timeout,
            DriverError::Cancelled => Self::Cancelled,
            DriverError::InsufficientSpace => Self::InsufficientSpace,
            DriverError::AccountsUnsupported => Self::PermissionDenied,
            DriverError::Protocol | DriverError::Bounds => Self::InvalidInput,
        }
    }
    pub fn staging(error: &StagingError) -> Self {
        match error {
            StagingError::LibraryBusy | StagingError::Referenced => Self::Busy,
            StagingError::ReceivingWindowFull => Self::WindowFull,
            StagingError::PlanChanged | StagingError::Conflict => Self::PreviewChanged,
            StagingError::RootOwnership | StagingError::InvalidLease | StagingError::UnsafePath => {
                Self::PermissionDenied
            }
            StagingError::Cancelled => Self::Cancelled,
            StagingError::Read
            | StagingError::Write
            | StagingError::Sync
            | StagingError::Publish => Self::Unavailable,
            StagingError::InsufficientSpace => Self::InsufficientSpace,
            StagingError::Database | StagingError::Cleanup => Self::Internal,
            _ => Self::InvalidInput,
        }
    }
    pub fn receiver(error: &ReceiverError) -> Self {
        match error {
            ReceiverError::AuthorizationRequired => Self::PermissionDenied,
            ReceiverError::AuthorizationMismatch | ReceiverError::PlanChanged => {
                Self::PreviewChanged
            }
            ReceiverError::InvalidState => Self::InvalidInput,
            ReceiverError::Core(error) => Self::core(error),
            ReceiverError::Staging(error) => Self::staging(error),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum PairingStage {
    Handshaking,
    Authenticating,
    AwaitingConfirmation,
    Confirmed,
    Terminal,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum TransportKind {
    Tcp,
    Usb,
}
#[derive(Debug, Clone, Serialize)]
pub struct AgreedConfiguration {
    pub phone_to_desktop: bool,
    pub mode: SyncMode,
    pub include_accounts: bool,
}
#[derive(Debug, Clone, Serialize)]
pub struct ProgressView {
    pub work_stage: WorkStage,
    pub work_active: bool,
    pub scanned_items: u64,
    pub total_items: Option<u64>,
    pub transferred_bytes: Option<u64>,
    pub transfer_total_bytes: Option<u64>,
    pub transfer_bytes_per_second: Option<u64>,
}
impl ProgressView {
    pub fn observing(work: &WorkControl) -> Self {
        let observation = work.observe();
        Self {
            work_stage: observation.stage,
            work_active: observation.active,
            scanned_items: observation.scanned_items,
            total_items: None,
            transferred_bytes: None,
            transfer_total_bytes: None,
            transfer_bytes_per_second: None,
        }
    }
}
#[derive(Debug, Clone, Serialize)]
pub struct EndpointView {
    pub pairing: PairingStage,
    pub confirmation_available: bool,
    pub invitation_remaining_ms: Option<u64>,
    pub peer_name: Option<String>,
    pub peer_clock_skew_seconds: Option<i64>,
    pub transport: TransportKind,
    pub host: bool,
    pub controller: bool,
    pub phone_controlled: bool,
    pub accounts_consent_authorized: bool,
    pub preview_approved: bool,
    pub source: Option<bool>,
    pub configuration: Option<AgreedConfiguration>,
    pub stage: State,
    pub terminal: bool,
    pub cleanup_pending: bool,
    pub progress: ProgressView,
}
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChangeCounts {
    pub added: u64,
    pub replaced: u64,
    pub removed: u64,
    pub kept: u64,
}
impl ChangeCounts {
    fn record(&mut self, action: Action) {
        match action {
            Action::Add => self.added += 1,
            Action::Replace => self.replaced += 1,
            Action::Remove => self.removed += 1,
            Action::Keep => self.kept += 1,
        }
    }
}
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConflictCounts {
    pub unknown_revision: u64,
    pub equal_revision: u64,
    pub clock_skew: u64,
}
#[derive(Debug, Clone, Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreviewSummary {
    pub binding: String,
    pub source_device: Option<SourceDescription>,
    pub mode: SyncMode,
    pub media: ChangeCounts,
    pub albums: ChangeCounts,
    pub space: SpaceEstimate,
    pub conflicts: ConflictCounts,
    pub receiver_budget: Option<super::space_budget::ReceiverBudgetView>,
    pub accounts: Option<ChangeCounts>,
}
pub fn summarize(
    plan: &SyncPlan,
    binding: &str,
    source_device: Option<SourceDescription>,
    work: &WorkControl,
) -> Result<PreviewSummary, CoreError> {
    let mut media = ChangeCounts::default();
    let mut albums = ChangeCounts::default();
    let mut conflicts = ConflictCounts::default();
    for decision in &plan.media {
        work.check()?;
        media.record(decision.action);
    }
    for decision in &plan.albums {
        work.check()?;
        albums.record(decision.action);
    }
    for conflict in &plan.conflicts {
        work.check()?;
        match conflict.reason {
            ConflictReason::UnknownRevision => conflicts.unknown_revision += 1,
            ConflictReason::EqualRevision => conflicts.equal_revision += 1,
            ConflictReason::ClockSkew => conflicts.clock_skew += 1,
        }
    }
    Ok(PreviewSummary {
        binding: binding.into(),
        source_device,
        mode: plan.mode,
        media,
        albums,
        conflicts,
        space: plan.space.clone(),
        receiver_budget: None,
        accounts: None,
    })
}

#[derive(Debug, Clone, Serialize)]
pub struct ConflictPage {
    pub items: Vec<Conflict>,
    pub next: Option<String>,
}
#[derive(Debug, Clone, Serialize)]
pub struct BackupMetadata {
    pub backup: Option<String>,
    pub source_library_uuid: Option<String>,
    pub source_name: Option<String>,
    pub created_at: Option<String>,
    /// None is unknown, never an assertion that the backup is library-only.
    pub includes_accounts: Option<bool>,
    /// Absence means metadata eligibility only; payload/SHA/originals are
    /// validated by the controlled restore, not by this bounded projection.
    pub unavailable_reason: Option<BackupUnavailableReason>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum BackupUnavailableReason {
    InvalidIdentity,
    InvalidMetadata,
    InvalidPayload,
    OwnershipUnknown,
    OwnershipInvalid,
    JournalInvalid,
    IncompleteOperation,
    InternalCompensation,
}
#[derive(Debug, Clone, Serialize)]
pub struct BackupPage {
    pub items: Vec<BackupMetadata>,
    pub next: Option<String>,
}
#[derive(Debug, Clone, Serialize)]
pub struct RestoreSummary {
    pub binding: String,
    pub current_digest: String,
    pub restored_digest: String,
    pub media: ChangeCounts,
    pub albums: ChangeCounts,
    pub includes_accounts: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct EndpointRead {
    pub value: Option<EndpointView>,
    pub progress: ProgressView,
    pub error: Option<ReadError>,
    pub tcp: Option<super::runtime::TcpView>,
}
#[derive(Debug, Clone, Serialize)]
pub struct PreviewRead {
    pub value: Option<PreviewSummary>,
    pub error: Option<ReadError>,
}
#[derive(Debug, Clone, Serialize)]
pub struct ConflictPageRead {
    pub value: Option<ConflictPage>,
    pub error: Option<ReadError>,
}
#[derive(Debug, Clone, Serialize)]
pub struct BackupPageRead {
    pub value: Option<BackupPage>,
    pub error: Option<ReadError>,
}
#[derive(Debug, Clone, Serialize)]
pub struct RestoreSummaryRead {
    pub value: Option<RestoreSummary>,
    pub error: Option<ReadError>,
}
macro_rules! read_result {
    ($name:ident, $value:ty) => {
        impl From<Result<$value, ReadError>> for $name {
            fn from(result: Result<$value, ReadError>) -> Self {
                match result {
                    Ok(value) => Self {
                        value: Some(value),
                        error: None,
                    },
                    Err(error) => Self {
                        value: None,
                        error: Some(error),
                    },
                }
            }
        }
    };
}
read_result!(PreviewRead, PreviewSummary);
read_result!(ConflictPageRead, ConflictPage);
read_result!(BackupPageRead, BackupPage);
read_result!(RestoreSummaryRead, RestoreSummary);

static CURSOR_KEY: OnceLock<[u8; 32]> = OnceLock::new();
fn cursor_tag(scope: &str, position: &str) -> String {
    let key = CURSOR_KEY.get_or_init(rand::random);
    let mut hash = Sha256::new();
    hash.update(key);
    hash.update((scope.len() as u64).to_be_bytes());
    hash.update(scope.as_bytes());
    hash.update(position.as_bytes());
    hex::encode(hash.finalize())
}
pub(crate) fn cursor(scope: &str, position: &str) -> String {
    format!("{position}:{}", cursor_tag(scope, position))
}
pub(crate) fn position<'a>(scope: &str, value: &'a str) -> Result<&'a str, ReadError> {
    if value.len() > 128 {
        return Err(ReadError::PreviewChanged);
    }
    let (position, tag) = value.split_once(':').ok_or(ReadError::PreviewChanged)?;
    let expected = cursor_tag(scope, position);
    if position.is_empty() || tag.as_bytes().ct_eq(expected.as_bytes()).unwrap_u8() != 1 {
        return Err(ReadError::PreviewChanged);
    }
    Ok(position)
}
pub(crate) fn check_limit(limit: usize) -> Result<(), ReadError> {
    if !(1..=MAX_PAGE_ITEMS).contains(&limit) {
        Err(ReadError::InvalidInput)
    } else {
        Ok(())
    }
}
pub(crate) fn fits(value: &impl Serialize) -> Result<bool, ReadError> {
    Ok(serde_json::to_vec(value)
        .map_err(|_| ReadError::Internal)?
        .len()
        <= MAX_PAGE_BYTES - 128)
}
pub(crate) fn conflict_page(
    plan: &SyncPlan,
    scope: &str,
    after: Option<&str>,
    limit: usize,
) -> Result<ConflictPage, ReadError> {
    check_limit(limit)?;
    let offset = match after {
        None => 0,
        Some(value) => {
            let raw = position(scope, value)?;
            let n = raw
                .parse::<usize>()
                .map_err(|_| ReadError::PreviewChanged)?;
            if n == 0 || n >= plan.conflicts.len() || n.to_string() != raw {
                return Err(ReadError::PreviewChanged);
            }
            n
        }
    };
    let mut page = ConflictPage {
        items: vec![],
        next: None,
    };
    for conflict in plan.conflicts.iter().skip(offset).take(limit) {
        page.items.push(conflict.clone());
        let next = offset + page.items.len();
        page.next = (next < plan.conflicts.len()).then(|| cursor(scope, &next.to_string()));
        if !fits(&page)? {
            page.items.pop();
            if page.items.is_empty() {
                return Err(ReadError::InvalidInput);
            }
            page.next = Some(cursor(scope, &(next - 1).to_string()));
            break;
        }
    }
    Ok(page)
}
