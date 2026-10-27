//! Real production owner/command regressions, with isolated synthetic libraries.
use super::*;
use crate::device_sync::read_model::PairingStage;
use crate::device_sync::runtime::TcpPhase;
use std::time::{Duration, Instant};

struct Pair {
    _roots: [tempfile::TempDir; 2],
    libraries: [String; 2],
    endpoints: [String; 2],
    io: Option<tokio::task::JoinHandle<()>>,
    fault: Arc<std::sync::atomic::AtomicU8>,
    native_root: Option<tempfile::TempDir>,
    target: usize,
}

#[tokio::test]
async fn benchmark_managed_tcp_and_usb_finish_only_after_real_owner_cleanup() {
    let _serial = owner_test_tools::SERIAL.lock().await;
    for usb in [false, true] {
        let pair = if usb { Pair::usb() } else { Pair::tcp() };
        let source = owner_test_tools::runtime_api(&pair.libraries[0]);
        let target = owner_test_tools::runtime_api(&pair.libraries[1]);
        source
            .create_album("Synthetic shared".into(), String::new(), false)
            .unwrap();
        let mut first = super::super::receiver::ReceiveOperation::prepare(
            target.database(),
            super::super::receiver::Snapshot::read(&source.database(), "Desktop").unwrap(),
            "Phone",
            SyncMode::Merge,
        )
        .unwrap();
        let mut authorization = first.authorize().unwrap();
        first
            .apply(
                Some(&mut authorization),
                None,
                &CancellationToken::default(),
                &mut |_| {},
            )
            .unwrap();
        pair.wait(|| {
            read_endpoint(&pair.endpoints[1])
                .value
                .is_some_and(|view| view.pairing == PairingStage::AwaitingConfirmation)
        })
        .await;
        command(&pair.endpoints[1], |driver| driver.confirm_pairing())
            .await
            .unwrap();
        pair.wait(|| {
            pair.endpoints
                .iter()
                .all(|endpoint| status(endpoint).unwrap().state == "Configuring")
        })
        .await;
        command(&pair.endpoints[1], |driver| {
            driver.configure(Direction::DesktopToPhone, SyncMode::Merge, false)
        })
        .await
        .unwrap();
        pair.wait(|| {
            pair.endpoints
                .iter()
                .all(|endpoint| status(endpoint).unwrap().state == "AwaitingApproval")
        })
        .await;
        let generation = target.database().device_sync_header().unwrap().generation;
        for endpoint in &pair.endpoints {
            let binding = status(endpoint).unwrap().binding.unwrap();
            assert!(
                crate::bridge::device_sync_benchmark_require_noop(endpoint.clone(), binding)
                    .await
                    .unwrap()
            );
            pair.wait(|| {
                matches!(
                    crate::bridge::device_sync_benchmark_metrics(endpoint.clone()),
                    Ok(None)
                )
            })
            .await;
        }
        let binding = status(&pair.endpoints[1]).unwrap().binding.unwrap();
        command(&pair.endpoints[1], move |driver| {
            driver.approve_controlled_preview(&binding)
        })
        .await
        .unwrap();
        pair.wait(|| {
            pair.endpoints
                .iter()
                .all(|endpoint| benchmark_metrics(endpoint).ok().flatten().is_some())
        })
        .await;
        assert_eq!(
            target.database().device_sync_header().unwrap().generation,
            generation
        );
        let source_result = read_benchmark(&pair, &pair.endpoints[0]).await;
        let target_result = read_benchmark(&pair, &pair.endpoints[1]).await;
        assert!(source_result.contains("benchmark_noop_armed=1"));
        assert!(target_result.contains("strict_noop_applied=1"));
        assert!(target_result.contains("media_bytes=0"));
        if usb {
            for endpoint in &pair.endpoints {
                let view = usb_view(endpoint).unwrap();
                assert!(view.closed);
                assert_eq!(
                    view.reason,
                    Some(super::super::usb::UsbCloseReason::Success)
                );
            }
        }
    }
}

async fn read_benchmark(pair: &Pair, endpoint: &str) -> String {
    let until = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(Some(record)) = benchmark_metrics(endpoint) {
            return record;
        }
        assert!(
            Instant::now() < until,
            "benchmark read deadline: {:?}",
            status(&pair.endpoints[1])
        );
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
}

#[tokio::test]
async fn runtime_local_transport_only_signal_preserves_real_external_journal() {
    let _serial = owner_test_tools::SERIAL.lock().await;
    let pair = Pair::usb();
    let (external, operation) = pair.account_pending().await;
    detach_transport_signal(&pair.endpoints[1]).unwrap();
    pair.wait(|| usb_view(&pair.endpoints[1]).unwrap().closed)
        .await;
    local_command(&pair.endpoints[1], |driver| driver.check_external_commit())
        .await
        .unwrap();
    local_command(&pair.endpoints[1], |driver| driver.external_step())
        .await
        .unwrap();
    local_command(&pair.endpoints[1], move |driver| {
        driver.finalize_accounts(external)
    })
    .await
    .unwrap();
    assert_eq!(
        journal(&pair.libraries[1], &operation)
            .unwrap()
            .unwrap()
            .stage,
        "finalized"
    );
    pair.wait(|| status(&pair.endpoints[1]).unwrap().state == "Completed")
        .await;
    assert_eq!(status(&pair.endpoints[1]).unwrap().state, "Completed");
}

