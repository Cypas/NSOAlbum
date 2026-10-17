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
        let Ok(request) = serde_json::from_slice::<NativeRequest>(&bytes) else {
            break;
        };
        let close = matches!(request, NativeRequest::Close);
        let response = NativeResponse {
            value: runtime.block_on(worker.execute(request)),
        };
        let failed = response
            .value
            .as_ref()
            .is_err_and(|error| *error != NativeError::WindowFull);
        let Ok(bytes) = serde_json::to_vec(&response) else {
            break;
        };
        if write_packet(&mut output, &bytes).is_err() || close || failed {
            break;
        }
    }
}
#[cfg(not(any(windows, target_os = "macos")))]
fn main() {
    std::process::exit(2);
}
