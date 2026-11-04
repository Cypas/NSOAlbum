//! One bounded command and TCP I/O owner per existing headless endpoint.
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::{
    atomic::{AtomicBool, AtomicU8, Ordering},
    mpsc::{self, Receiver, SyncSender},
    Arc, Condvar, Mutex,
};
use std::time::{Duration, Instant};

use tokio::sync::{oneshot, Notify, OwnedSemaphorePermit, Semaphore};

use super::driver::{pump::TcpDriver, Driver, DriverError};
use super::headless::Endpoint;
use super::read_model::ReadError;
use crate::sync::CancellationToken;

const COMMAND_CAPACITY: usize = 16;
const COMMAND_TTL: Duration = Duration::from_secs(5);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const TICK: Duration = Duration::from_millis(2);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceCommandError {
    pub code: ReadError,
    /// False only when this command is known not to have executed.
    pub executed: bool,
}
impl DeviceCommandError {
    pub(crate) fn rejected(code: ReadError) -> Self {
        Self {
            code,
            executed: false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub enum TcpPhase {
    Listening,
    Connecting,
    Connected,
    Closed,
}
#[derive(Clone, Debug, serde::Serialize)]
pub struct TcpView {
    pub phase: TcpPhase,
    pub error: Option<ReadError>,
}

pub(crate) enum Owner {
    Plain(Driver),
    Tcp(TcpDriver),
    Usb(Box<super::usb::UsbDriver>),
    Moving,
}
impl Owner {
    pub(crate) fn driver(&self) -> &Driver {
        match self {
            Self::Plain(driver) => driver,
            Self::Tcp(tcp) => tcp.driver(),
            Self::Usb(usb) => &usb.driver,
            Self::Moving => unreachable!("owner replacement holds the same mutex"),
        }
    }
    pub(crate) fn driver_mut(&mut self) -> &mut Driver {
        match self {
            Self::Plain(driver) => driver,
            Self::Tcp(tcp) => tcp.driver_mut(),
            Self::Usb(usb) => &mut usb.driver,
            Self::Moving => unreachable!("owner replacement holds the same mutex"),
        }
    }
}
pub(crate) type Job = Box<dyn FnOnce(&mut Driver) + Send>;

#[derive(Clone, Copy)]
pub(crate) enum CommandDomain {
    Network,
    Local,
}
pub(crate) fn admit_command(
    driver: &Driver,
    cancel: &CancellationToken,
    domain: CommandDomain,
) -> Result<(), DeviceCommandError> {
    if cancel.check().is_err() {
        return Err(DeviceCommandError::rejected(ReadError::Cancelled));
    }
    if driver.transport_detached()
        && (!matches!(domain, CommandDomain::Local) || !driver.local_apply_installed())
    {
        return Err(DeviceCommandError::rejected(ReadError::Disconnected));
    }
    Ok(())
}

pub(crate) enum Start {
    Listen(TcpListener),
    Connect(SocketAddr),
    Usb(super::usb::Start),
}
pub(crate) struct Control {
    sender: SyncSender<Job>,
    admission: Mutex<()>,
    slots: Arc<Semaphore>,
    phase: AtomicU8,
    error: Mutex<Option<ReadError>>,
    stopped: AtomicBool,
    done: Notify,
    blocking_done: (Mutex<bool>, Condvar),
    settle_requested: AtomicBool,
    native_settled: AtomicBool,
    native_done: Notify,
    blocking_native_done: (Mutex<bool>, Condvar),
    retiring: AtomicBool,
    pub(crate) usb: Option<Arc<super::usb::Control>>,
}
impl Control {
    pub(crate) fn new(start: &Start) -> (Arc<Self>, Receiver<Job>) {
        let (sender, receiver) = mpsc::sync_channel(COMMAND_CAPACITY);
        (
            Arc::new(Self {
                sender,
                admission: Mutex::new(()),
                slots: Arc::new(Semaphore::new(COMMAND_CAPACITY)),
                phase: AtomicU8::new(if matches!(start, Start::Listen(_)) {
                    0
                } else {
                    1
                }),
                error: Mutex::new(None),
                stopped: AtomicBool::new(false),
                done: Notify::new(),
                blocking_done: (Mutex::new(false), Condvar::new()),
                settle_requested: AtomicBool::new(false),
                native_settled: AtomicBool::new(false),
                native_done: Notify::new(),
                blocking_native_done: (Mutex::new(false), Condvar::new()),
                retiring: AtomicBool::new(false),
                usb: match start {
                    Start::Usb(start) => Some(super::usb::Control::new(start)),
                    _ => None,
                },
            }),
            receiver,
        )
    }
    pub(crate) fn view(&self) -> TcpView {
        TcpView {
            phase: match self.phase.load(Ordering::SeqCst) {
                0 => TcpPhase::Listening,
                1 => TcpPhase::Connecting,
                2 => TcpPhase::Connected,
                _ => TcpPhase::Closed,
            },
            error: *self.error.lock().unwrap_or_else(|e| e.into_inner()),
        }
    }
    pub(crate) async fn stopped(&self) {
        loop {
            let notified = self.done.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.stopped.load(Ordering::SeqCst) {
                return;
            }
            notified.await;
        }
    }
    pub(crate) fn wait_stopped(&self) {
        let (lock, changed) = &self.blocking_done;
        let mut stopped = lock.lock().unwrap_or_else(|e| e.into_inner());
        while !*stopped {
            stopped = changed.wait(stopped).unwrap_or_else(|e| e.into_inner());
        }
    }
    pub(crate) fn finish(&self) {
        self.phase.store(3, Ordering::SeqCst);
        self.slots.close();
        self.stopped.store(true, Ordering::SeqCst);
        *self
            .blocking_done
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = true;
        self.blocking_done.1.notify_all();
        self.done.notify_waiters();
    }
    pub(crate) fn request_settle(&self) {
        self.settle_requested.store(true, Ordering::SeqCst);
    }
    pub(crate) fn retire(&self) {
        let _admission = self.admission.lock().unwrap_or_else(|e| e.into_inner());
        self.retiring.store(true, Ordering::SeqCst);
        self.slots.close();
    }
    pub(crate) async fn settled(&self) {
        loop {
            let notified = self.native_done.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.native_settled.load(Ordering::SeqCst) {
                return;
            }
            notified.await;
        }
    }
    pub(crate) fn wait_settled(&self) {
        let (lock, changed) = &self.blocking_native_done;
        let mut done = lock.lock().unwrap_or_else(|error| error.into_inner());
        while !*done {
            done = changed
                .wait(done)
                .unwrap_or_else(|error| error.into_inner());
        }
    }
    fn finish_native(&self) {
        self.native_settled.store(true, Ordering::SeqCst);
        *self
            .blocking_native_done
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = true;
        self.blocking_native_done.1.notify_all();
        self.native_done.notify_waiters();
    }
    pub(crate) fn transport_closed(&self) {
        self.phase.store(3, Ordering::SeqCst);
    }
    pub(crate) fn fail(&self, error: ReadError) {
        *self.error.lock().unwrap_or_else(|e| e.into_inner()) = Some(error);
    }
    pub(crate) async fn call<T: Send + 'static>(
        &self,
        cancel: &CancellationToken,
        domain: CommandDomain,
        action: impl FnOnce(&mut Driver) -> Result<T, DriverError> + Send + 'static,
    ) -> Result<T, DeviceCommandError> {
        let result = {
            // Retire closes admission under this short queue-only lock. Every
            // earlier admitted job is enqueued before the final owner drain.
            let _admission = self.admission.lock().unwrap_or_else(|e| e.into_inner());
            if self.retiring.load(Ordering::SeqCst) {
                return Err(DeviceCommandError::rejected(ReadError::Disconnected));
            }
            let permit = self.slots.clone().try_acquire_owned().map_err(|_| {
                DeviceCommandError::rejected(if self.stopped.load(Ordering::SeqCst) {
                    ReadError::Disconnected
                } else {
                    ReadError::Busy
                })
            })?;
            let (reply, result) = oneshot::channel();
            let queued = Instant::now();
            let cancellation = cancel.clone();
            let job: Job = Box::new(move |driver| {
                if reply.is_closed() {
                    return;
                }
                let result = if queued.elapsed() >= COMMAND_TTL {
                    Err(DeviceCommandError::rejected(ReadError::Busy))
                } else {
                    admit_command(driver, &cancellation, domain).and_then(|()| {
                        action(driver).map_err(|e| DeviceCommandError {
                            code: ReadError::driver(&e),
                            executed: true,
                        })
                    })
                };
                // Capacity includes queued, executing and unconsumed results.
                let _ = reply.send((result, permit));
            });
            self.sender
                .try_send(job)
                .map_err(|_| DeviceCommandError::rejected(ReadError::Disconnected))?;
            result
        };
        let (result, _permit): (_, OwnedSemaphorePermit) =
            result.await.map_err(|_| DeviceCommandError {
                code: ReadError::Internal,
                executed: true,
            })?;
        result
    }
}

pub(crate) fn launch(
    endpoint: Arc<Endpoint>,
    start: Start,
    receiver: Receiver<Job>,
) -> std::io::Result<()> {
    let start = match start {
        Start::Usb(start) => return super::usb::launch(endpoint, start, receiver),
        start => start,
    };
    std::thread::Builder::new()
        .name("device-sync-tcp".into())
        .spawn(move || {
            let control = endpoint.runtime.as_ref().expect("managed owner");
            let connected = match start {
                Start::Listen(listener) => accept(&listener, &endpoint, &receiver),
                Start::Connect(address) => connect(address, &endpoint.transport_cancel),
                Start::Usb(_) => unreachable!(),
            };
            let outcome = connected.and_then(|stream| {
                let mut owner = endpoint.owner.lock().unwrap_or_else(|e| e.into_inner());
                let Owner::Plain(driver) = std::mem::replace(&mut *owner, Owner::Moving) else {
                    unreachable!("only the network owner installs its transport")
                };
                // The existing Driver is moved, not reconstructed or duplicated.
                match TcpDriver::from_stream_retaining(stream, driver) {
                    Ok(tcp) => {
                        *owner = Owner::Tcp(tcp);
                        Ok(())
                    }
                    Err((driver, error)) => {
                        *owner = Owner::Plain(*driver);
                        Err(ReadError::driver(&error))
                    }
                }
            });
            if let Err(error) = outcome {
                control.fail(error);
            } else {
                control.phase.store(2, Ordering::SeqCst);
                loop {
                    let mut owner = endpoint.owner.lock().unwrap_or_else(|e| e.into_inner());
                    if endpoint.transport_cancel.check().is_err() {
                        owner.driver_mut().disconnect();
                    }
                    if let Ok(job) = receiver.try_recv() {
                        job(owner.driver_mut());
                    }
                    let Owner::Tcp(tcp) = &mut *owner else {
                        unreachable!()
                    };
                    if let Err(error) = tcp.poll() {
                        control.fail(ReadError::driver(&error));
                    }
                    endpoint.publish(tcp.driver());
                    if tcp.is_closed() {
                        break;
                    }
                    drop(owner);
                    // Only this bounded owner polls; FRB never queues poll timers.
                    std::thread::sleep(TICK);
                }
            }
            retain(endpoint, receiver);
        })
        .map(|_| ())
}

/// Transport resources have ended, but this same owner/queue remains addressable.
/// Explicit native settle joins native work only; retirement is a later request.
pub(crate) fn retain(endpoint: Arc<Endpoint>, receiver: Receiver<Job>) {
    let control = endpoint.runtime.as_ref().expect("managed owner");
    control.transport_closed();
    {
        let mut owner = endpoint.owner.lock().unwrap_or_else(|e| e.into_inner());
        let transport_success = control.view().error.is_none()
            && control.usb.as_ref().is_none_or(|usb| {
                let view = usb.view();
                view.closed
                    && view.error.is_none()
                    && view.reason == Some(super::usb::UsbCloseReason::Success)
            });
        owner
            .driver_mut()
            .benchmark_transport_finished(transport_success);
        owner.driver_mut().disconnect();
        endpoint.publish(owner.driver());
    }
    loop {
        {
            let mut owner = endpoint.owner.lock().unwrap_or_else(|e| e.into_inner());
            if control.settle_requested.load(Ordering::SeqCst)
                && !control.native_settled.load(Ordering::SeqCst)
            {
                owner.driver_mut().cancel();
                owner.driver_mut().finish_shutdown();
                endpoint.publish(owner.driver());
                control.finish_native();
            } else if !control.native_settled.load(Ordering::SeqCst) {
                // Driver::poll routes detached installed work to poll_local.
                // Its error is a local outcome, not a new transport error.
                let _ = owner.driver_mut().poll();
            }
            if let Ok(job) = receiver.try_recv() {
                job(owner.driver_mut());
            }
            endpoint.publish(owner.driver());
        }
        if control.retiring.load(Ordering::SeqCst) && control.native_settled.load(Ordering::SeqCst)
        {
            let mut owner = endpoint.owner.lock().unwrap_or_else(|e| e.into_inner());
            while let Ok(job) = receiver.try_recv() {
                job(owner.driver_mut());
            }
            endpoint.publish(owner.driver());
            break;
        }
        std::thread::sleep(TICK);
    }
    drop(receiver);
    control.finish();
}

fn accept(
    listener: &TcpListener,
    endpoint: &Endpoint,
    receiver: &Receiver<Job>,
) -> Result<TcpStream, ReadError> {
    listener
        .set_nonblocking(true)
        .map_err(|_| ReadError::Unavailable)?;
    let started = Instant::now();
    loop {
        if endpoint.transport_cancel.check().is_err() {
            return Err(ReadError::Cancelled);
        }
        if started.elapsed() >= Duration::from_secs(300) {
            return Err(ReadError::Timeout);
        }
        if let Ok(job) = receiver.try_recv() {
            let mut owner = endpoint.owner.lock().unwrap_or_else(|e| e.into_inner());
            job(owner.driver_mut());
            endpoint.publish(owner.driver());
        }
        match listener.accept() {
            Ok((stream, _)) => return Ok(stream),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(TICK)
            }
            Err(_) => return Err(ReadError::Unavailable),
        }
    }
}
fn connect(address: SocketAddr, cancel: &CancellationToken) -> Result<TcpStream, ReadError> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| ReadError::Internal)?;
    runtime.block_on(async {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => Err(ReadError::Cancelled),
            _ = tokio::time::sleep(CONNECT_TIMEOUT) => Err(ReadError::Timeout),
            result = tokio::net::TcpStream::connect(address) => result
                .map_err(|_| ReadError::Disconnected)?
                .into_std().map_err(|_| ReadError::Internal),
        }
    })
}

/// Product binding is explicit, locally routable, and never a test bypass.
pub(crate) fn validate_bind(address: SocketAddr) -> Result<(), ReadError> {
    super::qr::validate_transport(&super::Transport::Tcp(SocketAddr::new(address.ip(), 1)))
        .map_err(|_| ReadError::InvalidInput)?;
    if address.ip().is_loopback() {
        return Err(ReadError::InvalidInput);
    }
    Ok(())
}
