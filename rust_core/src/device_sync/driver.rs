//! Single-session, locally authorized library-transfer driver.
mod files;
mod flow;
pub mod pump;
mod throughput;

use super::{
    accounts::{AccountCollector, AccountSet},
    clock::{Clock, ConnectionSample},
    diagnostics::{self, Boundary as DiagnosticBoundary},
    library_guard::ExclusiveLease,
    local_apply::{Identity as ApplyIdentity, LifecycleControl, LocalApplyAuthority},
    metrics::{IoKind, Metrics, Phase},
    planner::{build_plan_controlled, SyncMode, SyncPlan},
    receiver::{
        ApplyBoundary, ApplyReceipt, ApplyState, CommitGuard, LocalAuthorization, ReceiveOperation,
        RetainedSourceSnapshot, Snapshot,
    },
    wire::{self, ApplyPhase, ApplyWork, Envelope, Message, MetadataReceiver, MetadataSender},
    Session, SessionError, SessionState,
};
use crate::database::Database;
use crate::error::{CoreError, CoreResult};
use crate::sync::CancellationToken;
use std::{
    collections::{BTreeSet, VecDeque},
    fs::File,
    io::Read,
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering},
        Arc,
    },
    thread::JoinHandle,
};
use uuid::Uuid;
use zeroize::Zeroizing;

pub use super::wire::Direction;
const DATA_MS: u64 = 60_000;
const USER_MS: u64 = 300_000;
pub const LEASE_MS: u64 = 30_000;
const MAX_SQL_WORK: u64 = 512_000_000;
const SQL_MS: u64 = 300_000;
const MAX_OUTBOX: usize = 4;
const MAX_INFLIGHT_CHUNKS: usize = (flow::WINDOW_BYTES as usize) / wire::MEDIA_CHUNK;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum State {
    Pairing,
    Configuring,
    Scanning,
    Comparing,
    AwaitingApproval,
    AwaitingAccountConsent,
    AwaitingAccountFinal,
    AwaitingTargetAccountFinal,
    AwaitingExternal,
    Transferring,
    Verifying,
    Applying,
    Completed,
    CompletedUnconfirmed,
    Cancelled,
    Failed,
    RecoveryPending,
}
impl State {
    pub fn terminal(self) -> bool {
        matches!(
            self,
            Self::Completed
                | Self::CompletedUnconfirmed
                | Self::Cancelled
                | Self::Failed
                | Self::RecoveryPending
        )
    }
}

#[derive(Debug, thiserror::Error)]
pub enum DriverError {
    #[error("secure channel failed: {0:?}")]
    Channel(SessionError),
    #[error("device-sync message is invalid for this session or stage")]
    Protocol,
    #[error("device-sync resource boundary exceeded")]
    Bounds,
    #[error("device-sync local library or preview changed")]
    Library,
    #[error("device-sync operation timed out")]
    Timeout,
    #[error("accounts are not supported in this transfer stage")]
    AccountsUnsupported,
    #[error("device-sync operation was cancelled")]
    Cancelled,
    #[error("the receiving device does not have enough space")]
    InsufficientSpace,
}
impl From<SessionError> for DriverError {
    fn from(error: SessionError) -> Self {
        Self::Channel(error)
    }
}
type Result<T> = std::result::Result<T, DriverError>;

fn work_error(error: CoreError) -> DriverError {
    if matches!(error, CoreError::Cancelled) {
        DriverError::Cancelled
    } else {
        DriverError::Library
    }
}

fn receiver_work_error(error: super::receiver::ReceiverError) -> DriverError {
    match error {
        super::receiver::ReceiverError::Staging(
            super::staging::StagingError::InsufficientSpace,
        ) => DriverError::InsufficientSpace,
        super::receiver::ReceiverError::Core(error) => work_error(error),
        _ => DriverError::Library,
    }
}

#[derive(Debug, Default, Clone)]
pub struct TransferProgress {
    pub transferred_bytes: u64,
    pub transfer_total_bytes: u64,
    pub metadata_parts: u64,
    pub apply_work: u64,
    pub peak_outbox_messages: usize,
    pub peak_plaintext_bytes: usize,
    pub peak_ciphertext_bytes: usize,
    pub peak_receiving_files: usize,
}