#[tokio::test]
async fn runtime_local_transport_only_signal_before_grant_still_rejects_authorization() {
    let _serial = owner_test_tools::SERIAL.lock().await;
    let pair = Pair::usb();
    detach_transport_signal(&pair.endpoints[1]).unwrap();
    pair.wait(|| usb_view(&pair.endpoints[1]).unwrap().closed)
        .await;
    let status = status(&pair.endpoints[1]).unwrap();
    assert!(status.terminal && !status.local_apply_installed);
    assert!(status.transport_detached);
    assert!(owner_test_tools::runtime_api(&pair.libraries[1])
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
    assert!(
        command(&pair.endpoints[1], |driver| driver.confirm_pairing())
            .await
            .is_err()
    );
    assert!(detach_transport_signal("invalid-handle").is_err());
    close_endpoint_async(&pair.endpoints[1]).await.unwrap();
    assert!(detach_transport_signal(&pair.endpoints[1]).is_err());
}
impl Pair {
    fn tcp() -> Self {
        let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let libraries = roots.each_ref().map(|root| {
            open(root.path().to_string_lossy().into_owned())
                .unwrap()
                .handle
        });
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let host = host_bound_with_network(
            &libraries[0],
            "Desktop",
            listener,
            None,
            Some(super::super::connection::ApplicationBuild {
                version: "0.2.14".into(),
                build_number: "47".into(),
            }),
        )
        .unwrap();
        let phone = client_tcp_test(&libraries[1], &host.invitation, "Phone").unwrap();
        Self {
            _roots: roots,
            libraries,
            endpoints: [host.handle, phone],
            io: None,
            fault: Arc::new(std::sync::atomic::AtomicU8::new(0)),
            native_root: None,
            target: 1,
        }
    }
    fn usb() -> Self {
        use super::super::native_io::Direction as IoDirection;
        use super::super::usb::{UsbActionKind, UsbReply};
        use std::collections::BTreeMap;
        use std::sync::atomic::Ordering;
        let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let libraries = roots.each_ref().map(|root| {
            open(root.path().to_string_lossy().into_owned())
                .unwrap()
                .handle
        });
        let host = host_started_with_build(
            &libraries[0],
            "Desktop",
            None,
            Some(super::super::runtime::Start::Usb(
                super::super::usb::Start::DesktopActions,
            )),
            Some(super::super::connection::ApplicationBuild {
                version: "0.2.14".into(),
                build_number: "47".into(),
            }),
        )
        .unwrap();
        let phone = client_usb(&libraries[1], &host.invitation, "Phone").unwrap();
        let endpoints = [host.handle, phone];
        let io_endpoints = endpoints.clone();
        let fault = Arc::new(std::sync::atomic::AtomicU8::new(0));
        let io_fault = fault.clone();
        let io = tokio::spawn(async move {
            let mut boxes = [BTreeMap::<String, Vec<u8>>::new(), BTreeMap::new()];
            let mut next_sequence = [0_u64; 2];
            loop {
                for (index, io_endpoint) in io_endpoints.iter().enumerate() {
                    if usb_view(io_endpoint).unwrap().closed {
                        continue;
                    }
                    let Ok(Ok(Some(action))) =
                        tokio::time::timeout(Duration::from_millis(2), usb_next(io_endpoint)).await
                    else {
                        continue;
                    };
                    if index == 1 && io_fault.load(Ordering::SeqCst) == 3 {
                        // Leave one real delivered OS capability unresolved.
                        io_fault.store(4, Ordering::SeqCst);
                        continue;
                    }
                    let direction = usize::from(action.direction == IoDirection::Mobile);
                    let mut reply = UsbReply::empty(&action);
                    if index == 1 && io_fault.load(Ordering::SeqCst) == 1 {
                        io_fault.store(0, Ordering::SeqCst);
                        reply.error = Some(ReadError::PermissionDenied);
                    } else {
                        match action.kind {
                            UsbActionKind::Open | UsbActionKind::Close => {}
                            UsbActionKind::List => {
                                if index == 1
                                    && direction == 0
                                    && io_fault.load(Ordering::SeqCst) == 2
                                {
                                    io_fault.store(0, Ordering::SeqCst);
                                    boxes[0].insert(
                                        format!("{:016x}.block", next_sequence[0]),
                                        vec![0],
                                    );
                                }
                                reply.names = boxes[direction].keys().cloned().collect();
                            }
                            UsbActionKind::Read => {
                                reply.bytes =
                                    boxes[direction][action.name.as_ref().unwrap()].clone()
                            }
                            UsbActionKind::Write => {
                                let name = action.name.clone().unwrap();
                                next_sequence[direction] =
                                    u64::from_str_radix(&name[..16], 16).unwrap() + 1;
                                assert!(boxes[direction]
                                    .insert(name, action.bytes.clone())
                                    .is_none());
                            }
                            UsbActionKind::Acknowledge => {
                                let through = action.name.as_ref().unwrap();
                                assert!(boxes[direction].contains_key(through));
                                boxes[direction].retain(|name, _| name > through);
                            }
                            UsbActionKind::Enumerate => unreachable!(),
                        }
                    }
                    // A local cancellation can invalidate an in-flight OS action.
                    let _ = usb_complete(io_endpoint, reply);
                }
                tokio::task::yield_now().await;
            }
        });
        Self {
            _roots: roots,
            libraries,
            endpoints,
            io: Some(io),
            fault,
            native_root: None,
            target: 1,
        }
    }
    fn native() -> Self {
        use super::super::native_io::Direction as IoDirection;
        use super::super::usb::{UsbActionKind, UsbReply};
        let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let libraries = roots.each_ref().map(|root| {
            open(root.path().to_string_lossy().into_owned())
                .unwrap()
                .handle
        });
        let native_root = tempfile::tempdir().unwrap();
        let executable = native_root.path().join(if cfg!(windows) {
            "local-mailbox.exe"
        } else {
            "local-mailbox"
        });
        assert!(std::process::Command::new("rustc")
            .arg(
                std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("tests/fixtures/device_sync_local_mailbox_worker.rs")
            )
            .arg("-o")
            .arg(&executable)
            .status()
            .unwrap()
            .success());
        let host = host_started_with_build(
            &libraries[0],
            "Desktop",
            None,
            Some(super::super::runtime::Start::Usb(
                super::super::usb::Start::NativeFixture(executable),
            )),
            Some(super::super::connection::ApplicationBuild {
                version: "0.2.14".into(),
                build_number: "47".into(),
            }),
        )
        .unwrap();
        let phone = client_usb(&libraries[1], &host.invitation, "Phone").unwrap();
        let endpoints = [host.handle, phone];
        let io_endpoint = endpoints[1].clone();
        let io_root = native_root.path().join("exchange");
        let io = tokio::spawn(async move {
            loop {
                let Ok(Ok(Some(action))) =
                    tokio::time::timeout(Duration::from_millis(2), usb_next(&io_endpoint)).await
                else {
                    tokio::task::yield_now().await;
                    continue;
                };
                let base = io_root.join(format!("s-{}", action.session));
                let directory = base.join(if action.direction == IoDirection::Mobile {
                    "mobile"
                } else {
                    "desktop"
                });
                let mut reply = UsbReply::empty(&action);
                match action.kind {
                    UsbActionKind::Open => {
                        for direction in ["desktop", "mobile"] {
                            std::fs::create_dir_all(base.join(direction)).unwrap();
                        }
                    }
                    UsbActionKind::List => {
                        reply.names = std::fs::read_dir(directory)
                            .unwrap()
                            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
                            .filter(|name| name.ends_with(".block"))
                            .collect();
                        reply.names.sort();
                    }
                    UsbActionKind::Read => {
                        reply.bytes =
                            std::fs::read(directory.join(action.name.as_ref().unwrap())).unwrap()
                    }
                    UsbActionKind::Write => {
                        let path = directory.join(action.name.as_ref().unwrap());
                        let part = path.with_extension("part");
                        std::fs::write(&part, &action.bytes).unwrap();
                        std::fs::rename(part, path).unwrap();
                    }
                    UsbActionKind::Acknowledge => {
                        let through = action.name.as_ref().unwrap();
                        let names: Vec<_> = std::fs::read_dir(&directory)
                            .unwrap()
                            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
                            .filter(|name| name.ends_with(".block") && name <= through)
                            .collect();
                        assert!(names.len() <= 8);
                        for name in names {
                            std::fs::remove_file(directory.join(name)).unwrap();
                        }
                    }
                    UsbActionKind::Close => {}
                    UsbActionKind::Enumerate => unreachable!(),
                }
                let _ = usb_complete(&io_endpoint, reply);
            }
        });
        Self {
            _roots: roots,
            libraries,
            endpoints,
            io: Some(io),
            fault: Arc::new(std::sync::atomic::AtomicU8::new(0)),
            native_root: Some(native_root),
            target: 0,
        }
    }
    #[track_caller]
    fn wait<'a>(
        &'a self,
        predicate: impl Fn() -> bool + 'a,
    ) -> impl std::future::Future<Output = ()> + 'a {
        let caller = std::panic::Location::caller();
        async move {
            let until = Instant::now() + Duration::from_secs(10);
            while !predicate() {
                assert!(
                    Instant::now() < until,
                    "owner deadline at {caller}: {:?}, {:?}",
                    status(&self.endpoints[0]),
                    status(&self.endpoints[1])
                );
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        }
    }
    async fn approve_accounts(&self) -> Uuid {
        let source = &self.endpoints[1 - self.target];
        let target = &self.endpoints[self.target];
        if self.native_root.is_some() {
            self.wait(|| !usb_view(&self.endpoints[0]).unwrap().devices.is_empty())
                .await;
            usb_select(&self.endpoints[0], "synthetic", "storage").unwrap();
        }
        self.wait(|| {
            read_endpoint(&self.endpoints[1])
                .value
                .is_some_and(|view| view.pairing == PairingStage::AwaitingConfirmation)
        })
        .await;
        command(&self.endpoints[1], |driver| driver.confirm_pairing())
            .await
            .unwrap();
        self.wait(|| {
            status(&self.endpoints[0]).unwrap().state == "Configuring"
                && status(&self.endpoints[1]).unwrap().state == "Configuring"
        })
        .await;
        let direction = if self.target == 0 {
            Direction::PhoneToDesktop
        } else {
            Direction::DesktopToPhone
        };
        command(&self.endpoints[1], move |driver| {
            driver.configure(direction, SyncMode::Merge, true)
        })
        .await
        .unwrap();
        self.wait(|| status(&self.endpoints[1]).unwrap().state == "AwaitingAccountConsent")
            .await;
        command(&self.endpoints[1], |driver| driver.consent_controlled(true))
            .await
            .unwrap();
        self.wait(|| {
            read_endpoint(&self.endpoints[0])
                .value
                .is_some_and(|view| view.accounts_consent_authorized)
        })
        .await;
        command(source, |driver| {
            driver.authorize_accounts_export(
                br#"{"version":1,"accounts":[{"account_id":"synthetic","nickname":"Synthetic","session_token":"synthetic-only"}]}"#,
                &"a".repeat(64),
            )
        }).await.unwrap();
        command(target, |driver| {
            driver.authorize_accounts_receive(&"b".repeat(64))
        })
        .await
        .unwrap();
        self.wait(|| {
            self.endpoints
                .iter()
                .all(|handle| status(handle).unwrap().state == "AwaitingApproval")
        })
        .await;
        let binding = status(target).unwrap().binding.unwrap();
        let preview_binding = binding.clone();
        command(target, move |driver| {
            driver.publish_account_preview(
                &preview_binding,
                ChangeCounts {
                    added: 1,
                    ..Default::default()
                },
            )
        })
        .await
        .unwrap();
        self.wait(|| {
            read_preview(&self.endpoints[1])
                .value
                .is_some_and(|preview| preview.accounts.is_some())
        })
        .await;
        let approved_binding = binding.clone();
        command(&self.endpoints[1], move |driver| {
            driver.approve_controlled_preview(&approved_binding)
        })
        .await
        .unwrap();
        self.wait(|| {
            read_endpoint(target)
                .value
                .is_some_and(|view| view.preview_approved)
        })
        .await;
        let external = Uuid::new_v4();
        command(target, move |driver| {
            driver.approve_accounts_preview(&binding, &"b".repeat(64), external)
        })
        .await
        .unwrap();
        self.wait(|| status(target).unwrap().state == "AwaitingTargetAccountFinal")
            .await;
        command(target, |driver| {
            driver.approve_accounts_target_final(&"b".repeat(64))
        })
        .await
        .unwrap();
        self.wait(|| status(source).unwrap().state == "AwaitingAccountFinal")
            .await;
        command(source, |driver| {
            driver.approve_accounts_final(&"a".repeat(64))
        })
        .await
        .unwrap();
        external
    }
    async fn account_pending(&self) -> (Uuid, String) {
        let external = self.approve_accounts().await;
        self.wait(|| status(&self.endpoints[self.target]).unwrap().state == "AwaitingExternal")
            .await;
        (
            external,
            status(&self.endpoints[self.target])
                .unwrap()
                .operation
                .unwrap(),
        )
    }
}

