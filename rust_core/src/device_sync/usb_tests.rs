use super::{headless, read_model::PairingStage, usb::*};
use std::{collections::BTreeMap, time::Duration};

use super::headless::owner_test_tools::SERIAL;

fn pipe_fixture(name: &str) -> std::path::PathBuf {
    let output = tempfile::tempdir().unwrap().keep().join(if cfg!(windows) {
        "owner-fixture.exe"
    } else {
        "owner-fixture"
    });
    assert!(std::process::Command::new("rustc")
        .arg(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures")
                .join(name)
        )
        .arg("-o")
        .arg(&output)
        .status()
        .unwrap()
        .success());
    use sha2::Digest;
    println!(
        "USB controlled pipe fixture source={name} sha256={}",
        hex::encode(sha2::Sha256::digest(std::fs::read(&output).unwrap()))
    );
    output
}

struct Mobile {
    _roots: [tempfile::TempDir; 2],
    libraries: [String; 2],
    host: String,
    phone: String,
}
impl Mobile {
    fn new() -> Self {
        let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let libraries = roots.each_ref().map(|r| {
            headless::open(r.path().to_string_lossy().into_owned())
                .unwrap()
                .handle
        });
        let host = headless::host(&libraries[0], "Desktop", None).unwrap();
        let phone = headless::client_usb(&libraries[1], &host.invitation, "Phone").unwrap();
        Self {
            _roots: roots,
            libraries,
            host: host.handle,
            phone,
        }
    }
}
impl Drop for Mobile {
    fn drop(&mut self) {
        for e in [&self.host, &self.phone] {
            let _ = headless::close_endpoint(e);
        }
        for l in &self.libraries {
            let _ = headless::close_library(l);
        }
    }
}
async fn action(endpoint: &str) -> UsbAction {
    tokio::time::timeout(Duration::from_secs(3), headless::usb_next(endpoint))
        .await
        .unwrap()
        .unwrap()
        .unwrap()
}

#[tokio::test]
async fn usb_cancel_is_independent_of_inflight_os_and_old_tokens_cannot_touch_new_session() {
    let _serial = SERIAL.lock().await;
    let mobile = Mobile::new();
    let open = action(&mobile.phone).await;
    assert_eq!(
        headless::usb_next(&mobile.phone).await.unwrap_err(),
        super::read_model::ReadError::Busy
    );
    let mut forged = UsbReply::empty(&open);
    forged.generation = "0".repeat(32);
    assert_eq!(
        headless::usb_complete(&mobile.phone, forged),
        Err(super::read_model::ReadError::PreviewChanged)
    );
    headless::usb_complete(&mobile.phone, UsbReply::empty(&open)).unwrap();
    let pending = action(&mobile.phone).await;
    let started = std::time::Instant::now();
    headless::cancel_signal(&mobile.phone).unwrap();
    let closed = headless::usb_closed(&mobile.phone).await.unwrap();
    assert_eq!(closed.reason, Some(UsbCloseReason::Cancelled));
    assert!(started.elapsed() < Duration::from_millis(250));
    assert!(headless::usb_complete(&mobile.phone, UsbReply::empty(&pending)).is_err());
    headless::shutdown_async(&mobile.phone).await.unwrap();
    assert_eq!(headless::status(&mobile.phone).unwrap().state, "Cancelled");
    let fresh = headless::client_usb(
        &mobile.libraries[1],
        &headless::host(&mobile.libraries[0], "New desktop", None)
            .map(|h| {
                let invitation = h.invitation;
                headless::close_endpoint(&h.handle).unwrap();
                invitation
            })
            .unwrap(),
        "Fresh phone",
    )
    .unwrap();
    let fresh_action = action(&fresh).await;
    assert_ne!(fresh_action.generation, pending.generation);
    assert_eq!(
        headless::usb_complete(&fresh, UsbReply::empty(&pending)),
        Err(super::read_model::ReadError::PreviewChanged)
    );
    headless::close_endpoint_async(&fresh).await.unwrap();
}

