//! A single mailbox owner for the existing Driver; OS completions are capabilities.
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::{Notify, Semaphore};
use uuid::Uuid;

use super::driver::{pump::bundle::BundlePump, Driver, State};
use super::headless::Endpoint;
use super::metrics::IoKind;
use super::native_io::{self, Direction, NativeDevice, NativeError, NativeRequest};
use super::native_process::{NativeCancellation, NativeProcess};
use super::read_model::ReadError;
use super::runtime::{self, Owner};

const IO_DEADLINE: Duration = Duration::from_secs(30);
const TICK: Duration = Duration::from_millis(2);
const CLEANUP_BATCH_DELAY: Duration = Duration::from_millis(250);
const DIRECTORY_BYTES: usize = 32 * 1024 * 1024;
const DATA_DIRECTORY_BYTES: usize = DIRECTORY_BYTES - 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UsbActionKind {
    Enumerate,
    Open,
    List,
    Read,
    Write,
    Acknowledge,
    Close,
}
#[derive(Clone, Debug)]
pub struct UsbAction {
    pub token: String,
    pub generation: String,
    pub operation: String,
    pub session: String,
    pub kind: UsbActionKind,
    pub direction: Direction,
    pub name: Option<String>,
    pub bytes: Vec<u8>,
    pub device: Option<String>,
    pub storage: Option<String>,
}
#[derive(Clone, Debug)]
pub struct UsbReply {
    pub token: String,
    pub generation: String,
    pub operation: String,
    pub session: String,
    pub bytes: Vec<u8>,
    pub names: Vec<String>,
    pub devices: Vec<NativeDevice>,
    pub error: Option<ReadError>,
}
impl UsbReply {
    pub fn empty(action: &UsbAction) -> Self {
        Self {
            token: action.token.clone(),
            generation: action.generation.clone(),
            operation: action.operation.clone(),
            session: action.session.clone(),
            bytes: vec![],
            names: vec![],
            devices: vec![],
            error: None,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UsbCloseReason {
    Success,
    Cancelled,
    Failure,
}
#[derive(Clone, Debug)]
pub struct UsbView {
    pub closed: bool,
    pub reason: Option<UsbCloseReason>,
    pub error: Option<ReadError>,
    pub devices: Vec<NativeDevice>,
}

pub(crate) enum Start {
    Saf,
    Native,
    #[cfg(test)]
    DesktopActions,
    #[cfg(test)]
    NativeFixture(std::path::PathBuf),
}
impl Start {
    fn external(&self) -> bool {
        match self {
            Self::Saf => true,
            #[cfg(test)]
            Self::DesktopActions => true,
            _ => false,
        }
    }
    fn desktop(&self) -> bool {
        !matches!(self, Self::Saf)
    }
}
struct Pending {
    action: UsbAction,
    delivered: bool,
    reply: Option<UsbReply>,
    started: Instant,
}
struct Exchange {
    pending: Option<Pending>,
    cancelled: bool,
    detached: bool,
    view: UsbView,
    selected: Option<(String, String)>,
}
pub(crate) struct Control {
    exchange: Mutex<Exchange>,
    changed: Notify,
    closed: Notify,
    reader: Semaphore,
    closer: Semaphore,
    native: Mutex<Option<NativeCancellation>>,
    external: bool,
}
impl Control {
    pub(crate) fn new(start: &Start) -> Arc<Self> {
        Arc::new(Self {
            exchange: Mutex::new(Exchange {
                pending: None,
                cancelled: false,
                detached: false,
                selected: None,
                view: UsbView {
                    closed: false,
                    reason: None,
                    error: None,
                    devices: vec![],
                },
            }),
            changed: Notify::new(),
            closed: Notify::new(),
            reader: Semaphore::new(1),
            closer: Semaphore::new(1),
            native: Mutex::new(None),
            external: start.external(),
        })
    }
    pub(crate) fn view(&self) -> UsbView {
        self.exchange
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .view
            .clone()
    }
    pub(crate) fn cancel(&self) {
        {
            let mut exchange = self.exchange.lock().unwrap_or_else(|e| e.into_inner());
            if exchange.view.closed {
                return;
            }
            exchange.cancelled = true;
            // Invalidate the outstanding capability before notifying Dart/native.
            exchange.pending = None;
        }
        if let Some(native) = self
            .native
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
        {
            native.cancel();
        }
        self.closed.notify_waiters();
        self.changed.notify_waiters();
    }
    pub(crate) fn detach(&self) {
        {
            let mut exchange = self.exchange.lock().unwrap_or_else(|e| e.into_inner());
            if exchange.view.closed {
                return;
            }
            exchange.detached = true;
            exchange.pending = None;
        }
        if let Some(native) = self
            .native
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
        {
            native.cancel();
        }
        self.changed.notify_waiters();
    }
    pub(crate) async fn wait_closed(&self) -> Result<UsbView, ReadError> {
        let _slot = self.closer.try_acquire().map_err(|_| ReadError::Busy)?;
        loop {
            let notified = self.closed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let exchange = self.exchange.lock().unwrap_or_else(|e| e.into_inner());
                if exchange.view.closed {
                    return Ok(exchange.view.clone());
                }
                if exchange.cancelled {
                    return Ok(UsbView {
                        closed: false,
                        reason: Some(UsbCloseReason::Cancelled),
                        error: Some(ReadError::Cancelled),
                        devices: vec![],
                    });
                }
            }
            notified.await;
        }
    }
    pub(crate) async fn next(&self) -> Result<Option<UsbAction>, ReadError> {
        if !self.external {
            return Err(ReadError::PermissionDenied);
        }
        let _slot = self.reader.try_acquire().map_err(|_| ReadError::Busy)?;
        loop {
            let notified = self.changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let mut exchange = self.exchange.lock().unwrap_or_else(|e| e.into_inner());
                if exchange.cancelled || exchange.detached || exchange.view.closed {
                    return Ok(None);
                }
                if let Some(pending) = exchange.pending.as_mut() {
                    if pending.delivered {
                        if pending.reply.is_none() {
                            return Err(ReadError::Busy);
                        }
                    } else {
                        pending.delivered = true;
                        return Ok(Some(pending.action.clone()));
                    }
                }
            }
            notified.await;
        }
    }
    pub(crate) fn complete(&self, reply: UsbReply) -> Result<(), ReadError> {
        if !self.external {
            return Err(ReadError::PermissionDenied);
        }
        self.complete_inner(reply)
    }
    fn complete_inner(&self, reply: UsbReply) -> Result<(), ReadError> {
        if reply.bytes.len() > native_io::MAX_BLOCK
            || reply.names.len() > native_io::MAX_ENTRIES
            || reply.names.iter().any(|name| name.len() != 22)
            || !valid_devices(&reply.devices)
        {
            return Err(ReadError::InvalidInput);
        }
        let mut exchange = self.exchange.lock().unwrap_or_else(|e| e.into_inner());
        if exchange.detached {
            return Err(ReadError::Disconnected);
        }
        if exchange.cancelled || exchange.view.closed {
            return Err(ReadError::Cancelled);
        }
        let pending = exchange.pending.as_mut().ok_or(ReadError::PreviewChanged)?;
        let action = &pending.action;
        if !pending.delivered
            || pending.reply.is_some()
            || action.token != reply.token
            || action.generation != reply.generation
            || action.operation != reply.operation
            || action.session != reply.session
        {
            return Err(ReadError::PreviewChanged);
        }
        // Judge OS completion at receipt, not when the owner eventually
        // consumes it after synchronous source integrity work.
        if pending.started.elapsed() >= IO_DEADLINE {
            return Err(ReadError::Timeout);
        }
        let valid_payload = if reply.error.is_some() {
            reply.bytes.is_empty() && reply.names.is_empty() && reply.devices.is_empty()
        } else {
            match action.kind {
                UsbActionKind::Read => {
                    !reply.bytes.is_empty() && reply.names.is_empty() && reply.devices.is_empty()
                }
                UsbActionKind::List => reply.bytes.is_empty() && reply.devices.is_empty(),
                UsbActionKind::Enumerate => reply.bytes.is_empty() && reply.names.is_empty(),
                _ => reply.bytes.is_empty() && reply.names.is_empty() && reply.devices.is_empty(),
            }
        };
        if !valid_payload {
            return Err(ReadError::InvalidInput);
        }
        pending.reply = Some(reply);
        Ok(())
    }
    pub(crate) fn select(&self, device: &str, storage: &str) -> Result<(), ReadError> {
        let mut exchange = self.exchange.lock().unwrap_or_else(|e| e.into_inner());
        if exchange.cancelled || exchange.detached || exchange.view.closed {
            return Err(ReadError::Cancelled);
        }
        if exchange.selected.is_some()
            || !exchange
                .view
                .devices
                .iter()
                .any(|d| d.id == device && d.storages.iter().any(|s| s.id == storage))
        {
            return Err(ReadError::InvalidInput);
        }
        exchange.selected = Some((device.into(), storage.into()));
        Ok(())
    }
    fn finish(&self, reason: UsbCloseReason, error: Option<ReadError>) {
        let mut exchange = self.exchange.lock().unwrap_or_else(|e| e.into_inner());
        exchange.pending = None;
        exchange.view.closed = true;
        exchange.view.reason = Some(reason);
        exchange.view.error = error;
        exchange.view.devices.clear();
        drop(exchange);
        self.changed.notify_waiters();
        self.closed.notify_waiters();
    }
}
fn valid_devices(devices: &[NativeDevice]) -> bool {
    devices.len() <= 16
        && devices.iter().enumerate().all(|(index, d)| {
            !d.id.is_empty()
                && d.id.len() <= 128
                && d.name.len() <= 1024
                && d.storages.len() <= 16
                && devices[..index].iter().all(|previous| previous.id != d.id)
                && d.storages.iter().enumerate().all(|(index, s)| {
                    !s.id.is_empty()
                        && s.id.len() <= 128
                        && s.name.len() <= 1024
                        && d.storages[..index]
                            .iter()
                            .all(|previous| previous.id != s.id)
                })
        })
}

enum Stage {
    Enumerate,
    Select,
    Open,
    Receive,
    Read(String),
    DrainInput,
    Ack(String),
    Retire,
    Send,
    Close,
    Done,
}
pub(crate) struct UsbDriver {
    pub(crate) driver: Driver,
    pump: BundlePump,
    stage: Stage,
    incoming: VecDeque<String>,
    cleanup: VecDeque<String>,
    cleanup_since: Option<Instant>,
    outstanding: VecDeque<String>,
    outstanding_sizes: std::collections::HashMap<String, usize>,
    blocked: bool,
    operation: String,
    session: String,
    generation: String,
    outgoing: Direction,
    incoming_direction: Direction,
    success_started: Option<Instant>,
    discovering: bool,
    discovery_after: Option<Instant>,
    retire_after: Instant,
    poll_after: Instant,
    idle_ms: u64,
}
impl UsbDriver {
    #[cfg(test)]
    pub(crate) fn advance_for_test(&mut self, control: &Control) -> Result<bool, ReadError> {
        self.advance(control)
    }
    fn new(driver: Driver, start: &Start) -> Self {
        Self {
            operation: driver.channel_operation_id().into(),
            session: driver.session_id().into(),
            driver,
            pump: BundlePump::default(),
            stage: if start.external() || matches!(start, Start::Native) {
                Stage::Open
            } else {
                Stage::Enumerate
            },
            incoming: VecDeque::new(),
            cleanup: VecDeque::new(),
            cleanup_since: None,
            outstanding: VecDeque::new(),
            outstanding_sizes: std::collections::HashMap::new(),
            blocked: false,
            generation: Uuid::new_v4().simple().to_string(),
            outgoing: if start.desktop() {
                Direction::Desktop
            } else {
                Direction::Mobile
            },
            incoming_direction: if start.desktop() {
                Direction::Mobile
            } else {
                Direction::Desktop
            },
            success_started: None,
            discovering: matches!(start, Start::Native),
            discovery_after: None,
            retire_after: Instant::now(),
            poll_after: Instant::now(),
            idle_ms: 2,
        }
    }
    fn advance(&mut self, control: &Control) -> Result<bool, ReadError> {
        {
            let exchange = control.exchange.lock().unwrap_or_else(|e| e.into_inner());
            if exchange.cancelled {
                return Err(ReadError::Cancelled);
            }
            if exchange.detached {
                return Err(ReadError::Disconnected);
            }
        }
        // Driver completion revokes its business token. That is not an OS cancel:
        // an already accepted final CommitAck still owns a directory ACK.
        self.driver
            .poll()
            .inspect_err(|error| {
                super::diagnostics::driver(super::diagnostics::Boundary::UsbPoll, error)
            })
            .map_err(|e| ReadError::driver(&e))?;
        if self.pump.buffered_bytes() > 16 * 1024 * 1024 {
            return Err(ReadError::InvalidInput);
        }
        if self.driver.transport_detached()
            && self.driver.state() != State::Completed
            && !matches!(self.stage, Stage::Close | Stage::Done)
        {
            // An authenticated Abort/local transport detach cannot leave this
            // owner waiting for a future SAF receipt. But a genuine CommitAck
            // completes/revokes the source's business token before its incoming
            // block's owned directory ACK; Completed must finish bounded cleanup.
            // Explicit OS detach/cancel is still rejected above in every state.
            return Err(ReadError::Disconnected);
        }
        if self.driver.state().terminal() && self.driver.state() != State::Completed {
            return Err(if self.driver.state() == State::Cancelled {
                ReadError::Cancelled
            } else {
                ReadError::Disconnected
            });
        }
        if self.driver.state() == State::Completed {
            let started = self.success_started.get_or_insert_with(Instant::now);
            if started.elapsed() >= IO_DEADLINE {
                return Err(ReadError::Timeout);
            }
        }
        let completed = {
            let mut exchange = control.exchange.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(pending) = &mut exchange.pending {
                if pending.reply.is_none() && pending.started.elapsed() >= IO_DEADLINE {
                    if let Some(kind) = io_kind(pending.action.kind) {
                        self.driver.record_usb_io(
                            kind,
                            pending.started.elapsed().as_millis().min(u64::MAX as u128) as u64,
                            0,
                            true,
                        );
                    }
                    super::diagnostics::usb(pending.action.kind, &ReadError::Timeout);
                    return Err(ReadError::Timeout);
                }
                if pending.reply.is_none() {
                    let writing = pending.action.kind == UsbActionKind::Write;
                    drop(exchange);
                    if writing {
                        // Overlap only CPU/file preparation with the one native
                        // transaction; do not submit another MTP operation.
                        self.pump
                            .outgoing_without_finish(&mut self.driver)
                            .inspect_err(|error| {
                                super::diagnostics::driver(
                                    super::diagnostics::Boundary::UsbOutput,
                                    error,
                                )
                            })
                            .map_err(|error| ReadError::driver(&error))?;
                    }
                    return Ok(false);
                }
                let pending = exchange.pending.take().expect("checked pending");
                Some((
                    pending.action,
                    pending.reply.expect("checked reply"),
                    pending.started.elapsed(),
                ))
            } else {
                None
            }
        };
        if let Some((action, reply, elapsed)) = completed {
            if let Some(kind) = io_kind(action.kind) {
                let bytes = if reply.error.is_some() {
                    0
                } else {
                    match action.kind {
                        UsbActionKind::Read => reply.bytes.len(),
                        UsbActionKind::Write => action.bytes.len(),
                        _ => 0,
                    }
                };
                self.driver.record_usb_io(
                    kind,
                    elapsed.as_millis().min(u64::MAX as u128) as u64,
                    bytes as u64,
                    reply.error.is_some(),
                );
            }
            self.accept_completion(control, &action, reply)
                .inspect_err(|error| super::diagnostics::usb(action.kind, error))?;
        }
        if matches!(self.stage, Stage::DrainInput) {
            let accepted = self
                .pump
                .resume_input(&mut self.driver)
                .inspect_err(|error| {
                    super::diagnostics::driver(super::diagnostics::Boundary::UsbDrainInput, error)
                })
                .map_err(|error| ReadError::driver(&error))?;
            if let Some(name) = accepted {
                self.consumed(name)?;
            } else {
                // Input and output are independent TLS directions. A retained
                // large bundle may need an outgoing receipt to release its
                // consumer window. Keep its tail, but let that receipt publish.
                self.stage = Stage::Send;
            }
        }
        if matches!(self.stage, Stage::Done) {
            return Ok(true);
        }
        if self
            .discovery_after
            .is_some_and(|after| Instant::now() < after)
        {
            return Ok(false);
        }
        if matches!(self.stage, Stage::Receive) && Instant::now() < self.poll_after {
            return Ok(false);
        }
        if matches!(self.stage, Stage::Select) {
            let selection = control
                .exchange
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .selected
                .clone();
            if selection.is_none() {
                return Ok(false);
            }
            self.stage = Stage::Open;
        }
        // Do not read/ACK another ordered block until the decoded input window
        // has space. advance() still polls the driver above, so it can drain
        // retained TLS frames and continue outgoing work without dropping data.
        if matches!(self.stage, Stage::Receive | Stage::Read(_)) && !self.driver.ready_for_input() {
            if let Stage::Read(name) = &self.stage {
                self.incoming.push_front(name.clone());
            }
            self.stage = Stage::Send;
        }
        if self.cleanup_due() && matches!(self.stage, Stage::Receive | Stage::Read(_)) {
            // Read's name has already been removed from the directory queue.
            // Cleanup only preempts it; preserve it ahead of later entries.
            if let Stage::Read(name) = &self.stage {
                self.incoming.push_front(name.clone());
            }
            self.stage = Stage::Ack(self.cleanup.back().cloned().ok_or(ReadError::Internal)?);
        }
        let (kind, direction, name, bytes) = match &self.stage {
            Stage::Enumerate => (UsbActionKind::Enumerate, self.outgoing, None, vec![]),
            Stage::Open => (UsbActionKind::Open, self.outgoing, None, vec![]),
            Stage::Receive => (UsbActionKind::List, self.incoming_direction, None, vec![]),
            Stage::Read(name) => (
                UsbActionKind::Read,
                self.incoming_direction,
                Some(name.clone()),
                vec![],
            ),
            Stage::Ack(name) => (
                UsbActionKind::Acknowledge,
                self.incoming_direction,
                Some(name.clone()),
                vec![],
            ),
            Stage::Retire => (UsbActionKind::List, self.outgoing, None, vec![]),
            Stage::Send => {
                // Media credits use authenticated cumulative byte receipts.
                // This separate hard disk budget is not per-carrier stop/wait.
                if self.outstanding.len() >= 16 {
                    self.stage = if Instant::now() >= self.retire_after {
                        Stage::Retire
                    } else if self.pump.has_pending_input() {
                        Stage::DrainInput
                    } else {
                        Stage::Receive
                    };
                    return Ok(false);
                }
                if let Some((name, bytes)) = self
                    .pump
                    .outgoing_without_finish(&mut self.driver)
                    .inspect_err(|error| {
                        super::diagnostics::driver(super::diagnostics::Boundary::UsbOutput, error)
                    })
                    .map_err(|e| ReadError::driver(&e))?
                {
                    let name = name.to_owned();
                    let bytes = bytes.to_vec();
                    let used: usize = self
                        .outstanding
                        .iter()
                        .map(|name| self.outstanding_sizes.get(name).copied().unwrap_or(65_536))
                        .sum();
                    let limit = if self.pump.pending_is_control() {
                        DIRECTORY_BYTES
                    } else {
                        DATA_DIRECTORY_BYTES
                    };
                    if used.saturating_add(bytes.len()) > limit {
                        self.stage = if Instant::now() >= self.retire_after {
                            Stage::Retire
                        } else if self.pump.has_pending_input() {
                            Stage::DrainInput
                        } else {
                            Stage::Receive
                        };
                        return Ok(false);
                    }
                    (UsbActionKind::Write, self.outgoing, Some(name), bytes)
                } else {
                    self.stage = if self.cleanup_due() {
                        let name = self.cleanup.back().ok_or(ReadError::Internal)?;
                        Stage::Ack(name.clone())
                    } else if self.driver.state() == State::Completed
                        && self.outstanding.is_empty()
                        && self.pump.finish_success(&mut self.driver)
                    {
                        Stage::Close
                    } else if !self.outstanding.is_empty() && Instant::now() >= self.retire_after {
                        Stage::Retire
                    } else if self.pump.has_pending_input() {
                        Stage::DrainInput
                    } else {
                        Stage::Receive
                    };
                    return Ok(false);
                }
            }
            Stage::Close => (UsbActionKind::Close, self.outgoing, None, vec![]),
            Stage::Done | Stage::Select | Stage::DrainInput => return Ok(false),
        };
        let mut exchange = control.exchange.lock().unwrap_or_else(|e| e.into_inner());
        if exchange.cancelled {
            return Err(ReadError::Cancelled);
        }
        if exchange.detached {
            return Err(ReadError::Disconnected);
        }
        let (device, storage) = exchange
            .selected
            .clone()
            .map_or((None, None), |(d, s)| (Some(d), Some(s)));
        exchange.pending = Some(Pending {
            action: UsbAction {
                token: Uuid::new_v4().simple().to_string(),
                generation: self.generation.clone(),
                operation: self.operation.clone(),
                session: self.session.clone(),
                kind,
                direction,
                name,
                bytes,
                device,
                storage,
            },
            delivered: false,
            reply: None,
            started: Instant::now(),
        });
        drop(exchange);
        control.changed.notify_waiters();
        Ok(false)
    }
    fn accept_completion(
        &mut self,
        control: &Control,
        action: &UsbAction,
        reply: UsbReply,
    ) -> Result<(), ReadError> {
        if let Some(error) = reply.error {
            if self.discovering
                && action.kind == UsbActionKind::Open
                && matches!(error, ReadError::Busy | ReadError::Unavailable)
            {
                control
                    .exchange
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .view
                    .error = (error == ReadError::Unavailable).then_some(error);
                self.discovery_after = Some(Instant::now() + Duration::from_millis(500));
                self.stage = Stage::Open;
                return Ok(());
            }
            if error == ReadError::WindowFull
                && action.kind == UsbActionKind::Write
                && !self.outstanding.is_empty()
            {
                self.pump.window_full();
                self.blocked = true;
                // The retained carrier is already authenticated and ordered.
                // Listing before consuming its TLS tail can schedule it twice.
                self.stage = if self.pump.has_pending_input() {
                    Stage::DrainInput
                } else {
                    Stage::Receive
                };
                return Ok(());
            }
            return Err(error);
        }
        self.stage = match action.kind {
            UsbActionKind::Enumerate => {
                control
                    .exchange
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .view
                    .devices = reply.devices;
                Stage::Select
            }
            UsbActionKind::Open => {
                control
                    .exchange
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .view
                    .error = None;
                self.discovering = false;
                self.discovery_after = None;
                Stage::Receive
            }
            UsbActionKind::Read => {
                self.idle_ms = 2;
                let accepted = self
                    .pump
                    .accept(
                        &mut self.driver,
                        action.name.as_deref().ok_or(ReadError::Internal)?,
                        &reply.bytes,
                    )
                    .map_err(|e| ReadError::driver(&e))?;
                if let Some(name) = accepted {
                    self.consumed(name)?;
                    return Ok(());
                }
                Stage::DrainInput
            }
            UsbActionKind::Acknowledge => {
                let through = action.name.as_deref().ok_or(ReadError::Internal)?;
                while self
                    .cleanup
                    .front()
                    .is_some_and(|name| name.as_str() <= through)
                {
                    self.cleanup.pop_front();
                }
                if self.cleanup.is_empty() {
                    self.cleanup_since = None;
                }
                if self.blocked || self.outstanding.len() >= 16 {
                    // An inbound exchange was actually consumed, so the peer
                    // has made progress. Recheck capacity once under pressure;
                    // do not wait for the idle scan or assume any file retired.
                    self.retire_after = Instant::now();
                }
                if self.pump.has_pending_input() {
                    Stage::DrainInput
                } else if let Some(name) = self.incoming.pop_front() {
                    Stage::Read(name)
                } else {
                    Stage::Send
                }
            }
            UsbActionKind::Write => {
                if self.outstanding.len() >= native_io::MAX_ENTRIES {
                    return Err(ReadError::InvalidInput);
                }
                self.pump
                    .written(&mut self.driver)
                    .map_err(|e| ReadError::driver(&e))?;
                self.outstanding
                    .push_back(action.name.clone().ok_or(ReadError::Internal)?);
                self.outstanding_sizes.insert(
                    action.name.clone().ok_or(ReadError::Internal)?,
                    action.bytes.len(),
                );
                if self.pump.has_pending_input() {
                    Stage::DrainInput
                } else if self.driver.state() == State::Transferring && self.outstanding.len() < 16
                {
                    Stage::Send
                } else {
                    Stage::Receive
                }
            }
            UsbActionKind::List if action.direction == self.incoming_direction => {
                check_names(&reply.names)?;
                self.incoming = reply
                    .names
                    .into_iter()
                    .filter(|name| !self.cleanup.contains(name))
                    .collect();
                if self.incoming.is_empty() {
                    self.poll_after = Instant::now() + Duration::from_millis(self.idle_ms);
                    self.idle_ms = (self.idle_ms * 2).min(50);
                    Stage::Send
                } else {
                    self.idle_ms = 2;
                    self.incoming.pop_front().map_or(Stage::Send, Stage::Read)
                }
            }
            UsbActionKind::List => {
                check_names(&reply.names)?;
                // A directory count/change is not an ACK. Only an exact suffix
                // of our successfully published, same-scope sequence proves
                // that the counterpart retired a known contiguous prefix.
                let retired = self
                    .outstanding
                    .len()
                    .checked_sub(reply.names.len())
                    .ok_or(ReadError::InvalidInput)?;
                if !self.outstanding.iter().skip(retired).eq(reply.names.iter()) {
                    return Err(ReadError::InvalidInput);
                }
                for name in self.outstanding.drain(..retired) {
                    self.outstanding_sizes.remove(&name);
                }
                self.retire_after = Instant::now() + Duration::from_millis(250);
                if retired > 0 && self.blocked {
                    self.blocked = false;
                    self.pump.capacity_released();
                }
                if self.pump.has_pending_input() {
                    Stage::DrainInput
                } else if retired > 0
                    && self.driver.state() == State::Completed
                    && self.outstanding.is_empty()
                {
                    // The previous incoming snapshot preceded the peer's final
                    // ACK. Read again after that real retirement, so its already
                    // published ordered tail is accepted/ACKed before TLS close.
                    Stage::Receive
                } else if self.blocked || self.outstanding.len() >= 16 {
                    // Even a full outbound directory must service inbound
                    // receipts and the peer's own cleanup. Polling only our
                    // directory here deadlocks two bounded carriers.
                    Stage::Receive
                } else {
                    Stage::Send
                }
            }
            UsbActionKind::Close => Stage::Done,
        };
        Ok(())
    }
    fn consumed(&mut self, name: String) -> Result<(), ReadError> {
        if self.cleanup.len() >= 8 {
            return Err(ReadError::InvalidInput);
        }
        self.cleanup.push_back(name);
        self.cleanup_since.get_or_insert_with(Instant::now);
        self.stage = self.incoming.pop_front().map_or(Stage::Send, Stage::Read);
        Ok(())
    }
    fn cleanup_due(&self) -> bool {
        !self.cleanup.is_empty()
            && (self.cleanup.len() >= 8
                || self
                    .cleanup_since
                    .is_some_and(|since| since.elapsed() >= CLEANUP_BATCH_DELAY)
                || self.driver.state() == State::Completed)
    }
}
fn io_kind(kind: UsbActionKind) -> Option<IoKind> {
    match kind {
        UsbActionKind::List => Some(IoKind::List),
        UsbActionKind::Read => Some(IoKind::Read),
        UsbActionKind::Write => Some(IoKind::Write),
        UsbActionKind::Acknowledge => Some(IoKind::Acknowledge),
        _ => None,
    }
}
fn check_names(names: &[String]) -> Result<(), ReadError> {
    if names.len() > native_io::MAX_ENTRIES
        || names.iter().any(|n| !native_io::block_name(n))
        || names.windows(2).any(|p| p[0] >= p[1])
    {
        return Err(ReadError::InvalidInput);
    }
    Ok(())
}

fn native_error(error: NativeError) -> ReadError {
    match error {
        NativeError::InvalidScope => ReadError::PermissionDenied,
        NativeError::InvalidBlock | NativeError::Bounds | NativeError::Duplicate => {
            ReadError::InvalidInput
        }
        NativeError::WindowFull => ReadError::WindowFull,
        NativeError::Unavailable => ReadError::Unavailable,
        NativeError::Closed | NativeError::Io => ReadError::Disconnected,
        NativeError::Timeout => ReadError::Timeout,
    }
}
fn native_request(action: &UsbAction) -> Result<NativeRequest, ReadError> {
    let operation = action.operation.clone();
    let session = action.session.clone();
    let direction = action.direction;
    let name = action.name.clone().unwrap_or_default();
    Ok(match action.kind {
        UsbActionKind::Enumerate => NativeRequest::Enumerate,
        UsbActionKind::Open if action.device.is_none() && action.storage.is_none() => {
            NativeRequest::Discover { operation, session }
        }
        UsbActionKind::Open => NativeRequest::Open {
            device: action.device.clone().ok_or(ReadError::InvalidInput)?,
            storage: action.storage.clone().ok_or(ReadError::InvalidInput)?,
            operation,
            session,
        },
        UsbActionKind::List => NativeRequest::List {
            operation,
            session,
            direction,
        },
        UsbActionKind::Read => NativeRequest::Read {
            operation,
            session,
            direction,
            name,
        },
        UsbActionKind::Write => NativeRequest::Write {
            operation,
            session,
            name,
            bytes: action.bytes.clone(),
        },
        UsbActionKind::Acknowledge => NativeRequest::Acknowledge {
            operation,
            session,
            direction,
            name,
        },
        UsbActionKind::Close => NativeRequest::Close,
    })
}
fn native_reply(
    response: Result<super::native_io::NativeResponse, NativeError>,
    action: &UsbAction,
) -> UsbReply {
    let mut reply = UsbReply::empty(action);
    let result = (|| {
        let response = response.map_err(native_error)?;
        match action.kind {
            UsbActionKind::Open => {
                if !response.payload.is_empty() {
                    return Err(ReadError::InvalidInput);
                }
                if action.device.is_none() && action.storage.is_none() {
                    match response.value.as_bool() {
                        Some(true) => {}
                        Some(false) => return Err(ReadError::Busy),
                        None => return Err(ReadError::InvalidInput),
                    }
                } else if !response.value.is_null() {
                    return Err(ReadError::InvalidInput);
                }
            }
            UsbActionKind::Enumerate => {
                if !response.payload.is_empty() {
                    return Err(ReadError::InvalidInput);
                }
                reply.devices =
                    serde_json::from_value(response.value).map_err(|_| ReadError::InvalidInput)?
            }
            UsbActionKind::List => {
                if !response.payload.is_empty() {
                    return Err(ReadError::InvalidInput);
                }
                reply.names =
                    serde_json::from_value(response.value).map_err(|_| ReadError::InvalidInput)?
            }
            UsbActionKind::Read => {
                if !response.value.is_null()
                    || response.payload.is_empty()
                    || response.payload.len() > native_io::MAX_BLOCK
                {
                    return Err(ReadError::InvalidInput);
                }
                reply.bytes = response.payload;
            }
            _ if !response.value.is_null() || !response.payload.is_empty() => {
                return Err(ReadError::InvalidInput);
            }
            _ => {}
        }
        Ok(())
    })();
    if let Err(error) = result {
        reply.error = Some(error);
    }
    reply
}
fn executable(start: &Start) -> Result<std::path::PathBuf, ReadError> {
    #[cfg(test)]
    if let Start::NativeFixture(path) = start {
        return Ok(path.clone());
    }
    let _ = start;
    // No Bridge/QR/user path may choose executable code. Packaging is Task5C.
    let current = std::env::current_exe().map_err(|_| ReadError::Unavailable)?;
    let directory = current.parent().ok_or(ReadError::Unavailable)?;
    Ok(directory.join(if cfg!(windows) {
        "nsoalbum_mtp_worker.exe"
    } else {
        "nsoalbum_mtp_worker"
    }))
}

pub(crate) fn launch(
    endpoint: Arc<Endpoint>,
    start: Start,
    receiver: std::sync::mpsc::Receiver<runtime::Job>,
) -> std::io::Result<()> {
    std::thread::Builder::new()
        .name("device-sync-usb".into())
        .spawn(move || {
            let runtime = endpoint.runtime.as_ref().expect("managed owner");
            let control = runtime.usb.as_ref().expect("USB control");
            let mut process = None;
            let mut native_pending = None;
            let mut outcome = Ok(());
            if !start.external() {
                outcome = executable(&start)
                    .and_then(|path| NativeProcess::spawn(&path).map_err(native_error))
                    .map(|native| {
                        *control.native.lock().unwrap_or_else(|e| e.into_inner()) =
                            Some(native.cancellation());
                        process = Some(native);
                    });
            }
            {
                let mut owner = endpoint.owner.lock().unwrap_or_else(|e| e.into_inner());
                let Owner::Plain(driver) = std::mem::replace(&mut *owner, Owner::Moving) else {
                    unreachable!()
                };
                *owner = Owner::Usb(Box::new(UsbDriver::new(driver, &start)));
            }
            while outcome.is_ok() {
                let finished = {
                    let mut owner = endpoint.owner.lock().unwrap_or_else(|e| e.into_inner());
                    if let Ok(job) = receiver.try_recv() {
                        job(owner.driver_mut());
                    }
                    let Owner::Usb(usb) = &mut *owner else {
                        unreachable!()
                    };
                    let result = usb.advance(control);
                    endpoint.publish(&usb.driver);
                    result
                };
                match finished {
                    Ok(true) => break,
                    Err(error) => {
                        outcome = Err(error);
                        break;
                    }
                    _ => {}
                }
                if let Some(process) = &mut process {
                    if let Some(response) = process.poll_response() {
                        let action = native_pending.take().expect("one native action");
                        let reply = native_reply(response, &action);
                        if let Err(error) = control.complete_inner(reply) {
                            outcome = Err(error);
                        }
                    }
                    let action = {
                        let mut exchange =
                            control.exchange.lock().unwrap_or_else(|e| e.into_inner());
                        exchange.pending.as_mut().filter(|p| !p.delivered).map(|p| {
                            p.delivered = true;
                            p.action.clone()
                        })
                    };
                    if let Some(action) = action {
                        // Both pipe write and read run independently of the Driver.
                        match native_request(&action).and_then(|r| {
                            process.begin_request(r, IO_DEADLINE).map_err(native_error)
                        }) {
                            Ok(()) => native_pending = Some(action),
                            Err(error) => outcome = Err(error),
                        }
                    }
                }
                std::thread::sleep(TICK);
            }
            let cancelled = control
                .exchange
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .cancelled;
            if outcome.is_err() || cancelled {
                if let Some(process) = &process {
                    process.cancel();
                }
            }
            drop(process);
            control
                .native
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .take();
            {
                let mut owner = endpoint.owner.lock().unwrap_or_else(|e| e.into_inner());
                if cancelled {
                    owner.driver_mut().cancel();
                } else if outcome.is_err() {
                    owner.driver_mut().disconnect();
                }
                endpoint.publish(owner.driver());
            }
            let reason = if cancelled {
                UsbCloseReason::Cancelled
            } else if outcome.is_ok() {
                UsbCloseReason::Success
            } else {
                UsbCloseReason::Failure
            };
            control.finish(
                reason,
                if cancelled {
                    Some(ReadError::Cancelled)
                } else {
                    outcome.err()
                },
            );
            runtime::retain(endpoint, receiver);
        })
        .map(|_| ())
}

#[cfg(test)]
mod completion_tests {
    use super::*;
    use crate::api::CoreApi;
    use crate::device_sync::{
        clock::SystemClock, driver::Direction as TransferDirection, planner::SyncMode,
        receiver::ApplyBoundary, tests::confirmed, Role,
    };
    use std::sync::atomic::{AtomicBool, Ordering};