#[tokio::test]
async fn runtime_local_saf_receipt_error_keeps_actual_external_finalization() {
    usb_failure_keeps_local_commands(1).await;
}

#[tokio::test]
async fn runtime_local_mailbox_decode_error_keeps_actual_external_finalization() {
    usb_failure_keeps_local_commands(2).await;
}

#[tokio::test]
async fn runtime_local_usb_detach_stops_waiting_on_inflight_os_without_cancelling_apply() {
    let _serial = owner_test_tools::SERIAL.lock().await;
    let pair = Pair::usb();
    let (external, operation) = pair.account_pending().await;
    pair.fault.store(3, std::sync::atomic::Ordering::SeqCst);
    pair.wait(|| pair.fault.load(std::sync::atomic::Ordering::SeqCst) == 4)
        .await;
    let owner = endpoint(&pair.endpoints[1]).unwrap();
    let control = owner.runtime.as_ref().unwrap().usb.as_ref().unwrap();
    let outcome = {
        let mut locked = owner.owner.lock().unwrap();
        let super::super::runtime::Owner::Usb(usb) = &mut *locked else {
            panic!("same production USB owner");
        };
        // Exercise the actual transport detach transition on the real installed
        // Driver while preventing the runtime from racing this single advance.
        usb.driver.disconnect();
        usb.advance_for_test(control)
    };
    assert_eq!(
        outcome,
        Err(ReadError::Disconnected),
        "detached owner must not await a future SAF receipt"
    );
    pair.wait(|| usb_view(&pair.endpoints[1]).unwrap().closed)
        .await;
    local_command(&pair.endpoints[1], |driver| driver.check_external_commit())
        .await
        .unwrap();
    local_command(&pair.endpoints[1], |driver| driver.external_step())
        .await
        .unwrap();
    local_command(&pair.endpoints[1], move |driver| {
        driver.finalize_accounts(external)
    })
    .await
    .unwrap();
    assert_eq!(
        journal(&pair.libraries[1], &operation)
            .unwrap()
            .unwrap()
            .stage,
        "finalized"
    );
}