#[derive(Clone, Copy)]
struct Config {
    direction: Direction,
    mode: SyncMode,
    accounts: bool,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Step {
    Config,
    ClockReply,
    ClockSample,
    AccountConsent,
    SendAccounts,
    ReceiveAccounts,
    AccountBinding,
    SendSource,
    ReceiveSource,
    PreparingTarget,
    SendTarget,
    ReceiveTarget,
    Preview,
    Approval,
    Approved,
    Sending,
    Receiving,
    SourceReady,
    Lease,
    TargetFinal,
    Apply,
    Done,
}
struct SendingFile {
    sha: String,
    file: File,
    length: u64,
    offset: u64,
    awaiting: bool,
    pending_chunks: VecDeque<(u64, u64)>,
    acknowledged: u64,
}
struct PendingLease {
    id: u64,
    work: ApplyWork,
    requested: u64,
}
type Verification = JoinHandle<(
    ReceiveOperation,
    std::result::Result<(), super::staging::StagingError>,
)>;

struct Preparation {
    session: String,
    operation: String,
    source_digest: String,
    bytes: Arc<super::work::PreparationBytes>,
    last_observed: u64,
    last_enqueued: u64,
    active: bool,
    worker: JoinHandle<super::receiver::ReceiverResult<ReceiveOperation>>,
}

struct PreparationAllowance {
    source_digest: String,
    limit: u64,
    completed: u64,
    open: bool,
}

fn preparation_limit(snapshot: &Snapshot) -> Result<u64> {
    snapshot
        .manifest
        .records
        .iter()
        .try_fold(0_u64, |sum, record| {
            if let super::manifest::ManifestRecord::Media(record) = record {
                sum.checked_add(record.length).ok_or(DriverError::Bounds)
            } else {
                Ok(sum)
            }
        })
}

struct LeaseCleanup {
    lease: std::sync::Mutex<Option<ExclusiveLease>>,
    changed: std::sync::Condvar,
    clock: Arc<dyn Clock>,
    until: u64,
}
impl LeaseCleanup {
    fn start(lease: ExclusiveLease, clock: Arc<dyn Clock>, until: u64) -> Arc<Self> {
        let cleanup = Arc::new(Self {
            lease: std::sync::Mutex::new(Some(lease)),
            changed: std::sync::Condvar::new(),
            clock,
            until,
        });
        let task = cleanup.clone();
        std::thread::spawn(move || {
            let mut lease = task.lease.lock().unwrap_or_else(|e| e.into_inner());
            while lease.is_some() {
                let remaining = task.until.saturating_sub(task.clock.monotonic_ms());
                if remaining == 0 {
                    lease.take();
                    break;
                }
                let (next, _) = task
                    .changed
                    .wait_timeout(
                        lease,
                        std::time::Duration::from_millis(remaining.min(LEASE_MS)),
                    )
                    .unwrap_or_else(|e| e.into_inner());
                lease = next;
            }
        });
        cleanup
    }
    fn poll(&self) -> bool {
        let mut lease = self.lease.lock().unwrap_or_else(|e| e.into_inner());
        if self.clock.monotonic_ms() >= self.until {
            lease.take();
            self.changed.notify_all();
        }
        lease.is_some()
    }
}

/// All fields are local-only. A peer cannot construct authorization or permits.
struct Permit {
    clock: Arc<dyn Clock>,
    cancel: CancellationToken,
    active: AtomicBool,
    until: AtomicU64,
    work: AtomicU64,
    boundary: AtomicU8,
    budget: AtomicU64,
    sql_work: AtomicU64,
    sql_started: AtomicBool,
    sql_until: AtomicU64,
}
impl CommitGuard for Permit {
    fn check(&self) -> CoreResult<()> {
        self.cancel.check()?;
        let failure = if !self.active.load(Ordering::SeqCst) {
            Some(DiagnosticBoundary::ApplyPermitInactive)
        } else if self.clock.monotonic_ms() >= self.until.load(Ordering::SeqCst) {
            Some(DiagnosticBoundary::ApplyPermitLeaseExpired)
        } else if self.work.load(Ordering::SeqCst) > self.budget.load(Ordering::SeqCst) {
            Some(DiagnosticBoundary::ApplyPermitPublicationBudget)
        } else if self.sql_work.load(Ordering::SeqCst) > MAX_SQL_WORK {
            Some(DiagnosticBoundary::ApplyPermitSqlBudget)
        } else if self.sql_started.load(Ordering::SeqCst)
            && self.clock.monotonic_ms() >= self.sql_until.load(Ordering::SeqCst)
        {
            Some(DiagnosticBoundary::ApplyPermitSqlDeadline)
        } else {
            None
        };
        if let Some(boundary) = failure {
            diagnostics::checkpoint(boundary);
            return Err(CoreError::Cancelled);
        }
        Ok(())
    }
    fn sql_started(&self) {
        self.sql_until.store(
            self.clock.monotonic_ms().saturating_add(SQL_MS),
            Ordering::SeqCst,
        );
        self.sql_started.store(true, Ordering::SeqCst);
    }
    fn sql_progress(&self) {
        self.sql_work.fetch_add(2048, Ordering::SeqCst);
    }
}

pub(crate) struct TransferObserver {
    throughput: throughput::Throughput,
    clock: Arc<dyn Clock>,
}
impl TransferObserver {
    pub(crate) fn project(&self, progress: &mut super::read_model::ProgressView) {
        self.throughput.project(self.clock.monotonic_ms(), progress);
    }
}

pub struct Driver {
    session: Session,
    database: Arc<Database>,
    name: String,
    clock: Arc<dyn Clock>,
    state: State,
    step: Step,
    config: Option<Config>,
    sample: Option<ConnectionSample>,
    clock_start: Option<(i64, u64)>,
    sent_sequence: u64,
    received_sequence: u64,
    outbox: VecDeque<Message>,
    flush_required: bool,
    ciphertext_empty: bool,
    outstanding_ciphertext: usize,
    success_until: Option<u64>,
    sender: Option<MetadataSender>,
    collector: Option<MetadataReceiver>,
    retained: Option<RetainedSourceSnapshot>,
    source: Option<Snapshot>,
    target: Option<Snapshot>,
    source_digest: Option<String>,
    target_digest: Option<String>,
    plan: Option<SyncPlan>,
    binding: Option<String>,
    receive: Option<ReceiveOperation>,
    authorization: Option<LocalAuthorization>,
    needed: VecDeque<String>,
    served: BTreeSet<String>,
    file: Option<SendingFile>,
    pending_files: VecDeque<SendingFile>,
    awaiting_files: VecDeque<SendingFile>,
    requested_files: VecDeque<String>,
    receiving: Option<(String, u64, u64)>,
    receive_ack: flow::CumulativeAck,
    last_ack: Option<(String, u64)>,
    recent_acks: VecDeque<(String, u64)>,
    cancel: CancellationToken,
    permit: Arc<Permit>,
    work: super::work::WorkControl,
    preview_summary: Option<super::read_model::PreviewSummary>,
    worker: Option<JoinHandle<std::result::Result<ApplyReceipt, super::receiver::ReceiverError>>>,
    receipt: Option<ApplyReceipt>,
    source_lease: Option<ExclusiveLease>,
    source_until: u64,
    lease_id: u64,
    lease_work: ApplyWork,
    pending_lease: Option<PendingLease>,
    last_work: ApplyWork,
    deadline: u64,
    progress: TransferProgress,
    apply_observer: Option<Arc<dyn Fn(ApplyBoundary) + Send + Sync>>,
    verification: Option<Verification>,
    verification_bytes: Arc<AtomicU64>,
    verification_sent: u64,
    preparation: Option<Preparation>,
    preparation_allowance: Option<PreparationAllowance>,
    source_sql_until: Option<u64>,
    issued_until: u64,
    cleanup: Option<Arc<LeaseCleanup>>,
    transport_close: Option<Box<dyn FnOnce() + Send>>,
    export_accounts: Option<AccountSet>,
    import_accounts: Option<AccountSet>,
    source_account_state: Option<String>,
    target_account_state: Option<String>,
    account_digest: Option<String>,
    account_sender: Option<Zeroizing<Vec<u8>>>,
    account_offset: usize,
    account_collector: Option<AccountCollector>,
    external_reference: Option<Uuid>,
    account_final: bool,
    account_request: Option<(String, u64, ApplyWork)>,
    account_steps: u16,
    account_decision: Option<bool>,
    peer_account_decision: Option<bool>,
    sent_account_decision: Option<bool>,
    controller_account_consent: Option<bool>,
    preview_approved: bool,
    throughput: throughput::Throughput,
    metrics: Metrics,
    metrics_reported: bool,
    lifecycle: Arc<LifecycleControl>,
    local_authority: Option<Arc<LocalApplyAuthority>>,
    local_identity: Option<ApplyIdentity>,
    receiver_binding: Option<String>,
    pending_ready: Option<ApplyIdentity>,
    source_ack_until: Option<u64>,
    detached: bool,
    session_cleanup_pending: bool,
    benchmark_binding: Option<String>,
    benchmark_transport_pending: bool,
    benchmark_measurement: Option<String>,
    #[cfg(test)]
    fail_local_spawn: bool,
}
impl Driver {
    pub fn new(
        session: Session,
        database: Arc<Database>,
        name: &str,
        clock: Arc<dyn Clock>,
    ) -> Result<Self> {
        if name.trim().is_empty()
            || name.len() > 128
            || name.chars().any(char::is_control)
            || session.state() == SessionState::Terminal
        {
            return Err(DriverError::Protocol);
        }
        let now = clock.monotonic_ms();
        let cancel = CancellationToken::default();
        let lifecycle = LifecycleControl::new(cancel.clone());
        let permit = Arc::new(Permit {
            clock: clock.clone(),
            cancel: cancel.clone(),
            active: AtomicBool::new(false),
            until: AtomicU64::new(0),
            work: AtomicU64::new(0),
            boundary: AtomicU8::new(0),
            budget: AtomicU64::new(0),
            sql_work: AtomicU64::new(0),
            sql_started: AtomicBool::new(false),
            sql_until: AtomicU64::new(0),
        });
        let state = if session.state() == SessionState::Confirmed {
            State::Configuring
        } else {
            State::Pairing
        };
        let session_id =
            Uuid::parse_str(session.session_id()).map_err(|_| DriverError::Protocol)?;
        if session.state() == SessionState::Confirmed {
            database
                .device_sync_begin_session(
                    session_id,
                    Uuid::parse_str(session.operation_id()).map_err(|_| DriverError::Protocol)?,
                )
                .map_err(|_| DriverError::Library)?;
        }
        Ok(Self {
            session,
            database,
            name: name.into(),
            clock,
            state,
            step: Step::Config,
            config: None,
            sample: None,
            clock_start: None,
            sent_sequence: 0,
            received_sequence: 0,
            outbox: VecDeque::new(),
            flush_required: false,
            ciphertext_empty: false,
            outstanding_ciphertext: 0,
            success_until: None,
            sender: None,
            collector: None,
            retained: None,
            source: None,
            target: None,
            source_digest: None,
            target_digest: None,
            plan: None,
            binding: None,
            receive: None,
            authorization: None,
            needed: VecDeque::new(),
            served: BTreeSet::new(),
            file: None,
            pending_files: VecDeque::new(),
            awaiting_files: VecDeque::new(),
            requested_files: VecDeque::new(),
            receiving: None,
            receive_ack: Default::default(),
            last_ack: None,
            recent_acks: VecDeque::new(),
            work: super::work::WorkControl::new(cancel.clone()).with_sync_session(session_id),
            preview_summary: None,
            cancel,
            permit,
            worker: None,
            receipt: None,
            source_lease: None,
            source_until: 0,
            lease_id: 0,
            lease_work: ApplyWork::default(),
            pending_lease: None,
            last_work: ApplyWork::default(),
            deadline: now.saturating_add(USER_MS),
            progress: TransferProgress::default(),
            apply_observer: None,
            verification: None,
            verification_bytes: Arc::new(AtomicU64::new(0)),
            verification_sent: 0,
            preparation: None,
            preparation_allowance: None,
            source_sql_until: None,
            issued_until: 0,
            cleanup: None,
            transport_close: None,
            export_accounts: None,
            import_accounts: None,
            source_account_state: None,
            target_account_state: None,
            account_digest: None,
            account_sender: None,
            account_offset: 0,
            account_collector: None,
            external_reference: None,
            account_final: false,
            account_request: None,
            account_steps: 0,
            account_decision: None,
            peer_account_decision: None,
            sent_account_decision: None,
            controller_account_consent: None,
            preview_approved: false,
            throughput: throughput::Throughput::default(),
            metrics: Metrics::new(now),
            metrics_reported: false,
            lifecycle,
            local_authority: None,
            local_identity: None,
            receiver_binding: None,
            pending_ready: None,
            source_ack_until: None,
            detached: false,
            session_cleanup_pending: false,
            benchmark_binding: None,
            benchmark_transport_pending: false,
            benchmark_measurement: None,
            #[cfg(test)]
            fail_local_spawn: false,
        })
    }
    pub fn state(&self) -> State {
        self.state
    }
    pub fn progress(&self) -> &TransferProgress {
        &self.progress
    }
    pub fn local_apply_installed(&self) -> bool {
        self.lifecycle.installed()
    }
    pub(crate) fn lifecycle_control(&self) -> Arc<LifecycleControl> {
        self.lifecycle.clone()
    }
    pub fn source_grant_issued(&self) -> bool {
        self.lifecycle.issued()
    }
    pub fn transport_detached(&self) -> bool {
        self.detached
    }
    pub fn plan(&self) -> Option<&SyncPlan> {
        self.plan.as_ref()
    }
    pub fn preview_summary(&self) -> Option<&super::read_model::PreviewSummary> {
        self.preview_summary.as_ref()
    }
    fn cache_preview_summary(&mut self) -> Result<()> {
        let plan = self.plan.as_ref().ok_or(DriverError::Protocol)?;
        let source = self.source.as_ref().ok_or(DriverError::Protocol)?;
        let source_device = source
            .sources
            .entries
            .iter()
            .find(|entry| entry.library_uuid == plan.source_library_uuid)
            .cloned();
        self.preview_summary = Some(
            super::read_model::summarize(
                plan,
                self.binding.as_deref().ok_or(DriverError::Protocol)?,
                source_device,
                &self.work,
            )
            .inspect_err(|error| diagnostics::core(DiagnosticBoundary::PreviewSummary, error))
            .map_err(work_error)?,
        );
        Ok(())
    }
    pub fn read_view(&self) -> super::read_model::EndpointView {
        use super::read_model::*;
        let mut progress = ProgressView::observing(&self.work);
        progress.transferred_bytes = Some(self.progress.transferred_bytes);
        if self.state == State::Transferring {
            progress.transfer_total_bytes = Some(self.progress.transfer_total_bytes);
            progress.transfer_bytes_per_second =
                Some(self.throughput.rate(self.clock.monotonic_ms()));
        }
        if self.state.terminal() {
            progress.work_stage = super::work::WorkStage::Idle;
            progress.work_active = false;
        }
        let agreed = self.sample.is_some()
            && (self.session.phone_controlled()
                || !matches!(
                    self.step,
                    Step::AccountConsent
                        | Step::SendAccounts
                        | Step::ReceiveAccounts
                        | Step::AccountBinding
                ));
        EndpointView {
            pairing: match self.session.state() {
                SessionState::Handshaking => PairingStage::Handshaking,
                SessionState::Authenticating => PairingStage::Authenticating,
                SessionState::AwaitingConfirmation => PairingStage::AwaitingConfirmation,
                SessionState::Confirmed => PairingStage::Confirmed,
                SessionState::Terminal => PairingStage::Terminal,
            },
            confirmation_available: self
                .session
                .confirmation_available(self.clock.unix_ms() / 1000),
            invitation_remaining_ms: self.session.invitation_remaining_ms(),
            peer_name: self.session.peer_info().map(|p| p.name.clone()),
            peer_clock_skew_seconds: self.session.peer_info().map(|p| p.clock_skew_seconds),
            transport: match self.session.transport() {
                super::Transport::Tcp(_) => TransportKind::Tcp,
                super::Transport::Usb => TransportKind::Usb,
            },
            host: self.session.is_host(),
            controller: self.session.controller(),
            phone_controlled: self.session.phone_controlled(),
            accounts_consent_authorized: self.session.phone_controlled()
                && self.controller_account_consent == Some(true)
                && !self.state.terminal(),
            preview_approved: self.preview_approved && !self.state.terminal(),
            source: agreed.then(|| self.source_side()),
            configuration: self
                .config
                .filter(|_| agreed)
                .map(|config| AgreedConfiguration {
                    phone_to_desktop: config.direction == Direction::PhoneToDesktop,
                    mode: config.mode,
                    include_accounts: if self.session.phone_controlled() {
                        config.accounts
                    } else {
                        self.accounts_included()
                    },
                }),
            stage: self.state,
            terminal: self.state.terminal(),
            cleanup_pending: self.cleanup_pending(),
            local_apply_installed: self.local_apply_installed(),
            source_grant_issued: self.source_grant_issued(),
            transport_detached: self.transport_detached(),
            progress,
        }
    }
    pub fn preview_binding(&self) -> Option<&str> {
        self.binding.as_deref()
    }
    /// Debug-only, local preview guard. It never approves the preview.
    pub(crate) fn benchmark_require_noop(&mut self, binding: &str) -> Result<bool> {
        if !cfg!(debug_assertions) {
            return Err(DriverError::AccountsUnsupported);
        }
        if self.state != State::AwaitingApproval
            || self.session.state() != SessionState::Confirmed
            || !matches!(self.step, Step::Approval | Step::Approved)
            || self.preview_approved
            || self.binding.as_deref() != Some(binding)
        {
            return Err(DriverError::Protocol);
        }
        let config = self.config.ok_or(DriverError::Protocol)?;
        if config.mode != SyncMode::Merge
            || config.accounts
            || self.accounts_included()
            || self.external_reference.is_some()
            || self.export_accounts.is_some()
            || self.import_accounts.is_some()
            || !self.strict_noop_plan()?
        {
            return Ok(false);
        }
        self.check_benchmark_generation()?;
        if let Some(receive) = self.receive.as_mut() {
            receive
                .benchmark_require_noop()
                .map_err(receiver_work_error)?;
        }
        self.benchmark_binding = Some(binding.to_owned());
        Ok(true)
    }
    fn strict_noop_plan(&self) -> Result<bool> {
        let source = self.source.as_ref().ok_or(DriverError::Protocol)?;
        let target = self.target.as_ref().ok_or(DriverError::Protocol)?;
        let plan = self.plan.as_ref().ok_or(DriverError::Protocol)?;
        Ok(plan.mode == SyncMode::Merge
            && plan.is_strict_noop(
                &source.manifest,
                &target.manifest,
                &source.sources,
                &target.sources,
            )
            && super::benchmark::business_equivalent(source, target))
    }
    fn check_benchmark_generation(&self) -> Result<()> {
        let expected = if self.source_side() {
            self.source.as_ref()
        } else {
            self.target.as_ref()
        };
        let expected = expected.ok_or(DriverError::Protocol)?;
        self.work.check().map_err(work_error)?;
        let _lease = self.database.device_sync_exclusive().map_err(work_error)?;
        let current = self.database.device_sync_header().map_err(work_error)?;
        // Normal writes advance the generation. The full source/target snapshot
        // is still reread under the production final lease before any apply.
        if current.library_uuid != expected.manifest.header.library_uuid
            || current.generation != expected.manifest.header.generation
        {
            return Err(DriverError::Library);
        }
        Ok(())
    }
    fn check_benchmark_guard(&self) -> Result<()> {
        if let Some(binding) = &self.benchmark_binding {
            if self.binding.as_ref() != Some(binding)
                || self.accounts_included()
                || self.external_reference.is_some()
                || !self.strict_noop_plan()?
            {
                return Err(DriverError::Library);
            }
            self.check_benchmark_generation()?;
        }
        Ok(())
    }
    pub(crate) fn require_transport_cleanup(&mut self) {
        self.benchmark_transport_pending = true;
    }
    pub(crate) fn benchmark_transport_finished(&mut self, success: bool) {
        if success {
            self.benchmark_transport_pending = false;
            if self.benchmark_binding.is_some() && self.state == State::Completed {
                self.finish_success();
            }
        }
    }
    fn benchmark_finished(&self) -> bool {
        self.state == State::Completed
            && self.session.state() == SessionState::Terminal
            && !self.benchmark_transport_pending
            && !self.cleanup_pending()
            && self.worker.is_none()
            && self.preparation.is_none()
            && self.verification.is_none()
            && !self.database.device_sync_recovery_pending()
    }
    /// Immutable result: unfinished, failed and cancelled runs have no final record.
    pub(crate) fn benchmark_metrics(&self) -> Option<String> {
        if !cfg!(debug_assertions) || self.benchmark_binding.is_none() || !self.benchmark_finished()
        {
            return None;
        }
        self.benchmark_measurement.clone()
    }
    pub fn receipt(&self) -> Option<&ApplyReceipt> {
        self.receipt.as_ref()
    }
    /// Local durable-boundary notifications run on the application worker.
    /// Observers must return promptly and must not reenter the library.
    pub fn set_apply_observer(
        &mut self,
        observer: Arc<dyn Fn(ApplyBoundary) + Send + Sync>,
    ) -> Result<()> {
        if self.config.is_some() || self.state.terminal() {
            return Err(DriverError::Protocol);
        }
        self.apply_observer = Some(observer);
        Ok(())
    }
    pub fn cancellation(&self) -> CancellationToken {
        self.cancel.clone()
    }
    pub fn work_control(&self) -> super::work::WorkControl {
        self.work.clone()
    }
    pub(crate) fn transfer_observer(&self) -> TransferObserver {
        TransferObserver {
            throughput: self.throughput.clone(),
            clock: self.clock.clone(),
        }
    }
    /// Local I/O owners install one prompt, idempotent resource close action.
    /// A rejected late/duplicate registration closes its supplied resource too.
    pub fn set_transport_close(&mut self, close: impl FnOnce() + Send + 'static) -> Result<()> {
        if self.state.terminal() || self.transport_close.is_some() {
            close();
            return Err(DriverError::Protocol);
        }
        self.transport_close = Some(Box::new(close));
        Ok(())
    }
    /// The native helper remains owned by its I/O caller; termination shares
    /// the Session lifecycle without invoking a synchronous request on the UI.
    pub fn attach_native_cancellation(
        &mut self,
        cancellation: super::native_process::NativeCancellation,
    ) -> Result<()> {
        self.set_transport_close(move || cancellation.cancel())
    }
    /// A stopped source can still own a previously issued, unexpired permission.
    /// The cleanup survives page disposal, bounded by that last permission.
    pub fn cleanup_pending(&self) -> bool {
        self.session_cleanup_pending || self.cleanup.as_ref().is_some_and(|cleanup| cleanup.poll())
    }
    pub fn confirm_pairing(&mut self) -> Result<()> {
        self.session.confirm(self.clock.unix_ms() / 1000)?;
        self.persist_confirmed_pairing()
    }
    fn persist_confirmed_pairing(&mut self) -> Result<()> {
        if self.state == State::Pairing && self.session.state() == SessionState::Confirmed {
            self.database
                .device_sync_begin_session(
                    Uuid::parse_str(self.session.session_id())
                        .map_err(|_| DriverError::Protocol)?,
                    Uuid::parse_str(self.session.operation_id())
                        .map_err(|_| DriverError::Protocol)?,
                )
                .map_err(|_| DriverError::Library)?;
            self.state = State::Configuring;
            self.deadline = self.clock.monotonic_ms().saturating_add(USER_MS);
        }
        Ok(())
    }
    pub fn confirmation_code(&mut self) -> Result<String> {
        Ok(self
            .session
            .confirmation_code(self.clock.unix_ms() / 1000)?)
    }
    fn source_side(&self) -> bool {
        self.config.is_some_and(|c| match c.direction {
            Direction::DesktopToPhone => self.session.is_host(),
            Direction::PhoneToDesktop => !self.session.is_host(),
        })
    }
    fn enqueue(&mut self, message: Message) -> Result<()> {
        if let Message::ChunkAccepted { sha256, offset } = &message {
            if let Some(previous) = self.outbox.back_mut() {
                match previous {
                    Message::ChunkAccepted {
                        sha256: previous_sha,
                        offset: previous_offset,
                    } if previous_sha != sha256 => {
                        *previous = Message::ChunksAccepted {
                            files: vec![
                                wire::FileReceipt {
                                    sha256: previous_sha.clone(),
                                    offset: *previous_offset,
                                },
                                wire::FileReceipt {
                                    sha256: sha256.clone(),
                                    offset: *offset,
                                },
                            ],
                        };
                        return Ok(());
                    }
                    Message::ChunksAccepted { files }
                        if files.len() < flow::BATCH_FILES
                            && !files.iter().any(|file| &file.sha256 == sha256) =>
                    {
                        files.push(wire::FileReceipt {
                            sha256: sha256.clone(),
                            offset: *offset,
                        });
                        return Ok(());
                    }
                    _ => {}
                }
            }
        }
        if self.outbox.len() >= MAX_OUTBOX {
            return Err(DriverError::Bounds);
        }
        self.outbox.push_back(message);
        self.progress.peak_outbox_messages =
            self.progress.peak_outbox_messages.max(self.outbox.len());
        Ok(())
    }
    pub fn configure(
        &mut self,
        direction: Direction,
        mode: SyncMode,
        accounts: bool,
    ) -> Result<()> {
        self.persist_confirmed_pairing()?;
        if !self.session.controller()
            || self.session.state() != SessionState::Confirmed
            || self.config.is_some()
            || self.state.terminal()
        {
            return Err(DriverError::Protocol);
        }
        let start_ms = self.clock.unix_ms();
        self.clock_start = Some((start_ms, self.clock.monotonic_ms()));
        self.config = Some(Config {
            direction,
            mode,
            accounts,
        });
        self.step = Step::ClockReply;
        self.enqueue(Message::Configure {
            direction,
            mode,
            include_accounts: accounts,
            start_ms,
        })
    }
    fn begin_snapshots(&mut self) -> Result<()> {
        self.state = State::Scanning;
        self.deadline = self.clock.monotonic_ms().saturating_add(DATA_MS);
        if self.source_side() {
            let retained = Snapshot::retain_controlled(&self.database, &self.name, &self.work)
                .map_err(work_error)?;
            let snapshot = retained.snapshot().clone();
            self.source_digest = Some(
                snapshot
                    .digest_controlled(&self.work)
                    .inspect_err(|error| {
                        diagnostics::core(DiagnosticBoundary::PreviewSourceDigest, error)
                    })
                    .map_err(work_error)?,
            );
            self.source = Some(snapshot.clone());
            self.retained = Some(retained);
            self.begin_send(snapshot, Step::SendSource)?;
        } else {
            self.step = Step::ReceiveSource;
        }
        Ok(())
    }
    /// Call only after the source user's separate, explicit account consent.
    pub fn authorize_accounts_export(&mut self, payload: &[u8], state_digest: &str) -> Result<()> {
        if (self.session.phone_controlled()
            && (self.controller_account_consent != Some(true)
                || self.step != Step::AccountConsent
                || !self.source_side()))
            || (self.config.is_some() && self.step != Step::AccountConsent)
            || self.state.terminal()
            || self.export_accounts.is_some()
            || self.target_account_state.is_some()
            || !super::qr::valid_hex(state_digest, 64)
        {
            return Err(DriverError::Protocol);
        }
        let accounts = AccountSet::from_json(payload).map_err(|_| DriverError::Bounds)?;
        self.account_digest = Some(accounts.digest().map_err(|_| DriverError::Bounds)?);
        self.source_account_state = Some(state_digest.to_owned());
        self.export_accounts = Some(accounts);
        self.account_decision = Some(true);
        if self.step == Step::AccountConsent {
            self.account_consent_changed()?;
        }
        Ok(())
    }
    /// A peer option never calls this local-only receiver authorization.
    pub fn authorize_accounts_receive(&mut self, state_digest: &str) -> Result<()> {
        if (self.session.phone_controlled()
            && (self.controller_account_consent != Some(true)
                || self.step != Step::AccountConsent
                || self.source_side()))
            || (self.config.is_some() && self.step != Step::AccountConsent)
            || self.state.terminal()
            || self.export_accounts.is_some()
            || self.target_account_state.is_some()
            || !super::qr::valid_hex(state_digest, 64)
        {
            return Err(DriverError::Protocol);
        }
        self.target_account_state = Some(state_digest.to_owned());
        self.account_decision = Some(true);
        if self.step == Step::AccountConsent {
            self.account_consent_changed()?;
        }
        Ok(())
    }
    /// Both users explicitly choose library-only before the final configuration
    /// changes. A peer's refusal alone cannot reuse a local account approval.
    pub fn decline_accounts(&mut self) -> Result<()> {
        if self.session.phone_controlled() {
            return self.consent_controlled(false);
        }
        if self.state.terminal()
            || (self.config.is_some() && self.step != Step::AccountConsent)
            || self.account_decision == Some(false)
        {
            return Err(DriverError::Protocol);
        }
        self.account_decision = Some(false);
        self.export_accounts = None;
        self.account_digest = None;
        self.source_account_state = None;
        self.target_account_state = None;
        if self.step == Step::AccountConsent {
            self.account_consent_changed()?;
        }
        Ok(())
    }
    /// The authenticated phone grants this direction/scope only, never trust
    /// for a future invitation or permission to skip local secure storage.
    pub fn consent_controlled(&mut self, accepted: bool) -> Result<()> {
        if !self.session.phone_controlled()
            || !self.session.controller()
            || self.session.state() != SessionState::Confirmed
            || self.step != Step::AccountConsent
            || self.controller_account_consent.is_some()
        {
            return Err(DriverError::Protocol);
        }
        let config = self.config.ok_or(DriverError::Protocol)?;
        if !config.accounts {
            return Err(DriverError::Protocol);
        }
        self.enqueue(Message::ControllerAccountConsent {
            direction: config.direction,
            mode: config.mode,
            accepted,
        })?;
        let result = self.accept_controller_consent(accepted);
        if result.is_err() {
            // The decision has been consumed; a failed source snapshot must
            // retire it and its queued peer intent, never remain half active.
            self.stop(false);
        }
        result
    }
    fn accept_controller_consent(&mut self, accepted: bool) -> Result<()> {
        self.controller_account_consent = Some(accepted);
        if !accepted {
            self.config.as_mut().ok_or(DriverError::Protocol)?.accounts = false;
            self.begin_snapshots()?;
        }
        Ok(())
    }
    fn begin_accounts_or_snapshots(&mut self) -> Result<()> {
        if !self.config.ok_or(DriverError::Protocol)?.accounts {
            self.export_accounts = None;
            return self.begin_snapshots();
        }
        self.step = Step::AccountConsent;
        self.state = State::AwaitingAccountConsent;
        self.deadline = self.clock.monotonic_ms().saturating_add(USER_MS);
        self.account_consent_changed()
    }
    fn account_consent_changed(&mut self) -> Result<()> {
        if let Some(accepted) = self.account_decision {
            if self.sent_account_decision != Some(accepted) {
                self.enqueue(Message::AccountConsent { accepted })?;
                self.sent_account_decision = Some(accepted);
            }
            if self.peer_account_decision == Some(accepted) {
                if !accepted {
                    self.config.as_mut().ok_or(DriverError::Protocol)?.accounts = false;
                    self.begin_snapshots()?;
                } else if self.source_side() {
                    self.account_sender = Some(
                        self.export_accounts
                            .as_ref()
                            .ok_or(DriverError::Protocol)?
                            .to_json()
                            .map_err(|_| DriverError::Bounds)?,
                    );
                    self.step = Step::SendAccounts;
                    self.state = State::Scanning;
                } else {
                    if self.target_account_state.is_none() {
                        return Err(DriverError::Protocol);
                    }
                    self.account_collector = Some(AccountCollector::default());
                    self.step = Step::ReceiveAccounts;
                    self.state = State::Scanning;
                }
            }
        }
        Ok(())
    }
    pub fn accounts_included(&self) -> bool {
        self.config.is_some_and(|config| config.accounts)
            && self.account_digest.is_some()
            && self.source_account_state.is_some()
            && self.target_account_state.is_some()
    }
    pub fn accounts_payload(&self) -> Result<Option<Zeroizing<Vec<u8>>>> {
        self.import_accounts
            .as_ref()
            .map(|a| a.to_json().map_err(|_| DriverError::Bounds))
            .transpose()
    }
    pub fn receive_operation_id(&self) -> Option<Uuid> {
        self.receive
            .as_ref()
            .map(ReceiveOperation::operation_id)
            .or_else(|| self.receipt.as_ref().map(|r| r.operation_uuid))
            .or_else(|| {
                self.local_identity
                    .as_ref()
                    .map(|identity| identity.operation)
            })
    }
    pub fn target_library_id(&self) -> Option<&str> {
        self.target
            .as_ref()
            .map(|s| s.manifest.header.library_uuid.as_str())
    }
    pub fn session_id(&self) -> &str {
        self.session.session_id()
    }
    pub(crate) fn channel_operation_id(&self) -> &str {
        self.session.operation_id()
    }
    pub fn is_source(&self) -> bool {
        self.source_side()
    }
    pub fn overwrite(&self) -> bool {
        self.config
            .is_some_and(|config| config.mode == SyncMode::Overwrite)
    }
    pub fn approve_accounts_preview(
        &mut self,
        binding: &str,
        current: &str,
        external: Uuid,
    ) -> Result<()> {
        if (self.session.phone_controlled() && !self.preview_approved)
            || !self.accounts_included()
            || self.source_side()
            || self.binding.as_deref() != Some(binding)
            || self.target_account_state.as_deref() != Some(current)
            || external.is_nil()
            || self.external_reference.is_some()
        {
            return Err(DriverError::Protocol);
        }
        if self.session.phone_controlled() {
            self.check_approval_capacity()?;
        }
        self.external_reference = Some(external);
        self.approve_preview()
    }
    pub fn approve_accounts_final(&mut self, current: &str) -> Result<()> {
        if self.state != State::AwaitingAccountFinal
            || !self.source_side()
            || self.source_account_state.as_deref() != Some(current)
        {
            return Err(DriverError::Protocol);
        }
        self.account_final = true;
        if let Some(identity) = self.pending_ready.take() {
            self.state = State::Verifying;
            return self.issue_apply_grant(identity);
        }
        let (binding, id, work) = self.account_request.take().ok_or(DriverError::Protocol)?;
        self.state = State::Verifying;
        self.handle(Message::LeaseRequest { binding, id, work })
    }
    pub fn approve_accounts_target_final(&mut self, current: &str) -> Result<()> {
        if self.state != State::AwaitingTargetAccountFinal
            || self.step != Step::TargetFinal
            || self.source_side()
            || self.external_reference.is_none()
            || self.target_account_state.as_deref() != Some(current)
        {
            return Err(DriverError::Protocol);
        }
        self.cancel.check().map_err(|_| DriverError::Cancelled)?;
        self.step = Step::Lease;
        self.state = State::Verifying;
        self.request_apply()
    }
    pub fn check_external_commit(&self) -> Result<()> {
        if self.state != State::AwaitingExternal
            || !self.accounts_included()
            || self.source_side()
            || self.check_apply_guard().is_err()
        {
            return Err(DriverError::Cancelled);
        }
        if let Some(authority) = &self.local_authority {
            let identity = self.local_identity.as_ref().ok_or(DriverError::Protocol)?;
            if !authority.matches(
                identity,
                self.receiver_binding
                    .as_deref()
                    .ok_or(DriverError::Protocol)?,
            ) || self
                .receipt
                .as_ref()
                .is_none_or(|receipt| receipt.operation_uuid != identity.operation)
                || self
                    .database
                    .device_sync_journal(identity.operation)
                    .map_err(|_| DriverError::Library)?
                    .is_none_or(|journal| {
                        journal.stage != super::recovery::JournalStage::LibraryApplied
                            || journal.external_reference != identity.external
                    })
            {
                return Err(DriverError::Protocol);
            }
        }
        Ok(())
    }
    /// Report a completed, verified secure-storage step, never a timer heartbeat.
    pub fn external_step(&mut self) -> Result<()> {
        self.check_external_commit()?;
        if let Some(authority) = &self.local_authority {
            authority.account_step().map_err(work_error)?;
        }
        self.account_steps = self
            .account_steps
            .checked_add(1)
            .filter(|n| *n <= 64)
            .ok_or(DriverError::Bounds)?;
        Ok(())
    }
    pub fn finalize_accounts(&mut self, external: Uuid) -> Result<()> {
        self.check_external_commit()?;
        if self.external_reference != Some(external) {
            return Err(DriverError::Protocol);
        }
        let operation = self
            .receipt
            .as_ref()
            .ok_or(DriverError::Protocol)?
            .operation_uuid;
        let mut recovery = super::recovery::RecoveryOperation::preview_pending_controlled(
            self.database.clone(),
            operation,
            &self.name,
            &self.work,
        )
        .map_err(receiver_work_error)?;
        let mut authorization = recovery.authorize().map_err(receiver_work_error)?;
        self.check_apply_guard()
            .map_err(|_| DriverError::Cancelled)?;
        recovery
            .finalize_guarded(
                Some(&mut authorization),
                Some(external),
                &self.cancel,
                Some(self.apply_guard()),
            )
            .map_err(receiver_work_error)?;
        self.receipt.as_mut().ok_or(DriverError::Protocol)?.state = ApplyState::Finalized;
        self.complete_target()
    }
    fn complete_target(&mut self) -> Result<()> {
        self.state = State::Completed;
        self.step = Step::Done;
        self.success_until = Some(self.clock.monotonic_ms().saturating_add(LEASE_MS));
        self.import_accounts = None;
        if self.local_apply_installed() {
            self.lifecycle.settle();
            if !self.detached {
                // Durable success is independent of the best-effort receipt.
                let _ = self.enqueue(Message::CommitAck {
                    binding: self.binding.clone().ok_or(DriverError::Protocol)?,
                });
            }
            return Ok(());
        }
        self.enqueue(Message::CommitAck {
            binding: self.binding.clone().ok_or(DriverError::Protocol)?,
        })
    }
    fn begin_send(&mut self, snapshot: Snapshot, step: Step) -> Result<()> {
        self.enqueue(Message::SnapshotStart {
            header: snapshot.manifest.header.clone(),
        })?;
        self.sender = Some(MetadataSender::with_control(snapshot, &self.work)?);
        self.step = step;
        Ok(())
    }
    fn compute_binding(&self, plan: &SyncPlan) -> Result<String> {
        self.work.check().map_err(work_error)?;
        let config = self.config.ok_or(DriverError::Protocol)?;
        let value = (
            1u8,
            self.session.session_id(),
            self.session.operation_id(),
            1u64,
            config.direction,
            config.mode,
            self.sample,
            (
                &self.account_digest,
                &self.source_account_state,
                &self.target_account_state,
            ),
            self.source_digest.as_ref().ok_or(DriverError::Protocol)?,
            self.target_digest.as_ref().ok_or(DriverError::Protocol)?,
            plan,
        );
        self.work.validation.binding_digest();
        self.work
            .digest_json(&value)
            .inspect_err(|error| diagnostics::core(DiagnosticBoundary::PreviewBinding, error))
            .map_err(work_error)
    }
    pub fn approve_preview(&mut self) -> Result<()> {
        self.check_benchmark_guard()?;
        if (self.session.phone_controlled() && !self.preview_approved)
            || self.step != Step::Approval
            || self.state != State::AwaitingApproval
            || self.source_side()
            || (self.accounts_included() && self.external_reference.is_none())
        {
            return Err(DriverError::Protocol);
        }
        let controlled = self.session.phone_controlled();
        if controlled {
            self.check_approval_capacity()?;
        }
        let result = (|| {
            let authorization = self
                .receive
                .as_mut()
                .ok_or(DriverError::Protocol)?
                .authorize()
                .map_err(|_| DriverError::Library)?;
            self.authorization = Some(authorization);
            self.enqueue(Message::Approved {
                binding: self.binding.clone().ok_or(DriverError::Protocol)?,
            })?;
            self.throughput.reset();
            self.state = State::Transferring;
            self.step = Step::Receiving;
            self.deadline = self.clock.monotonic_ms().saturating_add(DATA_MS);
            self.next_file()
        })();
        if controlled && result.is_err() {
            // Authorization is one-use and Approved may already be queued.
            // Cleanup is safer than rolling back a peer-visible permission.
            self.stop(false);
        }
        result
    }
    fn check_approval_capacity(&self) -> Result<()> {
        let required = if self.needed.is_empty() && !self.accounts_included() {
            3 // Approved, FilesComplete and the initial LeaseRequest.
        } else {
            2 // Approved and FileRequest or account FilesComplete.
        };
        if self.outbox.len() > MAX_OUTBOX - required {
            Err(DriverError::Bounds)
        } else {
            Ok(())
        }
    }
    pub fn approve_controlled_preview(&mut self, binding: &str) -> Result<()> {
        self.check_benchmark_guard()?;
        if !self.session.phone_controlled()
            || !self.session.controller()
            || self.session.state() != SessionState::Confirmed
            || self.state != State::AwaitingApproval
            || self.preview_approved
            || self.binding.as_deref() != Some(binding)
            || !matches!(self.step, Step::Approval | Step::Approved)
            || (self.accounts_included()
                && self
                    .preview_summary
                    .as_ref()
                    .is_none_or(|p| p.accounts.is_none()))
        {
            return Err(DriverError::Protocol);
        }
        if self.source_side() {
            self.enqueue(Message::ControllerApproval {
                binding: binding.into(),
            })?;
            self.preview_approved = true;
            Ok(())
        } else {
            self.check_approval_capacity()?;
            self.preview_approved = true;
            if self.accounts_included() {
                Ok(())
            } else {
                self.approve_preview()
            }
        }
    }
    pub fn publish_account_preview(
        &mut self,
        binding: &str,
        counts: super::read_model::ChangeCounts,
    ) -> Result<()> {
        if !self.session.phone_controlled()
            || self.source_side()
            || !self.accounts_included()
            || self.state != State::AwaitingApproval
            || self.step != Step::Approval
            || self.preview_approved
            || self.binding.as_deref() != Some(binding)
            || self
                .preview_summary
                .as_ref()
                .is_none_or(|p| p.accounts.is_some())
            || !Self::valid_account_counts(&counts)
        {
            return Err(DriverError::Protocol);
        }
        self.enqueue(Message::ControllerAccountsPreview {
            binding: binding.into(),
            counts: counts.clone(),
        })?;
        self.preview_summary
            .as_mut()
            .ok_or(DriverError::Protocol)?
            .accounts = Some(counts);
        Ok(())
    }
    fn valid_account_counts(counts: &super::read_model::ChangeCounts) -> bool {
        [counts.added, counts.replaced, counts.removed, counts.kept]
            .into_iter()
            .all(|n| n <= super::accounts::MAX_ACCOUNTS as u64)
            && counts.added + counts.replaced + counts.removed + counts.kept
                <= (super::accounts::MAX_ACCOUNTS * 2) as u64
    }
    fn next_file(&mut self) -> Result<()> {
        self.receive_ack = Default::default();
        if let Some(sha) = self.next_requested_file()? {
            let receive = self.receive.as_mut().ok_or(DriverError::Protocol)?;
            let length = receive
                .plan()
                .media
                .iter()
                .find(|d| d.sha256 == sha)
                .and_then(|d| d.final_record.as_ref())
                .ok_or(DriverError::Protocol)?
                .length;
            let id = receive.operation_id();
            receive
                .staging_mut()
                .begin_file(id, &sha)
                .map_err(|_| DriverError::Library)?;
            self.receiving = Some((sha.clone(), 0, length));
            self.progress.peak_receiving_files = 1;
        } else {
            self.enqueue(Message::FilesComplete {})?;
            if self.accounts_included() {
                self.state = State::AwaitingTargetAccountFinal;
                self.step = Step::TargetFinal;
                self.deadline = self.clock.monotonic_ms().saturating_add(USER_MS);
                return Ok(());
            }
            self.state = State::Verifying;
            self.step = Step::Lease;
            self.request_apply()?;
        }
        Ok(())
    }
    fn request_lease(&mut self, work: ApplyWork) -> Result<()> {
        if self.pending_lease.is_some() {
            return Err(DriverError::Protocol);
        }
        let id = self.lease_id;
        self.pending_lease = Some(PendingLease {
            id,
            work,
            requested: self.clock.monotonic_ms(),
        });
        self.enqueue(Message::LeaseRequest {
            binding: self.binding.clone().ok_or(DriverError::Protocol)?,
            id,
            work,
        })
    }
    fn request_apply(&mut self) -> Result<()> {
        self.check_benchmark_guard()?;
        if !self.session.phone_controlled() {
            return self.request_lease(ApplyWork::default());
        }
        if self.session.state() != SessionState::Confirmed
            || !self.preview_approved
            || self.source_side()
            || !self.needed.is_empty()
            || self.receiving.is_some()
            || self.verification.is_some()
            || self.file.is_some()
            || (self.accounts_included() && self.external_reference.is_none())
            || self.outbox.len() >= MAX_OUTBOX
        {
            return Err(DriverError::Protocol);
        }
        let receive = self.receive.as_ref().ok_or(DriverError::Protocol)?;
        let receiver_binding = receive
            .handoff_binding(self.authorization.as_ref().ok_or(DriverError::Protocol)?)
            .map_err(receiver_work_error)?;
        let identity = ApplyIdentity {
            binding: self.binding.clone().ok_or(DriverError::Protocol)?,
            operation: receive.operation_id(),
            external: self.external_reference,
        };
        self.lifecycle.ready(identity.clone()).map_err(work_error)?;
        self.receiver_binding = Some(receiver_binding);
        self.local_identity = Some(identity.clone());
        self.enqueue(Message::ApplyReady {
            binding: identity.binding,
            receiver_operation: identity.operation,
            external_reference: identity.external,
        })
    }
    fn issue_apply_grant(&mut self, identity: ApplyIdentity) -> Result<()> {
        self.check_benchmark_guard()?;
        if self.file.is_some()
            || self.binding.as_ref() != Some(&identity.binding)
            || self.session.state() != SessionState::Confirmed
            || identity.operation.is_nil()
            || identity.external.is_some_and(|external| external.is_nil())
            || identity.external.is_some() != self.accounts_included()
        {
            return Err(DriverError::Protocol);
        }
        let lease = self.database.device_sync_exclusive().map_err(work_error)?;
        let source = self.source.as_ref().ok_or(DriverError::Protocol)?;
        let current = Snapshot::read_with_header_controlled(
            &self.database,
            source.manifest.header.clone(),
            Some(&self.name),
            &self.work,
        )
        .map_err(work_error)?;
        self.work
            .checkpoint(super::work::WorkStage::FinalCheck, 0)
            .map_err(work_error)?;
        if current.digest_controlled(&self.work).map_err(work_error)?
            != *self.source_digest.as_ref().ok_or(DriverError::Protocol)?
        {
            return Err(DriverError::Library);
        }
        let lifecycle = self.lifecycle.clone();
        let enqueued_at = lifecycle
            .issue(&identity, || {
                self.enqueue(Message::ApplyGrant {
                    binding: identity.binding.clone(),
                    receiver_operation: identity.operation,
                    external_reference: identity.external,
                })
                .map_err(|_| CoreError::Cancelled)?;
                Ok(self.clock.monotonic_ms())
            })
            .map_err(work_error)?;
        self.source_ack_until = Some(enqueued_at.saturating_add(USER_MS));
        drop(lease);
        self.retained = None;
        Ok(())
    }
    fn apply_guard(&self) -> Arc<dyn CommitGuard> {
        match &self.local_authority {
            Some(authority) => authority.clone(),
            None => self.permit.clone(),
        }
    }
    fn check_apply_guard(&self) -> CoreResult<()> {
        self.apply_guard().check()
    }
    fn apply_budget(&self) -> Result<u64> {
        let plan = self.plan.as_ref().ok_or(DriverError::Protocol)?;
        plan.space
            .new_staging_bytes
            .checked_mul(8)
            .ok_or(DriverError::Bounds)
    }
    fn current_work(&self) -> ApplyWork {
        let publication_bytes = self.permit.work.load(Ordering::SeqCst);
        let sql_steps = self.permit.sql_work.load(Ordering::SeqCst);
        let sql = self.permit.sql_started.load(Ordering::SeqCst);
        let boundary = self.permit.boundary.load(Ordering::SeqCst);
        let phase = if self.state == State::AwaitingExternal {
            ApplyPhase::Accounts
        } else if boundary >= 2 {
            ApplyPhase::Finalizing
        } else if sql {
            ApplyPhase::Sql
        } else if boundary >= 1 {
            ApplyPhase::Publishing
        } else {
            ApplyPhase::Preparing
        };
        ApplyWork {
            phase,
            publication_bytes,
            sql_steps,
            account_steps: self.account_steps,
        }
    }
    fn start_apply(&mut self) -> Result<()> {
        if !self.local_apply_installed() {
            self.permit
                .budget
                .store(self.apply_budget()?, Ordering::SeqCst);
        }
        #[cfg(test)]
        if self.fail_local_spawn && self.local_apply_installed() {
            self.lifecycle.cancel();
            self.lifecycle.settle();
            self.receive.take();
            self.authorization.take();
            self.state = State::Failed;
            return Err(DriverError::Library);
        }
        let mut receive = self.receive.take().ok_or(DriverError::Protocol)?;
        let mut auth = self.authorization.take().ok_or(DriverError::Protocol)?;
        let permit = self.permit.clone();
        let token = self.cancel.clone();
        let observer = self.apply_observer.clone();
        let external = self.external_reference;
        let guard = self.apply_guard();
        let verify_reused_originals = self.local_apply_installed();
        self.worker = Some(
            std::thread::Builder::new()
                .name("device-sync-apply".into())
                .spawn(move || {
                    let boundary_permit = permit.clone();
                    let file_permit = permit.clone();
                    let mut previous = None;
                    receive
                        .apply_guarded(
                            Some(&mut auth),
                            external,
                            &token,
                            &mut |boundary| {
                                let value = match boundary {
                                    ApplyBoundary::Prepared => 1,
                                    ApplyBoundary::LibraryApplied => 2,
                                    ApplyBoundary::Finalized => 3,
                                };
                                boundary_permit.boundary.store(value, Ordering::SeqCst);
                                if let Some(observer) = &observer {
                                    observer(boundary);
                                }
                            },
                            &mut |progress| {
                                let delta = previous
                                    .as_ref()
                                    .filter(|p: &&super::staging::Progress| {
                                        p.phase == progress.phase
                                    })
                                    .map(|p| {
                                        progress.completed_bytes.saturating_sub(p.completed_bytes)
                                    })
                                    .unwrap_or(progress.completed_bytes);
                                file_permit.work.fetch_add(delta, Ordering::SeqCst);
                                previous = Some(progress);
                            },
                            Some(guard),
                            verify_reused_originals,
                        )
                        .inspect_err(|error| {
                            diagnostics::receiver(DiagnosticBoundary::ApplyWorkerResult, error)
                        })
                })
                .map_err(|_| {
                    self.lifecycle.cancel();
                    self.lifecycle.settle();
                    self.state = State::Failed;
                    DriverError::Library
                })?,
        );
        self.step = Step::Apply;
        self.state = State::Applying;
        Ok(())
    }
    fn received_snapshot(&mut self, snapshot: Snapshot, digest: String) -> Result<()> {
        if !super::qr::valid_hex(&digest, 64) {
            diagnostics::checkpoint(DiagnosticBoundary::PreviewTargetDigest);
            return Err(DriverError::Protocol);
        }
        if self.source_side() {
            self.target_digest = Some(digest);
            self.target = Some(snapshot);
            let config = self.config.ok_or(DriverError::Protocol)?;
            let plan = build_plan_controlled(
                &self.source.as_ref().ok_or(DriverError::Protocol)?.manifest,
                &self.target.as_ref().ok_or(DriverError::Protocol)?.manifest,
                config.mode,
                self.sample.map(|s| s.trust()),
                &self.work,
            )
            .map_err(work_error)?;
            self.progress.transfer_total_bytes = plan.space.new_staging_bytes;
            self.binding = Some(self.compute_binding(&plan)?);
            self.plan = Some(plan);
            self.cache_preview_summary()?;
            self.step = Step::Preview;
            self.state = State::Comparing;
        } else {
            self.source_digest = Some(digest.clone());
            self.source = Some(snapshot.clone());
            if self.preparation.is_some() {
                return Err(DriverError::Protocol);
            }
            let bytes = super::work::PreparationBytes::new(preparation_limit(&snapshot)?);
            let work = self.work.with_preparation(bytes.clone());
            let database = self.database.clone();
            let name = self.name.clone();
            let mode = self.config.ok_or(DriverError::Protocol)?.mode;
            let sample = self.sample.map(|sample| sample.trust());
            self.preparation = Some(Preparation {
                session: self.session.session_id().into(),
                operation: self.session.operation_id().into(),
                source_digest: digest,
                bytes,
                last_observed: 0,
                last_enqueued: 0,
                active: true,
                worker: std::thread::spawn(move || {
                    ReceiveOperation::prepare_controlled(
                        database, snapshot, &name, mode, sample, &work,
                    )
                }),
            });
            self.step = Step::PreparingTarget;
            self.state = State::Comparing;
        }
        Ok(())
    }
    fn prepared_target(&mut self, mut receive: ReceiveOperation) -> Result<()> {
        let (source_digest, target_digest) = receive.snapshot_digests();
        self.source_digest = Some(source_digest.into());
        self.target_digest = Some(target_digest.into());
        self.target = Some(receive.target().clone());
        self.plan = Some(receive.plan().clone());
        self.binding = Some(self.compute_binding(receive.plan())?);
        self.cache_preview_summary()?;
        if let Some(summary) = &mut self.preview_summary {
            summary.receiver_budget = Some(receive.receiver_budget().clone());
        }
        let candidates = receive
            .plan()
            .media
            .iter()
            .filter_map(|decision| {
                decision
                    .final_record
                    .as_ref()
                    .map(|record| (decision.sha256.clone(), record.length))
            })
            .collect::<Vec<_>>();
        let mut needed = VecDeque::new();
        let mut transfer_total = 0_u64;
        for (sha, length) in candidates {
            if receive
                .staging_mut()
                .requires_transfer(&sha)
                .inspect_err(|error| {
                    diagnostics::receiver(
                        DiagnosticBoundary::PreparedTargetTransferSet,
                        &super::receiver::ReceiverError::Staging(*error),
                    )
                })
                .map_err(|_| DriverError::Library)?
            {
                transfer_total = transfer_total
                    .checked_add(length)
                    .ok_or(DriverError::Bounds)?;
                needed.push_back(sha);
            }
        }
        self.progress.transfer_total_bytes = transfer_total;
        self.needed = needed;
        let snapshot = receive.target().clone();
        self.receive = Some(receive);
        self.begin_send(snapshot, Step::SendTarget)
    }

