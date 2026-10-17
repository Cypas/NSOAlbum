//! Parent-side native I/O isolation. The child owns all MTP handles.
use super::native_io::{read_packet, write_packet, NativeError, NativeRequest, NativeResponse};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc, Mutex,
};
use std::time::{Duration, Instant};

type Reply = Result<serde_json::Value, NativeError>;
type CommandPacket = (Vec<u8>, mpsc::SyncSender<Reply>);
struct PendingRequest {
    response: mpsc::Receiver<Reply>,
    started: Instant,
    deadline: Duration,
    closing: bool,
}
pub struct NativeProcess {
    child: Arc<Mutex<Child>>,
    terminal: Arc<AtomicBool>,
    commands: mpsc::SyncSender<CommandPacket>,
    pending: Option<PendingRequest>,
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
        std::thread::spawn(move || {
            while let Ok((request, reply)) = incoming.recv() {
                if ended.load(Ordering::Acquire) {
                    break;
                }
                let answer = write_packet(&mut input, &request)
                    .and_then(|_| read_packet(&mut output))
                    .and_then(|bytes| {
                        serde_json::from_slice::<NativeResponse>(&bytes)
                            .map_err(|_| NativeError::Io)
                    })
                    .and_then(|reply| reply.value);
                let failed = answer
                    .as_ref()
                    .is_err_and(|error| *error != NativeError::WindowFull);
                if !ended.load(Ordering::Acquire) {
                    let _ = reply.try_send(answer);
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
        let request = serde_json::to_vec(&request).map_err(|_| NativeError::Bounds)?;
        if request.len() > super::native_io::MAX_IPC {
            return Err(NativeError::Bounds);
        }
        let (reply, response) = mpsc::sync_channel(1);
        self.commands
            .try_send((request, reply))
            .map_err(|_| NativeError::Closed)?;
        self.pending = Some(PendingRequest {
            response,
            started: Instant::now(),
            deadline,
            closing,
        });
        Ok(())
    }
    pub(crate) fn poll_response(&mut self) -> Option<Reply> {
        let pending = self.pending.as_ref()?;
        let answer = if self.terminal.load(Ordering::Acquire) {
            Err(NativeError::Closed)
        } else if pending.started.elapsed() >= pending.deadline {
            Err(NativeError::Timeout)
        } else {
            match pending.response.try_recv() {
                Ok(answer) => answer,
                Err(mpsc::TryRecvError::Empty) => return None,
                Err(mpsc::TryRecvError::Disconnected) => Err(NativeError::Io),
            }
        };
        let pending = self.pending.take().expect("one native request");
        if pending.closing
            || answer
                .as_ref()
                .is_err_and(|e| *e != NativeError::WindowFull)
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
                    bytes: "x".repeat(87392),
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
                    bytes: "AQ==".into(),
                },
                Duration::from_secs(2)
            ),
            Err(NativeError::InvalidBlock)
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
                    bytes: "AQID".into(),
                },
                Duration::from_secs(2)
            ),
            Err(NativeError::WindowFull)
        );
        assert_eq!(
            process.request(
                NativeRequest::Read {
                    operation: "a".repeat(32),
                    session: "b".repeat(32),
                    direction: super::super::native_io::Direction::Desktop,
                    name: "0000000000000000.block".into(),
                },
                Duration::from_secs(2)
            ),
            Ok(serde_json::json!("AQID"))
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
}