async fn usb_failure_keeps_local_commands(fault: u8) {
    let _serial = owner_test_tools::SERIAL.lock().await;
    let pair = Pair::usb();
    let (external, operation) = pair.account_pending().await;
    pair.fault.store(fault, std::sync::atomic::Ordering::SeqCst);
    pair.wait(|| usb_view(&pair.endpoints[1]).unwrap().closed)
        .await;
    let closed = usb_view(&pair.endpoints[1]).unwrap();
    assert!(closed.error.is_some());
    assert_eq!(
        closed.reason,
        Some(super::super::usb::UsbCloseReason::Failure)
    );
    assert_eq!(
        journal(&pair.libraries[1], &operation)
            .unwrap()
            .unwrap()
            .stage,
        "library_applied"
    );
    let checked = local_command(&pair.endpoints[1], |driver| driver.check_external_commit()).await;
    assert!(
        checked.is_ok(),
        "same USB runtime must retain real ExternalCheck: {checked:?}"
    );
    local_command(&pair.endpoints[1], |driver| driver.external_step())
        .await
        .unwrap();
    local_command(&pair.endpoints[1], move |driver| {
        driver.finalize_accounts(external)
    })
    .await
    .unwrap();
    assert_eq!(
        journal(&pair.libraries[1], &operation)
            .unwrap()
            .unwrap()
            .stage,
        "finalized"
    );
    // The command reply precedes the owner's nonblocking status publication.
    pair.wait(|| status(&pair.endpoints[1]).unwrap().state == "Completed")
        .await;
    assert_eq!(status(&pair.endpoints[1]).unwrap().state, "Completed");
    assert!(!owner_test_tools::runtime_api(&pair.libraries[1])
        .database()
        .device_sync_recovery_pending());
    assert!(usb_next(&pair.endpoints[1]).await.unwrap().is_none());
}

