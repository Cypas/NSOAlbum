//! A single mailbox owner for the existing Driver; OS completions are capabilities.
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::{engine::general_purpose::STANDARD, Engine};
use tokio::sync::{Notify, Semaphore};
use uuid::Uuid;

use super::driver::{pump::MailboxPump, Driver, State};
use super::headless::Endpoint;
use super::native_io::{self, Direction, NativeDevice, NativeError, NativeRequest};
use super::native_process::{NativeCancellation, NativeProcess};
use super::read_model::ReadError;
use super::runtime::{self, Owner};

const IO_DEADLINE: Duration = Duration::from_secs(30);
const TICK: Duration = Duration::from_millis(2);

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
    Ack(String),
    Retire,
    Send,
    Close,
    Done,
}
pub(crate) struct UsbDriver {
    pub(crate) driver: Driver,
    pump: MailboxPump,
    stage: Stage,
    incoming: VecDeque<String>,
    outstanding: VecDeque<String>,
    blocked: bool,
    operation: String,
    session: String,
    generation: String,
    outgoing: Direction,
    incoming_direction: Direction,
    success_started: Option<Instant>,
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
            pump: MailboxPump::default(),
            stage: if start.external() {
                Stage::Open
            } else {
                Stage::Enumerate
            },
            incoming: VecDeque::new(),
            outstanding: VecDeque::new(),
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
        self.driver.poll().map_err(|e| ReadError::driver(&e))?;
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
                if pending.started.elapsed() >= IO_DEADLINE {
                    return Err(ReadError::Timeout);
                }
                if pending.reply.is_none() {
                    return Ok(false);
                }
                let pending = exchange.pending.take().expect("checked pending");
                Some((pending.action, pending.reply.expect("checked reply")))
            } else {
                None
            }
        };
        if let Some((action, reply)) = completed {
            self.accept_completion(control, &action, reply)
                .inspect_err(|error| super::diagnostics::usb(action.kind, error))?;
        }
        if matches!(self.stage, Stage::Done) {
            return Ok(true);
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
            return Ok(false);
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
                if let Some((name, bytes)) = self
                    .pump
                    .outgoing_without_finish(&mut self.driver)
                    .map_err(|e| ReadError::driver(&e))?
                {
                    (
                        UsbActionKind::Write,
                        self.outgoing,
                        Some(name.into()),
                        bytes.to_vec(),
                    )
                } else {
                    self.stage = if self.driver.state() == State::Completed
                        && self.outstanding.is_empty()
                        && self.pump.finish_success(&mut self.driver)
                    {
                        Stage::Close
                    } else {
                        Stage::Receive
                    };
                    return Ok(false);
                }
            }
            Stage::Close => (UsbActionKind::Close, self.outgoing, None, vec![]),
            Stage::Done | Stage::Select => return Ok(false),
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
            if error == ReadError::WindowFull
                && action.kind == UsbActionKind::Write
                && !self.outstanding.is_empty()
            {
                self.pump.window_full();
                self.blocked = true;
                self.stage = Stage::Receive;
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
            UsbActionKind::Open => Stage::Receive,
            UsbActionKind::Read => {
                let accepted = self
                    .pump
                    .accept(
                        &mut self.driver,
                        action.name.as_deref().ok_or(ReadError::Internal)?,
                        &reply.bytes,
                    )
                    .map_err(|e| ReadError::driver(&e))?;
                Stage::Ack(accepted)
            }
            UsbActionKind::Acknowledge => {
                self.incoming.pop_front().map_or(Stage::Retire, Stage::Read)
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
                Stage::Receive
            }
            UsbActionKind::List if action.direction == self.incoming_direction => {
                check_names(&reply.names)?;
                self.incoming = reply.names.into();
                self.incoming.pop_front().map_or(Stage::Retire, Stage::Read)
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
                self.outstanding.drain(..retired);
                if retired > 0 && self.blocked {
                    self.blocked = false;
                    self.pump.capacity_released();
                }
                if retired > 0
                    && self.driver.state() == State::Completed
                    && self.outstanding.is_empty()
                {
                    // The previous incoming snapshot preceded the peer's final
                    // ACK. Read again after that real retirement, so its already
                    // published ordered tail is accepted/ACKed before TLS close.
                    Stage::Receive
                } else {
                    Stage::Send
                }
            }
            UsbActionKind::Close => Stage::Done,
        };
        Ok(())
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
            bytes: STANDARD.encode(&action.bytes),
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
fn native_reply(response: Result<serde_json::Value, NativeError>, action: &UsbAction) -> UsbReply {
    let mut reply = UsbReply::empty(action);
    let result = (|| {
        let value = response.map_err(native_error)?;
        match action.kind {
            UsbActionKind::Enumerate => {
                reply.devices =
                    serde_json::from_value(value).map_err(|_| ReadError::InvalidInput)?
            }
            UsbActionKind::List => {
                reply.names = serde_json::from_value(value).map_err(|_| ReadError::InvalidInput)?
            }
            UsbActionKind::Read => {
                let encoded = value.as_str().ok_or(ReadError::InvalidInput)?;
                if encoded.len() > native_io::MAX_BLOCK.div_ceil(3) * 4 {
                    return Err(ReadError::InvalidInput);
                }
                reply.bytes = STANDARD
                    .decode(encoded)
                    .map_err(|_| ReadError::InvalidInput)?;
            }
            _ if !value.is_null() => return Err(ReadError::InvalidInput),
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
        // Open, receive-empty, retire-empty, then the real final CommitAck.
        for kind in [
            UsbActionKind::Open,
            UsbActionKind::List,
            UsbActionKind::List,
        ] {
            let action = take(&mut usb, &control).await;
            assert_eq!(action.kind, kind);
            control.complete(UsbReply::empty(&action)).unwrap();
        }
        let final_ack = take(&mut usb, &control).await;
        assert_eq!(final_ack.kind, UsbActionKind::Write);
        control.complete(UsbReply::empty(&final_ack)).unwrap();
        let receive = take(&mut usb, &control).await;
        control.complete(UsbReply::empty(&receive)).unwrap();
        let retire = take(&mut usb, &control).await;
        source.ciphertext_written(late_grant.len()).unwrap();
        let mut order = super::super::mailbox::OrderedCiphertext::default();
        let (name, bytes) = order.encode(&late_grant).unwrap();
        let mut source_order = super::super::mailbox::OrderedCiphertext::default();
        let ciphertext = source_order
            .decode(final_ack.name.as_ref().unwrap(), &final_ack.bytes)
            .unwrap();
        if retire_before_final_receive {
            // The preceding incoming List really was empty. The source then
            // publishes its held grant before consuming/ACKing final_ack.
            source.ingest_ciphertext(&ciphertext).unwrap();
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
        let acknowledge = control.next().await.unwrap().unwrap();
        assert_eq!(acknowledge.kind, UsbActionKind::Acknowledge);
        control.complete(UsbReply::empty(&acknowledge)).unwrap();
        if !retire_before_final_receive {
            source.ingest_ciphertext(&ciphertext).unwrap();
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
