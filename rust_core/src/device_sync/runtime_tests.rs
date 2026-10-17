use crate::device_sync::{
    driver::Direction,
    headless,
    planner::SyncMode,
    read_model::{PairingStage, ReadError},
    runtime::TcpPhase,
    Qr, Transport,
};
use crate::models::GalleryQuery;
use sha2::{Digest, Sha256};
use std::net::{TcpListener, TcpStream};
use std::time::{Duration, Instant};

use crate::device_sync::headless::owner_test_tools::SERIAL;

#[test]
fn managed_endpoint_really_keeps_bound_listener_until_cancel() {
    let _serial = SERIAL.blocking_lock();
    let root = tempfile::tempdir().unwrap();
    let library = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let host = headless::host_bound(&library.handle, "Desktop", listener).unwrap();
    let qr = Qr::parse(&host.invitation, chrono::Utc::now().timestamp()).unwrap();
    assert_eq!(qr.transport(), &Transport::Tcp(address));
    let connection = TcpStream::connect_timeout(&address, Duration::from_millis(250));
    headless::close_endpoint(&host.handle).unwrap();
    headless::close_library(&library.handle).unwrap();
    assert!(
        connection.is_ok(),
        "the new managed endpoint must own a real listener, not just encode its address"
    );
}

#[test]
fn manual_endpoint_final_status_survives_library_close_until_explicit_endpoint_retirement() {
    let _serial = SERIAL.blocking_lock();
    let root = tempfile::tempdir().unwrap();
    let library = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    let host = headless::host(&library.handle, "Manual USB", None).unwrap();
    headless::shutdown(&host.handle).unwrap();
    headless::close_library(&library.handle).unwrap();
    let status = headless::status(&host.handle);
    assert!(status.is_ok(), "old manual account coordinator must still observe its stopped endpoint after the library registry entry closes");
    assert!(status.unwrap().terminal);
    headless::close_endpoint(&host.handle).unwrap();
}

