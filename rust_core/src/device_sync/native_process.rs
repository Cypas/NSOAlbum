//! Parent-side native I/O isolation. The child owns all MTP handles.
use super::io_metrics::{IoMetrics, IoStep};
use super::native_io::{
    read_packet, response_from_packet, validate_response_payload, write_packet, IpcPacket,
    NativeError, NativeRequest, NativeResponse,
};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc, Mutex,
};
use std::time::{Duration, Instant};

type Reply = Result<NativeResponse, NativeError>;
type ReceivedReply = (Reply, Instant);
fn terminal_error(error: NativeError, discovery: bool) -> bool {
    error != NativeError::WindowFull && !(discovery && error == NativeError::Unavailable)
}
type CommandPacket = (IpcPacket, mpsc::SyncSender<ReceivedReply>, bool);
struct PendingRequest {
    response: mpsc::Receiver<ReceivedReply>,
    started: Instant,
    deadline: Duration,
    closing: bool,
    discovery: bool,
    payload_expected: bool,
}
pub struct NativeProcess {
    child: Arc<Mutex<Child>>,
    terminal: Arc<AtomicBool>,
    commands: mpsc::SyncSender<CommandPacket>,
    pending: Option<PendingRequest>,
    timings: Arc<Mutex<IoMetrics>>,
}
pub struct NativeCancellation {
    terminal: Arc<AtomicBool>,
    child: Arc<Mutex<Child>>,
}
impl NativeCancellation {
    pub fn cancel(&self) {
        self.terminal.store(true, Ordering::Release);
        if let Ok(mut child) = self.child.lock() {
            let _ = child.kill();
        }
    }
}
impl NativeProcess {
    pub fn spawn(executable: &Path) -> Result<Self, NativeError> {
        let mut command = Command::new(executable);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        }
        let mut child = command.spawn().map_err(|_| NativeError::Unavailable)?;
        let mut input = child.stdin.take().ok_or(NativeError::Io)?;
        let mut output = child.stdout.take().ok_or(NativeError::Io)?;
        let child = Arc::new(Mutex::new(child));
        let terminal = Arc::new(AtomicBool::new(false));
        let (commands, incoming) = mpsc::sync_channel::<CommandPacket>(1);
        let ended = terminal.clone();
        let io_child = child.clone();
        let timings = Arc::new(Mutex::new(IoMetrics::default()));
        let io_timings = timings.clone();
        std::thread::spawn(move || {
            while let Ok((request, reply, discovery)) = incoming.recv() {
                if ended.load(Ordering::Acquire) {
                    break;
                }
                let started = Instant::now();
                let answer = write_packet(&mut input, &request)
                    .and_then(|_| read_packet(&mut output))
                    .and_then(|packet| {
                        let decoding = Instant::now();
                        let packet_bytes = packet.header.len() + packet.payload.len();
                        let answer = response_from_packet(packet);
                        io_timings
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .elapsed(IoStep::IpcDecode, decoding, packet_bytes as u64);
                        answer
                    });
                let received_at = Instant::now();
                io_timings
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .elapsed(
                        IoStep::IpcRoundtrip,
                        started,
                        (request.header.len() + request.payload.len()) as u64,
                    );
                let failed = answer
                    .as_ref()
                    .is_err_and(|error| terminal_error(*error, discovery));
                if !ended.load(Ordering::Acquire) {
                    let _ = reply.try_send((answer, received_at));
                }
                if failed {
                    break;
                }
            }
            if let Ok(mut child) = io_child.lock() {
                let _ = child.kill();
                let _ = child.try_wait();
            }
        });
        Ok(Self {
            child,
            terminal,
            commands,
            pending: None,
            timings,
        })
    }
    pub fn cancellation(&self) -> NativeCancellation {
        NativeCancellation {
            terminal: self.terminal.clone(),
            child: self.child.clone(),
        }
    }
    pub fn request(
        &mut self,
        request: NativeRequest,
        deadline: Duration,
    ) -> Result<serde_json::Value, NativeError> {
        if matches!(request, NativeRequest::Read { .. }) {
            return Err(NativeError::InvalidBlock);
        }
        self.request_response(request, deadline)
            .and_then(|response| {
                if response.payload.is_empty() {
                    Ok(response.value)
                } else {
                    Err(NativeError::InvalidBlock)
                }
            })
    }
    pub fn request_response(
        &mut self,
        request: NativeRequest,
        deadline: Duration,
    ) -> Result<NativeResponse, NativeError> {
        self.begin_request(request, deadline)?;
        loop {
            if let Some(answer) = self.poll_response() {
                return answer;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }
    /// One bounded request; the USB owner keeps polling its original Driver.
    pub(crate) fn begin_request(
        &mut self,
        request: NativeRequest,
        deadline: Duration,
    ) -> Result<(), NativeError> {
        if self.terminal.load(Ordering::Acquire) {
            return Err(NativeError::Closed);
        }
        if self.pending.is_some() {
            return Err(NativeError::Closed);
        }
        let closing = matches!(request, NativeRequest::Close);
        let discovery = matches!(request, NativeRequest::Discover { .. });
        let payload_expected = matches!(request, NativeRequest::Read { .. });
        let encoding = Instant::now();
        let request = request.into_packet()?;
        let request_bytes = request.header.len() + request.payload.len();
        self.timings
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .elapsed(IoStep::IpcEncode, encoding, request_bytes as u64);
        let (reply, response) = mpsc::sync_channel(1);
        let started = Instant::now();
        self.commands
            .try_send((request, reply, discovery))
            .map_err(|_| NativeError::Closed)?;
        self.pending = Some(PendingRequest {
            response,
            started,
            deadline,
            closing,
            discovery,
            payload_expected,
        });
        Ok(())
    }
    pub(crate) fn poll_response(&mut self) -> Option<Reply> {
        let pending = self.pending.as_ref()?;
        let answer = if self.terminal.load(Ordering::Acquire) {
            Err(NativeError::Closed)
        } else {
            match pending.response.try_recv() {
                Ok((answer, received_at)) => {
                    if received_at.saturating_duration_since(pending.started) >= pending.deadline {
                        Err(NativeError::Timeout)
                    } else {
                        answer.and_then(|response| {
                            validate_response_payload(response, pending.payload_expected)
                        })
                    }
                }
                Err(mpsc::TryRecvError::Empty) => {
                    if pending.started.elapsed() >= pending.deadline {
                        Err(NativeError::Timeout)
                    } else {
                        return None;
                    }
                }
                Err(mpsc::TryRecvError::Disconnected) => Err(NativeError::Io),
            }
        };
        let pending = self.pending.take().expect("one native request");
        self.timings
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .elapsed(IoStep::ReceiptWait, pending.started, 0);
        if pending.closing
            || answer
                .as_ref()
                .is_err_and(|e| terminal_error(*e, pending.discovery))
        {
            self.cancel();
        }
        Some(answer)
    }
    pub fn cancel(&self) {
        self.cancellation().cancel();
    }
}
impl Drop for NativeProcess {
    fn drop(&mut self) {
        self.cancel();
        eprintln!(
            "{} site=parent",
            self.timings.lock().unwrap_or_else(|e| e.into_inner())
        );
        // Never join the pipe thread or wait synchronously for native teardown.
        // A private bounded reaper observes only the child this instance spawned.
        let child = self.child.clone();
        std::thread::spawn(move || {
            for _ in 0..100 {
                if let Ok(mut child) = child.lock() {
                    if !matches!(child.try_wait(), Ok(None)) {
                        break;
                    }
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::OnceLock;

    fn response_fixture(source: &str) -> (tempfile::TempDir, std::path::PathBuf) {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join(if cfg!(windows) {
            "response.exe"
        } else {
            "response"
        });
        assert!(std::process::Command::new("rustc")
            .arg(
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("tests/fixtures")
                    .join(source),
            )
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap()
            .success());
        (directory, executable)
    }

    // Hold an actual child-process reply without altering its value or receipt
    // timestamp. This models an owner busy doing local work, not slow native I/O.
    fn hold_completed_reply(process: &mut NativeProcess, wait: Duration) {
        let pending = process.pending.as_mut().unwrap();
        let received = pending.response.recv_timeout(wait).unwrap();
        let (send, replacement) = mpsc::sync_channel(1);
        send.send(received).unwrap();
        pending.response = replacement;
    }

    #[test]
    fn native_timely_reply_is_not_timed_out_when_the_owner_polls_after_the_deadline() {
        let (_directory, executable) = response_fixture("device_sync_reply_worker.rs");
        let mut process = NativeProcess::spawn(&executable).unwrap();
        process
            .begin_request(NativeRequest::Enumerate, Duration::from_secs(2))
            .unwrap();
        hold_completed_reply(&mut process, Duration::from_secs(1));
        std::thread::sleep(Duration::from_millis(2100));
        assert_eq!(
            process.poll_response(),
            Some(Ok(NativeResponse {
                value: serde_json::json!(123),
                payload: vec![],
            }))
        );
        assert_eq!(
            process.request(NativeRequest::Enumerate, Duration::from_secs(2)),
            Ok(serde_json::json!(123)),
            "a timely native reply must not kill the reusable worker"
        );
    }

    #[test]
    fn native_late_reply_is_rejected_even_when_already_buffered_at_owner_poll() {
        let (_directory, executable) = response_fixture("device_sync_timed_reply_worker.rs");
        let mut process = NativeProcess::spawn(&executable).unwrap();
        process
            .begin_request(NativeRequest::Enumerate, Duration::from_millis(50))
            .unwrap();
        hold_completed_reply(&mut process, Duration::from_secs(2));
        assert_eq!(process.poll_response(), Some(Err(NativeError::Timeout)));
        assert_eq!(
            process.request(NativeRequest::Enumerate, Duration::from_secs(1)),
            Err(NativeError::Closed)
        );
    }

    #[test]
    fn native_cancel_revokes_a_timely_buffered_reply_before_owner_consumption() {
        let (_directory, executable) = response_fixture("device_sync_reply_worker.rs");
        let mut process = NativeProcess::spawn(&executable).unwrap();
        process
            .begin_request(NativeRequest::Enumerate, Duration::from_secs(2))
            .unwrap();
        hold_completed_reply(&mut process, Duration::from_secs(1));
        process.cancel();
        assert_eq!(process.poll_response(), Some(Err(NativeError::Closed)));
    }

    #[test]
    fn v4_carrier_crosses_real_worker_ipc_and_oversize_cannot_publish_a_partial() {
        use crate::device_sync::native_io::Direction;

        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join(if cfg!(windows) {
            "v2-mailbox.exe"
        } else {
            "v2-mailbox"
        });
        assert!(std::process::Command::new("rustc")
            .arg(
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("tests/fixtures/device_sync_local_mailbox_worker.rs")
            )
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap()
            .success());
        let mut worker = NativeProcess::spawn(&executable).unwrap();
        let deadline = Duration::from_secs(5);
        worker
            .request(
                NativeRequest::Open {
                    device: "synthetic".into(),
                    storage: "storage".into(),
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                },
                deadline,
            )
            .unwrap();
        let name = "0000000000000000.block";
        let payload = vec![0x53; super::super::native_io::MAX_BLOCK];
        assert_eq!(
            worker.request(
                NativeRequest::Write {
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                    name: name.into(),
                    bytes: payload.clone(),
                },
                deadline
            ),
            Ok(serde_json::Value::Null)
        );
        let value = worker
            .request_response(
                NativeRequest::Read {
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                    direction: Direction::Desktop,
                    name: name.into(),
                },
                deadline,
            )
            .unwrap();
        assert!(value.value.is_null());
        assert_eq!(value.payload, payload);
        worker
            .request(
                NativeRequest::Acknowledge {
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                    direction: Direction::Desktop,
                    name: name.into(),
                },
                deadline,
            )
            .unwrap();
        assert_eq!(
            worker.request(
                NativeRequest::Write {
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                    name: "0000000000000001.block".into(),
                    bytes: vec![0x53; super::super::native_io::MAX_BLOCK + 1],
                },
                deadline
            ),
            Err(NativeError::Bounds)
        );
        let folder = directory
            .path()
            .join("exchange")
            .join(format!("s-{}", "b".repeat(32)))
            .join("desktop");
        assert_eq!(std::fs::read_dir(folder).unwrap().count(), 0);
    }

    fn fixture() -> &'static Path {
        static FILE: OnceLock<std::path::PathBuf> = OnceLock::new();
        FILE.get_or_init(|| {
            let output = tempfile::tempdir().unwrap().keep().join(if cfg!(windows) {
                "blocked-native-fixture.exe"
            } else {
                "blocked-native-fixture"
            });
            let source = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/device_sync_blocked_worker.rs");
            assert!(std::process::Command::new("rustc")
                .arg(source)
                .arg("-o")
                .arg(&output)
                .status()
                .unwrap()
                .success());
            output
        })
    }
    #[test]
    fn timeout_interrupts_worker_that_never_reads_a_full_block_request() {
        let mut process = NativeProcess::spawn(fixture()).unwrap();
        let start = Instant::now();
        assert_eq!(
            process.request(
                NativeRequest::Write {
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                    name: "0000000000000000.block".into(),
                    bytes: vec![b'x'; 87392],
                },
                Duration::from_millis(100)
            ),
            Err(NativeError::Timeout)
        );
        assert!(start.elapsed() < Duration::from_secs(2));
        assert_eq!(
            process.request(NativeRequest::Enumerate, Duration::from_secs(1)),
            Err(NativeError::Closed)
        );
    }
    #[test]
    fn cancel_and_drop_do_not_wait_for_a_native_response() {
        let process = NativeProcess::spawn(fixture()).unwrap();
        let start = Instant::now();
        process.cancel();
        drop(process);
        assert!(start.elapsed() < Duration::from_secs(2));
    }
    #[test]
    fn cancellation_interrupts_an_inflight_request_and_remains_terminal() {
        let mut process = NativeProcess::spawn(fixture()).unwrap();
        let cancellation = process.cancellation();
        let (done, completion) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let answer = process.request(NativeRequest::Enumerate, Duration::from_secs(30));
            let _ = done.send(answer);
        });
        let start = Instant::now();
        cancellation.cancel();
        assert_eq!(
            completion.recv_timeout(Duration::from_secs(1)).unwrap(),
            Err(NativeError::Closed)
        );
        assert!(start.elapsed() < Duration::from_secs(2));
    }
    #[test]
    fn process_returns_bounded_real_worker_responses_and_native_errors() {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory
            .path()
            .join(if cfg!(windows) { "reply.exe" } else { "reply" });
        assert!(std::process::Command::new("rustc")
            .arg(
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("tests/fixtures/device_sync_reply_worker.rs")
            )
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap()
            .success());
        let mut process = NativeProcess::spawn(&executable).unwrap();
        assert_eq!(
            process
                .request(NativeRequest::Enumerate, Duration::from_secs(2))
                .unwrap(),
            serde_json::json!(123)
        );
        assert_eq!(
            process.request(
                NativeRequest::Write {
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                    name: "0000000000000000.block".into(),
                    bytes: vec![1],
                },
                Duration::from_secs(2)
            ),
            Err(NativeError::InvalidBlock)
        );
    }

    #[test]
    fn value_only_request_api_refuses_binary_reads_without_poisoning_worker() {
        use super::super::native_io::Direction;

        let (_directory, executable) = response_fixture("device_sync_reply_worker.rs");
        let mut process = NativeProcess::spawn(&executable).unwrap();
        assert_eq!(
            process.request(
                NativeRequest::Read {
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                    direction: Direction::Desktop,
                    name: "0000000000000000.block".into(),
                },
                Duration::from_secs(2)
            ),
            Err(NativeError::InvalidBlock)
        );
        assert_eq!(
            process.request(NativeRequest::Enumerate, Duration::from_secs(2)),
            Ok(serde_json::json!(123))
        );
    }

    #[test]
    fn close_is_terminal_before_any_later_native_command() {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory
            .path()
            .join(if cfg!(windows) { "reply.exe" } else { "reply" });
        assert!(std::process::Command::new("rustc")
            .arg(
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("tests/fixtures/device_sync_reply_worker.rs")
            )
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap()
            .success());
        let mut process = NativeProcess::spawn(&executable).unwrap();
        assert_eq!(
            process.request(NativeRequest::Close, Duration::from_secs(2)),
            Ok(serde_json::Value::Null)
        );
        assert_eq!(
            process.request(NativeRequest::Enumerate, Duration::from_secs(2)),
            Err(NativeError::Closed)
        );
    }
    #[test]
    fn full_window_rejection_keeps_the_same_worker_available_for_reads_and_ack() {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory
            .path()
            .join(if cfg!(windows) { "reply.exe" } else { "reply" });
        assert!(std::process::Command::new("rustc")
            .arg(
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("tests/fixtures/device_sync_reply_worker.rs")
            )
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap()
            .success());
        let mut process = NativeProcess::spawn(&executable).unwrap();
        assert_eq!(
            process.request(
                NativeRequest::Write {
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                    name: "0000000000000080.block".into(),
                    bytes: vec![1, 2, 3],
                },
                Duration::from_secs(2)
            ),
            Err(NativeError::WindowFull)
        );
        assert_eq!(
            process.request_response(
                NativeRequest::Read {
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                    direction: super::super::native_io::Direction::Desktop,
                    name: "0000000000000000.block".into(),
                },
                Duration::from_secs(2)
            ),
            Ok(NativeResponse {
                value: serde_json::Value::Null,
                payload: vec![1, 2, 3],
            })
        );
        assert_eq!(
            process.request(
                NativeRequest::Acknowledge {
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                    direction: super::super::native_io::Direction::Desktop,
                    name: "0000000000000000.block".into(),
                },
                Duration::from_secs(2)
            ),
            Ok(serde_json::Value::Null)
        );
    }
    #[test]
    fn temporary_discovery_unavailability_preserves_worker_but_open_failure_is_terminal() {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory
            .path()
            .join(if cfg!(windows) { "reply.exe" } else { "reply" });
        assert!(std::process::Command::new("rustc")
            .arg(
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("tests/fixtures/device_sync_reply_worker.rs")
            )
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap()
            .success());
        let mut process = NativeProcess::spawn(&executable).unwrap();
        let discovery = || NativeRequest::Discover {
            operation: "a".repeat(32),
            session: "b".repeat(32),
        };
        assert_eq!(
            process.request(discovery(), Duration::from_secs(2)),
            Err(NativeError::Unavailable)
        );
        assert_eq!(
            process.request(discovery(), Duration::from_secs(2)),
            Ok(serde_json::json!(false))
        );
        assert_eq!(
            process.request(
                NativeRequest::Open {
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                    device: "candidate".into(),
                    storage: "storage".into(),
                },
                Duration::from_secs(2)
            ),
            Err(NativeError::Unavailable)
        );
        assert_eq!(
            process.request(NativeRequest::Enumerate, Duration::from_secs(2)),
            Err(NativeError::Closed)
        );
    }
}