#[tokio::test]
async fn runtime_local_native_child_io_failure_keeps_real_local_owner_and_finalize() {
    let _serial = owner_test_tools::SERIAL.lock().await;
    let pair = Pair::native();
    let (external, operation) = pair.account_pending().await;
    std::fs::write(
        pair.native_root
            .as_ref()
            .unwrap()
            .path()
            .join("fail-native"),
        b"synthetic failure",
    )
    .unwrap();
    pair.wait(|| usb_view(&pair.endpoints[0]).unwrap().closed)
        .await;
    let view = usb_view(&pair.endpoints[0]).unwrap();
    assert_eq!(view.error, Some(ReadError::Disconnected));
    assert_eq!(
        view.reason,
        Some(super::super::usb::UsbCloseReason::Failure)
    );
    local_command(&pair.endpoints[0], |driver| driver.check_external_commit())
        .await
        .unwrap();
    local_command(&pair.endpoints[0], |driver| driver.external_step())
        .await
        .unwrap();
    local_command(&pair.endpoints[0], move |driver| {
        driver.finalize_accounts(external)
    })
    .await
    .unwrap();
    assert_eq!(
        journal(&pair.libraries[0], &operation)
            .unwrap()
            .unwrap()
            .stage,
        "finalized"
    );
    pair.wait(|| status(&pair.endpoints[0]).unwrap().state == "Completed")
        .await;
    assert_eq!(status(&pair.endpoints[0]).unwrap().state, "Completed");
    tokio::time::timeout(Duration::from_secs(1), shutdown_async(&pair.endpoints[0]))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(status(&pair.endpoints[0]).unwrap().state, "Completed");
}

