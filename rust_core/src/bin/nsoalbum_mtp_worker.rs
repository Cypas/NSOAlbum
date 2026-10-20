#[cfg(any(windows, target_os = "macos"))]
fn main() {
    use squid_album_core::device_sync::{
        native_io::{read_packet, write_packet, NativeError, NativeRequest, NativeResponse},
        native_mtp::MtpWorker,
    };
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let mut worker = MtpWorker::default();
    eprintln!("MTP_WORKER ready");
    let mut input = std::io::stdin().lock();
    let mut output = std::io::stdout().lock();
    while let Ok(bytes) = read_packet(&mut input) {
        let decoding = std::time::Instant::now();
        let Ok(request) = serde_json::from_slice::<NativeRequest>(&bytes) else {
            break;
        };
        worker.record_ipc_decode(decoding, bytes.len());
        let close = matches!(request, NativeRequest::Close);
        let discovery = matches!(request, NativeRequest::Discover { .. });
        #[cfg(debug_assertions)]
        let phase = match &request {
            NativeRequest::Enumerate => "Enumerate",
            NativeRequest::Discover { .. } => "Discover",
            NativeRequest::Open { .. } => "Open",
            NativeRequest::List { .. } => "List",
            NativeRequest::Read { .. } => "Read",
            NativeRequest::Write { .. } => "Write",
            NativeRequest::Acknowledge { .. } => "Acknowledge",
            NativeRequest::Close => "Close",
        };
        #[cfg(debug_assertions)]
        if phase == "Write" || phase == "Close" {
            eprintln!("device_sync boundary=UsbNative category=Begin reason={phase}");
        }
        let response = NativeResponse {
            value: runtime.block_on(worker.execute(request)),
        };
        #[cfg(debug_assertions)]
        if phase == "Write" || phase == "Close" || response.value.is_err() {
            eprintln!(
                "device_sync boundary=UsbNative category=End reason={phase} {:?}",
                response.value.as_ref().err()
            );
        }
        let failed = response.value.as_ref().is_err_and(|error| {
            *error != NativeError::WindowFull && !(discovery && *error == NativeError::Unavailable)
        });
        let encoding = std::time::Instant::now();
        let Ok(bytes) = serde_json::to_vec(&response) else {
            break;
        };
        worker.record_ipc_encode(encoding, bytes.len());
        if write_packet(&mut output, &bytes).is_err() || close || failed {
            break;
        }
    }
}
#[cfg(not(any(windows, target_os = "macos")))]
fn main() {
    std::process::exit(2);
}
