//! Synthetic byte-only MTP probe; never initializes CoreApi or accesses accounts/library data.
#[cfg(any(windows, target_os = "macos"))]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use squid_album_core::device_sync::{
        native_io::{Direction, NativeDevice, NativeRequest},
        native_process::NativeProcess,
    };
    use std::time::Duration;
    let worker = std::env::current_exe()?
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join(if cfg!(windows) {
            "nsoalbum_mtp_worker.exe"
        } else {
            "nsoalbum_mtp_worker"
        });
    let session = std::env::args()
        .nth(1)
        .unwrap_or_else(|| uuid::Uuid::new_v4().simple().to_string());
    let operation = uuid::Uuid::new_v4().simple().to_string();
    let mut process = NativeProcess::spawn(&worker).map_err(|e| format!("{e:?}"))?;
    let mut request = |request| {
        process
            .request_response(request, Duration::from_secs(15))
            .map_err(|e| format!("{e:?}"))
    };
    let devices: Vec<NativeDevice> =
        serde_json::from_value(request(NativeRequest::Enumerate)?.value)?;
    if devices.len() != 1 || devices[0].storages.is_empty() {
        return Err(
            "Probe requires exactly one available MTP device and a writable storage".into(),
        );
    }
    println!(
        "MTP_NATIVE_PROBE device={} storage={} session={session}",
        devices[0].name, devices[0].storages[0].name
    );
    request(NativeRequest::Open {
        device: devices[0].id.clone(),
        storage: devices[0].storages[0].id.clone(),
        operation: operation.clone(),
        session: session.clone(),
    })?;
    let name = "0000000000000000.block".to_string();
    let bytes = (0..123).map(|i| ((i * 37) & 255) as u8).collect::<Vec<_>>();
    request(NativeRequest::Write {
        operation: operation.clone(),
        session: session.clone(),
        name: name.clone(),
        bytes: bytes.clone(),
    })?;
    let received = request(NativeRequest::Read {
        operation: operation.clone(),
        session: session.clone(),
        direction: Direction::Desktop,
        name: name.clone(),
    })?;
    if !received.value.is_null() || received.payload != bytes {
        return Err("MTP byte mismatch".into());
    }
    println!("MTP_NATIVE_PROBE PASS forced-native write/part-publish/read 123 bytes");
    let mobile = request(NativeRequest::List {
        operation: operation.clone(),
        session: session.clone(),
        direction: Direction::Mobile,
    })?
    .value;
    if mobile
        .as_array()
        .is_some_and(|a| a.iter().any(|n| n.as_str() == Some(&name)))
    {
        let received = request(NativeRequest::Read {
            operation: operation.clone(),
            session: session.clone(),
            direction: Direction::Mobile,
            name: name.clone(),
        })?;
        if !received.value.is_null() || received.payload != bytes {
            return Err("Mobile byte mismatch".into());
        }
        println!("MTP_NATIVE_PROBE PASS Android SAF -> Windows MTP 123 bytes");
    } else {
        println!("MTP_NATIVE_PROBE Android SAF cross-read not executed: no synthetic mobile block");
    }
    if request(NativeRequest::Write {
        operation,
        session,
        name,
        bytes: vec![1],
    })
    .is_ok()
    {
        return Err("MTP overwrite unexpectedly accepted".into());
    }
    process.cancel();
    println!("MTP_NATIVE_PROBE PASS overwrite rejected/cancelled (synthetic session retained)");
    Ok(())
}
#[cfg(not(any(windows, target_os = "macos")))]
fn main() {
    eprintln!("Native MTP probe requires Windows/macOS");
    std::process::exit(2);
}