#[tokio::test]
async fn runtime_local_queue_ttl_is_known_unexecuted_and_does_not_renew_admission() {
    let _serial = owner_test_tools::SERIAL.lock().await;
    let pair = Pair::tcp();
    pair.wait(|| {
        read_endpoint(&pair.endpoints[1])
            .value
            .is_some_and(|view| view.pairing == PairingStage::AwaitingConfirmation)
    })
    .await;
    let (entered, observed) = std::sync::mpsc::sync_channel(1);
    let (release, paused) = std::sync::mpsc::sync_channel(1);
    let handle = pair.endpoints[1].clone();
    let blocking = tokio::spawn(async move {
        command(&handle, move |_| {
            entered.send(()).unwrap();
            paused.recv_timeout(Duration::from_secs(10)).unwrap();
            Ok(())
        })
        .await
    });
    tokio::task::yield_now().await;
    observed.recv_timeout(Duration::from_secs(3)).unwrap();
    let executed = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let observed_execution = executed.clone();
    let handle = pair.endpoints[1].clone();
    let expiring = tokio::spawn(async move {
        command(&handle, move |_| {
            observed_execution.store(true, std::sync::atomic::Ordering::SeqCst);
            Ok(())
        })
        .await
    });
    tokio::task::yield_now().await;
    tokio::time::sleep(Duration::from_millis(5100)).await;
    release.send(()).unwrap();
    blocking.await.unwrap().unwrap();
    let error = expiring.await.unwrap().unwrap_err();
    assert_eq!(error.code, ReadError::Busy);
    assert!(!error.executed);
    assert!(!executed.load(std::sync::atomic::Ordering::SeqCst));
}

impl Drop for Pair {
    fn drop(&mut self) {
        if let Some(io) = &self.io {
            io.abort();
        }
        for handle in &self.endpoints {
            let _ = cancel_signal(handle);
        }
        for handle in &self.endpoints {
            let _ = close_endpoint(handle);
        }
        for handle in &self.libraries {
            let _ = close_library(handle);
        }
    }
}

#[tokio::test]
async fn runtime_local_tcp_eof_during_prepared_keeps_original_binding_work_and_commands() {
    let _serial = owner_test_tools::SERIAL.lock().await;
    let pair = Pair::tcp();
    let entered = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let resume = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let observing = entered.clone();
    let releasing = resume.clone();
    command(&pair.endpoints[1], move |driver| {
        driver.set_apply_observer(Arc::new(move |boundary| {
            if boundary == super::super::receiver::ApplyBoundary::Prepared {
                observing.store(true, std::sync::atomic::Ordering::SeqCst);
                let until = Instant::now() + Duration::from_secs(10);
                while !releasing.load(std::sync::atomic::Ordering::SeqCst) {
                    assert!(Instant::now() < until);
                    std::thread::sleep(Duration::from_millis(1));
                }
            }
        }))
    })
    .await
    .unwrap();
    let external = pair.approve_accounts().await;
    pair.wait(|| entered.load(std::sync::atomic::Ordering::SeqCst))
        .await;
    let local_status = status(&pair.endpoints[1]).unwrap();
    let source_status = status(&pair.endpoints[0]).unwrap();
    assert!(local_status.local_apply_installed);
    assert!(local_status.operation.is_some());
    assert!(!local_status.source_grant_issued);
    assert!(source_status.source_grant_issued);
    assert!(!source_status.local_apply_installed);
    command(&pair.endpoints[0], |driver| {
        driver.disconnect();
        Ok(())
    })
    .await
    .unwrap();
    pair.wait(|| {
        read_endpoint(&pair.endpoints[1])
            .tcp
            .is_some_and(|tcp| tcp.phase == TcpPhase::Closed)
    })
    .await;
    // Release before any assertion can unwind/drop while the worker is paused.
    resume.store(true, std::sync::atomic::Ordering::SeqCst);
    pair.wait(|| status(&pair.endpoints[1]).unwrap().state == "AwaitingExternal")
        .await;
    local_command(&pair.endpoints[1], |driver| driver.check_external_commit())
        .await
        .unwrap();
    local_command(&pair.endpoints[1], |driver| driver.external_step())
        .await
        .unwrap();
    local_command(&pair.endpoints[1], move |driver| {
        driver.finalize_accounts(external)
    })
    .await
    .unwrap();
    let operation = status(&pair.endpoints[1]).unwrap().operation.unwrap();
    assert_eq!(
        journal(&pair.libraries[1], &operation)
            .unwrap()
            .unwrap()
            .stage,
        "finalized"
    );
}