struct Pair {
    roots: [tempfile::TempDir; 2],
    libraries: [String; 2],
    endpoints: [String; 2],
    address: std::net::SocketAddr,
}
impl Pair {
    fn new() -> Self {
        Self::with_invitation(|_| {})
    }
    fn with_invitation(edit: impl FnOnce(&mut serde_json::Value)) -> Self {
        let roots = [tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap()];
        let libraries = roots.each_ref().map(|root| {
            headless::open(root.path().to_string_lossy().into_owned())
                .unwrap()
                .handle
        });
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let host = headless::host_bound(&libraries[0], "Desktop", listener).unwrap();
        let mut invitation: serde_json::Value = serde_json::from_str(&host.invitation).unwrap();
        edit(&mut invitation);
        let phone = headless::client_tcp_test(
            &libraries[1],
            &serde_json::to_string(&invitation).unwrap(),
            "Phone",
        )
        .unwrap();
        Self {
            roots,
            libraries,
            endpoints: [host.handle, phone],
            address,
        }
    }
    fn api(&self, index: usize) -> std::sync::Arc<crate::api::CoreApi> {
        headless::owner_test_tools::runtime_api(&self.libraries[index])
    }
    async fn wait(&self, predicate: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(15);
        while !predicate() {
            assert!(
                Instant::now() < deadline,
                "runtime did not reach expected state: {:?} {:?}",
                headless::status(&self.endpoints[0]),
                headless::status(&self.endpoints[1])
            );
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    }
    async fn confirm(&self) {
        self.wait(|| {
            self.endpoints.iter().all(|endpoint| {
                headless::read_endpoint(endpoint)
                    .value
                    .is_some_and(|v| v.pairing == PairingStage::AwaitingConfirmation)
            })
        })
        .await;
        let a = headless::command(&self.endpoints[0], |d| d.confirmation_code())
            .await
            .unwrap();
        let b = headless::command(&self.endpoints[1], |d| d.confirmation_code())
            .await
            .unwrap();
        assert_eq!(a, b);
        for endpoint in &self.endpoints {
            headless::command(endpoint, |d| d.confirm_pairing())
                .await
                .unwrap();
        }
        self.wait(|| {
            self.endpoints.iter().all(|endpoint| {
                headless::read_endpoint(endpoint)
                    .value
                    .is_some_and(|v| v.pairing == PairingStage::Confirmed)
            })
        })
        .await;
    }
    async fn account_pending(&self) -> (uuid::Uuid, String) {
        self.confirm().await;
        headless::command(&self.endpoints[0], |d| d.authorize_accounts_export(
            br#"{"version":1,"accounts":[{"account_id":"synthetic","nickname":"","session_token":"synthetic-only"}]}"#,
            &"a".repeat(64),
        )).await.unwrap();
        headless::command(&self.endpoints[1], |d| {
            d.authorize_accounts_receive(&"b".repeat(64))
        })
        .await
        .unwrap();
        headless::command(&self.endpoints[0], |d| {
            d.configure(Direction::DesktopToPhone, SyncMode::Overwrite, true)
        })
        .await
        .unwrap();
        self.wait(|| headless::status(&self.endpoints[1]).unwrap().state == "AwaitingApproval")
            .await;
        let binding = headless::status(&self.endpoints[1])
            .unwrap()
            .binding
            .unwrap();
        let external = uuid::Uuid::new_v4();
        headless::command(&self.endpoints[1], move |d| {
            d.approve_accounts_preview(&binding, &"b".repeat(64), external)
        })
        .await
        .unwrap();
        self.wait(|| {
            headless::status(&self.endpoints[1]).unwrap().state == "AwaitingTargetAccountFinal"
        })
        .await;
        headless::command(&self.endpoints[1], |d| {
            d.approve_accounts_target_final(&"b".repeat(64))
        })
        .await
        .unwrap();
        self.wait(|| headless::status(&self.endpoints[0]).unwrap().state == "AwaitingAccountFinal")
            .await;
        headless::command(&self.endpoints[0], |d| {
            d.approve_accounts_final(&"a".repeat(64))
        })
        .await
        .unwrap();
        self.wait(|| headless::status(&self.endpoints[1]).unwrap().state == "AwaitingExternal")
            .await;
        (
            external,
            headless::status(&self.endpoints[1])
                .unwrap()
                .operation
                .unwrap(),
        )
    }
}
impl Drop for Pair {
    fn drop(&mut self) {
        for endpoint in &self.endpoints {
            let _ = headless::cancel_signal(endpoint);
        }
        for endpoint in &self.endpoints {
            let _ = headless::close_endpoint(endpoint);
        }
        for library in &self.libraries {
            let _ = headless::close_library(library);
        }
    }
}

#[tokio::test]
async fn managed_tcp_both_directions_modes_real_media_sql_preview_and_success_eof() {
    let _serial = SERIAL.lock().await;
    for phone_to_desktop in [false, true] {
        for overwrite in [false, true] {
            let pair = Pair::new();
            let source_index = usize::from(phone_to_desktop);
            let target_index = 1 - source_index;
            let source = pair.api(source_index);
            let target = pair.api(target_index);
            source.create_tag("incoming catalog".into()).unwrap();
            target.create_tag("target catalog".into()).unwrap();
            let bytes = vec![0x53; 1024 * 1024 + 37];
            let input = pair.roots[source_index].path().join("large.jpg");
            std::fs::write(&input, &bytes).unwrap();
            source
                .import_local_files(vec![input.to_string_lossy().into_owned()])
                .await
                .unwrap();
            let sha = hex::encode(Sha256::digest(&bytes));
            let generation = target.database().device_sync_header().unwrap().generation;
            assert!(headless::drain(&pair.endpoints[0]).is_err());
            assert!(headless::ingest(&pair.endpoints[0], b"not a peer").is_err());
            assert!(headless::written(&pair.endpoints[0], 1).is_err());
            assert!(headless::finish_success(&pair.endpoints[0]).is_err());
            assert!(headless::tick(&pair.endpoints[0]).is_err());
            pair.confirm().await;
            assert!(
                TcpStream::connect_timeout(&pair.address, Duration::from_millis(100)).is_err(),
                "the accepted invitation listener cannot accept a second client"
            );
            headless::command(&pair.endpoints[0], move |d| {
                d.configure(
                    if phone_to_desktop {
                        Direction::PhoneToDesktop
                    } else {
                        Direction::DesktopToPhone
                    },
                    if overwrite {
                        SyncMode::Overwrite
                    } else {
                        SyncMode::Merge
                    },
                    false,
                )
            })
            .await
            .unwrap();
            pair.wait(|| {
                pair.endpoints
                    .iter()
                    .all(|e| headless::status(e).unwrap().state == "AwaitingApproval")
            })
            .await;
            let preview = loop {
                let read = headless::read_preview(&pair.endpoints[target_index]);
                if let Some(value) = read.value {
                    break value;
                }
                assert_eq!(read.error, Some(ReadError::Busy), "{read:?}");
                tokio::time::sleep(Duration::from_millis(2)).await;
            };
            assert_eq!(preview.media.added, 1);
            tokio::time::sleep(Duration::from_millis(30)).await;
            assert_eq!(
                target.database().device_sync_header().unwrap().generation,
                generation
            );
            assert!(target
                .list_media(GalleryQuery::default())
                .unwrap()
                .is_empty());
            headless::command(&pair.endpoints[target_index], |d| d.approve_preview())
                .await
                .unwrap();
            pair.wait(|| {
                pair.endpoints.iter().all(|e| {
                    headless::read_endpoint(e)
                        .tcp
                        .is_some_and(|tcp| tcp.phase == TcpPhase::Closed)
                })
            })
            .await;
            for endpoint in &pair.endpoints {
                assert_eq!(headless::status(endpoint).unwrap().state, "Completed");
                assert!(!headless::status(endpoint).unwrap().cleanup_pending);
            }
            let media = target.list_media(GalleryQuery::default()).unwrap();
            assert_eq!(media.len(), 1);
            assert_eq!(media[0].sha256, sha);
            assert_eq!(std::fs::read(&media[0].storage_path).unwrap(), bytes);
            assert!(target
                .list_tags()
                .unwrap()
                .contains(&"incoming catalog".into()));
            assert_eq!(
                target
                    .list_tags()
                    .unwrap()
                    .contains(&"target catalog".into()),
                !overwrite
            );
            assert!(target
                .database()
                .device_sync_pending_journal()
                .unwrap()
                .is_none());
            // Rebinding proves the listener handle has been released while the endpoint remains registered.
            TcpListener::bind(pair.address).unwrap();
        }
    }
}

#[tokio::test]
async fn managed_tcp_mid_scan_queue_pressure_keeps_status_and_cancel_reachable() {
    let _serial = SERIAL.lock().await;
    let pair = Pair::new();
    let api = pair.api(0);
    for index in 0..1024 {
        api.create_tag(format!("scan-{index:04}")).unwrap();
    }
    let database = api.database();
    let generation = database.device_sync_header().unwrap().generation;
    let (reached, entered) = std::sync::mpsc::sync_channel(1);
    let (release, released) = std::sync::mpsc::sync_channel(1);
    let mut count = 0;
    database.connection.lock().unwrap().authorizer(Some(
        move |context: rusqlite::hooks::AuthContext<'_>| {
            if matches!(
                context.action,
                rusqlite::hooks::AuthAction::Read {
                    table_name: "sync_tag_state",
                    column_name: "name"
                }
            ) {
                count += 1;
                if count == 129 {
                    reached.send(()).unwrap();
                    released.recv_timeout(Duration::from_secs(10)).unwrap();
                }
            }
            rusqlite::hooks::Authorization::Allow
        },
    ));
    pair.confirm().await;
    headless::command(&pair.endpoints[0], |d| {
        d.configure(Direction::DesktopToPhone, SyncMode::Merge, false)
    })
    .await
    .unwrap();
    entered.recv_timeout(Duration::from_secs(10)).unwrap();
    let mut commands = Vec::new();
    for _ in 0..24 {
        let endpoint = pair.endpoints[0].clone();
        commands.push(tokio::spawn(async move {
            headless::command(&endpoint, |_| Ok(())).await
        }));
    }
    tokio::task::yield_now().await;
    for _ in 0..1000 {
        assert!(!headless::status(&pair.endpoints[0]).unwrap().terminal);
        let read = headless::read_endpoint(&pair.endpoints[0]);
        assert_eq!(read.error, Some(ReadError::Busy));
        assert!(read.progress.work_active);
        assert!(read.progress.scanned_items >= 128);
        assert_eq!(read.tcp.unwrap().phase, TcpPhase::Connected);
    }
    let started = Instant::now();
    headless::cancel_signal(&pair.endpoints[0]).unwrap();
    assert!(started.elapsed() < Duration::from_millis(100));
    release.send(()).unwrap();
    let mut busy = 0;
    for command in commands {
        let error = command.await.unwrap().unwrap_err();
        assert!(!error.executed);
        assert!(matches!(error.code, ReadError::Busy | ReadError::Cancelled));
        busy += usize::from(error.code == ReadError::Busy);
    }
    assert!(busy >= 8, "at most 16 commands/results may be admitted");
    headless::shutdown_async(&pair.endpoints[0]).await.unwrap();
    database
        .connection
        .lock()
        .unwrap()
        .authorizer(None::<fn(rusqlite::hooks::AuthContext<'_>) -> rusqlite::hooks::Authorization>);
    assert_eq!(
        headless::status(&pair.endpoints[0]).unwrap().state,
        "Cancelled"
    );
    assert_eq!(
        database.device_sync_header().unwrap().generation,
        generation
    );
    assert!(database.device_sync_pending_journal().unwrap().is_none());
    api.create_tag("write-after-cancel".into()).unwrap();
}

#[test]
fn managed_tcp_product_rejects_non_lan_and_close_library_cancels_listener() {
    let _serial = SERIAL.blocking_lock();
    let root = tempfile::tempdir().unwrap();
    let library = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    for address in [
        "127.0.0.1:0",
        "0.0.0.0:0",
        "8.8.8.8:12345",
        "224.0.0.1:12345",
        "[::1]:0",
        "[::]:0",
        "[ff02::1]:12345",
        "192.168.254.254:0",
    ] {
        assert!(headless::host_tcp(&library.handle, "Desktop", address).is_err());
    }
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let host = headless::host_bound(&library.handle, "Desktop", listener).unwrap();
    assert_eq!(
        headless::read_endpoint(&host.handle).tcp.unwrap().phase,
        TcpPhase::Listening
    );
    headless::close_library(&library.handle).unwrap();
    assert!(headless::status(&host.handle).is_err());
    TcpListener::bind(address).unwrap();
}

#[tokio::test]
async fn managed_tcp_bad_certificate_secret_and_peer_eof_close_without_retry_or_library_write() {
    let _serial = SERIAL.lock().await;
    for field in ["fingerprint", "secret"] {
        let pair = Pair::with_invitation(|qr| {
            let mut value = qr[field].as_str().unwrap().as_bytes().to_vec();
            value[0] = if value[0] == b'a' { b'b' } else { b'a' };
            qr[field] = String::from_utf8(value).unwrap().into();
        });
        pair.wait(|| {
            pair.endpoints
                .iter()
                .all(|e| headless::read_endpoint(e).tcp.unwrap().phase == TcpPhase::Closed)
        })
        .await;
        for (index, endpoint) in pair.endpoints.iter().enumerate() {
            assert!(headless::status(endpoint).unwrap().terminal);
            assert!(pair
                .api(index)
                .database()
                .device_sync_pending_journal()
                .unwrap()
                .is_none());
            assert!(pair
                .api(index)
                .list_media(GalleryQuery::default())
                .unwrap()
                .is_empty());
        }
        assert!(TcpStream::connect_timeout(&pair.address, Duration::from_millis(100)).is_err());
    }
    let root = tempfile::tempdir().unwrap();
    let library = headless::open(root.path().to_string_lossy().into_owned()).unwrap();
    for invalid in [false, true] {
        use std::io::{Read, Write};
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let host = headless::host_bound(&library.handle, "Desktop", listener).unwrap();
        let mut raw = TcpStream::connect(address).unwrap();
        raw.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let accepted = Instant::now() + Duration::from_secs(3);
        while headless::read_endpoint(&host.handle).tcp.unwrap().phase != TcpPhase::Connected {
            assert!(Instant::now() < accepted);
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
        if invalid {
            raw.write_all(b"invalid TLS record").unwrap();
            let limit = Instant::now() + Duration::from_secs(3);
            while headless::read_endpoint(&host.handle).tcp.unwrap().phase != TcpPhase::Closed {
                assert!(Instant::now() < limit);
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        } else {
            headless::cancel_signal(&host.handle).unwrap();
        }
        headless::shutdown_async(&host.handle).await.unwrap();
        match raw.read(&mut [0]) {
            Ok(0) => {}
            Err(error) if invalid && error.kind() == std::io::ErrorKind::ConnectionReset => {}
            other => panic!("closed real peer must observe EOF/reset, got {other:?}"),
        }
        assert!(TcpStream::connect_timeout(&address, Duration::from_millis(100)).is_err());
        let replay =
            headless::client_tcp_test(&library.handle, &host.invitation, "Replay").unwrap();
        let limit = Instant::now() + Duration::from_secs(3);
        while headless::read_endpoint(&replay).tcp.unwrap().phase != TcpPhase::Closed {
            assert!(Instant::now() < limit);
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
        headless::close_endpoint(&host.handle).unwrap();
        headless::close_endpoint(&replay).unwrap();
    }
    headless::close_library(&library.handle).unwrap();
}

#[tokio::test]
async fn managed_tcp_library_close_rejects_concurrent_admission_and_second_close() {
    let _serial = SERIAL.lock().await;
    let pair = Pair::new();
    pair.confirm().await;
    let (reached, entered) = std::sync::mpsc::sync_channel(1);
    let (release, released) = std::sync::mpsc::sync_channel(1);
    let endpoint = pair.endpoints[0].clone();
    let blocked = tokio::spawn(async move {
        headless::command(&endpoint, move |_| {
            reached.send(()).unwrap();
            released.recv_timeout(Duration::from_secs(5)).unwrap();
            Ok(())
        })
        .await
    });
    tokio::task::yield_now().await;
    entered.recv_timeout(Duration::from_secs(5)).unwrap();
    let library = pair.libraries[0].clone();
    let closing = tokio::spawn(async move { headless::close_library_async(&library).await });
    tokio::task::yield_now().await;
    for _ in 0..2 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        assert!(headless::host_bound(&pair.libraries[0], "Late Desktop", listener).is_err());
        TcpListener::bind(address).unwrap();
        assert!(
            headless::close_library_async(&pair.libraries[0])
                .await
                .is_err(),
            "a second close cannot own or remove the first close marker"
        );
    }
    release.send(()).unwrap();
    blocked.await.unwrap().unwrap();
    closing.await.unwrap().unwrap();
    assert!(headless::library_info(&pair.libraries[0]).is_err());
    assert!(headless::status(&pair.endpoints[0]).is_err());
    assert!(headless::host(&pair.libraries[0], "Stale handle", None).is_err());
}

#[tokio::test]
async fn managed_tcp_cancelled_account_pending_retains_source_lease_until_real_expiry() {
    let _serial = SERIAL.lock().await;
    let pair = Pair::new();
    let source = pair.api(0);
    source.create_tag("incoming".into()).unwrap();
    let target = pair.api(1);
    target.create_tag("old target".into()).unwrap();
    let (_, operation) = pair.account_pending().await;
    assert!(target.database().device_sync_recovery_pending());
    headless::shutdown_async(&pair.endpoints[0]).await.unwrap();
    headless::shutdown_async(&pair.endpoints[1]).await.unwrap();
    assert_eq!(
        headless::status(&pair.endpoints[0]).unwrap().state,
        "CompletedUnconfirmed"
    );
    assert_eq!(
        headless::status(&pair.endpoints[1]).unwrap().state,
        "RecoveryPending"
    );
    assert!(
        headless::status(&pair.endpoints[0])
            .unwrap()
            .cleanup_pending
    );
    assert!(source.create_tag("must-stay-locked".into()).is_err());
    assert!(
        headless::close_library(&pair.libraries[0]).is_err(),
        "closing a library cannot abandon an issued lease"
    );
    assert!(headless::library_info(&pair.libraries[0]).is_ok());
    assert!(source.create_tag("still-locked".into()).is_err());
    headless::compensate(&pair.libraries[1], &operation).unwrap();
    assert_eq!(target.list_tags().unwrap(), ["old target"]);
    let deadline = Instant::now() + Duration::from_secs(32);
    while headless::status(&pair.endpoints[0])
        .unwrap()
        .cleanup_pending
    {
        assert!(
            Instant::now() < deadline,
            "closed runtime status must refresh the original cleanup lease"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    source
        .create_tag("write-after-real-lease-expiry".into())
        .unwrap();
}

#[tokio::test]
async fn managed_tcp_lost_final_ack_preserves_real_finalized_commit_and_unconfirmed_source() {
    let _serial = SERIAL.lock().await;
    let pair = Pair::new();
    pair.api(0).create_tag("committed source".into()).unwrap();
    pair.api(1).create_tag("old target".into()).unwrap();
    let (external, operation) = pair.account_pending().await;
    let source = pair.endpoints[0].clone();
    headless::command(&pair.endpoints[1], move |driver| {
        driver.finalize_accounts(external)?;
        // This same owner has not returned to TCP flushing. Close the peer
        // after the actual guarded SQL commit, before any final ACK can drain.
        headless::cancel_signal(&source).unwrap();
        let until = Instant::now() + Duration::from_secs(3);
        while headless::read_endpoint(&source).tcp.unwrap().phase != TcpPhase::Closed {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(2));
        }
        Ok(())
    })
    .await
    .unwrap();
    pair.wait(|| {
        pair.endpoints
            .iter()
            .all(|e| headless::read_endpoint(e).tcp.unwrap().phase == TcpPhase::Closed)
    })
    .await;
    assert_eq!(
        headless::status(&pair.endpoints[0]).unwrap().state,
        "CompletedUnconfirmed"
    );
    assert_eq!(
        headless::status(&pair.endpoints[1]).unwrap().state,
        "Completed"
    );
    let target = pair.api(1);
    assert_eq!(
        headless::journal(&pair.libraries[1], &operation)
            .unwrap()
            .unwrap()
            .stage,
        "finalized"
    );
    assert!(!target.database().device_sync_recovery_pending());
    assert_eq!(target.list_tags().unwrap(), ["committed source"]);
    target
        .create_tag("write-after-finalized-loss".into())
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(32);
    while headless::status(&pair.endpoints[0])
        .unwrap()
        .cleanup_pending
    {
        assert!(Instant::now() < deadline);
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn managed_tcp_mid_transfer_cancel_releases_socket_and_uncommitted_media_only() {
    let _serial = SERIAL.lock().await;
    let pair = Pair::new();
    let source = pair.api(0);
    let target = pair.api(1);
    let input = pair.roots[0].path().join("stream-cancel.jpg");
    std::fs::write(&input, vec![0x61; 4 * 1024 * 1024]).unwrap();
    source
        .import_local_files(vec![input.to_string_lossy().into_owned()])
        .await
        .unwrap();
    let generation = target.database().device_sync_header().unwrap().generation;
    pair.confirm().await;
    headless::command(&pair.endpoints[0], |d| {
        d.configure(Direction::DesktopToPhone, SyncMode::Merge, false)
    })
    .await
    .unwrap();
    pair.wait(|| headless::status(&pair.endpoints[1]).unwrap().state == "AwaitingApproval")
        .await;
    headless::command(&pair.endpoints[1], |d| d.approve_preview())
        .await
        .unwrap();
    pair.wait(|| {
        let read = headless::read_endpoint(&pair.endpoints[0]);
        read.value.is_some_and(|v| {
            v.progress
                .transferred_bytes
                .is_some_and(|n| n > 0 && n < 4 * 1024 * 1024)
        })
    })
    .await;
    headless::cancel_signal(&pair.endpoints[1]).unwrap();
    headless::shutdown_async(&pair.endpoints[1]).await.unwrap();
    pair.wait(|| {
        headless::read_endpoint(&pair.endpoints[0])
            .tcp
            .unwrap()
            .phase
            == TcpPhase::Closed
    })
    .await;
    assert!(target
        .list_media(GalleryQuery::default())
        .unwrap()
        .is_empty());
    assert_eq!(
        target.database().device_sync_header().unwrap().generation,
        generation
    );
    assert!(!target.database().device_sync_recovery_pending());
    assert_eq!(source.list_media(GalleryQuery::default()).unwrap().len(), 1);
    target
        .create_tag("ordinary-write-after-transfer-cancel".into())
        .unwrap();
}