#[tokio::test]
async fn usb_typed_os_errors_and_untrusted_names_end_without_library_write_or_retry() {
    let _serial = SERIAL.lock().await;
    for error in [
        super::read_model::ReadError::PermissionDenied,
        super::read_model::ReadError::Unavailable,
        super::read_model::ReadError::Disconnected,
        super::read_model::ReadError::Timeout,
    ] {
        let mobile = Mobile::new();
        let open = action(&mobile.phone).await;
        let mut reply = UsbReply::empty(&open);
        reply.error = Some(error);
        headless::usb_complete(&mobile.phone, reply).unwrap();
        let closed = headless::usb_closed(&mobile.phone).await.unwrap();
        assert_eq!(closed.error, Some(error));
        assert_eq!(closed.reason, Some(UsbCloseReason::Failure));
        assert!(
            headless::owner_test_tools::runtime_api(&mobile.libraries[1])
                .list_media(Default::default())
                .unwrap()
                .is_empty()
        );
        assert!(headless::usb_next(&mobile.phone).await.unwrap().is_none());
    }
    for names in [
        vec!["0000000000000000.block", "0000000000000000.block"],
        vec!["0000000000000001.block", "0000000000000000.block"],
        vec!["../0000000000000.block"],
    ] {
        let mobile = Mobile::new();
        let open = action(&mobile.phone).await;
        headless::usb_complete(&mobile.phone, UsbReply::empty(&open)).unwrap();
        let list = action(&mobile.phone).await;
        let mut reply = UsbReply::empty(&list);
        reply.names = names.into_iter().map(str::to_owned).collect();
        if reply.names.iter().any(|n| n.len() != 22) {
            assert_eq!(
                headless::usb_complete(&mobile.phone, reply),
                Err(super::read_model::ReadError::InvalidInput)
            );
            headless::cancel_signal(&mobile.phone).unwrap();
        } else {
            headless::usb_complete(&mobile.phone, reply).unwrap();
            assert_eq!(
                headless::usb_closed(&mobile.phone).await.unwrap().error,
                Some(super::read_model::ReadError::InvalidInput)
            );
        }
    }
}

#[tokio::test]
async fn usb_reordered_tampered_and_oversized_os_blocks_never_receive_directory_ack() {
    let _serial = SERIAL.lock().await;
    for sequence in [0_u64, 1] {
        let mobile = Mobile::new();
        let open = action(&mobile.phone).await;
        headless::usb_complete(&mobile.phone, UsbReply::empty(&open)).unwrap();
        let list = action(&mobile.phone).await;
        let mut reply = UsbReply::empty(&list);
        reply.names = vec!["0000000000000000.block".into()];
        headless::usb_complete(&mobile.phone, reply).unwrap();
        let read = action(&mobile.phone).await;
        assert_eq!(read.kind, UsbActionKind::Read);
        let mut reply = UsbReply::empty(&read);
        reply.bytes.extend_from_slice(&sequence.to_be_bytes());
        reply
            .bytes
            .extend_from_slice(&(if sequence == 0 { 2_u32 } else { 1 }).to_be_bytes());
        reply.bytes.push(1); // Invalid declared size, or an out-of-order sequence.
        headless::usb_complete(&mobile.phone, reply).unwrap();
        assert!(headless::usb_closed(&mobile.phone)
            .await
            .unwrap()
            .error
            .is_some());
        assert!(headless::usb_next(&mobile.phone).await.unwrap().is_none());
    }
    let mobile = Mobile::new();
    let open = action(&mobile.phone).await;
    let mut reply = UsbReply::empty(&open);
    reply.bytes = vec![0; 65549];
    assert_eq!(
        headless::usb_complete(&mobile.phone, reply),
        Err(super::read_model::ReadError::InvalidInput)
    );
    headless::cancel_signal(&mobile.phone).unwrap();
}

#[tokio::test]
async fn usb_unknown_write_result_is_terminal_and_never_retries_or_accepts_late_success() {
    let _serial = SERIAL.lock().await;
    for error in [
        super::read_model::ReadError::Timeout,
        super::read_model::ReadError::Disconnected,
    ] {
        let mobile = Mobile::new();
        let open = action(&mobile.phone).await;
        headless::usb_complete(&mobile.phone, UsbReply::empty(&open)).unwrap();
        for _ in 0..2 {
            let list = action(&mobile.phone).await;
            assert_eq!(list.kind, UsbActionKind::List);
            headless::usb_complete(&mobile.phone, UsbReply::empty(&list)).unwrap();
        }
        let write = action(&mobile.phone).await;
        assert_eq!(write.kind, UsbActionKind::Write);
        assert!(!write.bytes.is_empty());
        let mut failed = UsbReply::empty(&write);
        failed.error = Some(error);
        headless::usb_complete(&mobile.phone, failed).unwrap();
        let closed = headless::usb_closed(&mobile.phone).await.unwrap();
        assert_eq!(closed.reason, Some(UsbCloseReason::Failure));
        assert_eq!(closed.error, Some(error));
        assert!(headless::usb_next(&mobile.phone).await.unwrap().is_none());
        assert!(headless::usb_complete(&mobile.phone, UsbReply::empty(&write)).is_err());
    }
}