    fn discovery_action() -> UsbAction {
        UsbAction {
            token: "a".repeat(32),
            generation: "b".repeat(32),
            operation: "c".repeat(32),
            session: "d".repeat(32),
            kind: UsbActionKind::Open,
            direction: Direction::Desktop,
            name: None,
            bytes: vec![],
            device: None,
            storage: None,
        }
    }

    #[test]
    fn desktop_discovery_open_needs_no_user_selected_device() {
        let request = native_request(&discovery_action());
        assert!(
            request.is_ok(),
            "Desktop must discover the scanned session without a selected device"
        );
        let packet = request.unwrap().into_packet().unwrap();
        let value: serde_json::Value = serde_json::from_slice(&packet.header).unwrap();
        assert_eq!(value["method"], "discover");
        assert_eq!(value["session"], "d".repeat(32));
        assert!(value.get("device").is_none());
    }

    #[test]
    fn desktop_discovery_absent_session_is_pending_not_a_transport_failure() {
        let response = |value| {
            Ok(native_io::NativeResponse {
                value,
                payload: vec![],
            })
        };
        let reply = native_reply(response(serde_json::json!(false)), &discovery_action());
        assert_eq!(reply.error, Some(ReadError::Busy));
        assert!(reply.bytes.is_empty());
        let ready = native_reply(response(serde_json::json!(true)), &discovery_action());
        assert_eq!(ready.error, None);
        let malformed = native_reply(response(serde_json::json!("true")), &discovery_action());
        assert_eq!(malformed.error, Some(ReadError::InvalidInput));
        let payload_on_open = native_reply(
            Ok(native_io::NativeResponse {
                value: serde_json::json!(true),
                payload: vec![1],
            }),
            &discovery_action(),
        );
        assert_eq!(payload_on_open.error, Some(ReadError::InvalidInput));
    }