    fn poll_preparation(&mut self, now: u64) -> Result<()> {
        let Some(preparation) = self.preparation.as_mut() else {
            return Ok(());
        };
        if !preparation.active
            || self.state.terminal()
            || self.cancel.check().is_err()
            || self.step != Step::PreparingTarget
            || preparation.session != self.session.session_id()
            || preparation.operation != self.session.operation_id()
            || self.session.state() != SessionState::Confirmed
        {
            if preparation.worker.is_finished() {
                let _ = self
                    .preparation
                    .take()
                    .expect("present preparation")
                    .worker
                    .join();
            }
            return Err(DriverError::Protocol);
        }
        let completed = preparation.bytes.completed();
        if completed < preparation.last_observed {
            return Err(DriverError::Bounds);
        }
        if completed > preparation.last_observed {
            preparation.last_observed = completed;
            self.deadline = now.saturating_add(DATA_MS);
        }
        if self.outbox.len() >= MAX_OUTBOX {
            return Ok(());
        }
        if preparation.worker.is_finished() {
            let preparation = self.preparation.take().expect("present preparation");
            let receive = preparation
                .worker
                .join()
                .map_err(|_| {
                    diagnostics::driver(DiagnosticBoundary::PreparationJoin, &DriverError::Library);
                    DriverError::Library
                })?
                .inspect_err(|error| {
                    diagnostics::receiver(DiagnosticBoundary::PreparedTarget, error)
                })
                .map_err(receiver_work_error)?;
            self.cancel.check().map_err(|_| DriverError::Cancelled)?;
            return self.prepared_target(receive).inspect_err(|error| {
                diagnostics::driver(DiagnosticBoundary::PreparedTarget, error)
            });
        }
        if completed > preparation.last_enqueued {
            preparation.last_enqueued = completed;
            let source_digest = preparation.source_digest.clone();
            self.enqueue(Message::PreparationProgress {
                source_digest,
                completed_bytes: completed,
            })?;
        }
        Ok(())
    }
    fn handle(&mut self, message: Message) -> Result<()> {
        match message {
            Message::Configure {
                direction,
                mode,
                include_accounts,
                start_ms,
            } if !self.session.controller()
                && self.step == Step::Config
                && self.config.is_none() =>
            {
                self.config = Some(Config {
                    direction,
                    mode,
                    accounts: include_accounts,
                });
                self.step = Step::ClockSample;
                self.enqueue(Message::ClockReply {
                    start_ms,
                    peer_ms: self.clock.unix_ms(),
                })?;
            }
            Message::ClockReply { start_ms, peer_ms }
                if self.session.controller() && self.step == Step::ClockReply =>
            {
                let (start, mono) = self.clock_start.take().ok_or(DriverError::Protocol)?;
                if start != start_ms {
                    return Err(DriverError::Protocol);
                }
                let elapsed = self
                    .clock
                    .monotonic_ms()
                    .checked_sub(mono)
                    .ok_or(DriverError::Protocol)?;
                let end = start
                    .checked_add(i64::try_from(elapsed).map_err(|_| DriverError::Bounds)?)
                    .ok_or(DriverError::Bounds)?;
                let sample = ConnectionSample::from_round_trip(start, end, peer_ms)
                    .ok_or(DriverError::Protocol)?;
                self.sample = Some(sample);
                self.enqueue(Message::ClockSample { sample })?;
                self.begin_accounts_or_snapshots()?;
            }
            Message::ClockSample { sample }
                if !self.session.controller() && self.step == Step::ClockSample =>
            {
                if sample.lower_offset_ms > sample.upper_offset_ms {
                    return Err(DriverError::Protocol);
                }
                self.sample = Some(sample);
                self.begin_accounts_or_snapshots()?;
            }
            Message::AccountConsent { accepted } if self.step == Step::AccountConsent => {
                if (self.session.phone_controlled()
                    && (self.controller_account_consent != Some(true) || !accepted))
                    || self.peer_account_decision == Some(accepted)
                    || self.peer_account_decision == Some(false)
                {
                    return Err(DriverError::Protocol);
                }
                self.peer_account_decision = Some(accepted);
                self.account_consent_changed()?;
            }
            Message::ControllerAccountConsent {
                direction,
                mode,
                accepted,
            } if self.session.phone_controlled()
                && !self.session.controller()
                && self.step == Step::AccountConsent
                && self.controller_account_consent.is_none() =>
            {
                let config = self.config.ok_or(DriverError::Protocol)?;
                if !config.accounts || config.direction != direction || config.mode != mode {
                    return Err(DriverError::Protocol);
                }
                self.accept_controller_consent(accepted)?;
            }
            Message::AccountPart {
                offset,
                total,
                data,
            } if self.step == Step::ReceiveAccounts => {
                let bytes = Zeroizing::new(wire::decode_chunk(&data)?);
                self.account_collector
                    .as_mut()
                    .ok_or(DriverError::Protocol)?
                    .part(offset, total, &bytes)
                    .map_err(|_| DriverError::Bounds)?;
                self.deadline = self.clock.monotonic_ms().saturating_add(DATA_MS);
            }
            Message::AccountEnd {
                digest,
                state_digest,
            } if self.step == Step::ReceiveAccounts => {
                if !super::qr::valid_hex(&state_digest, 64) {
                    return Err(DriverError::Protocol);
                }
                let accounts = self
                    .account_collector
                    .take()
                    .ok_or(DriverError::Protocol)?
                    .finish(&digest)
                    .map_err(|_| DriverError::Protocol)?;
                self.import_accounts = Some(accounts);
                self.account_digest = Some(digest.clone());
                self.source_account_state = Some(state_digest.clone());
                self.enqueue(Message::AccountBinding {
                    source_digest: digest,
                    source_state: state_digest,
                    target_state: self
                        .target_account_state
                        .clone()
                        .ok_or(DriverError::Protocol)?,
                })?;
                self.begin_snapshots()?;
            }
            Message::AccountBinding {
                source_digest,
                source_state,
                target_state,
            } if self.step == Step::AccountBinding => {
                if self.account_digest.as_ref() != Some(&source_digest)
                    || self.source_account_state.as_ref() != Some(&source_state)
                    || !super::qr::valid_hex(&target_state, 64)
                {
                    return Err(DriverError::Protocol);
                }
                self.target_account_state = Some(target_state);
                self.begin_snapshots()?;
            }
            Message::SnapshotStart { header }
                if matches!(self.step, Step::ReceiveSource | Step::ReceiveTarget)
                    && self.collector.is_none() =>
            {
                if self.source_side() {
                    self.preparation_allowance
                        .as_mut()
                        .ok_or(DriverError::Protocol)?
                        .open = false;
                }
                self.collector = Some(MetadataReceiver::with_control(header, self.work.clone())?);
            }
            Message::PagePart {
                page_kind,
                page,
                offset,
                total,
                data,
            } if matches!(self.step, Step::ReceiveSource | Step::ReceiveTarget) => {
                self.collector
                    .as_mut()
                    .ok_or(DriverError::Protocol)?
                    .part(page_kind, page, offset, total, &data)?;
                self.progress.metadata_parts += 1;
                self.deadline = self.clock.monotonic_ms().saturating_add(DATA_MS);
            }
            Message::SnapshotEnd { digest }
                if matches!(self.step, Step::ReceiveSource | Step::ReceiveTarget) =>
            {
                let snapshot = self
                    .collector
                    .take()
                    .ok_or(DriverError::Protocol)?
                    .finish(&digest)
                    .inspect_err(|error| {
                        diagnostics::channel(DiagnosticBoundary::SnapshotEnd, error)
                    })?;
                self.received_snapshot(snapshot, digest)
                    .inspect_err(|error| {
                        diagnostics::driver(DiagnosticBoundary::ReceivedSnapshot, error)
                    })?;
            }
            Message::PreparationProgress {
                source_digest,
                completed_bytes,
            } if self.source_side()
                && self.step == Step::ReceiveTarget
                && self.collector.is_none()
                && self.session.state() == SessionState::Confirmed =>
            {
                let allowance = self
                    .preparation_allowance
                    .as_mut()
                    .ok_or(DriverError::Protocol)?;
                if !allowance.open
                    || source_digest != allowance.source_digest
                    || completed_bytes <= allowance.completed
                    || completed_bytes > allowance.limit
                {
                    return Err(DriverError::Protocol);
                }
                allowance.completed = completed_bytes;
                self.deadline = self.clock.monotonic_ms().saturating_add(DATA_MS);
            }
            Message::Preview { binding }
                if !self.session.phone_controlled()
                    && self.step == Step::Preview
                    && self.binding.as_ref() == Some(&binding) =>
            {
                self.step = Step::Approved;
                self.state = State::AwaitingApproval;
                self.deadline = self.clock.monotonic_ms().saturating_add(USER_MS);
            }
            Message::ControllerPreview {
                summary,
                transfer_total_bytes,
            } if self.session.phone_controlled()
                && self.source_side()
                && self.step == Step::Preview =>
            {
                let local = self.preview_summary.as_ref().ok_or(DriverError::Protocol)?;
                if summary.binding != local.binding
                    || summary.mode != local.mode
                    || summary.source_device != local.source_device
                    || summary.media != local.media
                    || summary.albums != local.albums
                    || summary.conflicts != local.conflicts
                    || summary.space != local.space
                    || summary.accounts.is_some()
                    || summary.receiver_budget.as_ref().is_none_or(|b| {
                        b.volumes.len() > 3
                            || b.volumes
                                .iter()
                                .any(|v| v.roles.is_empty() || v.roles.len() > 3)
                    })
                    || transfer_total_bytes > self.progress.transfer_total_bytes
                {
                    return Err(DriverError::Protocol);
                }
                self.progress.transfer_total_bytes = transfer_total_bytes;
                self.preview_summary = Some(*summary);
                self.step = Step::Approved;
                self.state = State::AwaitingApproval;
                self.deadline = self.clock.monotonic_ms().saturating_add(USER_MS);
            }
            Message::ControllerAccountsPreview { binding, counts }
                if self.session.phone_controlled()
                    && self.source_side()
                    && self.step == Step::Approved
                    && self.accounts_included()
                    && !self.preview_approved
                    && self.binding.as_deref() == Some(&binding) =>
            {
                if !Self::valid_account_counts(&counts) {
                    return Err(DriverError::Bounds);
                }
                let preview = self.preview_summary.as_mut().ok_or(DriverError::Protocol)?;
                if preview.accounts.is_some() {
                    return Err(DriverError::Protocol);
                }
                preview.accounts = Some(counts);
            }
            Message::ControllerApproval { binding }
                if self.session.phone_controlled()
                    && !self.session.controller()
                    && !self.source_side()
                    && self.step == Step::Approval
                    && self.state == State::AwaitingApproval
                    && !self.preview_approved
                    && self.binding.as_deref() == Some(&binding) =>
            {
                if self.accounts_included()
                    && self
                        .preview_summary
                        .as_ref()
                        .is_none_or(|p| p.accounts.is_none())
                {
                    return Err(DriverError::Protocol);
                }
                self.preview_approved = true;
                if !self.accounts_included() {
                    self.approve_preview()?;
                }
            }
            Message::Approved { binding }
                if self.step == Step::Approved
                    && self.binding.as_ref() == Some(&binding)
                    && (!self.session.phone_controlled()
                        || !self.session.controller()
                        || self.preview_approved) =>
            {
                self.check_benchmark_guard()?;
                self.step = Step::Sending;
                self.throughput.reset();
                self.state = State::Transferring;
                self.deadline = self.clock.monotonic_ms().saturating_add(DATA_MS);
            }
            Message::FileRequest { sha256 }
                if self.step == Step::Sending
                    && self.file.is_none()
                    && self.pending_files.is_empty()
                    && self.awaiting_files.is_empty() =>
            {
                self.start_stream_file(sha256)?;
            }
            Message::FileRequestBatch { sha256 }
                if self.step == Step::Sending
                    && self.file.is_none()
                    && self.pending_files.is_empty()
                    && self.awaiting_files.is_empty() =>
            {
                self.start_stream_batch(sha256)?;
            }
            Message::FileChunk {
                sha256,
                offset,
                data,
            } if self.step == Step::Receiving => {
                if self.verification.is_some() {
                    return Err(DriverError::Protocol);
                }
                let (sha, received, length) =
                    self.receiving.as_mut().ok_or(DriverError::Protocol)?;
                if sha != &sha256 || *received != offset {
                    return Err(DriverError::Protocol);
                }
                let bytes = data;
                if bytes.is_empty() || bytes.len() > wire::MEDIA_CHUNK {
                    return Err(DriverError::Bounds);
                }
                let receive = self.receive.as_mut().ok_or(DriverError::Protocol)?;
                let id = receive.operation_id();
                receive
                    .staging_mut()
                    .write_chunk(id, &sha256, offset, &bytes)
                    .map_err(|_| DriverError::Library)?;
                *received += bytes.len() as u64;
                self.progress.transferred_bytes += bytes.len() as u64;
                self.throughput
                    .record(self.clock.monotonic_ms(), bytes.len() as u64);
                let new_offset = *received;
                let finished = *received == *length;
                if finished {
                    // The tail is acknowledged after seal/whole-batch verification,
                    // never by an earlier partial-ACK timer.
                    self.receive_ack = Default::default();
                    let final_file = self.needed.is_empty() && self.requested_files.is_empty();
                    self.state = if final_file {
                        State::Verifying
                    } else {
                        State::Transferring
                    };
                    let last_length = *length;
                    let mut receive = self.receive.take().ok_or(DriverError::Protocol)?;
                    let sha = sha256.clone();
                    let cancel = self.cancel.clone();
                    self.verification_bytes.store(0, Ordering::SeqCst);
                    self.verification_sent = 0;
                    let verified = self.verification_bytes.clone();
                    self.verification = Some(std::thread::spawn(move || {
                        let result =
                            receive
                                .staging_mut()
                                .seal_file(id, &sha, &cancel)
                                .and_then(|()| {
                                    if !final_file {
                                        return Ok(());
                                    }
                                    receive.staging_mut().verify_received(&cancel, &mut |p| {
                                        // Existing wire progress is bounded by the last file.
                                        // Scale the true batch progress, never pretend it is done.
                                        let total = p.total_bytes.unwrap_or(0);
                                        let scaled = if total == 0 {
                                            0
                                        } else {
                                            (u128::from(p.completed_bytes)
                                                * u128::from(last_length)
                                                / u128::from(total))
                                                as u64
                                        };
                                        verified.fetch_max(scaled, Ordering::SeqCst);
                                    })
                                });
                        (receive, result)
                    }));
                } else {
                    self.receive_ack
                        .observe(&sha256, new_offset, self.clock.monotonic_ms());
                }
                self.deadline = self.clock.monotonic_ms().saturating_add(DATA_MS);
            }
            Message::FileVerification { sha256, completed } if self.step == Step::Sending => {
                let file = self.file.as_ref().ok_or(DriverError::Protocol)?;
                if !file.awaiting
                    || file.offset != file.length
                    || file.sha != sha256
                    || completed <= self.verification_sent
                    || completed > file.length
                {
                    return Err(DriverError::Protocol);
                }
                self.verification_sent = completed;
                self.state = State::Verifying;
                self.deadline = self.clock.monotonic_ms().saturating_add(DATA_MS);
            }
            Message::ChunkAccepted { sha256, offset } if self.step == Step::Sending => {
                self.accept_stream_ack(sha256, offset)?;
            }
            Message::ChunksAccepted { files } if self.step == Step::Sending => {
                self.accept_stream_receipts(files)?;
            }
            Message::FilesComplete {}
                if self.step == Step::Sending
                    && self.file.is_none()
                    && self.pending_files.is_empty()
                    && self.awaiting_files.is_empty() =>
            {
                // The receiver may have independently reverified private bytes.
                // FileRequest membership and fully ACKed file windows remain mandatory.
                self.step = Step::SourceReady;
                self.state = State::Verifying;
                self.deadline = self.clock.monotonic_ms().saturating_add(USER_MS);
            }
            Message::ApplyReady {
                binding,
                receiver_operation,
                external_reference,
            } if self.session.phone_controlled()
                && self.source_side()
                && self.step == Step::SourceReady
                && self.pending_ready.is_none()
                && !self.source_grant_issued() =>
            {
                let identity = ApplyIdentity {
                    binding,
                    operation: receiver_operation,
                    external: external_reference,
                };
                if self.binding.as_ref() != Some(&identity.binding)
                    || identity.operation.is_nil()
                    || identity.external.is_some_and(|value| value.is_nil())
                    || identity.external.is_some() != self.accounts_included()
                    || (self.session.controller() && !self.preview_approved)
                {
                    return Err(DriverError::Protocol);
                }
                self.lifecycle
                    .source_checking(identity.clone())
                    .map_err(work_error)?;
                if self.accounts_included() && !self.account_final {
                    self.pending_ready = Some(identity);
                    self.state = State::AwaitingAccountFinal;
                    self.deadline = self.clock.monotonic_ms().saturating_add(USER_MS);
                } else {
                    self.issue_apply_grant(identity)?;
                }
            }
            Message::ApplyGrant {
                binding,
                receiver_operation,
                external_reference,
            } if self.session.phone_controlled()
                && !self.source_side()
                && self.step == Step::Lease
                && !self.local_apply_installed() =>
            {
                let identity = ApplyIdentity {
                    binding,
                    operation: receiver_operation,
                    external: external_reference,
                };
                if self.local_identity.as_ref() != Some(&identity)
                    || self.session.state() != SessionState::Confirmed
                    || !self.preview_approved
                    || self
                        .receive
                        .as_ref()
                        .ok_or(DriverError::Protocol)?
                        .handoff_binding(self.authorization.as_ref().ok_or(DriverError::Protocol)?)
                        .map_err(receiver_work_error)?
                        .as_str()
                        != self
                            .receiver_binding
                            .as_deref()
                            .ok_or(DriverError::Protocol)?
                {
                    return Err(DriverError::Protocol);
                }
                let mut publications = std::collections::BTreeMap::new();
                for (sha, length) in self
                    .plan
                    .as_ref()
                    .ok_or(DriverError::Protocol)?
                    .media
                    .iter()
                    .filter(|decision| !decision.reuse_original)
                    .filter_map(|decision| {
                        decision
                            .final_record
                            .as_ref()
                            .map(|record| (&decision.sha256, record.length))
                    })
                {
                    if publications.insert(sha.clone(), length).is_some() {
                        return Err(DriverError::Protocol);
                    }
                }
                let authority = self
                    .lifecycle
                    .install(
                        &identity,
                        self.receiver_binding.clone().ok_or(DriverError::Protocol)?,
                        publications,
                        self.clock.clone(),
                    )
                    .map_err(work_error)?;
                self.local_authority = Some(authority);
                self.start_apply()?;
            }
            Message::LeaseRequest { binding, id, work }
                if !self.session.phone_controlled()
                    && self.step == Step::SourceReady
                    && self.binding.as_ref() == Some(&binding) =>
            {
                if self.accounts_included() && self.source_lease.is_none() && !self.account_final {
                    if self.account_request.is_some() {
                        return Err(DriverError::Protocol);
                    }
                    self.account_request = Some((binding, id, work));
                    self.state = State::AwaitingAccountFinal;
                    self.deadline = self.clock.monotonic_ms().saturating_add(USER_MS);
                    return Ok(());
                }
                if work.publication_bytes > self.apply_budget()?
                    || work.sql_steps > MAX_SQL_WORK
                    || work.account_steps > 64
                    || (work.account_steps != 0
                        && (!self.accounts_included() || work.phase != ApplyPhase::Accounts))
                    || (work.phase < ApplyPhase::Sql && work.sql_steps != 0)
                    || (work.phase == ApplyPhase::Preparing && work.publication_bytes != 0)
                    || work.phase < self.lease_work.phase
                    || work.publication_bytes < self.lease_work.publication_bytes
                    || work.sql_steps < self.lease_work.sql_steps
                    || work.account_steps < self.lease_work.account_steps
                    || (self.lease_work.phase >= ApplyPhase::Sql
                        && work.publication_bytes != self.lease_work.publication_bytes)
                    || (self.lease_work.phase == ApplyPhase::Finalizing
                        && work != self.lease_work
                        && work.phase != ApplyPhase::Accounts)
                    || (work.phase == ApplyPhase::Accounts
                        && work.sql_steps != self.lease_work.sql_steps
                        && self.lease_work.phase == ApplyPhase::Accounts)
                {
                    return Err(DriverError::Bounds);
                }
                if self.source_lease.is_none() {
                    if id != 0 || work != ApplyWork::default() {
                        return Err(DriverError::Protocol);
                    }
                    let lease = self
                        .database
                        .device_sync_exclusive()
                        .map_err(|_| DriverError::Library)?;
                    let source = self.source.as_ref().ok_or(DriverError::Protocol)?;
                    let current = Snapshot::read_with_header_controlled(
                        &self.database,
                        source.manifest.header.clone(),
                        Some(&self.name),
                        &self.work,
                    )
                    .map_err(work_error)?;
                    self.work
                        .checkpoint(super::work::WorkStage::FinalCheck, 0)
                        .map_err(work_error)?;
                    if current.digest_controlled(&self.work).map_err(work_error)?
                        != *self.source_digest.as_ref().ok_or(DriverError::Protocol)?
                    {
                        return Err(DriverError::Library);
                    }
                    self.source_lease = Some(lease);
                } else if id != self.lease_id + 1 || work == self.lease_work {
                    return Err(DriverError::Protocol);
                }
                self.lease_id = id;
                self.lease_work = work;
                if work.phase >= ApplyPhase::Sql && self.source_sql_until.is_none() {
                    self.source_sql_until = Some(self.clock.monotonic_ms().saturating_add(SQL_MS));
                }
                self.source_until = self.clock.monotonic_ms().saturating_add(LEASE_MS);
                self.enqueue(Message::LeaseGranted { binding, id, work })?;
            }
            Message::LeaseGranted { binding, id, work }
                if !self.session.phone_controlled()
                    && (matches!(self.step, Step::Lease | Step::Apply)
                        || (self.step == Step::Done && self.receipt.is_some()))
                    && self.binding.as_ref() == Some(&binding) =>
            {
                let request = self.pending_lease.take().ok_or(DriverError::Protocol)?;
                if request.id != id
                    || request.work != work
                    || self.clock.monotonic_ms() >= request.requested.saturating_add(LEASE_MS)
                {
                    return Err(DriverError::Timeout);
                }
                self.permit
                    .until
                    .store(request.requested.saturating_add(LEASE_MS), Ordering::SeqCst);
                self.permit.active.store(true, Ordering::SeqCst);
                self.lease_id = id.checked_add(1).ok_or(DriverError::Bounds)?;
                self.last_work = work;
                if self.step == Step::Lease {
                    self.start_apply()?;
                }
            }
            Message::CommitAck { binding }
                if self.step == Step::SourceReady
                    && (self.source_lease.is_some() || self.source_grant_issued())
                    && self.binding.as_ref() == Some(&binding) =>
            {
                self.source_lease = None;
                self.retained = None;
                self.step = Step::Done;
                self.state = State::Completed;
                self.stop(false);
            }
            Message::Abort {} if self.local_apply_installed() => self.detach_transport(),
            Message::Abort {} => return Err(DriverError::Cancelled),
            _ => return Err(DriverError::Protocol),
        }
        Ok(())
    }
    pub fn poll(&mut self) -> Result<()> {
        self.observe_measurements();
        let mut result = self.poll_inner();
        if result.is_err() && self.cancel.check().is_err() && !self.state.terminal() {
            result = Err(DriverError::Cancelled);
        }
        if let Err(error) = &result {
            self.stop(matches!(error, DriverError::Cancelled));
        }
        self.observe_measurements();
        if self.benchmark_binding.is_some() && self.benchmark_finished() {
            self.publish_measurements();
        }
        result
    }
    fn observe_measurements(&mut self) {
        self.throughput.configure(
            self.state == State::Transferring,
            self.progress.transfer_total_bytes,
        );
        let phase = match self.state {
            State::Scanning => Some(Phase::Snapshot),
            State::Comparing => Some(Phase::Preview),
            State::Transferring if matches!(self.step, Step::Sending | Step::Receiving) => {
                Some(Phase::Transfer)
            }
            State::Verifying => Some(Phase::Verify),
            State::Applying => Some(Phase::Apply),
            State::Completed | State::CompletedUnconfirmed => Some(Phase::Receipt),
            _ => None,
        };
        self.metrics.phase(phase, self.clock.monotonic_ms());
        self.metrics
            .observe_media_bytes(self.progress.transferred_bytes);
    }
    pub(crate) fn record_usb_io(
        &mut self,
        kind: IoKind,
        elapsed_ms: u64,
        bytes: u64,
        failed: bool,
    ) {
        self.metrics.io(kind, elapsed_ms, bytes, failed);
    }
    pub(crate) fn record_usb_drain(&mut self, media: bool) {
        self.metrics.usb_drain(media);
    }
    pub(crate) fn record_usb_bundle(&mut self, drains: usize) {
        self.metrics.usb_published(drains);
    }
    fn publish_measurements(&mut self) {
        if self.benchmark_binding.is_some() && !self.benchmark_finished() {
            return;
        }
        if !self.metrics_reported {
            self.observe_measurements();
            let record = format!(
                "{} {}",
                self.metrics.finish(self.clock.monotonic_ms()),
                self.work.validation_metrics()
            );
            self.metrics_reported = true;
            if self.benchmark_binding.is_some() {
                self.benchmark_measurement = Some(format!("{record} benchmark_noop_armed=1"));
            }
            diagnostics::measurement(&record);
        }
    }
    fn poll_inner(&mut self) -> Result<()> {
        if self.detached && self.local_apply_installed() {
            return self.poll_local();
        }
        // A local result must be consumed even after cancellation made the
        // displayed state terminal. The durable journal decides the outcome.
        self.poll_finished_local_worker()?;
        self.cleanup_pending();
        if self.state == State::Completed && self.session.state() == SessionState::Terminal {
            let _ = self.retire_session_record();
        }
        if self
            .preparation
            .as_ref()
            .is_some_and(|owner| !owner.active && owner.worker.is_finished())
        {
            let _ = self
                .preparation
                .take()
                .expect("finished preparation")
                .worker
                .join();
        }
        if self.state.terminal()
            && (self.state != State::Completed || self.session.state() == SessionState::Terminal)
        {
            return Ok(());
        }
        let now = self.clock.monotonic_ms();
        if self.source_grant_issued()
            && !self.state.terminal()
            && self.source_ack_until.is_some_and(|until| now >= until)
        {
            self.state = State::CompletedUnconfirmed;
            self.stop(false);
            return Ok(());
        }
        if self.success_until.is_some_and(|until| now >= until) {
            self.stop(false);
            return Ok(());
        }
        if self.cancel.check().is_err() && self.state != State::Completed {
            self.stop(true);
            return Err(DriverError::Cancelled);
        }
        self.session.tick(self.clock.unix_ms() / 1000)?;
        if self.session.state() != SessionState::Confirmed {
            return Ok(());
        }
        self.persist_confirmed_pairing()?;
        if self.source_lease.is_some()
            && (now >= self.source_until || self.source_sql_until.is_some_and(|until| now >= until))
        {
            diagnostics::checkpoint(if now >= self.source_until {
                DiagnosticBoundary::ApplySourceLeaseExpired
            } else {
                DiagnosticBoundary::ApplySourceSqlDeadline
            });
            self.state = State::CompletedUnconfirmed;
            self.stop(false);
            return Ok(());
        }
        if !self.state.terminal()
            && self.step != Step::Apply
            && self.source_lease.is_none()
            && !self.source_grant_issued()
            && now >= self.deadline
        {
            return Err(DriverError::Timeout);
        }
        if self.step == Step::Apply && !self.local_apply_installed() && self.permit.check().is_err()
        {
            return Err(DriverError::Timeout);
        }
        let receive_limit = if matches!(self.session.transport(), super::Transport::Usb) {
            MAX_INFLIGHT_CHUNKS
        } else {
            1
        };
        for index in 0..receive_limit {
            if self.verification.is_some()
                && self.session.peek_payload().is_some_and(Envelope::is_media)
            {
                // An ordered small-file batch may already have queued the next
                // file. Let its predecessor seal asynchronously before consuming.
                break;
            }
            if index > 0 {
                // Only already-authenticated, already-queued media/ACK frames
                // may share this bounded poll. Do not consume permission,
                // account or configuration work ahead of its original boundary.
                let ready_media = self.session.peek_payload().is_some_and(|bytes| {
                    Envelope::is_media(bytes)
                        || Envelope::decode(bytes).is_ok_and(|envelope| {
                            matches!(
                                envelope.message,
                                Message::FileChunk { .. }
                                    | Message::ChunkAccepted { .. }
                                    | Message::ChunksAccepted { .. }
                            )
                        })
                });
                if !ready_media {
                    break;
                }
            }
            let Some(bytes) = self.session.receive_payload(self.clock.unix_ms() / 1000)? else {
                break;
            };
            self.progress.peak_plaintext_bytes =
                self.progress.peak_plaintext_bytes.max(bytes.len());
            let envelope = Envelope::decode(&bytes)?;
            if envelope.session != self.session.session_id()
                || envelope.operation != self.session.operation_id()
                || envelope.sequence != self.received_sequence
            {
                return Err(DriverError::Protocol);
            }
            self.received_sequence = self
                .received_sequence
                .checked_add(1)
                .ok_or(DriverError::Bounds)?;
            let media = matches!(
                envelope.message,
                Message::FileChunk { .. }
                    | Message::ChunkAccepted { .. }
                    | Message::ChunksAccepted { .. }
            );
            self.handle(envelope.message)?;
            if self.session.state() == SessionState::Terminal {
                return Ok(());
            }
            if !media || self.outbox.len() >= MAX_OUTBOX {
                break;
            }
        }
        self.poll_preparation(now)?;
        if self.receive_ack.ready(now) && self.outbox.len() < MAX_OUTBOX {
            if let Some((sha256, offset)) = self.receive_ack.take() {
                self.enqueue(Message::ChunkAccepted { sha256, offset })?;
            }
        }
        let verification_finished = self.verification.as_ref().is_some_and(|w| w.is_finished());
        // A completed seal owns its result until every response can be queued:
        // tail ACK, possibly a new request, or FilesComplete + apply request.
        // Native output can remain in flight across many owner polls. That is
        // backpressure, not a peer violation; never consume half a completion.
        let completion_slots = if !self.requested_files.is_empty() {
            1
        } else if !self.needed.is_empty() || self.accounts_included() {
            2
        } else {
            3
        };
        if verification_finished && self.outbox.len() <= MAX_OUTBOX - completion_slots {
            let (receive, result) = self
                .verification
                .take()
                .ok_or(DriverError::Library)?
                .join()
                .map_err(|_| DriverError::Library)?;
            result.map_err(|_| DriverError::Library)?;
            self.receive = Some(receive);
            let (sha256, offset, _) = self.receiving.take().ok_or(DriverError::Protocol)?;
            self.enqueue(Message::ChunkAccepted { sha256, offset })?;
            self.state = State::Transferring;
            self.next_file()?;
            self.deadline = now.saturating_add(DATA_MS);
        } else if !verification_finished && self.verification.is_some() {
            let completed = self.verification_bytes.load(Ordering::SeqCst);
            if completed > self.verification_sent && self.outbox.is_empty() {
                self.verification_sent = completed;
                let sha256 = self
                    .receiving
                    .as_ref()
                    .ok_or(DriverError::Protocol)?
                    .0
                    .clone();
                self.enqueue(Message::FileVerification { sha256, completed })?;
                self.deadline = now.saturating_add(DATA_MS);
            }
        }
        if self.local_apply_installed() {
            self.poll_finished_local_worker()?;
        } else if self.worker.as_ref().is_some_and(|w| w.is_finished()) {
            let outcome = self
                .worker
                .take()
                .ok_or(DriverError::Library)?
                .join()
                .map_err(|_| DriverError::Library)?;
            match outcome {
                Ok(receipt) => {
                    let pending = receipt.state == ApplyState::LibraryAppliedPending;
                    self.receipt = Some(receipt);
                    if pending {
                        self.state = State::AwaitingExternal;
                    } else {
                        self.complete_target()?;
                    }
                }
                Err(error) => return Err(receiver_work_error(error)),
            }
        } else if self.step == Step::Apply && !self.local_apply_installed() {
            let work = self.current_work();
            self.progress.apply_work = work.sql_steps;
            if work != self.last_work && self.pending_lease.is_none() {
                self.request_lease(work)?;
            }
        }
        if !self.flush_required && self.outbox.is_empty() {
            if self.step == Step::SendAccounts {
                let bytes = self.account_sender.as_ref().ok_or(DriverError::Protocol)?;
                if self.account_offset < bytes.len() {
                    let end = (self.account_offset + wire::RAW_CHUNK).min(bytes.len());
                    let message = Message::AccountPart {
                        offset: self.account_offset,
                        total: bytes.len(),
                        data: wire::encode_chunk(&bytes[self.account_offset..end]),
                    };
                    self.account_offset = end;
                    self.enqueue(message)?;
                } else {
                    self.enqueue(Message::AccountEnd {
                        digest: self.account_digest.clone().ok_or(DriverError::Protocol)?,
                        state_digest: self
                            .source_account_state
                            .clone()
                            .ok_or(DriverError::Protocol)?,
                    })?;
                    self.account_sender = None;
                    self.export_accounts = None;
                    self.step = Step::AccountBinding;
                }
            } else if matches!(self.step, Step::SendSource | Step::SendTarget) {
                if let Some(message) = self.sender.as_mut().ok_or(DriverError::Protocol)?.next()? {
                    let ended = matches!(message, Message::SnapshotEnd { .. });
                    if self.step == Step::SendSource {
                        if let Message::SnapshotEnd { digest } = &message {
                            self.preparation_allowance = Some(PreparationAllowance {
                                source_digest: digest.clone(),
                                limit: preparation_limit(
                                    self.source.as_ref().ok_or(DriverError::Protocol)?,
                                )?,
                                completed: 0,
                                open: true,
                            });
                        }
                    }
                    self.enqueue(message)?;
                    self.deadline = now.saturating_add(DATA_MS);
                    if ended {
                        self.sender = None;
                        if self.step == Step::SendSource {
                            self.step = Step::ReceiveTarget;
                        } else {
                            if self.session.phone_controlled() {
                                self.enqueue(Message::ControllerPreview {
                                    summary: Box::new(
                                        self.preview_summary
                                            .clone()
                                            .ok_or(DriverError::Protocol)?,
                                    ),
                                    transfer_total_bytes: self.progress.transfer_total_bytes,
                                })?;
                            } else {
                                self.enqueue(Message::Preview {
                                    binding: self.binding.clone().ok_or(DriverError::Protocol)?,
                                })?;
                            }
                            self.step = Step::Approval;
                            self.state = State::AwaitingApproval;
                            self.deadline = now.saturating_add(USER_MS);
                        }
                    }
                }
            } else if self.step == Step::Sending {
                self.advance_stream_file();
                let in_flight = self
                    .file
                    .iter()
                    .chain(self.awaiting_files.iter())
                    .map(|file| file.offset.saturating_sub(file.acknowledged))
                    .sum::<u64>();
                if let Some(file) = &mut self.file {
                    if file.offset < file.length && in_flight < flow::WINDOW_BYTES {
                        let remaining = file.length - file.offset;
                        let size = remaining
                            .min(wire::MEDIA_CHUNK as u64)
                            .min(flow::WINDOW_BYTES - in_flight);
                        let mut bytes = vec![0; size as usize];
                        file.file
                            .read_exact(&mut bytes)
                            .map_err(|_| DriverError::Library)?;
                        let offset = file.offset;
                        let chunk_bytes = bytes.len() as u64;
                        file.offset += chunk_bytes;
                        file.pending_chunks.push_back((file.offset, chunk_bytes));
                        file.awaiting = true;
                        let message = Message::FileChunk {
                            sha256: file.sha.clone(),
                            offset,
                            data: bytes,
                        };
                        self.enqueue(message)?;
                    }
                }
            }
        }
        if !self.flush_required {
            for _ in 0..MAX_INFLIGHT_CHUNKS {
                let Some(message) = self.outbox.pop_front() else {
                    break;
                };
                let ready_usb_ack = matches!(self.session.transport(), super::Transport::Usb)
                    && matches!(
                        message,
                        Message::ChunkAccepted { .. } | Message::ChunksAccepted { .. }
                    );
                let grants_permission = matches!(message, Message::LeaseGranted { .. });
                let media = matches!(message, Message::FileChunk { .. });
                let envelope = Envelope {
                    version: 1,
                    session: self.session.session_id().into(),
                    operation: self.session.operation_id().into(),
                    generation: 1,
                    sequence: self.sent_sequence,
                    message,
                };
                let payload = envelope.encode()?;
                if media {
                    self.session
                        .send_media_payload(&payload, self.clock.unix_ms() / 1000)?;
                } else {
                    self.session
                        .send_payload(&payload, self.clock.unix_ms() / 1000)?;
                }
                if grants_permission {
                    self.issued_until = self.source_until;
                }
                self.sent_sequence = self
                    .sent_sequence
                    .checked_add(1)
                    .ok_or(DriverError::Bounds)?;
                self.flush_required = true;
                self.ciphertext_empty = false;
                // ACKs already queued by this poll can share the immediate TLS
                // output. Never wait for another ACK, poll new work here, merge
                // permission/finalization controls, or change TCP packetization.
                if !ready_usb_ack
                    || payload.len() > super::MAX_CONTROL
                    || !matches!(
                        self.outbox.front(),
                        Some(Message::ChunkAccepted { .. } | Message::ChunksAccepted { .. })
                    )
                {
                    break;
                }
            }
        }
        Ok(())
    }
    pub fn drain_ciphertext(&mut self) -> Result<Vec<u8>> {
        self.drain_classified_ciphertext().map(|(bytes, _)| bytes)
    }
    pub(crate) fn media_publication_boundary(&self) -> bool {
        if self.step != Step::Sending || self.flush_required || !self.outbox.is_empty() {
            return false;
        }
        let in_flight: u64 = self
            .file
            .iter()
            .chain(self.awaiting_files.iter())
            .map(|file| file.offset.saturating_sub(file.acknowledged))
            .sum();
        in_flight >= flow::WINDOW_BYTES
            || (self.pending_files.is_empty()
                && self
                    .file
                    .as_ref()
                    .is_some_and(|file| file.offset == file.length))
    }
    pub(crate) fn drain_classified_ciphertext(
        &mut self,
    ) -> Result<(Vec<u8>, super::session::OutputClass)> {
        if self.state == State::Completed && self.session.state() == SessionState::Terminal {
            return Ok((vec![], super::session::OutputClass::Immediate));
        }
        let result = self
            .session
            .drain_classified_ciphertext(self.clock.unix_ms() / 1000);
        match result {
            Ok((bytes, class)) => {
                self.flush_required = self.session.has_pending_output();
                self.ciphertext_empty = bytes.is_empty();
                self.outstanding_ciphertext = self
                    .outstanding_ciphertext
                    .checked_add(bytes.len())
                    .ok_or(DriverError::Bounds)?;
                self.progress.peak_ciphertext_bytes =
                    self.progress.peak_ciphertext_bytes.max(bytes.len());
                Ok((bytes, class))
            }
            Err(error) => {
                self.stop(false);
                Err(error.into())
            }
        }
    }
    /// Report only bytes actually accepted by the local I/O sink, not a TLS drain.
    /// Mailbox owners report after the atomic block write has completed.
    pub fn ciphertext_written(&mut self, count: usize) -> Result<()> {
        self.outstanding_ciphertext = self
            .outstanding_ciphertext
            .checked_sub(count)
            .ok_or(DriverError::Protocol)?;
        Ok(())
    }
    /// Consume the local close owner after the final ACK is fully written.
    /// An empty TLS drain alone does not prove external I/O completed.
    pub fn finish_success(&mut self) -> bool {
        if self.state != State::Completed {
            return false;
        }
        if self.session.state() == SessionState::Terminal {
            let _ = self.retire_session_record();
            self.publish_measurements();
            return true;
        }
        if self.ciphertext_empty
            && self.outstanding_ciphertext == 0
            && !self.flush_required
            && self.outbox.is_empty()
        {
            self.stop(false);
            let _ = self.retire_session_record();
            self.publish_measurements();
            return true;
        }
        false
    }
    pub(crate) fn ready_for_input(&self) -> bool {
        self.session.ready_for_input()
    }

