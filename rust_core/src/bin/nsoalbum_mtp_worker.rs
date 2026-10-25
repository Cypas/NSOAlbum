#[cfg(any(windows, target_os = "macos"))]
fn main() {
    use squid_album_core::device_sync::{
        native_io::{read_packet, response_packet, write_packet, NativeError, NativeRequest},
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
    while let Ok(packet) = read_packet(&mut input) {
        let decoding = std::time::Instant::now();
        let packet_bytes = packet.header.len() + packet.payload.len();
        let Ok(request) = NativeRequest::from_packet(packet) else {
            break;
        };
        worker.record_ipc_decode(decoding, packet_bytes);
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
        let value = runtime.block_on(worker.execute(request));
        let payload = worker.take_response_payload();
        let failed = value.as_ref().is_err_and(|error| {
            *error != NativeError::WindowFull && !(discovery && *error == NativeError::Unavailable)
        });
        #[cfg(debug_assertions)]
        if phase == "Write" || phase == "Close" || failed {
            eprintln!(
                "device_sync boundary=UsbNative category=End reason={phase} {:?}",
                value.as_ref().err()
            );
        }
        let encoding = std::time::Instant::now();
        let Ok(response) = response_packet(value, payload) else {
            break;
        };
        worker.record_ipc_encode(encoding, response.header.len() + response.payload.len());
        if write_packet(&mut output, &response).is_err() || close || failed {
            break;
        }
    }
}
#[cfg(not(any(windows, target_os = "macos")))]
fn main() {
    std::process::exit(2);
}