    #[tokio::test]
    async fn desktop_discovery_wait_is_bounded_and_cancel_does_not_need_os_completion() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let (session, _, _) = confirmed(Role::Sender);
        let driver = Driver::new(
            session,
            api.database(),
            "Desktop",
            Arc::new(SystemClock::default()),
        )
        .unwrap();
        let mut usb = UsbDriver::new(driver, &Start::Native);
        // Only the OS boundary is external; the production desktop state
        // machine must discover without a call to select().
        let control = Control::new(&Start::DesktopActions);
        let first = take(&mut usb, &control).await;
        assert_eq!(first.kind, UsbActionKind::Open);
        assert!(first.device.is_none() && first.storage.is_none());
        control
            .complete(native_reply(
                Ok(native_io::NativeResponse {
                    value: serde_json::json!(false),
                    payload: vec![],
                }),
                &first,
            ))
            .unwrap();
        usb.advance(&control).unwrap();
        assert!(control.exchange.lock().unwrap().pending.is_none());
        tokio::time::sleep(Duration::from_millis(510)).await;
        let second = take(&mut usb, &control).await;
        assert_ne!(second.token, first.token);
        control
            .complete(native_reply(Err(NativeError::Unavailable), &second))
            .unwrap();
        usb.advance(&control).unwrap();
        assert_eq!(control.view().error, Some(ReadError::Unavailable));
        assert!(!control.view().closed);
        tokio::time::sleep(Duration::from_millis(510)).await;
        let third = take(&mut usb, &control).await;
        control.cancel();
        assert_eq!(usb.advance(&control), Err(ReadError::Cancelled));
        assert!(control.complete(UsbReply::empty(&third)).is_err());
        assert!(api.list_media(Default::default()).unwrap().is_empty());
    }