#[tokio::test]
async fn usb_native_blocked_pipe_never_holds_driver_or_delays_cancel_and_library_close() {
    let _serial = SERIAL.lock().await;
    let fixture = pipe_fixture("device_sync_blocked_worker.rs");
    let root = tempfile::tempdir().unwrap();
    let library = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    let host = headless::host_usb_fixture(&library.handle, fixture).unwrap();
    headless::command(&host.handle, |_| Ok(())).await.unwrap();
    tokio::time::sleep(Duration::from_millis(25)).await;
    let command = tokio::time::timeout(
        Duration::from_secs(1),
        headless::command(&host.handle, |_| Ok(())),
    )
    .await;
    assert!(matches!(
        headless::usb_next(&host.handle).await,
        Err(super::read_model::ReadError::PermissionDenied)
    ));
    let started = std::time::Instant::now();
    headless::close_library_async(&library.handle)
        .await
        .unwrap();
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(headless::status(&host.handle).is_err());
    command
        .expect("native waiting must not stall the original command owner")
        .unwrap();
}

#[tokio::test]
async fn usb_native_owner_rejects_ambiguous_local_device_ids_from_real_child() {
    let _serial = SERIAL.lock().await;
    let fixture = pipe_fixture("device_sync_owner_worker.rs");
    let root = tempfile::tempdir().unwrap();
    let library = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    let host = headless::host_usb_fixture(&library.handle, fixture).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !headless::usb_view(&host.handle).unwrap().closed && std::time::Instant::now() < deadline
    {
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let result = headless::usb_view(&host.handle).unwrap();
    headless::close_endpoint_async(&host.handle).await.unwrap();
    headless::close_library_async(&library.handle)
        .await
        .unwrap();
    assert!(
        result.closed,
        "ambiguous local IDs must end the same native owner, not wait for selection"
    );
    assert_eq!(
        result.error,
        Some(super::read_model::ReadError::InvalidInput)
    );
}

#[tokio::test]
async fn usb_same_endpoint_moves_real_tls_over_129_blocks_and_acks_final_commit_before_close() {
    real_tls_over_native_window(false).await;
}

#[tokio::test]
async fn usb_phone_control_moves_real_tls_over_129_blocks_and_acks_final_commit_before_close() {
    real_tls_over_native_window(true).await;
}

async fn real_tls_over_native_window(phone_controlled: bool) {
    let _serial = SERIAL.lock().await;
    let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
    let libraries = roots.each_ref().map(|root| {
        headless::open(root.path().to_string_lossy().into_owned())
            .unwrap()
            .handle
    });
    let api = headless::owner_test_tools::runtime_api(&libraries[0]);
    let input = roots[0].path().join("stream.jpg");
    let bytes = vec![0x53; 9 * 1024 * 1024 + 1];
    std::fs::write(&input, &bytes).unwrap();
    api.import_local_files(vec![input.to_string_lossy().into_owned()])
        .await
        .unwrap();
    let host = if phone_controlled {
        headless::owner_test_tools::phone_usb_actions(&libraries[0], "Desktop")
    } else {
        headless::host_usb_test(&libraries[0], "Desktop").unwrap()
    };
    let phone = headless::client_usb(&libraries[1], &host.invitation, "Phone").unwrap();
    let endpoints = [host.handle, phone];
    let mut boxes = [BTreeMap::<String, Vec<u8>>::new(), BTreeMap::new()];
    let mut writes = [0, 0];
    let mut full = [0, 0];
    let mut held: [Option<(UsbAction, UsbReply, std::time::Instant)>; 2] = [None, None];
    let mut confirmed = false;
    let mut configured = false;
    let mut approved = false;
    let mut closed = [false, false];
    let deadline = std::time::Instant::now() + Duration::from_secs(45);
    while !closed.iter().all(|v| *v) {
        assert!(
            std::time::Instant::now() < deadline,
            "{:?} {:?}",
            headless::status(&endpoints[0]),
            headless::status(&endpoints[1])
        );
        for index in 0..2 {
            if closed[index] {
                continue;
            }
            if held[index]
                .as_ref()
                .is_some_and(|(_, _, until)| std::time::Instant::now() >= *until)
            {
                let (action, reply, _) = held[index].take().unwrap();
                boxes[1 - index]
                    .remove(action.name.as_ref().unwrap())
                    .unwrap();
                headless::usb_complete(&endpoints[index], reply).unwrap_or_else(|error| panic!(
                    "held ACK failed side={index} error={error:?} closed={closed:?} writes={writes:?} boxes={:?} USB={:?} {:?}",
                    boxes.each_ref().map(|b|b.len()), headless::usb_view(&endpoints[0]), headless::usb_view(&endpoints[1])
                ));
            }
            if held[index].is_some() {
                continue;
            }
            if let Ok(Ok(Some(action))) = tokio::time::timeout(
                Duration::from_millis(1),
                headless::usb_next(&endpoints[index]),
            )
            .await
            {
                let peer = 1 - index;
                let mut reply = UsbReply::empty(&action);
                match action.kind {
                    UsbActionKind::Open => {}
                    UsbActionKind::List => {
                        let box_index = match action.direction {
                            super::native_io::Direction::Desktop => 0,
                            super::native_io::Direction::Mobile => 1,
                        };
                        reply.names = boxes[box_index].keys().cloned().collect();
                    }
                    UsbActionKind::Read => {
                        reply.bytes = boxes[peer][action.name.as_ref().unwrap()].clone()
                    }
                    UsbActionKind::Acknowledge => {
                        // Delay real deletion, not a falsely successful receipt.
                        let delay = if (writes[0] + writes[1]) % 2 == index {
                            3
                        } else {
                            25
                        };
                        held[index] = Some((
                            action.clone(),
                            reply,
                            std::time::Instant::now() + Duration::from_millis(delay),
                        ));
                        continue;
                    }
                    UsbActionKind::Write => {
                        // A real, deliberately small OS window produces backpressure
                        // while both owners keep reading and acknowledging.
                        if !boxes[index].is_empty() {
                            reply.error = Some(super::read_model::ReadError::WindowFull);
                            full[index] += 1;
                        } else {
                            boxes[index].insert(action.name.clone().unwrap(), action.bytes.clone());
                            writes[index] += 1;
                        }
                    }
                    UsbActionKind::Close => {
                        assert!(
                            boxes.iter().all(|b| b.is_empty()),
                            "final directory ACK must precede successful close"
                        );
                        closed[index] = true;
                    }
                    UsbActionKind::Enumerate => unreachable!(),
                }
                headless::usb_complete(&endpoints[index], reply.clone()).unwrap();
                assert!(
                    headless::usb_complete(&endpoints[index], reply).is_err(),
                    "one token cannot complete twice"
                );
            }
        }
        if !confirmed
            && endpoints.iter().all(|e| {
                headless::read_endpoint(e)
                    .value
                    .is_some_and(|v| v.pairing == PairingStage::AwaitingConfirmation)
            })
        {
            for e in endpoints.iter().skip(usize::from(phone_controlled)) {
                headless::command(e, |d| d.confirm_pairing()).await.unwrap();
            }
            confirmed = true;
        }
        if confirmed
            && !configured
            && headless::status(&endpoints[0]).unwrap().state == "Configuring"
        {
            headless::command(&endpoints[usize::from(phone_controlled)], |d| {
                d.configure(
                    super::driver::Direction::DesktopToPhone,
                    super::planner::SyncMode::Merge,
                    false,
                )
            })
            .await
            .unwrap();
            configured = true;
        }
        if !approved && headless::status(&endpoints[1]).unwrap().state == "AwaitingApproval" {
            assert!(headless::owner_test_tools::runtime_api(&libraries[1])
                .list_media(Default::default())
                .unwrap()
                .is_empty());
            headless::command(&endpoints[1], move |d| {
                if phone_controlled {
                    let binding = d.preview_binding().unwrap().to_owned();
                    d.approve_controlled_preview(&binding)
                } else {
                    d.approve_preview()
                }
            })
            .await
            .unwrap();
            approved = true;
        }
        if held.iter().any(Option::is_some) {
            tokio::time::sleep(Duration::from_millis(1)).await;
        } else {
            tokio::task::yield_now().await;
        }
    }
    assert!(
        writes[0] >= 129,
        "real TLS stream must cross the fixed native window size"
    );
    println!("USB synthetic writes={writes:?} WindowFull={full:?}");
    assert!(
        full.iter().all(|count| *count > 0),
        "both owners must preserve inbound liveness while their own OS window is full"
    );
    let media = headless::owner_test_tools::runtime_api(&libraries[1])
        .list_media(Default::default())
        .unwrap();
    assert_eq!(std::fs::read(&media[0].storage_path).unwrap(), bytes);
    if phone_controlled {
        // These are real one-shot handoff facts, never set by the test.
        assert!(headless::status(&endpoints[0]).unwrap().source_grant_issued);
        assert!(
            headless::status(&endpoints[1])
                .unwrap()
                .local_apply_installed
        );
    }
    for endpoint in &endpoints {
        assert_eq!(
            headless::usb_closed(endpoint).await.unwrap().reason,
            Some(UsbCloseReason::Success)
        );
        assert_eq!(headless::status(endpoint).unwrap().state, "Completed");
        headless::close_endpoint_async(endpoint).await.unwrap();
    }
    for library in &libraries {
        headless::close_library_async(library).await.unwrap();
    }
}

/// Explicit opt-in child for a normal fresh-DLL FRB consumer. Never a product
/// backend: no environment means a refused, ignored test, not native success.
#[tokio::test]
#[ignore = "Controlled FRB child; requires a new synthetic TEMP root and bounded stdin grants"]
async fn usb_frb_peer() {
    use std::io::{Read, Write};
    let selected = std::env::var_os("NSOALBUM_DEVICE_SYNC_USB_PEER_ROOT")
        .expect("explicit synthetic root required");
    let root = std::path::PathBuf::from(selected);
    assert!(root.is_absolute());
    assert!(root
        .file_name()
        .unwrap()
        .to_string_lossy()
        .starts_with("nsoalbum-5a3-peer-"));
    assert_eq!(
        root.parent().unwrap().canonicalize().unwrap(),
        std::env::temp_dir().canonicalize().unwrap()
    );
    assert_eq!(std::fs::read_dir(&root).unwrap().count(), 0);
    let source = root.join("source");
    let exchange = root.join("exchange");
    std::fs::create_dir(&source).unwrap();
    std::fs::create_dir(&exchange).unwrap();
    let library = headless::open(source.to_string_lossy().into_owned()).unwrap();
    let api = headless::owner_test_tools::runtime_api(&library.handle);
    let input = source.join("synthetic.jpg");
    std::fs::write(&input, vec![0x53; 256 * 1024 + 13]).unwrap();
    api.import_local_files(vec![input.to_string_lossy().into_owned()])
        .await
        .unwrap();
    let host = headless::host_usb_test(&library.handle, "Synthetic desktop").unwrap();
    let (commands, incoming) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut input = std::io::stdin().lock();
        for _ in 0..16 {
            let mut line = Vec::new();
            loop {
                let mut byte = [0];
                if input.read_exact(&mut byte).is_err() {
                    return;
                }
                if byte[0] == b'\n' {
                    break;
                }
                if line.len() >= 64 {
                    return;
                }
                line.push(byte[0]);
            }
            let Ok(command) = String::from_utf8(line) else {
                return;
            };
            if commands.send(command).is_err() {
                return;
            }
        }
    });
    fn event(kind: &str, value: serde_json::Value) {
        println!(
            "NSOALBUM_USB_PEER {}",
            serde_json::json!({"kind":kind,"value":value})
        );
        std::io::stdout().flush().unwrap();
    }
    event("invitation", host.invitation.into());
    let deadline = std::time::Instant::now() + Duration::from_secs(90);
    let fail_final_ack = std::env::var("NSOALBUM_DEVICE_SYNC_USB_PEER_FAIL_FINAL_ACK")
        .ok()
        .as_deref()
        == Some("1");
    let mut final_grant = false;
    let mut final_sent = false;
    let mut confirm_grant = false;
    let mut confirmed = false;
    let mut configure_grant = None;
    let mut configured = false;
    let mut source_protected = false;
    let mut final_ack_failed = false;
    let mut writes = 0;
    loop {
        assert!(
            std::time::Instant::now() < deadline,
            "controlled child deadline"
        );
        if let Ok(command) = incoming.try_recv() {
            match command.as_str() {
                "confirm" => {
                    assert!(!confirm_grant && !confirmed);
                    confirm_grant = true;
                }
                "configure_accounts" | "configure_library" => {
                    assert!(configure_grant.is_none() && !configured);
                    configure_grant = Some(command == "configure_accounts");
                }
                "source_final" => final_grant = true,
                "cancel" => {
                    headless::cancel_signal(&host.handle).unwrap();
                    break;
                }
                _ => panic!("invalid bounded child grant"),
            }
        }
        if confirm_grant
            && !confirmed
            && headless::read_endpoint(&host.handle)
                .value
                .is_some_and(|v| v.confirmation_available)
        {
            headless::command(&host.handle, |d| d.confirm_pairing())
                .await
                .unwrap();
            confirmed = true;
        }
        if let Some(accounts) = configure_grant {
            if headless::status(&host.handle).unwrap().state == "Configuring" {
                headless::command(&host.handle, move |d| {
                    if accounts {
                        d.authorize_accounts_export(br#"{"version":1,"accounts":[{"account_id":"new","nickname":"New","session_token":"synthetic-new"}]}"#, &"a".repeat(64))?;
                    }
                    d.configure(super::driver::Direction::DesktopToPhone, if accounts { super::planner::SyncMode::Overwrite } else { super::planner::SyncMode::Merge }, accounts)
                }).await.unwrap();
                configure_grant = None;
                configured = true;
            }
        }
        if final_grant
            && !final_sent
            && headless::status(&host.handle).unwrap().state == "AwaitingAccountFinal"
        {
            headless::command(&host.handle, |d| d.approve_accounts_final(&"a".repeat(64)))
                .await
                .unwrap();
            assert!(matches!(
                api.create_tag("must-remain-locked".into()),
                Err(crate::error::CoreError::LibraryBusy)
            ));
            source_protected = true;
            final_sent = true;
        }
        if headless::usb_view(&host.handle).unwrap().closed {
            break;
        }
        if let Ok(Ok(Some(action))) =
            tokio::time::timeout(Duration::from_millis(2), headless::usb_next(&host.handle)).await
        {
            let base = exchange.join(format!("s-{}", action.session));
            let directory = base.join(match action.direction {
                super::native_io::Direction::Desktop => "desktop",
                super::native_io::Direction::Mobile => "mobile",
            });
            let mut reply = UsbReply::empty(&action);
            match action.kind {
                UsbActionKind::Open => {
                    std::fs::create_dir_all(base.join("desktop")).unwrap();
                    std::fs::create_dir_all(base.join("mobile")).unwrap();
                }
                UsbActionKind::List => {
                    reply.names = std::fs::read_dir(&directory)
                        .unwrap()
                        .map(|e| e.unwrap().file_name().into_string().unwrap())
                        .filter(|n| !n.ends_with(".part"))
                        .collect();
                    reply.names.sort();
                    assert!(reply.names.len() <= 128);
                }
                UsbActionKind::Read => {
                    reply.bytes =
                        std::fs::read(directory.join(action.name.as_ref().unwrap())).unwrap();
                    assert!(reply.bytes.len() <= 65548);
                }
                UsbActionKind::Write => {
                    let target = directory.join(action.name.as_ref().unwrap());
                    assert!(!target.exists());
                    let partial = target.with_extension("block.part");
                    std::fs::write(&partial, &action.bytes).unwrap();
                    std::fs::rename(partial, target).unwrap();
                    writes += 1;
                }
                UsbActionKind::Acknowledge => {
                    if fail_final_ack {
                        // Process accepted TLS on the same owner before testing
                        // the final CommitAck directory acknowledgement boundary.
                        let _ = headless::command(&host.handle, |d| d.poll()).await;
                    }
                    if fail_final_ack
                        && headless::status(&host.handle).unwrap().state == "Completed"
                    {
                        reply.error = Some(super::read_model::ReadError::PermissionDenied);
                        final_ack_failed = true;
                    } else {
                        std::fs::remove_file(directory.join(action.name.as_ref().unwrap()))
                            .unwrap();
                    }
                }
                UsbActionKind::Close => {}
                UsbActionKind::Enumerate => unreachable!(),
            }
            headless::usb_complete(&host.handle, reply).unwrap();
        }
    }
    let state = headless::status(&host.handle).unwrap().state;
    headless::shutdown_async(&host.handle).await.unwrap();
    let until = std::time::Instant::now() + Duration::from_secs(32);
    while headless::status(&host.handle).unwrap().cleanup_pending {
        assert!(std::time::Instant::now() < until);
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    headless::close_endpoint_async(&host.handle).await.unwrap();
    headless::close_library_async(&library.handle)
        .await
        .unwrap();
    event(
        "done",
        serde_json::json!({"state":state,"writes":writes,"source_protected":source_protected,"final_ack_failed":final_ack_failed}),
    );
}