    pub fn ingest_ciphertext(&mut self, bytes: &[u8]) -> Result<()> {
        self.ciphertext_empty = false;
        if let Err(error) = self
            .session
            .ingest_ciphertext(bytes, self.clock.unix_ms() / 1000)
        {
            self.stop(false);
            return Err(error.into());
        }
        self.persist_confirmed_pairing()
    }
    fn stop(&mut self, cancelled: bool) {
        if self.local_apply_installed() && !cancelled {
            self.detach_transport();
            return;
        }
        if cancelled {
            self.lifecycle_control().cancel();
        }
        self.detached = true;
        self.cancel.cancel();
        if let Some(preparation) = &mut self.preparation {
            preparation.active = false;
        }
        self.permit.active.store(false, Ordering::SeqCst);
        if !self.state.terminal() {
            self.state = if self.source_lease.is_some() || self.source_grant_issued() {
                State::CompletedUnconfirmed
            } else if cancelled {
                State::Cancelled
            } else {
                State::Failed
            };
        }
        if let Some(lease) = self.source_lease.take() {
            if self.clock.monotonic_ms() < self.issued_until {
                self.cleanup = Some(LeaseCleanup::start(
                    lease,
                    self.clock.clone(),
                    self.issued_until,
                ));
            }
        }
        self.retained = None;
        self.authorization = None;
        self.receive = None;
        self.file = None;
        self.pending_files.clear();
        self.awaiting_files.clear();
        self.requested_files.clear();
        self.receive_ack = Default::default();
        self.sender = None;
        self.collector = None;
        self.export_accounts = None;
        self.import_accounts = None;
        self.account_sender = None;
        self.account_collector = None;
        self.account_request = None;
        self.outbox.clear();
        self.outstanding_ciphertext = 0;
        self.success_until = None;
        self.session.cancel();
        if self.worker.is_none()
            && !matches!(self.state, State::Completed | State::CompletedUnconfirmed)
            && self.database.device_sync_recovery_pending()
        {
            self.state = State::RecoveryPending;
        }
        if let Some(close) = self.transport_close.take() {
            close();
        }
    }
    pub fn cancel(&mut self) {
        self.stop(true);
    }
    pub fn disconnect(&mut self) {
        self.stop(false);
    }
    pub(crate) fn retire_session_record(&mut self) -> Result<()> {
        if self.cleanup.as_ref().is_some_and(|cleanup| cleanup.poll())
            || self.worker.is_some()
            || self.preparation.is_some()
            || self.verification.is_some()
        {
            return Err(DriverError::Library);
        }
        if self.database.device_sync_recovery_pending() {
            // Unsettled apply is recovered through the real journal, not erased.
            return Ok(());
        }
        let session =
            Uuid::parse_str(self.session.session_id()).map_err(|_| DriverError::Protocol)?;
        self.session_cleanup_pending = true;
        let records = self
            .database
            .device_sync_unfinished_sessions()
            .map_err(|_| DriverError::Library)?;
        if let Some(record) = records.iter().find(|record| record.session == session) {
            super::startup_recovery::recover_session(&self.database, record)
                .map_err(|_| DriverError::Library)?;
        }
        self.session_cleanup_pending = false;
        Ok(())
    }
    fn detach_transport(&mut self) {
        self.detached = true;
        self.outbox.clear();
        self.outstanding_ciphertext = 0;
        self.session.cancel();
        if let Some(close) = self.transport_close.take() {
            close();
        }
    }
    pub(crate) fn poll_local(&mut self) -> Result<()> {
        if !self.local_apply_installed() {
            return Err(DriverError::Protocol);
        }
        self.poll_finished_local_worker()?;
        if self.state == State::Completed && self.session.state() == SessionState::Terminal {
            let _ = self.retire_session_record();
        }
        let cancelled = self.cancel.check().is_err();
        if cancelled && !self.state.terminal() {
            self.stop(true);
        }
        if cancelled && self.state != State::Completed {
            return Err(DriverError::Cancelled);
        }
        Ok(())
    }
    fn poll_finished_local_worker(&mut self) -> Result<()> {
        if !self.local_apply_installed() {
            return Ok(());
        }
        if let Some(authority) = &self.local_authority {
            self.progress.apply_work = authority.sql_work();
        }
        if self
            .worker
            .as_ref()
            .is_some_and(|worker| worker.is_finished())
        {
            let outcome = self
                .worker
                .take()
                .ok_or(DriverError::Library)?
                .join()
                .map_err(|_| DriverError::Library)
                .and_then(|outcome| outcome.map_err(receiver_work_error));
            return self.reconcile_local_worker(outcome, true);
        }
        Ok(())
    }
    fn reconcile_local_worker(
        &mut self,
        outcome: Result<ApplyReceipt>,
        external_allowed: bool,
    ) -> Result<()> {
        use super::recovery::JournalStage;

        let journal = self
            .local_identity
            .as_ref()
            .ok_or(DriverError::Library)
            .and_then(|identity| {
                let entry = self
                    .database
                    .device_sync_journal(identity.operation)
                    .map_err(|_| DriverError::Library)?;
                if entry.as_ref().is_some_and(|entry| {
                    entry.operation_uuid != identity.operation
                        || entry.external_reference != identity.external
                        || Some(entry.preview_digest.as_str()) != self.receiver_binding.as_deref()
                }) {
                    return Err(DriverError::Library);
                }
                Ok(entry)
            });
        let cancelled = self.cancel.check().is_err();
        let state = match journal {
            Ok(Some(entry)) if entry.stage == JournalStage::Finalized => {
                // A panic/error after finalization must not erase real success.
                self.receipt = Some(ApplyReceipt {
                    operation_uuid: entry.operation_uuid,
                    backup_uuid: entry.backup_uuid,
                    state: ApplyState::Finalized,
                });
                return self.complete_target();
            }
            Ok(Some(entry)) if entry.stage == JournalStage::LibraryApplied => {
                let pending = ApplyReceipt {
                    operation_uuid: entry.operation_uuid,
                    backup_uuid: entry.backup_uuid,
                    state: ApplyState::LibraryAppliedPending,
                };
                if external_allowed && !cancelled && outcome.as_ref().ok() == Some(&pending) {
                    self.receipt = Some(pending);
                    self.state = State::AwaitingExternal;
                    return Ok(());
                }
                State::RecoveryPending
            }
            Err(_) => State::RecoveryPending, // Unreadable ownership is not a safe failure.
            Ok(Some(entry)) if entry.stage == JournalStage::Prepared => State::RecoveryPending,
            Ok(_) if self.database.device_sync_recovery_pending() => State::RecoveryPending,
            Ok(_) if cancelled || matches!(outcome, Err(DriverError::Cancelled)) => {
                State::Cancelled
            }
            Ok(_) => State::Failed,
        };
        self.lifecycle.cancel();
        self.lifecycle.settle();
        self.state = state;
        self.receipt = None;
        Err(outcome.err().unwrap_or(DriverError::Library))
    }
    /// Join only during explicit teardown, never from the transport pump.
    pub fn finish_shutdown(&mut self) {
        if self.preparation.is_some() {
            self.stop(true);
            if let Some(preparation) = self.preparation.take() {
                let _ = preparation.worker.join();
            }
        }
        if let Some(worker) = self.verification.take() {
            let _ = worker.join();
        }
        if let Some(worker) = self.worker.take() {
            let outcome = worker
                .join()
                .map_err(|_| DriverError::Library)
                .and_then(|outcome| outcome.map_err(receiver_work_error));
            if self.local_apply_installed() {
                let _ = self.reconcile_local_worker(outcome, false);
            } else if let Ok(receipt) = outcome {
                let pending = receipt.state == ApplyState::LibraryAppliedPending;
                self.receipt = Some(receipt);
                self.state = if pending {
                    State::RecoveryPending
                } else {
                    State::Completed
                };
            }
        }
        if self
            .receipt
            .as_ref()
            .is_none_or(|receipt| receipt.state == ApplyState::LibraryAppliedPending)
            && self.database.device_sync_recovery_pending()
        {
            self.state = State::RecoveryPending;
        }
    }
}
impl Drop for Driver {
    fn drop(&mut self) {
        self.stop(true);
        self.finish_shutdown();
        self.publish_measurements();
    }
}

#[cfg(test)]
mod tests;