    async fn take(usb: &mut UsbDriver, control: &Control) -> UsbAction {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            assert!(Instant::now() < deadline, "controlled USB action deadline");
            usb.advance(control).unwrap();
            let ready = control
                .exchange
                .lock()
                .unwrap()
                .pending
                .as_ref()
                .is_some_and(|p| !p.delivered);
            if ready {
                return control.next().await.unwrap().unwrap();
            }
            tokio::task::yield_now().await;
        }
    }

    fn ack_driver(api: &CoreApi) -> (UsbDriver, Arc<Control>) {
        let (session, _, _) = confirmed(Role::Sender);
        let driver = Driver::new(
            session,
            api.database(),
            "Phone",
            Arc::new(SystemClock::default()),
        )
        .unwrap();
        let mut usb = UsbDriver::new(driver, &Start::Saf);
        usb.stage = Stage::Ack("0000000000000000.block".into());
        (usb, Control::new(&Start::Saf))
    }

    #[test]
    fn publishing_local_output_does_not_reset_idle_inbound_directory_backoff() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let (mut session, _, now) = confirmed(Role::Sender);
        session.send_payload(b"synthetic control", now).unwrap();
        let driver = Driver::new(
            session,
            api.database(),
            "Phone",
            Arc::new(SystemClock::default()),
        )
        .unwrap();
        let mut usb = UsbDriver::new(driver, &Start::Saf);
        usb.stage = Stage::Send;
        let (name, bytes) = usb
            .pump
            .outgoing_without_finish(&mut usb.driver)
            .unwrap()
            .map(|(name, bytes)| (name.to_owned(), bytes.to_vec()))
            .unwrap();
        let action = UsbAction {
            token: "a".repeat(32),
            generation: usb.generation.clone(),
            operation: usb.operation.clone(),
            session: usb.session.clone(),
            kind: UsbActionKind::Write,
            direction: usb.outgoing,
            name: Some(name),
            bytes,
            device: None,
            storage: None,
        };
        usb.idle_ms = 50;

        usb.accept_completion(
            &Control::new(&Start::Saf),
            &action,
            UsbReply::empty(&action),
        )
        .unwrap();

        assert_eq!(
            usb.idle_ms, 50,
            "outbound writes are not evidence that the peer's incoming folder changed"
        );
    }

    #[test]
    fn rejected_publication_resumes_the_retained_input_before_listing_it_again() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let (mut sender, receiver, now) = confirmed(Role::Sender);
        for index in 0..9_u8 {
            sender
                .send_media_payload(&vec![index; 16_384], now)
                .unwrap();
        }
        let mut drains = Vec::new();
        loop {
            let bytes = sender.drain_ciphertext(now).unwrap();
            if bytes.is_empty() {
                break;
            }
            drains.push(bytes);
        }
        let carrier = super::super::mailbox::bundle::BundleEncoder::default()
            .encode(&drains)
            .unwrap();
        let driver = Driver::new(
            receiver,
            api.database(),
            "Desktop",
            Arc::new(SystemClock::default()),
        )
        .unwrap();
        let mut usb = UsbDriver::new(driver, &Start::Saf);
        assert!(usb
            .pump
            .accept(&mut usb.driver, &carrier.name, &carrier.bytes)
            .unwrap()
            .is_none());
        assert!(usb.pump.has_pending_input());
        usb.outstanding.push_back("0000000000000000.block".into());
        let mut action = discovery_action();
        action.kind = UsbActionKind::Write;
        action.name = Some("0000000000000001.block".into());
        let mut reply = UsbReply::empty(&action);
        reply.error = Some(ReadError::WindowFull);

        usb.accept_completion(&Control::new(&Start::Saf), &action, reply)
            .unwrap();

        assert!(
            matches!(usb.stage, Stage::DrainInput),
            "a full output directory cannot reread an authenticated carrier whose TLS tail is retained"
        );
        assert!(
            usb.cleanup.is_empty(),
            "unconsumed input is not acknowledged"
        );
        assert!(usb.blocked);
    }

    #[tokio::test]
    async fn cleanup_deadline_preserves_the_already_selected_read_before_later_entries() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let (mut usb, control) = ack_driver(&api);
        usb.stage = Stage::Read("0000000000000001.block".into());
        usb.incoming = [
            "0000000000000002.block".into(),
            "0000000000000003.block".into(),
        ]
        .into();
        usb.cleanup.push_back("0000000000000000.block".into());
        usb.cleanup_since = Some(Instant::now() - Duration::from_millis(251));
        let ack = take(&mut usb, &control).await;
        assert_eq!(ack.kind, UsbActionKind::Acknowledge);
        assert_eq!(ack.name.as_deref(), Some("0000000000000000.block"));
        control.complete(UsbReply::empty(&ack)).unwrap();

        let read = take(&mut usb, &control).await;
        assert_eq!(read.kind, UsbActionKind::Read);
        assert_eq!(
            read.name.as_deref(),
            Some("0000000000000001.block"),
            "cleanup must resume the selected read, not skip to a later directory entry"
        );
        assert_eq!(
            usb.incoming.iter().map(String::as_str).collect::<Vec<_>>(),
            ["0000000000000002.block", "0000000000000003.block"]
        );
        control.cancel();
        assert_eq!(usb.advance(&control), Err(ReadError::Cancelled));
    }

    #[tokio::test]
    async fn cleanup_waits_for_batch_window_while_inbound_polling_is_due() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let (mut usb, control) = ack_driver(&api);
        usb.stage = Stage::Receive;
        usb.cleanup.push_back("0000000000000000.block".into());
        usb.cleanup_since = Some(Instant::now() - Duration::from_millis(100));

        let poll = take(&mut usb, &control).await;
        assert_eq!(
            poll.kind,
            UsbActionKind::List,
            "a small cleanup batch must not preempt live inbound polling"
        );
        assert_eq!(usb.cleanup.len(), 1);
        control.cancel();
        assert!(control.complete(UsbReply::empty(&poll)).is_err());
    }

    #[tokio::test]
    async fn cleanup_waits_for_batch_window_when_output_is_temporarily_empty() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let (mut usb, control) = ack_driver(&api);
        usb.stage = Stage::Send;
        usb.cleanup.push_back("0000000000000000.block".into());
        usb.cleanup_since = Some(Instant::now() - Duration::from_millis(100));

        let poll = take(&mut usb, &control).await;
        assert_eq!(
            poll.kind,
            UsbActionKind::List,
            "a temporary output gap must not bypass the cleanup batch window"
        );
        assert_eq!(poll.direction, usb.incoming_direction);
        assert_eq!(usb.cleanup.len(), 1);
        control.cancel();
        assert!(control.complete(UsbReply::empty(&poll)).is_err());
    }

    #[tokio::test]
    async fn cleanup_full_batch_resumes_the_selected_read_without_consuming_a_later_entry() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let (mut usb, control) = ack_driver(&api);
        usb.stage = Stage::Read("0000000000000008.block".into());
        usb.incoming.push_back("0000000000000009.block".into());
        usb.cleanup = (0..8).map(|n| format!("{n:016x}.block")).collect();
        let ack = take(&mut usb, &control).await;
        assert_eq!(ack.kind, UsbActionKind::Acknowledge);
        assert_eq!(ack.name.as_deref(), Some("0000000000000007.block"));
        control.complete(UsbReply::empty(&ack)).unwrap();

        let read = take(&mut usb, &control).await;
        assert_eq!(read.kind, UsbActionKind::Read);
        assert_eq!(
            read.name.as_deref(),
            Some("0000000000000008.block"),
            "a full cleanup batch must not discard a preselected ciphertext block"
        );
        assert_eq!(
            usb.incoming.iter().map(String::as_str).collect::<Vec<_>>(),
            ["0000000000000009.block"]
        );
        control.cancel();
        assert!(control.complete(UsbReply::empty(&read)).is_err());
    }

    #[tokio::test]
    async fn full_publication_budget_still_polls_incoming_business_receipts() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let (mut usb, control) = ack_driver(&api);
        usb.stage = Stage::Send;
        usb.outstanding = (0..16).map(|n| format!("{n:016x}.block")).collect();
        // Nothing was retired yet. This must not turn into an endless sequence
        // of outgoing-directory scans that starves the peer's media receipts.
        for _ in 0..4 {
            let next = take(&mut usb, &control).await;
            assert_eq!(next.kind, UsbActionKind::List);
            if next.direction == usb.incoming_direction {
                return;
            }
            let mut reply = UsbReply::empty(&next);
            reply.names = usb.outstanding.iter().cloned().collect();
            control.complete(reply).unwrap();
        }
        panic!("full publication budget starved the inbound channel");
    }

    #[tokio::test]
    async fn directory_byte_budget_blocks_media_but_preserves_independent_control_capacity() {
        for media in [true, false] {
            let root = tempfile::tempdir().unwrap();
            let api = CoreApi::open(root.path()).unwrap();
            let (mut session, _, now) = confirmed(Role::Sender);
            if media {
                session
                    .send_media_payload(&vec![1; 256 * 1024], now)
                    .unwrap();
            } else {
                session.send_payload(b"control", now).unwrap();
            }
            let driver = Driver::new(
                session,
                api.database(),
                "Phone",
                Arc::new(SystemClock::default()),
            )
            .unwrap();
            let mut usb = UsbDriver::new(driver, &Start::Saf);
            let control = Control::new(&Start::Saf);
            usb.stage = Stage::Send;
            usb.retire_after = Instant::now() + Duration::from_secs(1);
            for (index, size) in [8, 8, 8, 7].into_iter().enumerate() {
                let name = format!("{index:016x}.block");
                usb.outstanding.push_back(name.clone());
                usb.outstanding_sizes.insert(name, size * 1024 * 1024);
            }
            let next = take(&mut usb, &control).await;
            if media {
                assert_eq!(
                    next.kind,
                    UsbActionKind::List,
                    "31MiB of media must leave control reserve, not publish another data carrier"
                );
                assert_eq!(next.direction, usb.incoming_direction);
            } else {
                assert_eq!(next.kind, UsbActionKind::Write);
                assert!(next.bytes.len() < 1024 * 1024);
                assert!(31 * 1024 * 1024 + next.bytes.len() <= 32 * 1024 * 1024);
            }
            control.cancel();
            assert_eq!(usb.advance(&control), Err(ReadError::Cancelled));
            assert!(control.complete(UsbReply::empty(&next)).is_err());
        }
    }

    #[tokio::test]
    async fn consumed_peer_traffic_rechecks_blocked_publication_before_the_idle_scan() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let (mut usb, control) = ack_driver(&api);
        usb.cleanup.push_back("0000000000000000.block".into());
        usb.outstanding.push_back("0000000000000000.block".into());
        usb.blocked = true;
        usb.pump.window_full();
        usb.retire_after = Instant::now() + Duration::from_secs(1);
        let ack = take(&mut usb, &control).await;
        assert_eq!(ack.kind, UsbActionKind::Acknowledge);
        control.complete(UsbReply::empty(&ack)).unwrap();
        let next = take(&mut usb, &control).await;
        assert_eq!(next.kind, UsbActionKind::List);
        assert_eq!(
            next.direction, usb.outgoing,
            "real consumed peer traffic must trigger one pressure scan before idle polling"
        );
    }

    #[tokio::test]
    async fn timely_usb_receipt_survives_owner_consuming_after_io_deadline() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let (mut usb, control) = ack_driver(&api);
        let action = take(&mut usb, &control).await;
        assert_eq!(action.kind, UsbActionKind::Acknowledge);
        control.complete(UsbReply::empty(&action)).unwrap();
        // Receipt already arrived. Simulate snapshot hashing delaying only its
        // consumption, not a genuinely slow OS operation.
        control
            .exchange
            .lock()
            .unwrap()
            .pending
            .as_mut()
            .unwrap()
            .started = Instant::now() - IO_DEADLINE - Duration::from_secs(1);
        assert_eq!(usb.advance(&control), Ok(false));
        let next = take(&mut usb, &control).await;
        assert_eq!(next.kind, UsbActionKind::List);
        assert_ne!(next.token, action.token);
    }

    #[tokio::test]
    async fn usb_receipt_arriving_after_io_deadline_is_rejected_before_consumption() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let (mut usb, control) = ack_driver(&api);
        let action = take(&mut usb, &control).await;
        control
            .exchange
            .lock()
            .unwrap()
            .pending
            .as_mut()
            .unwrap()
            .started = Instant::now() - IO_DEADLINE - Duration::from_secs(1);
        assert_eq!(
            control.complete(UsbReply::empty(&action)),
            Err(ReadError::Timeout)
        );
        assert!(control
            .exchange
            .lock()
            .unwrap()
            .pending
            .as_ref()
            .unwrap()
            .reply
            .is_none());
        assert_eq!(usb.advance(&control), Err(ReadError::Timeout));
    }

    #[tokio::test]
    async fn missing_usb_receipt_still_times_out_and_cancel_revokes_timely_receipt() {
        let root = tempfile::tempdir().unwrap();
        let api = CoreApi::open(root.path()).unwrap();
        let (mut usb, control) = ack_driver(&api);
        let action = take(&mut usb, &control).await;
        control
            .exchange
            .lock()
            .unwrap()
            .pending
            .as_mut()
            .unwrap()
            .started = Instant::now() - IO_DEADLINE - Duration::from_secs(1);
        assert_eq!(usb.advance(&control), Err(ReadError::Timeout));
        control.cancel();
        assert_eq!(
            control.complete(UsbReply::empty(&action)),
            Err(ReadError::Cancelled)
        );
        assert_eq!(usb.advance(&control), Err(ReadError::Cancelled));

        let (mut usb, control) = ack_driver(&api);
        let action = take(&mut usb, &control).await;
        control.complete(UsbReply::empty(&action)).unwrap();
        control.cancel();
        assert_eq!(usb.advance(&control), Err(ReadError::Cancelled));
        assert_eq!(
            control.complete(UsbReply::empty(&action)),
            Err(ReadError::Cancelled)
        );
    }

    async fn late_real_lease_grant(retire_before_final_receive: bool) {
        let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let source_api = CoreApi::open(roots[0].path()).unwrap();
        let target_api = CoreApi::open(roots[1].path()).unwrap();
        source_api.create_tag("committed".into()).unwrap();
        let (source_session, target_session, _) = confirmed(Role::Receiver);
        let mut source = Driver::new(
            source_session,
            source_api.database(),
            "Source",
            Arc::new(SystemClock::default()),
        )
        .unwrap();
        let mut target = Driver::new(
            target_session,
            target_api.database(),
            "Target",
            Arc::new(SystemClock::default()),
        )
        .unwrap();
        let paused = Arc::new(AtomicBool::new(false));
        let release = Arc::new(AtomicBool::new(false));
        let worker_paused = paused.clone();
        let worker_release = release.clone();
        target
            .set_apply_observer(Arc::new(move |boundary| {
                if boundary == ApplyBoundary::Prepared {
                    worker_paused.store(true, Ordering::SeqCst);
                    let deadline = Instant::now() + Duration::from_secs(10);
                    while !worker_release.load(Ordering::SeqCst) {
                        assert!(Instant::now() < deadline, "controlled apply pause deadline");
                        std::thread::sleep(Duration::from_millis(1));
                    }
                }
            }))
            .unwrap();
        source
            .configure(TransferDirection::DesktopToPhone, SyncMode::Merge, false)
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut approved = false;
        while !paused.load(Ordering::SeqCst) {
            assert!(Instant::now() < deadline, "real receiver apply deadline");
            source.poll().unwrap();
            let bytes = source.drain_ciphertext().unwrap();
            if !bytes.is_empty() {
                target.ingest_ciphertext(&bytes).unwrap();
                source.ciphertext_written(bytes.len()).unwrap();
            }
            target.poll().unwrap();
            if !approved && target.state() == State::AwaitingApproval {
                target.approve_preview().unwrap();
                approved = true;
            }
            let bytes = target.drain_ciphertext().unwrap();
            if !bytes.is_empty() {
                source.ingest_ciphertext(&bytes).unwrap();
                target.ciphertext_written(bytes.len()).unwrap();
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        // Hold an actual source LeaseGranted in the OS boundary, not a forged
        // protocol message. The prepared worker still has its valid prior lease.
        let late_grant = loop {
            assert!(Instant::now() < deadline, "real late grant deadline");
            target.poll().unwrap();
            let bytes = target.drain_ciphertext().unwrap();
            if !bytes.is_empty() {
                source.ingest_ciphertext(&bytes).unwrap();
                target.ciphertext_written(bytes.len()).unwrap();
            }
            source.poll().unwrap();
            let bytes = source.drain_ciphertext().unwrap();
            if !bytes.is_empty() {
                break bytes;
            }
            tokio::task::yield_now().await;
        };
        release.store(true, Ordering::SeqCst);
        while target.state() != State::Completed {
            assert!(Instant::now() < deadline, "actual finalize deadline");
            target.poll().unwrap();
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        assert_eq!(target_api.list_tags().unwrap(), vec!["committed"]);
        let control = Control::new(&Start::Saf);
        let mut usb = UsbDriver::new(target, &Start::Saf);
        // Directory polling is adaptive. Consume only empty setup listings
        // until the actual final CommitAck is atomically published.
        let final_ack = loop {
            let action = take(&mut usb, &control).await;
            if action.kind == UsbActionKind::Write {
                break action;
            }
            assert!(matches!(
                action.kind,
                UsbActionKind::Open | UsbActionKind::List
            ));
            control.complete(UsbReply::empty(&action)).unwrap();
        };
        control.complete(UsbReply::empty(&final_ack)).unwrap();
        let retire = loop {
            let action = take(&mut usb, &control).await;
            assert_eq!(action.kind, UsbActionKind::List);
            if action.direction == usb.outgoing {
                break action;
            }
            control.complete(UsbReply::empty(&action)).unwrap();
        };
        source.ciphertext_written(late_grant.len()).unwrap();
        let mut order = super::super::mailbox::bundle::BundleEncoder::default();
        let bundle = order.encode(&[late_grant]).unwrap();
        let name = bundle.name;
        let bytes = bundle.bytes;
        let mut source_order = super::super::mailbox::bundle::BundleDecoder::default();
        let drains = source_order
            .decode(final_ack.name.as_ref().unwrap(), &final_ack.bytes)
            .unwrap();
        if retire_before_final_receive {
            // The preceding incoming List really was empty. The source then
            // publishes its held grant before consuming/ACKing final_ack.
            for ciphertext in &drains {
                source.ingest_ciphertext(ciphertext).unwrap();
            }
            source.poll().unwrap();
            assert_eq!(source.state(), State::Completed);
        }
        let mut reply = UsbReply::empty(&retire);
        if !retire_before_final_receive {
            reply.names = vec![final_ack.name.clone().unwrap()];
        }
        control.complete(reply).unwrap();
        // Expose the held grant after either an empty outgoing drain with the
        // final block still live, or a real retirement after the prior empty list.
        let receive = take(&mut usb, &control).await;
        let tls_closed_before_directory_ack = usb.driver.cancellation().check().is_err();
        assert_eq!(
            receive.kind,
            UsbActionKind::List,
            "actual final publication retirement requires a fresh inbound pass, not close"
        );
        assert_eq!(receive.direction, usb.incoming_direction);
        let mut reply = UsbReply::empty(&receive);
        reply.names = vec![name.clone()];
        control.complete(reply).unwrap();
        let read = take(&mut usb, &control).await;
        assert_eq!(read.kind, UsbActionKind::Read);
        let mut reply = UsbReply::empty(&read);
        reply.bytes = bytes;
        control.complete(reply).unwrap();
        let accepted = usb.advance(&control);
        println!(
            "USB controlled final ACK: early_tls_closed={tls_closed_before_directory_ack} late_grant_result={accepted:?} target={:?}",
            usb.driver.state()
        );
        assert!(
            accepted.is_ok() && !tls_closed_before_directory_ack,
            "unretired final CommitAck must preserve TLS for the real late grant"
        );
        let acknowledge = take(&mut usb, &control).await;
        assert_eq!(acknowledge.kind, UsbActionKind::Acknowledge);
        control.complete(UsbReply::empty(&acknowledge)).unwrap();
        if !retire_before_final_receive {
            for ciphertext in &drains {
                source.ingest_ciphertext(ciphertext).unwrap();
            }
            source.poll().unwrap();
        }
        assert_eq!(source.state(), State::Completed);
        // Only now does the actual peer directory ACK retire final_ack.
        loop {
            let action = take(&mut usb, &control).await;
            let close = action.kind == UsbActionKind::Close;
            control.complete(UsbReply::empty(&action)).unwrap();
            if close {
                assert!(usb.advance(&control).unwrap());
                break;
            }
        }
        assert_eq!(usb.driver.state(), State::Completed);
        assert!(usb.driver.cancellation().check().is_err());
        assert_eq!(target_api.list_tags().unwrap(), vec!["committed"]);
    }

    #[tokio::test]
    async fn usb_final_commit_directory_ack_keeps_tls_live_for_late_real_lease_grant() {
        late_real_lease_grant(false).await;
    }

    #[tokio::test]
    async fn usb_final_commit_retirement_checks_real_tail_published_after_previous_empty_list() {
        late_real_lease_grant(true).await;
    }
}