#[tokio::test]
async fn runtime_local_shutdown_settles_native_not_future_coordinator_and_keeps_reads() {
    let _serial = owner_test_tools::SERIAL.lock().await;
    let pair = Pair::tcp();
    let (external, operation) = pair.account_pending().await;
    // No future advance/finalize is dispatched. Native shutdown must return
    // with the genuine unresolved journal available for the original coordinator.
    for _ in 0..3 {
        tokio::time::timeout(Duration::from_secs(1), shutdown_async(&pair.endpoints[1]))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(status(&pair.endpoints[1]).unwrap().state, "RecoveryPending");
        assert_eq!(
            journal(&pair.libraries[1], &operation)
                .unwrap()
                .unwrap()
                .stage,
            "library_applied"
        );
    }
    for result in [
        local_command(&pair.endpoints[1], |driver| driver.check_external_commit()).await,
        local_command(&pair.endpoints[1], |driver| driver.external_step()).await,
        local_command(&pair.endpoints[1], move |driver| {
            driver.finalize_accounts(external)
        })
        .await,
    ] {
        let error = result.unwrap_err();
        assert_eq!(error.code, ReadError::Cancelled);
        assert!(!error.executed, "cancelled writes never enter their action");
    }
    // Settlement keeps the owner available to the original coordinator.
    // Its publication may briefly hold the lock used by the nonblocking reader.
    // Exercise that legitimate Busy result deterministically, then still require
    // a real snapshot before compensating or retiring the endpoint.
    let mut observed = {
        let owner = endpoint(&pair.endpoints[1]).unwrap();
        let _publication = owner.owner.lock().unwrap();
        let observed = read_endpoint(&pair.endpoints[1]);
        assert_eq!(observed.error, Some(ReadError::Busy));
        assert!(observed.value.is_none());
        observed
    };
    let read_until = Instant::now() + Duration::from_secs(10);
    while observed.error == Some(ReadError::Busy) {
        assert!(
            Instant::now() < read_until,
            "settled endpoint remained busy before compensation"
        );
        tokio::time::sleep(Duration::from_millis(2)).await;
        observed = read_endpoint(&pair.endpoints[1]);
    }
    assert!(observed.error.is_none(), "{observed:?}");
    assert!(observed.value.is_some());
    assert_eq!(
        compensate(&pair.libraries[1], &operation).unwrap().stage,
        "rolled_back"
    );
    close_endpoint_async(&pair.endpoints[1]).await.unwrap();
    assert!(status(&pair.endpoints[1]).is_err());
}

#[tokio::test]
async fn runtime_local_signal_uses_installed_lifecycle_without_waiting_for_owner() {
    use std::sync::atomic::{AtomicBool, Ordering};
    let _serial = owner_test_tools::SERIAL.lock().await;
    let pair = Pair::tcp();
    let entered = Arc::new(AtomicBool::new(false));
    let resume = Arc::new(AtomicBool::new(false));
    let observing = entered.clone();
    let releasing = resume.clone();
    command(&pair.endpoints[1], move |driver| {
        driver.set_apply_observer(Arc::new(move |boundary| {
            if boundary == super::super::receiver::ApplyBoundary::Prepared {
                observing.store(true, Ordering::SeqCst);
                let until = Instant::now() + Duration::from_secs(10);
                while !releasing.load(Ordering::SeqCst) {
                    assert!(Instant::now() < until);
                    std::thread::sleep(Duration::from_millis(1));
                }
            }
        }))
    })
    .await
    .unwrap();
    pair.approve_accounts().await;
    pair.wait(|| entered.load(Ordering::SeqCst)).await;
    let endpoint_owner = endpoint(&pair.endpoints[1]).unwrap();
    {
        let owner = endpoint_owner.owner.lock().unwrap();
        assert!(Arc::ptr_eq(
            &endpoint_owner.lifecycle,
            &owner.driver().lifecycle_control()
        ));
    }
    let (blocked, observed) = std::sync::mpsc::sync_channel(1);
    let (release, paused) = std::sync::mpsc::sync_channel(1);
    let handle = pair.endpoints[1].clone();
    let held = tokio::spawn(async move {
        command(&handle, move |_| {
            blocked.send(()).unwrap();
            paused.recv_timeout(Duration::from_secs(10)).unwrap();
            Ok(())
        })
        .await
    });
    tokio::task::yield_now().await;
    observed.recv_timeout(Duration::from_secs(3)).unwrap();
    let began = Instant::now();
    cancel_signal(&pair.endpoints[1]).unwrap();
    let elapsed = began.elapsed();
    release.send(()).unwrap();
    resume.store(true, Ordering::SeqCst);
    held.await.unwrap().unwrap();
    assert!(elapsed < Duration::from_millis(100));
    tokio::time::timeout(Duration::from_secs(2), shutdown_async(&pair.endpoints[1]))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(status(&pair.endpoints[1]).unwrap().state, "Cancelled");
    assert!(owner_test_tools::runtime_api(&pair.libraries[1])
        .database()
        .device_sync_pending_journal()
        .unwrap()
        .is_none());
    assert!(!owner_test_tools::runtime_api(&pair.libraries[1])
        .database()
        .device_sync_recovery_pending());
    // Settlement does not retire the runtime owner. Its next publication may
    // briefly hold the mutex used by this intentionally nonblocking reader.
    let read_until = Instant::now() + Duration::from_secs(10);
    let observed = loop {
        let observed = read_endpoint(&pair.endpoints[1]);
        if observed.error != Some(ReadError::Busy) {
            break observed;
        }
        assert!(
            Instant::now() < read_until,
            "cancelled endpoint remained busy after shutdown"
        );
        tokio::time::sleep(Duration::from_millis(2)).await;
    };
    assert!(observed.error.is_none(), "{observed:?}");
    assert!(observed.value.is_some());
}

#[tokio::test]
async fn runtime_local_detach_rejects_network_commands_without_executing_them() {
    let _serial = owner_test_tools::SERIAL.lock().await;
    let pair = Pair::tcp();
    let (_, operation) = pair.account_pending().await;
    command(&pair.endpoints[0], |driver| {
        driver.disconnect();
        Ok(())
    })
    .await
    .unwrap();
    pair.wait(|| {
        read_endpoint(&pair.endpoints[1])
            .tcp
            .is_some_and(|view| view.phase == TcpPhase::Closed)
    })
    .await;
    let called = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let action_called = called.clone();
    let rejected = command(&pair.endpoints[1], move |_| {
        action_called.store(true, std::sync::atomic::Ordering::SeqCst);
        Ok(())
    })
    .await
    .unwrap_err();
    assert_eq!(rejected.code, ReadError::Disconnected);
    assert!(!rejected.executed);
    assert!(!called.load(std::sync::atomic::Ordering::SeqCst));
    local_command(&pair.endpoints[1], |driver| driver.check_external_commit())
        .await
        .unwrap();
    assert_eq!(
        journal(&pair.libraries[1], &operation)
            .unwrap()
            .unwrap()
            .stage,
        "library_applied"
    );
}

#[tokio::test]
async fn runtime_local_tcp_eof_keeps_real_external_commands_and_finalized_journal() {
    let _serial = owner_test_tools::SERIAL.lock().await;
    let pair = Pair::tcp();
    owner_test_tools::runtime_api(&pair.libraries[0])
        .create_tag("real incoming metadata".into())
        .unwrap();
    let (external, operation) = pair.account_pending().await;
    command(&pair.endpoints[0], |driver| {
        // Real peer socket EOF, not a manufactured target transport flag.
        driver.disconnect();
        Ok(())
    })
    .await
    .unwrap();
    pair.wait(|| {
        read_endpoint(&pair.endpoints[1])
            .tcp
            .is_some_and(|view| view.phase == TcpPhase::Closed)
    })
    .await;
    assert_eq!(
        journal(&pair.libraries[1], &operation)
            .unwrap()
            .unwrap()
            .stage,
        "library_applied"
    );
    let checked = local_command(&pair.endpoints[1], |driver| driver.check_external_commit()).await;
    assert!(
        checked.is_ok(),
        "real ExternalCheck must still execute after peer EOF: {checked:?}"
    );
    // Managed commands return independently of the owner's next publication.
    // A real nonblocking read may be Busy while that owner is still polling.
    // Retry only that documented transient; keep every substantive error.
    let read_until = Instant::now() + Duration::from_secs(10);
    let observed = loop {
        let observed = read_endpoint(&pair.endpoints[1]);
        if observed.error != Some(ReadError::Busy) {
            break observed;
        }
        assert!(
            Instant::now() < read_until,
            "local read remained busy after EOF"
        );
        tokio::time::sleep(Duration::from_millis(2)).await;
    };
    assert!(
        observed.error.is_none(),
        "transport error must not hide the local read model"
    );
    assert!(observed.tcp.unwrap().error.is_some());
    let local = observed.value.unwrap();
    assert!(local.local_apply_installed && local.transport_detached);
    assert!(!local.source_grant_issued);
    assert_eq!(local.stage, super::super::driver::State::AwaitingExternal);
    local_command(&pair.endpoints[1], |driver| driver.external_step())
        .await
        .unwrap();
    local_command(&pair.endpoints[1], move |driver| {
        driver.finalize_accounts(external)
    })
    .await
    .unwrap();
    assert_eq!(
        journal(&pair.libraries[1], &operation)
            .unwrap()
            .unwrap()
            .stage,
        "finalized"
    );
    pair.wait(|| {
        status(&pair.endpoints[1]).unwrap().state == "Completed"
            && status(&pair.endpoints[0]).unwrap().state == "CompletedUnconfirmed"
    })
    .await;
    assert_eq!(status(&pair.endpoints[1]).unwrap().state, "Completed");
    assert_eq!(
        status(&pair.endpoints[0]).unwrap().state,
        "CompletedUnconfirmed"
    );
}
